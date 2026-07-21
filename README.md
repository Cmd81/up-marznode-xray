<div align="center">

# up-marznode-xray

تغییر و آپدیت هسته **Xray** روی نودهای **مرزنشین / Marzneshin** با یک دستور

</div>

---

## ⚡ نصب سریع

    bash <(curl -sL https://raw.githubusercontent.com/Cmd81/up-marznode-xray/main/change-core.sh)

بدون آرگومان، نسخه پیش‌فرض `25.8.3` نصب می‌شود.

## 🎯 نصب نسخه دلخواه

نسخه را به عنوان آرگومان بدهید:

    bash <(curl -sL https://raw.githubusercontent.com/Cmd81/up-marznode-xray/main/change-core.sh) 25.9.11

لیست نسخه‌ها: https://github.com/XTLS/Xray-core/releases

## 📌 نصب دائمی روی سرور

    curl -sL https://raw.githubusercontent.com/Cmd81/up-marznode-xray/main/change-core.sh -o /usr/local/bin/up-xray
    chmod +x /usr/local/bin/up-xray

از این پس فقط:

    up-xray 25.9.11

## ✨ امکانات

- تشخیص خودکار معماری سرور (amd64 / arm64 / armv7)
- دانلود، استخراج و جایگزینی هسته در `/var/lib/marznode`
- ست کردن خودکار `XRAY_EXECUTABLE_PATH` و `XRAY_ASSETS_PATH` در `compose.yml`
- بکاپ تاریخ‌دار از `compose.yml` قبل از هر تغییر
- ریستارت خودکار marznode و نمایش نسخه نصب‌شده

## 📋 پیش‌نیاز

- دسترسی `root`
- نود marznode نصب‌شده طبق داکیومنت مرزنشین
- مسیر پروژه `/root/marznode` (در غیر این صورت `COMPOSE_DIR` را در اسکریپت تغییر دهید)

## ⚠️ نکته

اسکریپت کانتینر marznode را down و up می‌کند؛ در لحظه اجرا اتصال کاربران آن نود چند ثانیه قطع می‌شود.