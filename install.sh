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

SCRIPT_VERSION="2.1.0"
REPO_RAW="https://raw.githubusercontent.com/Cmd81/up-marznode-xray/main"

MARZNODE_DIR="/var/lib/marznode"
MARZNESHIN_DIR="/var/lib/marzneshin"
ASSETS_DIR="${MARZNODE_DIR}/data"
CERT_FILE="${MARZNODE_DIR}/client.pem"
XRAY_CONFIG="${MARZNODE_DIR}/xray_config.json"
XRAY_BIN="${MARZNODE_DIR}/xray"

APP_DIR_DEFAULT="/opt/marznode"
MARZNODE_GIT="https://github.com/marzneshin/marznode"
XRAY_REPO="XTLS/Xray-core"
WGCF_REPO="ViRb3/wgcf"
DEFAULT_PORT="53042"
DEFAULT_DNS="1.1.1.1 8.8.8.8"
WARP_MTU="1420"
WGCF_DIR="/etc/wireguard/wgcf"

# runtime flags
ASSUME_YES=0
DO_UPDATE=0
DO_DOCKER=0
DO_NODE=0
DO_CORE=0
DO_DNS=0
DO_CERTS=0
DO_WARP=0
CORE_VERSION=""
WANT_PORT=""
CERT_SRC_FILE=""
CERT_SRC_URL=""
FULL_UPGRADE=0
APP_DIR=""
CERTS_BASE=""
LE_EMAIL=""
DOMAIN_LIST=""
DNS_SERVERS="$DEFAULT_DNS"
WIZARD=0

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

  # keep xray supervised: restart it inside the container if it dies
  set_env "XRAY_RESTART_ON_FAILURE"          "True" "$dir/compose.yml"
  set_env "XRAY_RESTART_ON_FAILURE_INTERVAL" "5"    "$dir/compose.yml"

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

# ================================================================= STEP: DNS
step_setup_dns() {
  local dns="${1:-$DEFAULT_DNS}"
  info "configuring resolvers: $dns"
  if [ -f /etc/systemd/resolved.conf ] && systemctl list-unit-files 2>/dev/null | grep -q systemd-resolved; then
    cp -f /etc/systemd/resolved.conf "/etc/systemd/resolved.conf.bak.$(date +%Y%m%d-%H%M%S)"
    if grep -qE '^[#[:space:]]*DNS=' /etc/systemd/resolved.conf; then
      sed -i -E "s|^[#[:space:]]*DNS=.*|DNS=${dns}|" /etc/systemd/resolved.conf
    else
      printf 'DNS=%s\n' "$dns" >>/etc/systemd/resolved.conf
    fi
    systemctl restart systemd-resolved
    ok "systemd-resolved updated"
  else
    warn "systemd-resolved not present — writing /etc/resolv.conf directly"
    cp -f /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    : >/etc/resolv.conf
    local s; for s in $dns; do printf 'nameserver %s\n' "$s" >>/etc/resolv.conf; done
    ok "/etc/resolv.conf updated"
  fi
  getent hosts github.com >/dev/null 2>&1 \
    && ok "name resolution works" \
    || warn "name resolution test failed — check the settings"
}

# =============================================================== STEP: certbot
# Decide where issued certificates are copied to.
resolve_certs_base() {
  if [ -n "$CERTS_BASE" ]; then echo "$CERTS_BASE"; return; fi
  if [ -d "$MARZNESHIN_DIR" ]; then echo "${MARZNESHIN_DIR}/certs"; return; fi
  echo "${MARZNODE_DIR}/certs"
}

server_ip() {
  curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null \
    || ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}'
}

# Warn (do not block) when the domain does not point at this server.
check_domain_dns() {
  local domain="$1" mine resolved
  mine="$(server_ip)"; resolved="$(getent hosts "$domain" | awk '{print $1; exit}')"
  if [ -z "$resolved" ]; then
    warn "$domain does not resolve yet — certbot will fail"
    return 1
  fi
  if [ -n "$mine" ] && [ "$resolved" != "$mine" ]; then
    warn "$domain -> $resolved but this server is $mine (Cloudflare proxy? disable the orange cloud)"
    return 1
  fi
  ok "$domain -> $resolved"
  return 0
}

