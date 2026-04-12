#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  exec docker compose --project-directory "${ROOT_DIR}" "$@"
fi

if command -v cmd.exe >/dev/null 2>&1 && command -v wslpath >/dev/null 2>&1; then
  WIN_ROOT="$(wslpath -w "${ROOT_DIR}")"
  args=()
  for arg in "$@"; do
    args+=("${arg}")
  done
  exec cmd.exe /c "cd /d ${WIN_ROOT} && docker compose ${args[*]}"
fi

echo "No working Docker daemon was found. Use native docker or Docker Desktop via cmd.exe." >&2
exit 1
