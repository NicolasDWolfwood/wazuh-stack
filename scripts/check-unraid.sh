#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"
SMOKE_SYSLOG=0
HEALTH_TIMEOUT=180

note() {
  printf '[INFO] %s\n' "$*"
}

pass() {
  printf '[PASS] %s\n' "$*"
}

fail() {
  printf '[FAIL] %s\n' "$*" >&2
  exit 1
}

for arg in "$@"; do
  case "${arg}" in
    --smoke-syslog)
      SMOKE_SYSLOG=1
      ;;
    *)
      fail "Unknown argument: ${arg}"
      ;;
  esac
done

require_env() {
  local key="$1"
  local value
  value="$(awk -F= -v k="$key" '$1 == k {sub($1"=",""); print; exit}' "${ENV_FILE}")"
  if [[ -z "${value}" ]]; then
    fail "Missing ${key} in ${ENV_FILE}"
  fi
  printf '%s' "${value}"
}

optional_env() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k {sub($1"=",""); print; exit}' "${ENV_FILE}"
}

check_container_running() {
  local name="$1"
  local running
  running="$(docker inspect --format '{{.State.Running}}' "${name}" 2>/dev/null || true)"
  [[ "${running}" == "true" ]] || fail "Container ${name} is not running"
  pass "Container ${name} is running"
}

check_status_line() {
  local daemon="$1"
  local output="$2"
  grep -q "^${daemon} is running" <<<"${output}" || fail "${daemon} is not running"
  pass "${daemon} is running"
}

check_mode() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(stat -c '%a' "${path}")"
  [[ "${actual}" == "${expected}" ]] || fail "Expected mode ${expected} on ${path}, found ${actual}"
  pass "${path} has mode ${expected}"
}

check_owner() {
  local path="$1"
  local expected="$2"
  local actual
  actual="$(stat -c '%u:%g' "${path}")"
  [[ "${actual}" == "${expected}" ]] || fail "Expected owner ${expected} on ${path}, found ${actual}"
  pass "${path} has owner ${expected}"
}

wait_for_health() {
  local name="$1"
  local timeout="$2"
  local elapsed=0
  while (( elapsed < timeout )); do
    local status
    status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${name}" 2>/dev/null || true)"
    if [[ "${status}" == "healthy" ]]; then
      pass "Container ${name} is healthy"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  fail "Container ${name} did not become healthy within ${timeout}s"
}

wait_for_api_token() {
  local timeout="$1"
  local elapsed=0
  while (( elapsed < timeout )); do
    local token
    token="$(
      docker exec wazuh-dashboard sh -lc \
        'curl -sk -u "$API_USERNAME:$API_PASSWORD" "https://'"${WAZUH_MANAGER_IP}"':55000/security/user/authenticate?raw=true"' \
        2>/dev/null || true
    )"
    if grep -Eq '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' <<<"${token}"; then
      pass "Dashboard can authenticate against the Wazuh API"
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done
  fail "Wazuh API token request failed"
}

smoke_syslog() {
  local marker log_hits manager_hits
  marker="wazuh-smoke-$(date +%s)"
  command -v logger >/dev/null 2>&1 || fail "logger is not installed for --smoke-syslog"
  logger -n "${SYSLOG_BR0_IP}" -P 514 -T "${marker}"

  for _ in $(seq 1 12); do
    log_hits="$(grep -R "${marker}" "${APPDATA_ROOT}/syslog-ng/logs" 2>/dev/null || true)"
    manager_hits="$(docker exec wazuh-manager sh -lc 'grep -R "'"${marker}"'" /var/ossec/logs/archives /var/ossec/logs/alerts 2>/dev/null' || true)"
    if [[ -n "${log_hits}" && -n "${manager_hits}" ]]; then
      pass "Smoke syslog message reached raw syslog storage and Wazuh"
      return 0
    fi
    sleep 5
  done

  fail "Smoke syslog message did not reach both syslog storage and Wazuh"
}

if [[ ! -f "${ENV_FILE}" ]]; then
  fail "Missing ${ENV_FILE}"
fi

for key in \
  APPDATA_ROOT \
  BR0_NETWORK_NAME \
  CUSTOM_DOCKER_NETWORK \
  SYSLOG_BR0_IP \
  SYSLOG_NG_IP \
  WAZUH_MANAGER_IP \
  WAZUH_INDEXER_IP \
  WAZUH_DASHBOARD_IP \
  WAZUH_CLUSTER_KEY \
  API_USERNAME \
  API_PASSWORD; do
  require_env "${key}" >/dev/null
done