port80_holder() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -lntpH 2>/dev/null | awk '$4 ~ /:80$/ {print $6; exit}'
}

copy_domain_cert() {
  local domain="$1" base="$2" live="/etc/letsencrypt/live/$1" dest
  [ -d "$live" ] || { warn "no live directory for $domain"; return 1; }
  dest="$base/$domain"
  install -d -m 755 "$dest"
  cp -fL "$live/fullchain.pem" "$dest/fullchain.pem"
  cp -fL "$live/privkey.pem"   "$dest/privkey.pem"
  chmod 644 "$dest/fullchain.pem"; chmod 600 "$dest/privkey.pem"
  ok "copied -> $dest/{fullchain,privkey}.pem"
}

# Certbot only renews; it does not copy. Without this hook the copies under
# /var/lib/... silently go stale after 90 days.
install_renew_hook() {
  local base="$1" dir; dir="$(detect_app_dir)"
  install -d -m 755 /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/marznode-certs.sh <<HOOK
#!/usr/bin/env bash
# generated by marznode-setup — re-copies renewed certificates and reloads the node
set -euo pipefail
BASE="$base"
APP_DIR="$dir"
for live in /etc/letsencrypt/live/*/; do
  d="\$(basename "\$live")"
  [ "\$d" = "README" ] && continue
  install -d -m 755 "\$BASE/\$d"
  cp -fL "\$live/fullchain.pem" "\$BASE/\$d/fullchain.pem"
  cp -fL "\$live/privkey.pem"   "\$BASE/\$d/privkey.pem"
  chmod 644 "\$BASE/\$d/fullchain.pem"; chmod 600 "\$BASE/\$d/privkey.pem"
done
if [ -f "\$APP_DIR/compose.yml" ]; then
  cd "\$APP_DIR" && docker compose restart || true
fi
HOOK
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/marznode-certs.sh
  ok "renewal hook installed (/etc/letsencrypt/renewal-hooks/deploy/marznode-certs.sh)"
}

issue_cert() {
  local domain="$1" base="$2" stopped=0 holder
  info "issuing a certificate for $domain"
  check_domain_dns "$domain" || confirm "DNS looks wrong. Continue anyway?" || return 1

  holder="$(port80_holder)"
  if [ -n "$holder" ]; then
    warn "port 80 is busy ($holder) — certbot --standalone needs it"
    if confirm "Temporarily stop the marznode container to free port 80?"; then
      compose down >/dev/null 2>&1 && stopped=1
    else
      warn "skipping $domain"; return 1
    fi
  fi

  local args=(certonly --standalone -d "$domain" --agree-tos --no-eff-email
              --non-interactive --keep-until-expiring)
  if [ -n "$LE_EMAIL" ]; then
    args+=(--email "$LE_EMAIL")
  else
    args+=(--register-unsafely-without-email)
  fi

  if certbot "${args[@]}"; then
    copy_domain_cert "$domain" "$base"
  else
    err "certbot failed for $domain"
    [ "$stopped" -eq 1 ] && compose up -d >/dev/null 2>&1
    return 1
  fi
  [ "$stopped" -eq 1 ] && compose up -d >/dev/null 2>&1
  return 0
}

step_get_certs() {
  need_apt; apt_env
  info "step — TLS certificates (Let's Encrypt)"
  command -v certbot >/dev/null 2>&1 || { info "installing certbot"; apt-get install -y -qq certbot; }

  local base; base="$(resolve_certs_base)"
  install -d -m 755 "$base"
  info "certificates will be placed in: $base"

  local -a domains=()
  if [ -n "$DOMAIN_LIST" ]; then
    IFS=',' read -r -a domains <<<"$DOMAIN_LIST"
  else
    local count i d
    count="$(ask "How many domains do you want a certificate for?" "1")"
    [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -ge 1 ] || die "invalid count: $count"
    for ((i = 1; i <= count; i++)); do
      d="$(ask "domain #$i")"
      [ -n "$d" ] || die "empty domain"
      domains+=("$d")
    done
  fi
  [ -n "$LE_EMAIL" ] || LE_EMAIL="$(ask "email for Let's Encrypt (empty = none)" "")"

  local d failed=0 first=""
  for d in "${domains[@]}"; do
    d="$(echo "$d" | tr -d '[:space:]')"
    [ -n "$d" ] || continue
    if issue_cert "$d" "$base"; then
      [ -z "$first" ] && first="$d"
    else
      failed=$((failed + 1))
    fi
  done

  # convenience: flat copy of the primary domain at the base of the directory,
  # matching the layout used by older manual setups
  if [ -n "$first" ]; then
    cp -fL "$base/$first/fullchain.pem" "$base/fullchain.pem"
    cp -fL "$base/$first/privkey.pem"   "$base/privkey.pem"
    chmod 600 "$base/privkey.pem"
    info "primary domain $first also copied flat to $base/{fullchain,privkey}.pem"
  fi

  install_renew_hook "$base"
  [ "$failed" -eq 0 ] && ok "all certificates ready" || warn "$failed domain(s) failed"

  echo
  info "paths to use in the panel / xray config:"
  for d in "${domains[@]}"; do
    d="$(echo "$d" | tr -d '[:space:]')"
    [ -d "$base/$d" ] && printf '  %s -> %s/{fullchain,privkey}.pem\n' "$d" "$base/$d"
  done
  echo
}

# ================================================================== STEP: WARP
wgcf_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7)  echo "armv7" ;;
    armv6l)        echo "armv6" ;;
    i386|i686)     echo "386" ;;
    s390x)         echo "s390x" ;;
    *) die "wgcf: unsupported architecture $(uname -m)" ;;
  esac
}

latest_wgcf_version() {
  local json ver url
  if json="$(curl -fsSL "https://api.github.com/repos/${WGCF_REPO}/releases/latest" 2>/dev/null)"; then
    ver="$(printf '%s\n' "$json" | grep -m1 '"tag_name"' | cut -d'"' -f4 | sed 's/^v//')"
    [ -n "$ver" ] && { printf '%s' "$ver"; return 0; }
  fi
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "https://github.com/${WGCF_REPO}/releases/latest" 2>/dev/null)" || return 1
  ver="${url##*/tag/}"; ver="${ver#v}"
  [ -n "$ver" ] && [ "$ver" != "$url" ] || return 1
  printf '%s' "$ver"
}

