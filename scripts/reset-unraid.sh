#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

usage() {
  cat <<'EOF'
Usage: ./scripts/reset-unraid.sh [--dry-run] [--remove-repo]

What it does:
  - Stops and removes the Wazuh/syslog-ng containers for this repo
  - Removes the named Docker volumes created by this Compose project
  - Removes the appdata directory defined by APPDATA_ROOT in .env

Optional:
  --dry-run       Print the reset actions without executing them
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

DRY_RUN=0
REMOVE_REPO=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run)
      DRY_RUN=1
      ;;
    --remove-repo)
      REMOVE_REPO=1
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
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

APPDATA_ROOT="${APPDATA_ROOT:-$(require_env APPDATA_ROOT)}"
PROJECT_NAME="${COMPOSE_PROJECT_NAME:-$(basename "${ROOT_DIR}")}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "Dry run for project '${PROJECT_NAME}'"
else
  echo "Resetting project '${PROJECT_NAME}'"
fi
echo "Appdata root: ${APPDATA_ROOT}"

run_cmd() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

if [[ "${DRY_RUN}" -eq 0 ]]; then
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    echo "Docker daemon is not available." >&2
    exit 1
  fi
fi

# Stop/remove the main stack and any orphaned services from previous revisions.
run_cmd docker compose --project-directory "${ROOT_DIR}" down --remove-orphans --volumes || true
run_cmd docker compose --project-directory "${ROOT_DIR}" -f "${ROOT_DIR}/generate-indexer-certs.yml" down --remove-orphans --volumes || true

# Clean up explicitly named containers in case Compose metadata drifted.
run_cmd docker rm -f wazuh-manager wazuh-indexer wazuh-dashboard syslog-ng 2>/dev/null || true

# Remove named volumes created by this project if they still exist.
run_cmd docker volume rm \
  "${PROJECT_NAME}_manager_etc_runtime" \
  "${PROJECT_NAME}_dashboard_wazuh_config" \
  2>/dev/null || true

# Remove the generated appdata tree.
run_cmd rm -rf "${APPDATA_ROOT}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "Would remove appdata under ${APPDATA_ROOT}"
else
  echo "Removed appdata under ${APPDATA_ROOT}"
fi

if [[ "${REMOVE_REPO}" -eq 1 ]]; then
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "Would remove repository directory: ${ROOT_DIR}"
  else
    echo "Scheduling repository removal for ${ROOT_DIR}"
    (
      cd /
      nohup sh -c "sleep 1; rm -rf '${ROOT_DIR}'" >/dev/null 2>&1 &
    )
    echo "Repository removal scheduled."
  fi
else
  echo "Repository directory left in place: ${ROOT_DIR}"
  echo "To remove it manually later: cd \"$(dirname "${ROOT_DIR}")\" && rm -rf \"$(basename "${ROOT_DIR}")\""
fi
