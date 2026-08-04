#!/usr/bin/env bash
#
# marznode-setup — All-in-one installer & Xray core manager for Marzneshin nodes
# https://github.com/Cmd81/up-marznode-xray
#
# Steps: update server -> install docker -> install marznode -> configure -> set xray core
#
# Quick start (interactive menu):
#   bash <(curl -sL https://raw.githubusercontent.com/Cmd81/up-marznode-xray/main/install.sh)
#
# Full unattended install:
#   bash install.sh --all --cert-file /root/client.pem --port 53042 --core latest -y
#
set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
REPO_RAW="https://raw.githubusercontent.com/Cmd81/up-marznode-xray/main"

MARZNODE_DIR="/var/lib/marznode"
ASSETS_DIR="${MARZNODE_DIR}/data"
CERT_FILE="${MARZNODE_DIR}/client.pem"
XRAY_CONFIG="${MARZNODE_DIR}/xray_config.json"
XRAY_BIN="${MARZNODE_DIR}/xray"

APP_DIR_DEFAULT="/opt/marznode"
MARZNODE_GIT="https://github.com/marzneshin/marznode"
XRAY_REPO="XTLS/Xray-core"
DEFAULT_PORT="53042"

# runtime flags
ASSUME_YES=0
DO_UPDATE=0
DO_DOCKER=0
DO_NODE=0
DO_CORE=0
CORE_VERSION=""
WANT_PORT=""
CERT_SRC_FILE=""
CERT_SRC_URL=""
FULL_UPGRADE=0
APP_DIR=""

# ---------------------------------------------------------------- ui helpers
if [ -t 1 ]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'
  C_CYN=$'\e[36m'; C_BLD=$'\e[1m';  C_OFF=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_CYN=""; C_BLD=""; C_OFF=""
fi

info() { printf '%s==>%s %s\n' "$C_CYN" "$C_OFF" "$*"; }
ok()   { printf '%s[ok]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s  %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
err()  { printf '%s[x]%s  %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }

trap 'err "failed at line $LINENO (exit $?)"' ERR

# ------------------------------------------------------------------ tty / io
# When the script is run as `curl ... | bash`, stdin is the script itself and
# interactive reads would consume it. Rebind stdin to the terminal if possible.
ensure_tty() {
  [ -t 0 ] && return 0
  if [ -r /dev/tty ]; then exec </dev/tty; return 0; fi
  return 1
}

confirm() {
  local prompt="$1"
  [ "$ASSUME_YES" -eq 1 ] && return 0
  ensure_tty || die "no terminal available; re-run with -y and explicit flags"
  local ans
  read -r -p "$prompt [y/N]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

ask() {
  local prompt="$1" default="${2:-}" ans
  ensure_tty || { printf '%s' "$default"; return 0; }
  read -r -p "$prompt${default:+ [$default]}: " ans
  printf '%s' "${ans:-$default}"
}

# --------------------------------------------------------------- environment
need_root() { [ "$(id -u)" -eq 0 ] || die "run this script as root"; }

need_apt() {
  command -v apt-get >/dev/null 2>&1 \
    || die "only Debian/Ubuntu based systems are supported (apt-get not found)"
}

apt_env() {
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a          # do not prompt about service restarts
  export NEEDRESTART_SUSPEND=1
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "Xray-linux-64.zip" ;;
    aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
    armv7l|armv7)  echo "Xray-linux-arm32-v7a.zip" ;;
    armv6l)        echo "Xray-linux-arm32-v6.zip" ;;
    s390x)         echo "Xray-linux-s390x.zip" ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
}

# Locate an existing marznode checkout, otherwise fall back to the default.
detect_app_dir() {
  if [ -n "$APP_DIR" ]; then echo "$APP_DIR"; return; fi
  local d
  for d in "$APP_DIR_DEFAULT" /root/marznode /opt/marznode "$HOME/marznode"; do
    [ -f "$d/compose.yml" ] && { echo "$d"; return; }
  done
  echo "$APP_DIR_DEFAULT"
}

compose() {
  local dir; dir="$(detect_app_dir)"
  ( cd "$dir" && docker compose "$@" )
}