step_install_warp() {
  need_apt; apt_env
  info "step — Cloudflare WARP (wgcf + wireguard)"
  apt-get install -y -qq wireguard wireguard-tools resolvconf >/dev/null \
    || die "could not install wireguard packages"

  if ! command -v wgcf >/dev/null 2>&1; then
    local ver arch
    ver="$(latest_wgcf_version)" || die "could not resolve the latest wgcf release"
    arch="$(wgcf_arch)"
    info "installing wgcf v$ver ($arch)"
    curl -fL --retry 3 --progress-bar \
      -o /usr/bin/wgcf \
      "https://github.com/${WGCF_REPO}/releases/download/v${ver}/wgcf_${ver}_linux_${arch}" \
      || die "wgcf download failed"
    chmod +x /usr/bin/wgcf
  fi
  ok "wgcf: $(command -v wgcf)"

  install -d -m 700 "$WGCF_DIR"
  cd "$WGCF_DIR"
  if [ ! -f "$WGCF_DIR/wgcf-account.toml" ]; then
    info "registering a new WARP account"
    wgcf register --accept-tos || die "wgcf register failed"
  else
    info "existing WARP account found — updating"
    wgcf update || warn "wgcf update failed; continuing with the current account"
  fi
  wgcf generate || die "wgcf generate failed"
  [ -f "$WGCF_DIR/wgcf-profile.conf" ] || die "wgcf-profile.conf was not produced"

  # MTU 1420 avoids fragmentation; Table=off keeps WARP from hijacking the
  # server's default route (otherwise the node loses its own connectivity).
  local prof="$WGCF_DIR/wgcf-profile.conf"
  grep -qE '^[[:space:]]*MTU[[:space:]]*=' "$prof" \
    && sed -i -E "s|^[[:space:]]*MTU[[:space:]]*=.*|MTU = ${WARP_MTU}|" "$prof" \
    || sed -i "0,/^\[Interface\]/s||&\nMTU = ${WARP_MTU}|" "$prof"
  grep -qE '^[[:space:]]*Table[[:space:]]*=' "$prof" \
    && sed -i -E "s|^[[:space:]]*Table[[:space:]]*=.*|Table = off|" "$prof" \
    || sed -i "0,/^\[Interface\]/s||&\nTable = off|" "$prof"

  install -m 600 "$prof" /etc/wireguard/warp.conf
  ok "/etc/wireguard/warp.conf written (MTU ${WARP_MTU}, Table off)"

  systemctl enable --now wg-quick@warp >/dev/null 2>&1 \
    || die "wg-quick@warp failed to start — check: journalctl -u wg-quick@warp"
  sleep 2
  warp_status
  warn "Table=off means WARP is NOT the default route. Traffic only uses it when"
  warn "an xray outbound is bound to the warp interface / its address."
}

