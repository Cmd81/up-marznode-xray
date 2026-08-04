#!/usr/bin/env bash
#
# DEPRECATED — kept for backward compatibility.
# This project is now a full marznode installer + core manager.
#
#   old:  bash change-core.sh 25.8.3
#   new:  bash install.sh --core 25.8.3
#
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/Cmd81/up-marznode-xray/main"
VERSION="${1:-latest}"

echo "[!] change-core.sh is deprecated — forwarding to install.sh --core ${VERSION}"

if [ -f "$(dirname "$0")/install.sh" ]; then
  exec bash "$(dirname "$0")/install.sh" --core "$VERSION"
fi

tmp="$(mktemp)"
curl -fsSL "${REPO_RAW}/install.sh" -o "$tmp" || { echo "[x] download failed"; exit 1; }
exec bash "$tmp" --core "$VERSION"
