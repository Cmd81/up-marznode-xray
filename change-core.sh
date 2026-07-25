#!/usr/bin/env bash
#
# up-marznode-xray — Change/update the Xray core on Marzneshin (marznode) nodes
# https://github.com/Cmd81/up-marznode-xray
#
# Usage:
#   bash change-core.sh              # default version
#   bash change-core.sh 25.9.11      # custom version
#
set -euo pipefail

XRAY_VERSION="${1:-25.8.3}"
MARZNODE_DIR="/var/lib/marznode"
DATA_DIR="$MARZNODE_DIR/data"
COMPOSE_DIR="/root/marznode"
COMPOSE_FILE="$COMPOSE_DIR/compose.yml"

red()   { echo -e "\e[31m$*\e[0m"; }
green() { echo -e "\e[32m$*\e[0m"; }
info()  { echo -e "\e[36m==> $*\e[0m"; }

# --- Require root ---
[ "$(id -u)" -eq 0 ] || { red "This script must be run as root."; exit 1; }

# --- Detect server architecture ---
case "$(uname -m)" in
  x86_64|amd64)  ZIP="Xray-linux-64.zip" ;;
  aarch64|arm64) ZIP="Xray-linux-arm64-v8a.zip" ;;
  armv7l)        ZIP="Xray-linux-arm32-v7a.zip" ;;
  *) red "Architecture $(uname -m) is not supported."; exit 1 ;;
esac
info "Arch: $(uname -m) | File: $ZIP | Version: v$XRAY_VERSION"

# --- Pre-check compose.yml before making any changes ---
[ -f "$COMPOSE_FILE" ] || { red "File $COMPOSE_FILE not found. Fix the COMPOSE_DIR variable."; exit 1; }
grep -qE "^[[:space:]]*environment:" "$COMPOSE_FILE" \
  || { red "No 'environment:' block found in compose.yml."; exit 1; }

# --- Install prerequisites ---
info "Installing prerequisites"
apt-get update -qq
apt-get install -y -qq unzip wget

# --- Download and extract the core ---
info "Downloading core"
mkdir -p "$DATA_DIR"
cd "$DATA_DIR"
URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${ZIP}"
wget -q --show-progress -O "$ZIP" "$URL" \
  || { red "Download failed. Check the version:"; echo "$URL"; exit 1; }

info "Extracting"
unzip -o -q "$ZIP"
rm -f "$ZIP"
[ -f "$DATA_DIR/xray" ] || { red "xray binary not found after extraction."; exit 1; }

# --- Place the binary in the marznode directory ---
cp -f "$DATA_DIR/xray" "$MARZNODE_DIR/xray"
chmod +x "$MARZNODE_DIR/xray"
green "Installed version: $("$MARZNODE_DIR/xray" version | head -n1)"

# --- Edit compose.yml ---
BACKUP="$COMPOSE_FILE.bak.$(date +%Y%m%d-%H%M%S)"
cp "$COMPOSE_FILE" "$BACKUP"
info "Backup: $BACKUP"

set_env() {
  local key="$1" val="$2"
  if grep -qE "^[[:space:]]*${key}:" "$COMPOSE_FILE"; then
    sed -i -E "s|^([[:space:]]*)${key}:.*|\1${key}: \"${val}\"|" "$COMPOSE_FILE"
  else
    sed -i "0,/^[[:space:]]*environment:/s||&\n      ${key}: \"${val}\"|" "$COMPOSE_FILE"
  fi
}
set_env "XRAY_EXECUTABLE_PATH" "$MARZNODE_DIR/xray"
set_env "XRAY_ASSETS_PATH"     "$DATA_DIR"
green "compose.yml updated."

# --- Restart marznode ---
info "Restarting marznode"
cd "$COMPOSE_DIR"
docker compose down
docker compose up -d

green "Done ✅   Logs: cd $COMPOSE_DIR && docker compose logs -f"