warp_status() {
  if systemctl is-active --quiet wg-quick@warp 2>/dev/null; then
    ok "wg-quick@warp is active"
    wg show warp 2>/dev/null | head -n 8 || true
    local trace
    trace="$(curl -fsSL --max-time 8 --interface warp https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^warp=' || true)"
    [ -n "$trace" ] && info "cloudflare trace via warp: $trace"
  else
    info "wg-quick@warp is not running"
  fi
}

warp_disable() {
  systemctl disable --now wg-quick@warp >/dev/null 2>&1 || true
  ok "warp disabled"
}

warp_enable() {
  [ -f /etc/wireguard/warp.conf ] || die "warp.conf not found — run the WARP install first"
  systemctl enable --now wg-quick@warp
  warp_status
}

# ================================================================ WIZARD MODE
# Ask every question up front, then run the seven steps back-to-back with no
# further prompts, then print one final report.
run_wizard() {
  banner
  echo "${C_BLD}Guided setup — answer a few questions, then everything runs automatically.${C_OFF}"
  echo

  # -------- 1/7 collect answers (nothing is executed yet) --------
  local do_upgrade wiz_port wiz_core wiz_warp wiz_ncerts
  local -a wiz_domains=()
  local wiz_email="" wiz_cert_src=""

  confirm "Run a full 'apt upgrade' too (can restart services)?" && do_upgrade=1 || do_upgrade=0

  ensure_tty && {
    if [ ! -s "$CERT_FILE" ] || ! grep -q "BEGIN CERTIFICATE" "$CERT_FILE" 2>/dev/null; then
      wiz_cert_src="$(ask "Path to the node's client.pem (empty = paste it later)" "")"
    fi
  }

  wiz_port="$(ask "SERVICE_PORT for this node" "$DEFAULT_PORT")"
  wiz_core="$(ask "Xray core version to install" "25.8.3")"

  confirm "Install Cloudflare WARP (wgcf) on this server?" && wiz_warp=1 || wiz_warp=0

  wiz_ncerts="$(ask "How many domains do you want a Let's Encrypt certificate for? (0 = skip)" "0")"
  [[ "$wiz_ncerts" =~ ^[0-9]+$ ]] || die "invalid number: $wiz_ncerts"
  if [ "$wiz_ncerts" -gt 0 ]; then
    local i d
    for ((i = 1; i <= wiz_ncerts; i++)); do
      d="$(ask "  domain #$i")"
      [ -n "$d" ] || die "empty domain"
      wiz_domains+=("$d")
    done
    wiz_email="$(ask "Email for Let's Encrypt (empty = register without one)" "")"
  fi

  echo
  info "All questions answered — running unattended from here on."
  echo

  # apply the collected answers to the globals the step_* functions read
  ASSUME_YES=1
  [ "$do_upgrade" -eq 1 ] && FULL_UPGRADE=1
  [ -n "$wiz_cert_src" ] && CERT_SRC_FILE="$wiz_cert_src"
  WANT_PORT="$wiz_port"
  CORE_VERSION="$wiz_core"
  LE_EMAIL="$wiz_email"
  if [ "$wiz_ncerts" -gt 0 ]; then
    DOMAIN_LIST="$(IFS=,; echo "${wiz_domains[*]}")"
  fi

  local t0 rc=0
  t0="$(date +%s)"

  # -------- 2/7 update & upgrade --------
  echo "${C_BLD}[1/7] Updating the server${C_OFF}"
  step_update_server || rc=1

  # -------- 3/7 install marznode --------
  echo; echo "${C_BLD}[2/7] Installing marznode${C_OFF}"
  step_install_docker || rc=1
  step_install_marznode || rc=1

  # -------- 4/7 config (port + cert already applied inside step 3) ---------
  echo; echo "${C_BLD}[3/7] Node configuration (port, certificate)${C_OFF}"
  ok "SERVICE_PORT=$wiz_port and client.pem were applied during install"

  # -------- 5/7 xray core --------
  echo; echo "${C_BLD}[4/7] Updating the Xray core to v${wiz_core}${C_OFF}"
  step_change_core || rc=1

  # -------- 6/7 warp --------
  if [ "$wiz_warp" -eq 1 ]; then
    echo; echo "${C_BLD}[5/7] Installing Cloudflare WARP${C_OFF}"
    step_install_warp || rc=1
  else
    echo; echo "${C_BLD}[5/7] Cloudflare WARP — skipped${C_OFF}"
  fi

  # -------- 7/7 certificates --------
  if [ "$wiz_ncerts" -gt 0 ]; then
    echo; echo "${C_BLD}[6/7] Issuing TLS certificates${C_OFF}"
    step_get_certs || rc=1
  else
    echo; echo "${C_BLD}[6/7] TLS certificates — skipped${C_OFF}"
  fi

  # -------- final report --------
  echo; echo "${C_BLD}[7/7] Final report${C_OFF}"
  wizard_report "$t0" "$wiz_port" "$wiz_core" "$wiz_warp" "$wiz_ncerts"

  return "$rc"
}