APPDATA_ROOT="${APPDATA_ROOT:-$(require_env APPDATA_ROOT)}"
BR0_NETWORK_NAME="${BR0_NETWORK_NAME:-$(require_env BR0_NETWORK_NAME)}"
CUSTOM_DOCKER_NETWORK="${CUSTOM_DOCKER_NETWORK:-$(require_env CUSTOM_DOCKER_NETWORK)}"
SYSLOG_BR0_IP="${SYSLOG_BR0_IP:-$(require_env SYSLOG_BR0_IP)}"
SYSLOG_NG_IP="${SYSLOG_NG_IP:-$(require_env SYSLOG_NG_IP)}"
WAZUH_MANAGER_IP="${WAZUH_MANAGER_IP:-$(require_env WAZUH_MANAGER_IP)}"
WAZUH_API_PORT="${WAZUH_API_PORT:-$(optional_env WAZUH_API_PORT)}"
if [[ -z "${WAZUH_API_PORT}" ]]; then
  WAZUH_API_PORT=55000
fi
WAZUH_API_BIND_IP="${WAZUH_API_BIND_IP:-$(optional_env WAZUH_API_BIND_IP)}"
if [[ -z "${WAZUH_API_BIND_IP}" ]]; then
  WAZUH_API_BIND_IP=127.0.0.1
fi

note "Checking Docker daemon"
command -v docker >/dev/null 2>&1 || fail "docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is not available"
pass "Docker daemon is available"

note "Checking external Docker networks"
docker network inspect "${BR0_NETWORK_NAME}" >/dev/null 2>&1 || fail "Missing Docker network ${BR0_NETWORK_NAME}"
docker network inspect "${CUSTOM_DOCKER_NETWORK}" >/dev/null 2>&1 || fail "Missing Docker network ${CUSTOM_DOCKER_NETWORK}"
pass "Required Docker networks exist"

note "Checking appdata structure"
[[ -f "${APPDATA_ROOT}/manager/etc/ossec.conf" ]] || fail "Missing manager ossec.conf under ${APPDATA_ROOT}"
[[ -f "${APPDATA_ROOT}/indexer/config/opensearch.yml" ]] || fail "Missing indexer opensearch.yml under ${APPDATA_ROOT}"
[[ -f "${APPDATA_ROOT}/indexer/config/opensearch-security/internal_users.yml" ]] || fail "Missing internal_users.yml under ${APPDATA_ROOT}"
[[ -f "${APPDATA_ROOT}/dashboard/config/opensearch_dashboards.yml" ]] || fail "Missing dashboard opensearch_dashboards.yml under ${APPDATA_ROOT}"
[[ -f "${APPDATA_ROOT}/dashboard/config/opensearch_dashboards.keystore" ]] || fail "Missing dashboard keystore under ${APPDATA_ROOT}"
[[ -f "${APPDATA_ROOT}/certs/root-ca.pem" ]] || fail "Missing root-ca.pem under ${APPDATA_ROOT}/certs"
pass "Expected appdata files exist"

note "Checking sensitive file permissions"
check_mode "${APPDATA_ROOT}/manager/etc/ossec.conf" 600
check_mode "${APPDATA_ROOT}/indexer/config/opensearch.yml" 600
check_mode "${APPDATA_ROOT}/indexer/config/opensearch-security/internal_users.yml" 600
check_mode "${APPDATA_ROOT}/dashboard/config/opensearch_dashboards.keystore" 600
check_owner "${APPDATA_ROOT}/indexer/config/opensearch.yml" 1000:1000
check_owner "${APPDATA_ROOT}/indexer/config/opensearch-security/internal_users.yml" 1000:1000
check_owner "${APPDATA_ROOT}/dashboard/config/opensearch_dashboards.keystore" 1000:1000
check_mode "${APPDATA_ROOT}/certs" 755
check_mode "${APPDATA_ROOT}/certs/root-ca.pem" 644
[ -f "${APPDATA_ROOT}/certs/root-ca-manager.pem" ] && check_mode "${APPDATA_ROOT}/certs/root-ca-manager.pem" 644
[ -f "${APPDATA_ROOT}/certs/admin.pem" ] && check_mode "${APPDATA_ROOT}/certs/admin.pem" 644
[ -f "${APPDATA_ROOT}/certs/wazuh.indexer.pem" ] && check_mode "${APPDATA_ROOT}/certs/wazuh.indexer.pem" 644
[ -f "${APPDATA_ROOT}/certs/wazuh.manager.pem" ] && check_mode "${APPDATA_ROOT}/certs/wazuh.manager.pem" 644
[ -f "${APPDATA_ROOT}/certs/admin-key.pem" ] && check_mode "${APPDATA_ROOT}/certs/admin-key.pem" 600
[ -f "${APPDATA_ROOT}/certs/wazuh.indexer-key.pem" ] && check_mode "${APPDATA_ROOT}/certs/wazuh.indexer-key.pem" 600
[ -f "${APPDATA_ROOT}/certs/wazuh.manager-key.pem" ] && check_mode "${APPDATA_ROOT}/certs/wazuh.manager-key.pem" 600

