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

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <admin_password> <kibanaserver_password> <wazuh_wui_password> <readall_password>" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

WAZUH_VERSION="${WAZUH_VERSION:-$(require_env WAZUH_VERSION)}"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker run --rm "wazuh/wazuh-indexer:${WAZUH_VERSION}" bash -lc '
    for p in "$@"; do
      /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh -p "$p" | tail -n 1
    done
  ' _ "$1" "$2" "$3" "$4"
  exit 0
fi

if command -v python3 >/dev/null 2>&1; then
  python3 - "$@" <<'PY'
import sys

try:
    import bcrypt
except ImportError:
    print("docker is unavailable and python3 bcrypt is not installed", file=sys.stderr)
    sys.exit(1)

for password in sys.argv[1:]:
    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt(rounds=12)).decode()
    print(hashed.replace("$2b$", "$2y$", 1))
PY
  exit 0
fi

echo "docker is unavailable and no local bcrypt-capable fallback was found" >&2
exit 1