wizard_report() {
  local t0="$1" port="$2" core="$3" warp="$4" ncerts="$5"
  local dur; dur=$(( $(date +%s) - t0 ))
  local dir; dir="$(detect_app_dir)"
  local base; base="$(resolve_certs_base)"

  echo
  echo "══════════════════════════════════════════════════════════"
  echo "  ${C_BLD}marznode-setup — final report${C_OFF}  (${dur}s)"
  echo "══════════════════════════════════════════════════════════"

  printf '  %-20s ' "Server"
  if [ "${FULL_UPGRADE:-0}" -eq 1 ]; then echo "updated + upgraded"; else echo "updated (no full upgrade)"; fi

  printf '  %-20s %s\n' "Install dir" "$dir"

  printf '  %-20s ' "marznode container"
  if compose ps --status running 2>/dev/null | grep -q marznode; then
    echo "${C_GRN}running${C_OFF} on port $port"
  else
    echo "${C_RED}not running${C_OFF} — check: cd $dir && docker compose logs -f"
  fi

  printf '  %-20s ' "Xray core"
  if [ -x "$XRAY_BIN" ]; then
    echo "$("$XRAY_BIN" version 2>/dev/null | head -n1)  (requested v$core)"
  else
    echo "${C_YEL}not installed — image default in use (requested v$core)${C_OFF}"
  fi

  printf '  %-20s ' "Cloudflare WARP"
  if [ "$warp" -eq 1 ]; then
    if systemctl is-active --quiet wg-quick@warp 2>/dev/null; then
      echo "${C_GRN}active${C_OFF} (Table=off — not the default route)"
    else
      echo "${C_RED}requested but not active${C_OFF} — check: journalctl -u wg-quick@warp"
    fi
  else
    echo "skipped"
  fi

  printf '  %-20s ' "TLS certificates"
  if [ "$ncerts" -gt 0 ] && [ -d "$base" ]; then
    echo "$base"
    local d
    for d in "$base"/*/; do
      [ -d "$d" ] || continue
      printf '    - %-30s' "$(basename "$d")"
      if [ -f "$d/fullchain.pem" ] && command -v openssl >/dev/null 2>&1; then
        printf 'expires %s' "$(openssl x509 -enddate -noout -in "$d/fullchain.pem" 2>/dev/null | cut -d= -f2)"
      else
        printf '${C_RED}missing${C_OFF}'
      fi
      echo
    done
  else
    echo "skipped"
  fi

  echo "──────────────────────────────────────────────────────────"
  echo "  useful commands:"
  echo "    marznode-setup --status"
  echo "    cd $dir && docker compose logs -f"
  [ "$warp" -eq 1 ] && echo "    marznode-setup --warp-status"
  echo "══════════════════════════════════════════════════════════"
  echo
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
  local base; base="$(resolve_certs_base)"
  if [ -d "$base" ]; then
    echo
    info "certificates in $base:"
    local d
    for d in "$base"/*/; do
      [ -d "$d" ] || continue
      printf '  %s' "$(basename "$d")"
      if [ -f "$d/fullchain.pem" ] && command -v openssl >/dev/null 2>&1; then
        printf '  (expires %s)' \
          "$(openssl x509 -enddate -noout -in "$d/fullchain.pem" 2>/dev/null | cut -d= -f2)"
      fi
      echo
    done
  fi
  echo
  if systemctl is-active --quiet wg-quick@warp 2>/dev/null; then
    ok "warp: active"
  else
    info "warp: inactive"
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
  --- guided ------------------------------------------------------
  1) Guided full setup  (asks everything first, then runs it all)
  --- install (manual, step by step) -------------------------------
  2) Update server packages
  3) Set DNS resolvers (1.1.1.1 / 8.8.8.8)
  4) Install docker
  5) Install / repair marznode
  6) Change or update the xray core
  --- extras ----------------------------------------------------
  7) Get TLS certificates (Let's Encrypt / certbot)
  8) Install Cloudflare WARP (wgcf)
  9) WARP: enable / disable / status
  --- manage ----------------------------------------------------
 10) Change SERVICE_PORT
 11) Status
 12) Logs
 13) Restart node
 14) Update marznode (git pull + image pull)
 15) Install the "marznode-setup" shortcut
 16) Uninstall node
  0) Exit
