#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

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

require_env() {
  local key="$1"
  local value
  value="$(awk -F= -v k="$key" '$1 == k {sub($1"=",""); print; exit}' "${ENV_FILE}")"
  if [[ -z "${value}" ]]; then
    fail "Missing ${key} in ${ENV_FILE}"
  fi
  printf '%s' "${value}"
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
API_USERNAME="${API_USERNAME:-$(require_env API_USERNAME)}"
API_PASSWORD="${API_PASSWORD:-$(require_env API_PASSWORD)}"

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
[[ -f "${APPDATA_ROOT}/dashboard/config/opensearch_dashboards.yml" ]] || fail "Missing dashboard opensearch_dashboards.yml under ${APPDATA_ROOT}"
[[ -f "${APPDATA_ROOT}/certs/root-ca.pem" ]] || fail "Missing root-ca.pem under ${APPDATA_ROOT}/certs"
pass "Expected appdata files exist"

note "Checking running containers"
check_container_running syslog-ng
check_container_running wazuh-manager
check_container_running wazuh-indexer
check_container_running wazuh-dashboard

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
manager_status="$(docker exec wazuh-manager /var/ossec/bin/wazuh-control status)"
check_status_line wazuh-analysisd "${manager_status}"
check_status_line wazuh-db "${manager_status}"
check_status_line wazuh-remoted "${manager_status}"
check_status_line wazuh-execd "${manager_status}"
check_status_line wazuh-modulesd "${manager_status}"
check_status_line wazuh-apid "${manager_status}"

note "Checking Wazuh API authentication"
api_token="$(
  docker exec wazuh-dashboard sh -lc \
    'curl -sk -u "$API_USERNAME:$API_PASSWORD" "https://'"${WAZUH_MANAGER_IP}"':55000/security/user/authenticate?raw=true"' \
    2>/dev/null || true
)"
grep -Eq '^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$' <<<"${api_token}" || fail "Wazuh API token request failed"
pass "Dashboard can authenticate against the Wazuh API"

pass "Unraid deployment checks passed"