note "Checking running containers"
check_container_running syslog-ng
check_container_running wazuh-manager
check_container_running wazuh-indexer
check_container_running wazuh-dashboard

note "Checking health status"
wait_for_health syslog-ng "${HEALTH_TIMEOUT}"
wait_for_health wazuh-manager "${HEALTH_TIMEOUT}"
wait_for_health wazuh-indexer "${HEALTH_TIMEOUT}"
wait_for_health wazuh-dashboard "${HEALTH_TIMEOUT}"

note "Checking syslog-ng network attachment"
syslog_networks="$(docker inspect syslog-ng --format '{{range $k,$v := .NetworkSettings.Networks}}{{printf "%s=%s\n" $k $v.IPAddress}}{{end}}')"
grep -q "^${BR0_NETWORK_NAME}=${SYSLOG_BR0_IP}$" <<<"${syslog_networks}" || fail "syslog-ng is not on ${BR0_NETWORK_NAME} with IP ${SYSLOG_BR0_IP}"
grep -q "^${CUSTOM_DOCKER_NETWORK}=${SYSLOG_NG_IP}$" <<<"${syslog_networks}" || fail "syslog-ng is not on ${CUSTOM_DOCKER_NETWORK} with IP ${SYSLOG_NG_IP}"
pass "syslog-ng IPs match .env"

note "Checking syslog-ng config and listeners"
docker exec syslog-ng sh -lc 'syslog-ng --syntax-only -f /config/syslog-ng.conf >/dev/null 2>&1' || fail "syslog-ng config validation failed"
syslog_listeners="$(docker exec syslog-ng sh -lc 'netstat -lntup 2>/dev/null')"
grep -Eq 'tcp.*[.:]514[[:space:]]' <<<"${syslog_listeners}" || fail "syslog-ng is not listening on TCP 514"
grep -Eq 'udp.*[.:]514[[:space:]]' <<<"${syslog_listeners}" || fail "syslog-ng is not listening on UDP 514"
pass "syslog-ng is listening on TCP/UDP 514"

note "Checking Wazuh manager core daemons"
manager_status="$(timeout 20 docker exec wazuh-manager sh -lc '/var/ossec/bin/wazuh-control status 2>/dev/null || true')"
[[ -n "${manager_status}" ]] || fail "Timed out while checking Wazuh manager daemon status"
check_status_line wazuh-analysisd "${manager_status}"
check_status_line wazuh-db "${manager_status}"
check_status_line wazuh-remoted "${manager_status}"
check_status_line wazuh-execd "${manager_status}"
check_status_line wazuh-modulesd "${manager_status}"
check_status_line wazuh-apid "${manager_status}"

note "Checking Wazuh API authentication"
wait_for_api_token "${HEALTH_TIMEOUT}"
api_bindings="$(docker inspect wazuh-manager --format '{{range $port, $bindings := .NetworkSettings.Ports}}{{if eq $port "'"${WAZUH_API_PORT}"'/tcp"}}{{range $bindings}}{{println .HostIp}}{{end}}{{end}}{{end}}')"
grep -qx "${WAZUH_API_BIND_IP}" <<<"${api_bindings}" || fail "Wazuh API is not bound only to ${WAZUH_API_BIND_IP}"
pass "Wazuh API is bound to ${WAZUH_API_BIND_IP}"

note "Checking dashboard secret handling"
! grep -q 'opensearch.password' "${APPDATA_ROOT}/dashboard/config/opensearch_dashboards.yml" || fail "Dashboard config still contains opensearch.password"
! grep -q 'opensearch.username' "${APPDATA_ROOT}/dashboard/config/opensearch_dashboards.yml" || fail "Dashboard config still contains opensearch.username"
dashboard_env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' wazuh-dashboard)"
! grep -q '^INDEXER_PASSWORD=' <<<"${dashboard_env}" || fail "wazuh-dashboard still exposes INDEXER_PASSWORD in container env"
! grep -q '^INDEXER_USERNAME=' <<<"${dashboard_env}" || fail "wazuh-dashboard still exposes INDEXER_USERNAME in container env"
pass "Dashboard credentials are not persisted in config or container env"

note "Checking recent indexer logs for permission warnings"
recent_indexer_logs="$(docker logs --since=10m wazuh-indexer 2>&1 || true)"
! grep -q 'insecure file permissions' <<<"${recent_indexer_logs}" || fail "Indexer reported insecure file permission warnings"
pass "Indexer logs do not report insecure file permission warnings"

if [[ "${SMOKE_SYSLOG}" -eq 1 ]]; then
  note "Running end-to-end syslog smoke test"
  smoke_syslog
fi

pass "Unraid deployment checks passed"
