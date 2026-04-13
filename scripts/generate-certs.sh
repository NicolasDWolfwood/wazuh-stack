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
CERTS_DIR="${APPDATA_ROOT}/certs"

"${ROOT_DIR}/scripts/docker-compose-host.sh" -f "${ROOT_DIR}/generate-indexer-certs.yml" up

# Normalize cert permissions for the mounted services. Public certs and shared
# CAs can be broader in general, but OpenSearch warns unless the files mounted
# into its config dir are 0600 and readable by the indexer user.
chmod 755 "${CERTS_DIR}"
find "${CERTS_DIR}" -maxdepth 1 -type f -name '*.pem' ! -name '*-key.pem' -exec chmod 644 {} +
find "${CERTS_DIR}" -maxdepth 1 -type f -name '*-key.pem' -exec chmod 600 {} +
[ -f "${CERTS_DIR}/root-ca.pem" ] && chmod 600 "${CERTS_DIR}/root-ca.pem"
[ -f "${CERTS_DIR}/root-ca-manager.pem" ] && chmod 644 "${CERTS_DIR}/root-ca-manager.pem"
[ -f "${CERTS_DIR}/admin.pem" ] && chmod 600 "${CERTS_DIR}/admin.pem"
[ -f "${CERTS_DIR}/wazuh.indexer.pem" ] && chmod 600 "${CERTS_DIR}/wazuh.indexer.pem"
[ -f "${CERTS_DIR}/admin-key.pem" ] && chmod 600 "${CERTS_DIR}/admin-key.pem"
[ -f "${CERTS_DIR}/wazuh.indexer-key.pem" ] && chmod 600 "${CERTS_DIR}/wazuh.indexer-key.pem"
[ -f "${CERTS_DIR}/wazuh.manager-key.pem" ] && chmod 600 "${CERTS_DIR}/wazuh.manager-key.pem"
[ -f "${CERTS_DIR}/root-ca.pem" ] && chown 1000:1000 "${CERTS_DIR}/root-ca.pem"
[ -f "${CERTS_DIR}/admin.pem" ] && chown 1000:1000 "${CERTS_DIR}/admin.pem"
[ -f "${CERTS_DIR}/wazuh.indexer.pem" ] && chown 1000:1000 "${CERTS_DIR}/wazuh.indexer.pem"
[ -f "${CERTS_DIR}/admin-key.pem" ] && chown 1000:1000 "${CERTS_DIR}/admin-key.pem"
[ -f "${CERTS_DIR}/wazuh.indexer-key.pem" ] && chown 1000:1000 "${CERTS_DIR}/wazuh.indexer-key.pem"

echo "Certificates generated under ${CERTS_DIR}"
echo "Normalized permissions under ${CERTS_DIR}"
