#!/usr/bin/env bash
#
# up-marznode-xray — تغییر هسته Xray روی نودهای مرزنشین (marznode)
# https://github.com/Cmd81/up-marznode-xray
#
# استفاده:
#   bash change-core.sh              # نسخه پیش‌فرض
#   bash change-core.sh 25.9.11      # نسخه دلخواه
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

# --- بررسی دسترسی روت ---
[ "$(id -u)" -eq 0 ] || { red "این اسکریپت باید با کاربر root اجرا شود."; exit 1; }

# --- تشخیص معماری سرور ---
case "$(uname -m)" in
  x86_64|amd64)  ZIP="Xray-linux-64.zip" ;;
  aarch64|arm64) ZIP="Xray-linux-arm64-v8a.zip" ;;
  armv7l)        ZIP="Xray-linux-arm32-v7a.zip" ;;
  *) red "معماری $(uname -m) پشتیبانی نمی‌شود."; exit 1 ;;
esac
info "معماری: $(uname -m) | فایل: $ZIP | نسخه: v$XRAY_VERSION"

# --- بررسی اولیه compose.yml قبل از هر تغییری ---
[ -f "$COMPOSE_FILE" ] || { red "فایل $COMPOSE_FILE پیدا نشد. متغیر COMPOSE_DIR را اصلاح کنید."; exit 1; }
grep -qE "^[[:space:]]*environment:" "$COMPOSE_FILE" \
  || { red "بلاک environment در compose.yml پیدا نشد."; exit 1; }

# --- نصب پیش‌نیازها ---
info "نصب پیش‌نیازها"
apt-get update -qq
apt-get install -y -qq unzip wget

# --- دانلود و استخراج هسته ---
info "دانلود هسته"
mkdir -p "$DATA_DIR"
cd "$DATA_DIR"
URL="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/${ZIP}"
wget -q --show-progress -O "$ZIP" "$URL" \
  || { red "دانلود ناموفق بود. نسخه را بررسی کنید:"; echo "$URL"; exit 1; }

info "استخراج فایل"
unzip -o -q "$ZIP"
rm -f "$ZIP"
[ -f "$DATA_DIR/xray" ] || { red "فایل xray بعد از استخراج پیدا نشد."; exit 1; }

# --- قرار دادن باینری در مسیر marznode ---
cp -f "$DATA_DIR/xray" "$MARZNODE_DIR/xray"
chmod +x "$MARZNODE_DIR/xray"
green "نسخه نصب‌شده: $("$MARZNODE_DIR/xray" version | head -n1)"

# --- ویرایش compose.yml ---
BACKUP="$COMPOSE_FILE.bak.$(date +%Y%m%d-%H%M%S)"
cp "$COMPOSE_FILE" "$BACKUP"
info "بکاپ: $BACKUP"

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
green "compose.yml بروزرسانی شد."

# --- ریستارت marznode ---
info "ریستارت marznode"
cd "$COMPOSE_DIR"
docker compose down
docker compose up -d

green "تمام شد ✅   لاگ: cd $COMPOSE_DIR && docker compose logs -f"