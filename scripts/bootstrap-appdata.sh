#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

require_env() {
  local key="$1"
  local value
  value="$(awk -F= -v k="$key" '$1 == k {sub($1"=",""); print; exit}' "${ENV_FILE}")"
  if [[ -z "${value}" ]]; then
    echo "Missing ${key} in ${ENV_FILE}" >&2
    exit 1
  fi
  printf '%s' "${value}"
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&|\\]/\\&/g'
}

render_template() {
  local template="$1"
  local output="$2"
  shift 2

  local args=()
  local key replacement
  for key in "$@"; do
    replacement="$(escape_sed_replacement "${!key}")"
    args+=(-e "s|\${${key}}|${replacement}|g")
  done

  sed "${args[@]}" "${template}" > "${output}"
}

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

APPDATA_ROOT="${APPDATA_ROOT:-$(require_env APPDATA_ROOT)}"
SYSLOG_NG_IP="${SYSLOG_NG_IP:-$(require_env SYSLOG_NG_IP)}"
WAZUH_MANAGER_IP="${WAZUH_MANAGER_IP:-$(require_env WAZUH_MANAGER_IP)}"
WAZUH_INDEXER_IP="${WAZUH_INDEXER_IP:-$(require_env WAZUH_INDEXER_IP)}"
WAZUH_DASHBOARD_IP="${WAZUH_DASHBOARD_IP:-$(require_env WAZUH_DASHBOARD_IP)}"
WAZUH_CLUSTER_KEY="${WAZUH_CLUSTER_KEY:-$(require_env WAZUH_CLUSTER_KEY)}"
WAZUH_PUBLIC_HOST="${WAZUH_PUBLIC_HOST:-$(require_env WAZUH_PUBLIC_HOST)}"
INDEXER_USERNAME="${INDEXER_USERNAME:-$(require_env INDEXER_USERNAME)}"
INDEXER_PASSWORD="${INDEXER_PASSWORD:-$(require_env INDEXER_PASSWORD)}"
DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD:-$(require_env DASHBOARD_PASSWORD)}"
API_USERNAME="${API_USERNAME:-$(require_env API_USERNAME)}"
API_PASSWORD="${API_PASSWORD:-$(require_env API_PASSWORD)}"

INDEXER_PASSWORD="${INDEXER_PASSWORD//\$\$/\$}"
DASHBOARD_PASSWORD="${DASHBOARD_PASSWORD//\$\$/\$}"
API_PASSWORD="${API_PASSWORD//\$\$/\$}"

mkdir -p \
  "${APPDATA_ROOT}/certs" \
  "${APPDATA_ROOT}/dashboard/config" \
  "${APPDATA_ROOT}/dashboard/custom-assets" \
  "${APPDATA_ROOT}/indexer/config" \
  "${APPDATA_ROOT}/indexer/config/opensearch-security" \
  "${APPDATA_ROOT}/indexer/data" \
  "${APPDATA_ROOT}/manager/active-response/bin" \
  "${APPDATA_ROOT}/manager/agentless" \
  "${APPDATA_ROOT}/manager/api-configuration" \
  "${APPDATA_ROOT}/manager/etc" \
  "${APPDATA_ROOT}/manager/filebeat-etc" \
  "${APPDATA_ROOT}/manager/filebeat-var" \
  "${APPDATA_ROOT}/manager/integrations" \
  "${APPDATA_ROOT}/manager/logs" \
  "${APPDATA_ROOT}/manager/queue" \
  "${APPDATA_ROOT}/manager/var/multigroups" \
  "${APPDATA_ROOT}/manager/wodles" \
  "${APPDATA_ROOT}/syslog-ng/config" \
  "${APPDATA_ROOT}/syslog-ng/logs"

install -m 0644 "${ROOT_DIR}/config/syslog-ng/syslog-ng.conf" \
  "${APPDATA_ROOT}/syslog-ng/config/syslog-ng.conf"
sed "s|CHANGE_ME_WAZUH_CLUSTER_KEY|$(escape_sed_replacement "${WAZUH_CLUSTER_KEY}")|g" \
  "${ROOT_DIR}/config/wazuh_cluster/ossec.conf" > "${APPDATA_ROOT}/manager/etc/ossec.conf"
chmod 0644 "${APPDATA_ROOT}/manager/etc/ossec.conf"
render_template \
  "${ROOT_DIR}/config/wazuh_dashboard/opensearch_dashboards.yml" \
  "${APPDATA_ROOT}/dashboard/config/opensearch_dashboards.yml" \
  WAZUH_PUBLIC_HOST INDEXER_USERNAME INDEXER_PASSWORD
chmod 0644 "${APPDATA_ROOT}/dashboard/config/opensearch_dashboards.yml"
install -m 0644 "${ROOT_DIR}/config/wazuh_indexer/opensearch.yml" \
  "${APPDATA_ROOT}/indexer/config/opensearch.yml"

mapfile -t HASHES < <("${ROOT_DIR}/scripts/generate-password-hashes.sh" \
  "${INDEXER_PASSWORD}" \
  "${DASHBOARD_PASSWORD}" \
  "${API_PASSWORD}" \
  "unused-readall-password")

cat > "${APPDATA_ROOT}/indexer/config/internal_users.yml" <<EOF
---
_meta:
  type: "internalusers"
  config_version: 2

admin:
  hash: "${HASHES[0]}"
  reserved: true
  backend_roles:
    - "admin"
  description: "Indexer admin user"

kibanaserver:
  hash: "${HASHES[1]}"
  reserved: true
  description: "Dashboard service user"

wazuh-wui:
  hash: "${HASHES[2]}"
  reserved: false
  backend_roles:
    - "admin"
  description: "Wazuh dashboard API user"
EOF

chmod 0644 "${APPDATA_ROOT}/indexer/config/opensearch-security/internal_users.yml"

cat > "${APPDATA_ROOT}/certs/certs.yml" <<EOF
nodes:
  indexer:
    - name: wazuh.indexer
      ip: ${WAZUH_INDEXER_IP}
  server:
    - name: wazuh.manager
      ip: ${WAZUH_MANAGER_IP}
  dashboard:
    - name: wazuh.dashboard
      ip: ${WAZUH_DASHBOARD_IP}
EOF

echo "Bootstrapped appdata layout under ${APPDATA_ROOT}"
