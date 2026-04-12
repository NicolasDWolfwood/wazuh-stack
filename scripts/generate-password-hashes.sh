#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "Usage: $0 <admin_password> <kibanaserver_password> <wazuh_wui_password> <readall_password>" >&2
  exit 1
fi

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  docker run --rm wazuh/wazuh-indexer:4.14.4 bash -lc '
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