MENU
  local choice; choice="$(ask "select" "1")"
  case "$choice" in
    1) run_wizard ;;
    2) step_update_server ;;
    3) step_setup_dns "$(ask "resolvers" "$DEFAULT_DNS")" ;;
    4) step_install_docker ;;
    5) step_install_marznode ;;
    6) CORE_VERSION="$(ask "version (or 'latest')" "latest")"; step_change_core ;;
    7) step_get_certs ;;
    8) step_install_warp ;;
    9) local w; w="$(ask "warp action (enable/disable/status)" "status")"
       case "$w" in
         enable)  warp_enable ;;
         disable) warp_disable ;;
         *)       warp_status ;;
       esac ;;
   10) set_service_port "$(ask "port" "$DEFAULT_PORT")"; restart_node ;;
   11) show_status ;;
   12) show_logs ;;
   13) restart_node ;;
   14) update_node ;;
   15) install_shortcut ;;
   16) uninstall_node ;;
    0) exit 0 ;;
    *) die "invalid choice" ;;
  esac
}

usage() {
  cat <<USAGE
marznode-setup v${SCRIPT_VERSION}

Usage: install.sh [options]
  (no options)          interactive menu

  --wizard              guided mode: ask everything up front, then run
                        update -> marznode -> config -> xray core -> warp ->
                        certificates -> final report, with no further prompts
  --all                 run every step: update, dns, docker, node, core
  --update              update system packages
  --full-upgrade        with --update, also run apt upgrade
  --dns [RESOLVERS]     set resolvers (default "${DEFAULT_DNS}")
  --docker              install docker + compose plugin
  --node                install / repair marznode
  --core [VERSION]      install an xray core (default: latest)
  --port PORT           SERVICE_PORT (default ${DEFAULT_PORT})
  --dir PATH            marznode project dir (default ${APP_DIR_DEFAULT})
  --cert-file PATH      read client.pem (node <-> panel) from a local file
  --cert-url URL        download client.pem from a URL

 TLS / domains:
  --certs [d1,d2,...]   issue Let's Encrypt certs (asks interactively if empty)
  --email ADDR          email used for Let's Encrypt registration
  --certs-dir PATH      where issued certs are copied
                        (default: ${MARZNESHIN_DIR}/certs if the panel is
                         installed, otherwise ${MARZNODE_DIR}/certs)

 WARP:
  --warp                install Cloudflare WARP via wgcf (Table=off)
  --warp-on | --warp-off | --warp-status

 Manage:
  --status | --logs | --restart | --update-node | --uninstall
  -y, --yes             assume yes for all prompts
  -h, --help            this help

Examples:
  install.sh --all --cert-file /root/client.pem --port 53042 -y
  install.sh --certs node1.example.com,node2.example.com --email you@mail.com -y
  install.sh --warp
  install.sh --core latest
USAGE
}