# ------------------------------------------------------------ compose editing
# set_env KEY VALUE FILE — update an existing key or insert it into the
# first `environment:` block.
set_env() {
  local key="$1" val="$2" file="$3"
  grep -qE '^[[:space:]]*environment:' "$file" \
    || die "no 'environment:' block found in $file"
  if grep -qE "^[[:space:]]*${key}:" "$file"; then
    sed -i -E "s|^([[:space:]]*)${key}:.*|\1${key}: \"${val}\"|" "$file"
  else
    sed -i -E "0,/^[[:space:]]*environment:[[:space:]]*$/s||&\n      ${key}: \"${val}\"|" "$file"
  fi
}

backup_compose() {
  local file="$1" bak
  bak="${file}.bak.$(date +%Y%m%d-%H%M%S)"
  cp -f "$file" "$bak"
  info "backup: $bak"
}

# ============================================================== STEP 1: system
step_update_server() {
  need_apt; apt_env
  info "step 1/4 — updating the server"
  apt-get update -qq
  if [ "$FULL_UPGRADE" -eq 1 ]; then
    warn "full upgrade requested — services (and possibly the kernel) may restart"
    apt-get -y -qq -o Dpkg::Options::=--force-confold upgrade
  fi
  apt-get install -y -qq \
    ca-certificates curl wget unzip git jq nano tar socat cron \
    >/dev/null
  timedatectl set-ntp true >/dev/null 2>&1 || true
  ok "system packages ready"
}

# ============================================================== STEP 2: docker
step_install_docker() {
  info "step 2/4 — docker"
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "docker $(docker --version | awk '{print $3}' | tr -d ,) + compose plugin already present"
  else
    info "installing docker via get.docker.com"
    curl -fsSL https://get.docker.com | sh
    docker compose version >/dev/null 2>&1 \
      || die "docker compose plugin missing after install"
    ok "docker installed"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || true
  docker info >/dev/null 2>&1 || die "docker daemon is not running"
}

# ============================================================ STEP 3: marznode
install_cert() {
  mkdir -p "$MARZNODE_DIR"
  if [ -s "$CERT_FILE" ] && grep -q "BEGIN CERTIFICATE" "$CERT_FILE"; then
    ok "certificate already in place ($CERT_FILE)"
    return 0
  fi
  if [ -n "$CERT_SRC_FILE" ]; then
    [ -f "$CERT_SRC_FILE" ] || die "cert file not found: $CERT_SRC_FILE"
    cp -f "$CERT_SRC_FILE" "$CERT_FILE"
  elif [ -n "$CERT_SRC_URL" ]; then
    curl -fsSL "$CERT_SRC_URL" -o "$CERT_FILE" || die "cert download failed"
  else
    ensure_tty || die "certificate required: use --cert-file or --cert-url"
    echo
    echo "${C_BLD}Paste the client certificate from the Marzneshin panel${C_OFF}"
    echo "(Nodes -> certificate). Finish with a line containing only: EOF"
    echo
    : >"$CERT_FILE"
    local line
    while IFS= read -r line; do
      [ "$line" = "EOF" ] && break
      printf '%s\n' "$line" >>"$CERT_FILE"
    done
  fi
  grep -q "BEGIN CERTIFICATE" "$CERT_FILE" \
    || die "$CERT_FILE does not look like a PEM certificate"
  chmod 600 "$CERT_FILE"
  ok "certificate saved to $CERT_FILE"
}

install_xray_config() {
  if [ -s "$XRAY_CONFIG" ]; then
    ok "xray_config.json already exists — kept untouched"
    return 0
  fi
  info "fetching default xray_config.json"
  curl -fsSL "${MARZNODE_GIT}/raw/master/xray_config.json" -o "$XRAY_CONFIG" \
    || die "could not download xray_config.json"
  ok "xray_config.json installed"
}

open_firewall_port() {
  local port="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 && info "ufw: opened ${port}/tcp"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
    info "firewalld: opened ${port}/tcp"
  fi
}

