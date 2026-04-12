#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

usage() {
  cat <<'EOF'
Usage: ./scripts/reset-unraid.sh [--remove-repo]

What it does:
  - Stops and removes the Wazuh/syslog-ng containers for this repo
  - Removes the named Docker volumes created by this Compose project
  - Removes the appdata directory defined by APPDATA_ROOT in .env

Optional:
  --remove-repo   Also delete this cloned repository directory after cleanup

This does NOT remove your external Docker networks such as br0 or creanet.
EOF
}

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

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

REMOVE_REPO=0
for arg in "$@"; do
  case "${arg}" in
    --remove-repo)
      REMOVE_REPO=1
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

APPDATA_ROOT="${APPDATA_ROOT:-$(require_env APPDATA_ROOT)}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "${ROOT_DIR}")}"

echo "Resetting project '${PROJECT_NAME}'"
echo "Appdata root: ${APPDATA_ROOT}"

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "Docker daemon is not available." >&2
  exit 1
fi

# Stop/remove the main stack and any orphaned services from previous revisions.
docker compose --project-directory "${ROOT_DIR}" down --remove-orphans --volumes || true
docker compose --project-directory "${ROOT_DIR}" -f "${ROOT_DIR}/generate-indexer-certs.yml" down --remove-orphans --volumes || true

# Clean up explicitly named containers in case Compose metadata drifted.
docker rm -f wazuh-manager wazuh-indexer wazuh-dashboard syslog-ng 2>/dev/null || true

# Remove named volumes created by this project if they still exist.
docker volume rm \
  "${PROJECT_NAME}_manager_etc_runtime" \
  "${PROJECT_NAME}_dashboard_wazuh_config" \
  2>/dev/null || true

# Remove the generated appdata tree.
rm -rf "${APPDATA_ROOT}"

echo "Removed appdata under ${APPDATA_ROOT}"

if [[ "${REMOVE_REPO}" -eq 1 ]]; then
  echo "Scheduling repository removal for ${ROOT_DIR}"
  (
    cd /
    nohup sh -c "sleep 1; rm -rf '${ROOT_DIR}'" >/dev/null 2>&1 &
  )
  echo "Repository removal scheduled."
else
  echo "Repository directory left in place: ${ROOT_DIR}"
  echo "To remove it manually later: cd \"$(dirname "${ROOT_DIR}")\" && rm -rf \"$(basename "${ROOT_DIR}")\""
fi