main() {
  need_root
  local ran=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --wizard)       WIZARD=1 ;;
      --all)          DO_UPDATE=1; DO_DNS=1; DO_DOCKER=1; DO_NODE=1; DO_CORE=1 ;;
      --update)       DO_UPDATE=1 ;;
      --full-upgrade) DO_UPDATE=1; FULL_UPGRADE=1 ;;
      --dns)          DO_DNS=1
                      if [ "${2:-}" ] && [[ "${2}" != -* ]]; then DNS_SERVERS="$2"; shift; fi ;;
      --docker)       DO_DOCKER=1 ;;
      --node)         DO_NODE=1 ;;
      --core)         DO_CORE=1
                      if [ "${2:-}" ] && [[ "${2}" != -* ]]; then CORE_VERSION="$2"; shift; fi ;;
      --certs)        DO_CERTS=1
                      if [ "${2:-}" ] && [[ "${2}" != -* ]]; then DOMAIN_LIST="$2"; shift; fi ;;
      --email)        LE_EMAIL="${2:?--email needs a value}"; shift ;;
      --certs-dir)    CERTS_BASE="${2:?--certs-dir needs a path}"; shift ;;
      --warp)         DO_WARP=1 ;;
      --warp-on)      warp_enable; ran=1 ;;
      --warp-off)     warp_disable; ran=1 ;;
      --warp-status)  warp_status; ran=1 ;;
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

  if [ "$WIZARD" -eq 1 ]; then
    run_wizard
    exit $?
  fi

  if [ $((DO_UPDATE + DO_DNS + DO_DOCKER + DO_NODE + DO_CORE + DO_CERTS + DO_WARP)) -eq 0 ]; then
    [ "$ran" -eq 1 ] && exit 0
    menu
    exit 0
  fi

  banner
  [ "$DO_UPDATE" -eq 1 ] && step_update_server
  [ "$DO_DNS"    -eq 1 ] && step_setup_dns "$DNS_SERVERS"
  [ "$DO_DOCKER" -eq 1 ] && step_install_docker
  [ "$DO_NODE"   -eq 1 ] && step_install_marznode
  [ "$DO_CORE"   -eq 1 ] && step_change_core
  [ "$DO_CERTS"  -eq 1 ] && step_get_certs
  [ "$DO_WARP"   -eq 1 ] && step_install_warp
  echo
  ok "all done — status: install.sh --status"
}

main "$@"
