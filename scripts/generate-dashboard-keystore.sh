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

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

APPDATA_ROOT="${APPDATA_ROOT:-$(require_env APPDATA_ROOT)}"
WAZUH_VERSION="${WAZUH_VERSION:-$(require_env WAZUH_VERSION)}"
INDEXER_USERNAME="${INDEXER_USERNAME:-$(require_env INDEXER_USERNAME)}"
INDEXER_PASSWORD="${INDEXER_PASSWORD:-$(require_env INDEXER_PASSWORD)}"
INDEXER_PASSWORD="${INDEXER_PASSWORD//\$\$/\$}"
CONFIG_DIR="${APPDATA_ROOT}/dashboard/config"
KEYSTORE_PATH="${CONFIG_DIR}/opensearch_dashboards.keystore"

mkdir -p "${CONFIG_DIR}"
rm -f "${KEYSTORE_PATH}"

docker run --rm \
  --user 0:0 \
  -e INDEXER_USERNAME="${INDEXER_USERNAME}" \
  -e INDEXER_PASSWORD="${INDEXER_PASSWORD}" \
  -v "${CONFIG_DIR}:/usr/share/wazuh-dashboard/config" \
  --entrypoint sh \
  "wazuh/wazuh-dashboard:${WAZUH_VERSION}" \
  -c '
    set -eu
    export OPENSEARCH_PATH_CONF=/usr/share/wazuh-dashboard/config
    /usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore create
    printf "%s\n" "$INDEXER_USERNAME" | /usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore add --stdin opensearch.username
    printf "%s\n" "$INDEXER_PASSWORD" | /usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore add --stdin opensearch.password
    /usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore list | grep -q "^opensearch.username$"
    /usr/share/wazuh-dashboard/bin/opensearch-dashboards-keystore list | grep -q "^opensearch.password$"
  '

chmod 0600 "${KEYSTORE_PATH}"

echo "Dashboard keystore generated at ${KEYSTORE_PATH}"
