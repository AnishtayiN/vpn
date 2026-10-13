# VoidrauVPN — لایسنس و ربات تلگرام (Cloudflare Worker)

## چی هست
- **Worker تک‌فایلی** (`license-worker.js`): هم ربات تلگرام هم API لایسنس برای اپ.
- KV برای ذخیره لایسنس‌ها، تست رایگان ۲۴ ساعته، رفرال (هر ۳ دعوت = ۷ روز)، پلن‌های خرید، پنل ادمین با دستورات.

## دیپلوی (۵ دقیقه)
```bash
npm i -g wrangler
wrangler kv namespace create LICENSES        # id را در wrangler.toml بگذار
wrangler secret put BOT_TOKEN                # توکن از @BotFather
wrangler secret put ADMIN_ID                 # آیدی عددی خودت (از /id در ربات)
wrangler secret put BOT_USERNAME             # یوزرنیم ربات (بدون @) — برای لینک رفرال
wrangler deploy
```

## هوک تلگرام
بعد از دیپلوی، یک بار در مرورگر:
```
https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://voidrau.massagetoanishtayin.workers.dev/webhook
```

## تغییر API در اپ
آدرس Worker در اپ با `--dart-define` می‌آید (پیش‌فرض در `license_service.dart`):
```
--dart-define=VOIDRAU_LICENSE_API=https://voidrau.massagetoanishtayin.workers.dev
```
در workflow ریلیز (release.yml) اضافه کن به extra-front-end-options.

## دستورات ادمین
- `/gen <days> [telegram_id]` — ساخت/تمدید کد دستی
- `/ok <telegram_id> <days>` — تایید خرید در انتظار
- `/id` — آیدی عددی کاربر

## دستورات کاربر (منوی /start)
- 🎁 تست رایگان ۲۴ ساعته (یک بار برای هر آیدی)
- 🛒 خرید لایسنس (۳ پلن → درخواست به ادمین)
- 👥 دعوت دوستان (لینک رفرال + اعتبار)
- 🔑 کد لایسنس من
