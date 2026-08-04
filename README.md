<div align="center">

# marznode-setup

نصب خودکار **نود مرزنشین (marznode)** و مدیریت هسته‌ی **Xray** — با یک اسکریپت

`آپدیت سرور` ← `DNS` ← `نصب داکر` ← `نصب مرزنود` ← `کانفیگ` ← `تغییر هسته Xray` ← `سرتیفیکیت` ← `WARP`

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
| ۲ | تنظیم DNS (`1.1.1.1` / `8.8.8.8`) |
| ۳ | نصب داکر از `get.docker.com` (اگر نصب باشد رد می‌شود) و بررسی افزونه‌ی `docker compose` |
| ۴ | ساخت `/var/lib/marznode`، دریافت `client.pem`، دانلود `xray_config.json`، کلون مرزنود در `/opt/marznode`، ست کردن `SERVICE_PORT` و `XRAY_RESTART_ON_FAILURE`، باز کردن پورت در فایروال و `docker compose up -d` |
| ۵ | دانلود هسته‌ی Xray متناسب با معماری سرور، نصب در `/var/lib/marznode`، ست کردن `XRAY_EXECUTABLE_PATH` و `XRAY_ASSETS_PATH` و ری‌استارت نود |
| ۶ | (اختیاری) گرفتن سرتیفیکیت دامنه‌ها و نصب WARP |

گواهی نود (`client.pem`) را می‌توانید به سه شکل بدهید:

- **پیست مستقیم** در ترمینال (پایان با خط `EOF`)
- `--cert-file /path/to/client.pem`
- `--cert-url https://...`

---

## 🔐 گرفتن سرتیفیکیت برای دامنه‌ها

```bash
marznode-setup            # گزینه‌ی ۷ از منو
# یا
marznode-setup --certs node1.example.com,node2.example.com --email you@mail.com -y
```

در حالت تعاملی اول می‌پرسد **برای چند دامنه سرت می‌خواهید؟** و بعد دامنه‌ها را یکی‌یکی می‌گیرد.

مسیر ذخیره‌سازی به‌صورت خودکار تشخیص داده می‌شود:

| شرایط | مسیر پیش‌فرض |
|---|---|
| اگر `/var/lib/marzneshin` وجود داشته باشد (سرور پنل) | `/var/lib/marzneshin/certs/` |
| در غیر این صورت (سرور نود) | `/var/lib/marznode/certs/` |
| دستی | `--certs-dir /path/...` |

هر دامنه در **پوشه‌ی جدا** ذخیره می‌شود تا با چند دامنه روی هم نیفتند:

```
/var/lib/marznode/certs/
├── fullchain.pem            ← کپی مسطح دامنه‌ی اول (سازگاری با کانفیگ‌های قبلی)
├── privkey.pem
├── node1.example.com/
│   ├── fullchain.pem
│   └── privkey.pem
└── node2.example.com/
    ├── fullchain.pem
    └── privkey.pem
```

**تمدید خودکار:** یک deploy-hook در `/etc/letsencrypt/renewal-hooks/deploy/marznode-certs.sh` نصب می‌شود که بعد از هر تمدید، فایل‌ها را دوباره کپی و کانتینر را ری‌استارت می‌کند.

قبل از صدور، اسکریپت رکورد DNS دامنه را با IP سرور مقایسه می‌کند و اگر پورت ۸۰ اشغال باشد هشدار می‌دهد و پیشنهاد می‌کند کانتینر موقتاً stop شود.

---

## 🌐 نصب WARP (wgcf)

```bash
marznode-setup --warp
marznode-setup --warp-on | --warp-off | --warp-status
```

- آخرین نسخه‌ی `wgcf` به‌صورت خودکار و متناسب با معماری سرور نصب می‌شود.
- اکانت WARP در `/etc/wireguard/wgcf/` نگهداری می‌شود؛ اجرای مجدد اکانت جدید نمی‌سازد.
- پروفایل با `MTU = 1420` و **`Table = off`** ساخته و در `/etc/wireguard/warp.conf` قرار می‌گیرد.

> ⚠️ `Table = off` یعنی WARP مسیر پیش‌فرض سرور **نمی‌شود**. این عمداً است — در غیر این صورت خود نود ارتباطش با پنل را از دست می‌دهد. برای استفاده باید در `xray_config.json` یک outbound به اینترفیس/آدرس warp ببندید.

---

## 🧭 تنظیم DNS

```bash
marznode-setup --dns                    # 1.1.1.1 8.8.8.8
marznode-setup --dns "9.9.9.9 8.8.4.4"
```

اگر `systemd-resolved` فعال باشد فایل `/etc/systemd/resolved.conf` ویرایش می‌شود (با بکاپ)، در غیر این صورت مستقیم `/etc/resolv.conf` نوشته می‌شود.

---

## 🎛️ آپشن‌های خط فرمان

```
--all                 اجرای همه‌ی مراحل
--update              فقط آپدیت پکیج‌های سیستم
--full-upgrade        همراه با apt upgrade کامل (پیش‌فرض خاموش است)
--dns [RESOLVERS]     تنظیم DNS (پیش‌فرض 1.1.1.1 8.8.8.8)
--docker              فقط نصب داکر
--node                فقط نصب / تعمیر مرزنود
--core [VERSION]      نصب هسته Xray (پیش‌فرض: latest)
--certs [d1,d2,...]   گرفتن سرت Let's Encrypt (خالی = تعاملی)
--email ADDR          ایمیل ثبت‌نام Let's Encrypt
--certs-dir PATH      مسیر ذخیره‌ی سرت‌ها
--warp                نصب WARP با wgcf
--warp-on/-off/-status  مدیریت سرویس WARP
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
- ست کردن `XRAY_RESTART_ON_FAILURE: "True"` و `XRAY_RESTART_ON_FAILURE_INTERVAL: "5"` هنگام نصب نود
- تمدید خودکار سرتیفیکیت‌ها با deploy-hook (کپی مجدد + ری‌استارت نود)
- `--status` تاریخ انقضای سرت‌ها و وضعیت WARP را هم نشان می‌دهد

---

## 📋 پیش‌نیازها

- سرور Debian / Ubuntu با دسترسی `root`
- گواهی نود از پنل مرزنشین (بخش Nodes → Certificate)
- پورت پیش‌فرض `53042` باید بین پنل و نود یکسان باشد.
- برای گرفتن سرت: دامنه باید به IP همین سرور اشاره کند و پورت ۸۰ آزاد باشد.

## ⚠️ هشدارها

- تعویض هسته باعث `down`/`up` شدن کانتینر می‌شود؛ کاربران آن نود چند ثانیه قطع می‌شوند.
- `--full-upgrade` ممکن است سرویس‌ها یا کرنل را ری‌استارت کند؛ روی نود پرترافیک با احتیاط استفاده کنید.
- هسته‌ی سفارشی روی هاست نصب می‌شود و از طریق ولوم `/var/lib/marznode` داخل کانتینر اجرا می‌شود؛ پس از هر آپدیت ایمیج مرزنود، هسته‌ی شما دست‌نخورده باقی می‌ماند.
- اگر دامنه پشت پروکسی ابری (ابر نارنجی) باشد، `certbot --standalone` شکست می‌خورد.
- پیش از اجرای هر اسکریپت با `curl | bash`، محتوای آن را بخوانید.

---

## 📜 تاریخچه

نسخه‌ی قبلی این مخزن فقط `change-core.sh` (تعویض هسته) بود. آن اسکریپت هنوز کار می‌کند ولی صرفاً به `install.sh --core` هدایت می‌شود.
