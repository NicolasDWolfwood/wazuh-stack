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

# The cert generator creates restrictive permissions that prevent the dashboard
# from traversing the mounted cert directory and reading the shared CA file.
chmod 755 "${CERTS_DIR}"
chmod 644 "${CERTS_DIR}/root-ca.pem"

echo "Certificates generated under ${CERTS_DIR}"
echo "Normalized permissions for ${CERTS_DIR} and ${CERTS_DIR}/root-ca.pem"