set_service_port() {
  local port="$1" dir file
  dir="$(detect_app_dir)"; file="$dir/compose.yml"
  [ -f "$file" ] || die "compose.yml not found in $dir"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ] \
    || die "invalid port: $port"
  backup_compose "$file"
  set_env "SERVICE_PORT" "$port" "$file"
  open_firewall_port "$port"
  ok "SERVICE_PORT set to $port"
}

step_install_marznode() {
  info "step 3/4 — marznode"
  local dir; dir="$(detect_app_dir)"

  mkdir -p "$MARZNODE_DIR" "$ASSETS_DIR"
  install_cert
  install_xray_config

  if [ -d "$dir/.git" ]; then
    info "existing checkout found in $dir — pulling"
    git -C "$dir" pull --ff-only || warn "git pull failed; continuing with local copy"
  elif [ -f "$dir/compose.yml" ]; then
    info "using existing compose project in $dir"
  else
    info "cloning marznode into $dir"
    rm -rf "$dir"
    git clone --depth 1 "$MARZNODE_GIT" "$dir" || die "git clone failed"
  fi

  local port="${WANT_PORT:-}"
  if [ -z "$port" ]; then
    if grep -qE '^[[:space:]]*SERVICE_PORT:' "$dir/compose.yml"; then
      port="$(grep -E '^[[:space:]]*SERVICE_PORT:' "$dir/compose.yml" \
              | head -n1 | tr -d ' "' | cut -d: -f2)"
    else
      port="$DEFAULT_PORT"
    fi
  fi
  set_service_port "$port"

  info "pulling image and starting the container"
  ( cd "$dir" && docker compose pull -q && docker compose up -d )
  sleep 5
  if compose ps --status running 2>/dev/null | grep -q marznode; then
    ok "marznode is running in $dir on port $port"
  else
    warn "container is not reported as running — check: cd $dir && docker compose logs -f"
  fi
}

# ============================================================== STEP 4: xray
latest_xray_version() {
  local json ver url
  # primary: GitHub API
  if json="$(curl -fsSL "https://api.github.com/repos/${XRAY_REPO}/releases/latest" 2>/dev/null)"; then
    ver="$(printf '%s\n' "$json" | grep -m1 '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')"
    [ -n "$ver" ] && { printf '%s' "$ver"; return 0; }
  fi
  # fallback: follow the /releases/latest redirect (works when the API is rate limited)
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "https://github.com/${XRAY_REPO}/releases/latest" 2>/dev/null)" || return 1
  ver="${url##*/tag/}"; ver="${ver#v}"
  [ -n "$ver" ] && [ "$ver" != "$url" ] || return 1
  printf '%s' "$ver"
}

step_change_core() {
  info "step 4/4 — xray core"
  local ver="${CORE_VERSION:-latest}"
  if [ "$ver" = "latest" ] || [ -z "$ver" ]; then
    info "resolving latest release of ${XRAY_REPO}"
    ver="$(latest_xray_version)" || true
    [ -n "$ver" ] || die "could not resolve the latest version; pass one explicitly"
  fi
  ver="${ver#v}"

  local zip url tmp
  zip="$(detect_arch)"
  url="https://github.com/${XRAY_REPO}/releases/download/v${ver}/${zip}"
  info "arch $(uname -m) | asset $zip | version v$ver"

  command -v unzip >/dev/null 2>&1 || { apt_env; apt-get install -y -qq unzip; }

  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" RETURN

  curl -fL --retry 3 --progress-bar -o "$tmp/$zip" "$url" \
    || die "download failed — check the version at https://github.com/${XRAY_REPO}/releases"
  unzip -o -q "$tmp/$zip" -d "$tmp/x" || die "unzip failed"
  [ -f "$tmp/x/xray" ] || die "xray binary not found inside the archive"
  chmod +x "$tmp/x/xray"

  local newver
  newver="$("$tmp/x/xray" version 2>/dev/null | head -n1)" \
    || die "the downloaded binary does not run on this host"

  mkdir -p "$ASSETS_DIR"
  [ -f "$XRAY_BIN" ] && cp -f "$XRAY_BIN" "${XRAY_BIN}.bak"
  install -m 755 "$tmp/x/xray" "$XRAY_BIN"
  for f in geoip.dat geosite.dat; do
    [ -f "$tmp/x/$f" ] && install -m 644 "$tmp/x/$f" "$ASSETS_DIR/$f"
  done
  ok "installed: $newver"

  local dir file; dir="$(detect_app_dir)"; file="$dir/compose.yml"
  [ -f "$file" ] || die "compose.yml not found in $dir — install the node first"
  backup_compose "$file"
  set_env "XRAY_EXECUTABLE_PATH" "$XRAY_BIN"  "$file"
  set_env "XRAY_ASSETS_PATH"     "$ASSETS_DIR" "$file"
  ok "compose.yml updated"

  info "restarting marznode (users on this node drop for a few seconds)"
  ( cd "$dir" && docker compose down && docker compose up -d )
  sleep 5
  if compose ps --status running 2>/dev/null | grep -q marznode; then
    ok "core switched to v$ver"
  else
    warn "container did not come up — restoring the previous binary"
    [ -f "${XRAY_BIN}.bak" ] && install -m 755 "${XRAY_BIN}.bak" "$XRAY_BIN"
    ( cd "$dir" && docker compose up -d ) || true
    die "rollback done; inspect: cd $dir && docker compose logs -f"
  fi
}

