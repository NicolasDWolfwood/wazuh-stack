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

optional_env() {
  local key="$1"
  awk -F= -v k="$key" '$1 == k {sub($1"=",""); print; exit}' "${ENV_FILE}"
}

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

APPDATA_ROOT="${APPDATA_ROOT:-$(require_env APPDATA_ROOT)}"
SYSLOG_RETENTION_DAYS="${SYSLOG_RETENTION_DAYS:-$(optional_env SYSLOG_RETENTION_DAYS)}"
if [[ -z "${SYSLOG_RETENTION_DAYS}" ]]; then
  SYSLOG_RETENTION_DAYS=30
fi
LOG_ROOT="${APPDATA_ROOT}/syslog-ng/logs"

if ! [[ "${SYSLOG_RETENTION_DAYS}" =~ ^[0-9]+$ ]]; then
  echo "SYSLOG_RETENTION_DAYS must be an integer" >&2
  exit 1
fi

if [[ "${SYSLOG_RETENTION_DAYS}" -eq 0 ]]; then
  echo "Syslog pruning disabled because SYSLOG_RETENTION_DAYS=0"
  exit 0
fi

find "${LOG_ROOT}" -type f -mtime +"${SYSLOG_RETENTION_DAYS}" -delete
find "${LOG_ROOT}" -depth -type d -empty -delete

echo "Pruned raw syslog files older than ${SYSLOG_RETENTION_DAYS} days under ${LOG_ROOT}"
