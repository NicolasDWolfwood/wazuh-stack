#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

usage() {
  cat <<'EOF'
Usage: ./scripts/deploy-unraid.sh [--skip-check]

What it does:
  - validates required .env values and Docker networks
  - bootstraps appdata into APPDATA_ROOT
  - generates Wazuh certificates
  - recreates the stack
  - runs the post-deploy health check by default

Optional:
  --skip-check    Do not run scripts/check-unraid.sh at the end
EOF
}

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

SKIP_CHECK=0
for arg in "$@"; do
  case "${arg}" in
    --skip-check)
      SKIP_CHECK=1
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

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
  INDEXER_USERNAME \
  INDEXER_PASSWORD \
  DASHBOARD_USERNAME \
  DASHBOARD_PASSWORD \
  API_USERNAME \
  API_PASSWORD; do
  require_env "${key}" >/dev/null
done

APPDATA_ROOT="${APPDATA_ROOT:-$(require_env APPDATA_ROOT)}"
BR0_NETWORK_NAME="${BR0_NETWORK_NAME:-$(require_env BR0_NETWORK_NAME)}"
CUSTOM_DOCKER_NETWORK="${CUSTOM_DOCKER_NETWORK:-$(require_env CUSTOM_DOCKER_NETWORK)}"
WAZUH_CLUSTER_KEY="${WAZUH_CLUSTER_KEY:-$(require_env WAZUH_CLUSTER_KEY)}"

[[ "${WAZUH_CLUSTER_KEY}" =~ ^[A-Za-z0-9]{32}$ ]] || fail "WAZUH_CLUSTER_KEY must be exactly 32 alphanumeric characters"

note "Checking Docker daemon"
command -v docker >/dev/null 2>&1 || fail "docker is not installed"
docker info >/dev/null 2>&1 || fail "Docker daemon is not available"
pass "Docker daemon is available"

note "Checking external Docker networks"
docker network inspect "${BR0_NETWORK_NAME}" >/dev/null 2>&1 || fail "Missing Docker network ${BR0_NETWORK_NAME}"
docker network inspect "${CUSTOM_DOCKER_NETWORK}" >/dev/null 2>&1 || fail "Missing Docker network ${CUSTOM_DOCKER_NETWORK}"
pass "Required Docker networks exist"

note "Checking Compose render"
compose_render="$(mktemp)"
trap 'rm -f "${compose_render}"' EXIT
"${ROOT_DIR}/scripts/docker-compose-host.sh" config > "${compose_render}"
if grep -q '\${[^}]\+}' "${compose_render}"; then
  fail "Compose render still contains unresolved variables"
fi
pass "Compose renders cleanly"

note "Bootstrapping appdata under ${APPDATA_ROOT}"
"${ROOT_DIR}/scripts/bootstrap-appdata.sh"
pass "Appdata bootstrapped"

note "Generating certificates"
"${ROOT_DIR}/scripts/generate-certs.sh"
pass "Certificates generated"

note "Starting stack"
"${ROOT_DIR}/scripts/docker-compose-host.sh" up -d --force-recreate
pass "Stack recreated"

if [[ "${SKIP_CHECK}" -eq 0 ]]; then
  note "Running post-deploy health check"
  "${ROOT_DIR}/scripts/check-unraid.sh"
else
  note "Skipping post-deploy health check"
fi

pass "Unraid deployment completed"