# ------------------------------------------------------------------ utilities
show_status() {
  local dir; dir="$(detect_app_dir)"
  echo
  printf '%sinstall dir%s   %s\n' "$C_BLD" "$C_OFF" "$dir"
  printf '%sdata dir%s      %s\n' "$C_BLD" "$C_OFF" "$MARZNODE_DIR"
  if [ -f "$CERT_FILE" ]; then ok "client.pem present"; else warn "client.pem missing"; fi
  if [ -f "$XRAY_CONFIG" ]; then ok "xray_config.json present"; else warn "xray_config.json missing"; fi
  if [ -x "$XRAY_BIN" ]; then ok "custom core: $("$XRAY_BIN" version | head -n1)"; else
    info "custom core: not installed (image default in use)"; fi
  if [ -f "$dir/compose.yml" ]; then
    grep -E '^[[:space:]]*(SERVICE_PORT|XRAY_EXECUTABLE_PATH|XRAY_ASSETS_PATH):' \
      "$dir/compose.yml" || info "SERVICE_PORT not set (default $DEFAULT_PORT)"
    echo
    ( cd "$dir" && docker compose ps ) 2>/dev/null || true
  else
    warn "no compose.yml found — node not installed"
  fi
  echo
}

show_logs()    { compose logs -f --tail 100; }
restart_node() { compose down && compose up -d && ok "restarted"; }

update_node() {
  local dir; dir="$(detect_app_dir)"
  [ -d "$dir/.git" ] && git -C "$dir" pull --ff-only || true
  ( cd "$dir" && docker compose pull && docker compose up -d )
  ok "marznode image updated"
}

uninstall_node() {
  local dir; dir="$(detect_app_dir)"
  confirm "Stop and remove the marznode container from $dir?" || return 0
  ( cd "$dir" && docker compose down -v ) 2>/dev/null || true
  rm -rf "$dir"
  ok "container and $dir removed"
  if confirm "Also delete $MARZNODE_DIR (certificate, config, core)?"; then
    rm -rf "$MARZNODE_DIR"
    ok "$MARZNODE_DIR removed"
  else
    info "$MARZNODE_DIR kept"
  fi
}

install_shortcut() {
  curl -fsSL "${REPO_RAW}/install.sh" -o /usr/local/bin/marznode-setup \
    && chmod +x /usr/local/bin/marznode-setup \
    && ok "shortcut installed — run: marznode-setup" \
    || warn "could not install the shortcut"
}

# ----------------------------------------------------------------- menu / cli
banner() {
  cat <<BANNER
${C_BLD}
  marznode-setup v${SCRIPT_VERSION}
  automatic node installer + xray core manager for Marzneshin
${C_OFF}
BANNER
}

