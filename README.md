<div align="center">

# marznode-setup

نصب خودکار **نود مرزنشین (marznode)** و مدیریت هسته‌ی **Xray** — با یک اسکریپت

`آپدیت سرور` ← `نصب داکر` ← `نصب مرزنود` ← `کانفیگ` ← `تغییر هسته Xray`

</div>

---

## ⚡ اجرای سریع (منوی تعاملی)

```bash
bash <(curl -sL https://raw.githubusercontent.com/Cmd81/up-marznode-xray/main/install.sh)
```

منو باز می‌شود و می‌توانید گزینه‌ی «نصب کامل» یا هر مرحله را جداگانه اجرا کنید.

## 🤖 نصب کامل و بدون تعامل

اگر فایل گواهی را از قبل روی سرور دارید:

```bash
curl -sL https://raw.githubusercontent.com/Cmd81/up-marznode-xray/main/install.sh -o install.sh
bash install.sh --all --cert-file /root/client.pem --port 53042 -y
```

## 📌 نصب دائمی (شورتکات)

```bash
curl -sL https://raw.githubusercontent.com/Cmd81/up-marznode-xray/main/install.sh -o /usr/local/bin/marznode-setup
chmod +x /usr/local/bin/marznode-setup
```

از این پس فقط `marznode-setup` را اجرا کنید.

---

## 🔧 مراحلی که اسکریپت انجام می‌دهد

| مرحله | کار |
|---|---|
| ۱ | `apt update` و نصب پیش‌نیازها (`curl`, `wget`, `unzip`, `git`, `jq`, `socat`, …) + همگام‌سازی ساعت سرور |
| ۲ | نصب داکر از `get.docker.com` (اگر نصب باشد رد می‌شود) و بررسی افزونه‌ی `docker compose` |
| ۳ | ساخت `/var/lib/marznode`، دریافت `client.pem`، دانلود `xray_config.json`، کلون مرزنود در `/opt/marznode`، ست کردن `SERVICE_PORT`، باز کردن پورت در فایروال و `docker compose up -d` |
| ۴ | دانلود هسته‌ی Xray متناسب با معماری سرور، نصب در `/var/lib/marznode`، ست کردن `XRAY_EXECUTABLE_PATH` و `XRAY_ASSETS_PATH` و ری‌استارت نود |

گواهی را می‌توانید به سه شکل بدهید:

- **پیست مستقیم** در ترمینال (پایان با خط `EOF`)
- `--cert-file /path/to/client.pem`
- `--cert-url https://...`

---

## 🎛️ آپشن‌های خط فرمان

```
--all                 اجرای همه‌ی مراحل
--update              فقط آپدیت پکیج‌های سیستم
--full-upgrade        همراه با apt upgrade کامل (پیش‌فرض خاموش است)
--docker              فقط نصب داکر
--node                فقط نصب / تعمیر مرزنود
--core [VERSION]      نصب هسته Xray (پیش‌فرض: latest)
--port PORT           تعیین SERVICE_PORT (پیش‌فرض 53042)
--dir PATH            مسیر پروژه مرزنود (پیش‌فرض /opt/marznode)
--cert-file PATH      خواندن client.pem از فایل
--cert-url URL        دانلود client.pem از لینک
--status              نمایش وضعیت نصب و کانتینر
--logs                لاگ زنده
--restart             ری‌استارت نود
--update-node         git pull + docker compose pull
--uninstall           حذف نود
-y, --yes             تأیید خودکار همه‌ی سؤالات
```

نمونه‌ها:

```bash
marznode-setup --core latest      # آخرین هسته
marznode-setup --core 25.8.3      # نسخه‌ی مشخص
marznode-setup --port 53043       # تغییر پورت
marznode-setup --status
```

لیست نسخه‌های هسته: <https://github.com/XTLS/Xray-core/releases>

---

## ✨ ویژگی‌ها

- **ایمن در اجرای مجدد (idempotent)**: اگر گواهی، کانفیگ یا داکر از قبل باشد، دست نمی‌خورد؛ `xray_config.json` موجود هرگز بازنویسی نمی‌شود.
- **تشخیص خودکار مسیر نصب**: اگر قبلاً نود را در `/root/marznode` نصب کرده‌اید، همان مسیر استفاده می‌شود.
- **تشخیص معماری**: amd64 / arm64 / armv7 / armv6 / s390x
- **بازگشت خودکار (rollback)**: اگر بعد از تعویض هسته کانتینر بالا نیامد، باینری قبلی برگردانده می‌شود.
- **بکاپ تاریخ‌دار** از `compose.yml` قبل از هر تغییر
- **فایروال**: پورت سرویس در `ufw` یا `firewalld` فعال باز می‌شود.
- نصب `geoip.dat` و `geosite.dat` همراه هسته در `XRAY_ASSETS_PATH`

---

## 📋 پیش‌نیازها

- سرور Debian / Ubuntu با دسترسی `root`
- گواهی نود از پنل مرزنشین (بخش Nodes → Certificate)
- پورت پیش‌فرض `53042` باید بین پنل و نود یکسان باشد.

## ⚠️ هشدارها

- تعویض هسته باعث `down`/`up` شدن کانتینر می‌شود؛ کاربران آن نود چند ثانیه قطع می‌شوند.
- `--full-upgrade` ممکن است سرویس‌ها یا کرنل را ری‌استارت کند؛ روی نود پرترافیک با احتیاط استفاده کنید.
- هسته‌ی سفارشی روی هاست نصب می‌شود و از طریق ولوم `/var/lib/marznode` داخل کانتینر اجرا می‌شود؛ پس از هر آپدیت ایمیج مرزنود، هسته‌ی شما دست‌نخورده باقی می‌ماند.
- پیش از اجرای هر اسکریپت با `curl | bash`، محتوای آن را بخوانید.

---

## 📜 تاریخچه

نسخه‌ی قبلی این مخزن فقط `change-core.sh` (تعویض هسته) بود. آن اسکریپت هنوز کار می‌کند ولی صرفاً به `install.sh --core` هدایت می‌شود.