menu() {
  banner
  cat <<'MENU'
  1) Full install       (update -> docker -> marznode -> xray core)
  2) Update server packages only
  3) Install docker only
  4) Install / repair marznode only
  5) Change or update the xray core
  6) Change SERVICE_PORT
  7) Status
  8) Logs
  9) Restart node
 10) Update marznode (git pull + image pull)
 11) Install the "marznode-setup" shortcut
 12) Uninstall
  0) Exit
MENU
  local choice; choice="$(ask "select" "1")"
  case "$choice" in
    1) step_update_server; step_install_docker; step_install_marznode
       if confirm "Replace the built-in xray core with a specific version?"; then
         CORE_VERSION="$(ask "version (or 'latest')" "latest")"; step_change_core
       fi ;;
    2) step_update_server ;;
    3) step_install_docker ;;
    4) step_install_marznode ;;
    5) CORE_VERSION="$(ask "version (or 'latest')" "latest")"; step_change_core ;;
    6) set_service_port "$(ask "port" "$DEFAULT_PORT")"; restart_node ;;
    7) show_status ;;
    8) show_logs ;;
    9) restart_node ;;
   10) update_node ;;
   11) install_shortcut ;;
   12) uninstall_node ;;
    0) exit 0 ;;
    *) die "invalid choice" ;;
  esac
}

usage() {
  cat <<USAGE
marznode-setup v${SCRIPT_VERSION}

Usage: install.sh [options]
  (no options)          interactive menu

  --all                 run every step: update, docker, node, core
  --update              update system packages
  --full-upgrade        with --update, also run apt upgrade
  --docker              install docker + compose plugin
  --node                install / repair marznode
  --core [VERSION]      install an xray core (default: latest)
  --port PORT           SERVICE_PORT (default ${DEFAULT_PORT})
  --dir PATH            marznode project dir (default ${APP_DIR_DEFAULT})
  --cert-file PATH      read client.pem from a local file
  --cert-url URL        download client.pem from a URL
  --status | --logs | --restart | --update-node | --uninstall
  -y, --yes             assume yes for all prompts
  -h, --help            this help

Examples:
  install.sh --all --cert-file /root/client.pem --port 53042 -y
  install.sh --core 25.8.3
  install.sh --core latest
USAGE
}

main() {
  need_root
  local ran=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all)          DO_UPDATE=1; DO_DOCKER=1; DO_NODE=1; DO_CORE=1 ;;
      --update)       DO_UPDATE=1 ;;
      --full-upgrade) DO_UPDATE=1; FULL_UPGRADE=1 ;;
      --docker)       DO_DOCKER=1 ;;
      --node)         DO_NODE=1 ;;
      --core)         DO_CORE=1
                      if [ "${2:-}" ] && [[ "${2}" != -* ]]; then CORE_VERSION="$2"; shift; fi ;;
      --port)         WANT_PORT="${2:?--port needs a value}"; shift ;;
      --dir)          APP_DIR="${2:?--dir needs a value}"; shift ;;
      --cert-file)    CERT_SRC_FILE="${2:?--cert-file needs a path}"; shift ;;
      --cert-url)     CERT_SRC_URL="${2:?--cert-url needs a url}"; shift ;;
      --status)       show_status; ran=1 ;;
      --logs)         show_logs; ran=1 ;;
      --restart)      restart_node; ran=1 ;;
      --update-node)  update_node; ran=1 ;;
      --uninstall)    uninstall_node; ran=1 ;;
      -y|--yes)       ASSUME_YES=1 ;;
      -h|--help)      usage; exit 0 ;;
      *)              usage; die "unknown option: $1" ;;
    esac
    shift
  done

  if [ $((DO_UPDATE + DO_DOCKER + DO_NODE + DO_CORE)) -eq 0 ]; then
    [ "$ran" -eq 1 ] && exit 0
    menu
    exit 0
  fi

  banner
  [ "$DO_UPDATE" -eq 1 ] && step_update_server
  [ "$DO_DOCKER" -eq 1 ] && step_install_docker
  [ "$DO_NODE"   -eq 1 ] && step_install_marznode
  [ "$DO_CORE"   -eq 1 ] && step_change_core
  echo
  ok "all done — status: install.sh --status"
}

main "$@"
