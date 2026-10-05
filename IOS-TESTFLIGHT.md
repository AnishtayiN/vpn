# iOS / TestFlight — راهنمای ساخت و انتشار

## جواب کوتاه

**بله، می‌توان اپ را با TestFlight نصب کرد، بدون اینکه نسخهٔ عمومی App Store منتشر شده باشد.**
اما TestFlight راه دورزدن عضویت Apple Developer نیست. برای امضا و آپلود، عضویت فعال
Apple Developer Program، App Store Connect و گواهی‌های معتبر لازم است. نصب TestFlight
برای تستر رایگان است؛ هر بیلد حداکثر **۹۰ روز** قابل آزمایش است. گروه تستر خارجی و لینک
عمومی معمولاً برای اولین بیلد به Beta App Review نیاز دارند.

برای اپ VPN، بند **5.4** مقررات اپل حساب توسعه‌دهندهٔ **Organization**، افشای روشن
رفتار داده و الزامات حقوقی VPN را مطرح می‌کند. داشتن حساب شخصی یا IPA تضمین پذیرش نیست.

منابع رسمی:
- [TestFlight overview و اعتبار ۹۰روزه](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/)
- [TestFlight و گروه‌های تست](https://developer.apple.com/testflight/)
- [قوانین VPN اپل، بند 5.4](https://developer.apple.com/app-store/review/guidelines/#vpn-apps)
- [حساب توسعه‌دهنده و عضویت](https://developer.apple.com/help/account/basics/about-your-developer-account)

## وضعیت واقعی این پیاده‌سازی

این تغییر **کد اپ، افزونهٔ واقعی packet tunnel، پل بومی Aether/HEV و مسیر CI امضا/آپلود**
را اضافه می‌کند؛ صفحهٔ نمایشی یا VPN شبیه‌سازی‌شده نیست. بااین‌حال تا وقتی job macOS سبز
نشده و تست روی آیفون انجام نشده، نباید آن را یک نسخهٔ تأییدشدهٔ آمادهٔ انتشار عمومی نامید.
در محیط توسعهٔ لینوکسی امکان اجرای Xcode، امضای Apple یا آزمایش اتصال آیفون وجود ندارد.

- حداقل هدف: **iOS / iPadOS 16، دستگاه arm64**.
- UI فارسی/انگلیسی Flutter حفظ شده است.
- `NETunnelProviderManager` برای نصب پروفایل با تأیید کاربر و شروع/توقف.
- `NEPacketTunnelProvider` در پردازش جدا؛ بسته‌شدن UI به‌تنهایی VPN را متوقف نمی‌کند.
- Aether به‌صورت **static library** داخل افزونه اجرا می‌شود؛ هیچ `Process`، دانلود
  کد اجرایی، binary جانبی اندروید یا دسترسی خصوصی به descriptor سیستم استفاده نمی‌شود.
- موتور از همان تنظیمات MASQUE H3/H2، WireGuard، gool، MASQUE×2 استفاده می‌کند.
  Smart fallback و فیلتر کشور در لایهٔ Flutter هستند؛ کار پس‌زمینهٔ این منطق در زمان
  تعلیق UI تضمین نمی‌شود. خود موتور با تنظیم quick reconnect در افزونه زنده می‌ماند.
- `NEPacketTunnelFlow` با socketpair و framing چهاربایتی Darwin به HEV وصل می‌شود؛
  هیچ descriptor خصوصی/KVC استفاده نمی‌شود.
- HEV برای iOS با یک patch دوخطی (`scripts/ios/hev-ios.patch`) همان کاری می‌کند که
  upstream برای tvOS می‌کند: فراخوانی‌های `fork/exec/daemon` مربوط به اسکریپت‌های
  post-up حذف می‌شوند، چون در افزونهٔ iOS ممنوع و کشندهٔ پروسه هستند.
- قبل از تکمیل راه‌اندازی، تست واقعی HTTP از SOCKS انجام می‌شود؛ UI بعد از آن مسیر
  device VPN را هم می‌آزماید. صرفاً بازبودن پورت به‌معنی اتصال موفق نیست.
- DNS به `1.1.1.1`/`1.0.0.1` در مسیر تونل می‌رود. IPv6 حتی در حالت خاموش capture و
  discard می‌شود تا عمداً به شبکهٔ بیرونی fall through نکند. LAN bypass انتخابی است.
- `killSwitch` به `includeAllNetworks` نگاشت می‌شود؛ این **Always-On سازمانی و تضمین
  صفرنشتی در همهٔ شرایط iOS نیست**. استثناهای سیستم، crash، تغییر شبکه و خاموش‌کردن
  VPN باید روی دستگاه بررسی شوند. بین توقف و شروع دوبارهٔ تونل در fallback نیز ممکن است
  مسیر عادی سیستم برگردد؛ حفاظت پیوسته در این فاصله تضمین نمی‌شود. bypass LAN عمداً
  ترافیک محلی را مستثنا می‌کند.
- پروکسی مستقل، اشتراک LAN و انتخاب دلخواه اپ‌ها در iOS معمولی غیرفعال‌اند. per-app VPN
  مدیریتی به زیرساخت سازمانی/MDM جدا نیاز دارد و اینجا پیاده نشده است.
- `autoConnect` یعنی هنگام بازکردن اپ، **نه هنگام بوت دستگاه**. قوانین on-demand دائمی
  اضافه نشده‌اند تا Disconnect کاربر خنثی نشود.
- به‌روزرسانی فقط از TestFlight/App Store است. ریلیز Android/Windows، نسخهٔ iOS را قفل
  نمی‌کند و iOS هیچ APK/EXE دانلود یا نصب نمی‌کند.

## هشدار مهم مجوز Aether

Aether در revision پین‌شدهٔ v2.1.0 دارای **AGPL-3.0-only** است، نه MIT. HEV در نسخهٔ
پین‌شده MIT است. اطلاعات اشتباه قبلی در `NOTICE.md` اصلاح شده است.

لینک استاتیک AGPL با اپ و شرایط توزیع TestFlight/App Store باید **قبل از آپلود** از نظر
مجوز بررسی شود؛ ممکن است به اجازه/مجوز جایگزین از صاحبان حقوق نیاز باشد. MIT بودن سورس
اولیهٔ این مخزن یا قراردادن فایل source کنار IPA این موضوع را خودبه‌خود حل نمی‌کند.
گزینهٔ `distribution_rights_reviewed` فقط تأیید شماست، مجوز جدید صادر نمی‌کند.

## ۱. تنظیم یک‌باره در پنل اپل

1. عضویت معتبر و دسترسی Certificates, Identifiers & Profiles / App Store Connect داشته باشید.
2. دو **Explicit App ID** بسازید؛ به‌عنوان نمونه:
   - اپ: `pm.dnschanger.voidrauvpn`
   - افزونه: `pm.dnschanger.voidrauvpn.PacketTunnel`
3. برای **هر دو** شناسه قابلیت **Network Extensions / Packet Tunnel** را فعال کنید.
   اگر روی حساب شما در دسترس نیست، موضوع باید از طریق اپل حل شود؛ workflow نمی‌تواند
   entitlement تأییدنشده را جعل کند. App Groups در این معماری لازم نیست.
4. یک گواهی **Apple Distribution** همراه کلید خصوصی بسازید و از Keychain به شکل
   `.p12` با رمز صادر کنید. فایل `.cer` بدون private key کافی نیست.
5. دو provisioning profile از نوع **App Store Connect / App Store distribution** بسازید؛
   یکی برای Runner و یکی برای PacketTunnel، با همان گواهی. پروفایل Development، Ad Hoc،
   Enterprise، wildcard یا expired برای این job پذیرفته نمی‌شود.
6. در App Store Connect یک app record با Bundle ID اصلی و SKU یکتا ایجاد کنید.
7. در Users and Access → Integrations → App Store Connect API یک **Team API key** با
   دسترسی مناسب آپلود بسازید؛ Key ID، Issuer ID و فایل `.p8` را نگه دارید.
8. قراردادهای معلق اپل را تأیید کنید. beta description، اطلاعات تماس review، privacy
   policy URL واقعی، توضیحات تست و اطلاعات export compliance را تکمیل کنید.

**Export compliance را خودسرانه «بدون رمزنگاری» انتخاب نکنید.** این VPN رمزنگاری دارد؛
کد عمداً `ITSAppUsesNonExemptEncryption=false` جعل نمی‌کند. پاسخ درست و مدارک لازم
باید با توجه به محصول/حوزهٔ توزیع تعیین شود. ممکن است بیلد پس از آپلود تا تکمیل این
بخش در وضعیت Missing Compliance بماند.

صفحهٔ حریم خصوصی داخل اپ، consent اولیه و `PrivacyInfo.xcprivacy` اضافه شده‌اند، اما
نام حقوقی ناشر، نشانی تماس، privacy policy عمومی، اظهارات App Privacy و ممیزی همهٔ
APIهای required-reason و dependencyها باید توسط ناشر نهایی تکمیل/بررسی شوند.

## ۲. Variables و Secrets مخزن

در **Repository → Settings → Secrets and variables → Actions** تنظیم کنید.
اطلاعات محرمانه را در فایل‌های Git، issue، chat یا لاگ workflow قرار ندهید.

### Variables

| نام | مقدار |
|---|---|
| `IOS_BUNDLE_ID` | شناسهٔ اپ اصلی؛ پیش‌فرض `pm.dnschanger.voidrauvpn` |
| `APPLE_TEAM_ID` | Team ID ده‌کاراکتری عضویت اپل |

شناسهٔ افزونه خودکار از `${IOS_BUNDLE_ID}.PacketTunnel` ساخته می‌شود. شناسهٔ نهایی را
پیش از اولین انتشار انتخاب کنید و بعد تغییر ندهید.

### Secrets

| نام | محتوا |
|---|---|
| `IOS_CERTIFICATE_P12_BASE64` | فایل گواهی + private key در فرمت P12، Base64 |
| `IOS_CERTIFICATE_PASSWORD` | رمز همان P12 |
| `IOS_APP_PROFILE_BASE64` | پروفایل App Store اپ اصلی، Base64 |
| `IOS_TUNNEL_PROFILE_BASE64` | پروفایل App Store افزونه، Base64 |
| `IOS_KEYCHAIN_PASSWORD` | یک رمز تصادفی قوی برای keychain موقت runner |
| `ASC_KEY_ID` | Key ID ده‌کاراکتری App Store Connect API |
| `ASC_ISSUER_ID` | Issuer ID همان API key |
| `ASC_PRIVATE_KEY_BASE64` | فایل `.p8` همان API key، Base64 |

نمونه در Terminal **مک خودتان** برای انتقال مستقیم به clipboard، بدون چاپ کلید در log:

```sh
base64 -i distribution.p12 | tr -d '\n' | pbcopy
base64 -i App.mobileprovision | tr -d '\n' | pbcopy
base64 -i Tunnel.mobileprovision | tr -d '\n' | pbcopy
base64 -i AuthKey_YOURKEYID.p8 | tr -d '\n' | pbcopy
```

هر خروجی را در Secret مربوط به خودش paste کنید. Certificate/API key قابل لغو و تمدیدند؛
پس از تمدید profileها، Secretهای اپ و افزونه را با هم به‌روز کنید.

## ۳. اجرای workflow

workflow جدید: **Actions → iOS - Build and TestFlight → Run workflow**.
فایل: `.github/workflows/ios.yml`؛ workflow قبلی APK/EXE مستقل و دست‌نخورده است.

اگر workflow تازه روی شاخهٔ پیش‌فرض هنوز وجود ندارد، دکمهٔ دستی ممکن است در UI دیده
نشود. بعد از merge قابل مشاهده است؛ یا با GitHub CLI از شاخه‌ای که فایل روی آن قرار
گرفته اجرا کنید (در این جلسه همان `arena/01a0cb14-vpn`). ابتدا تغییرات باید روی remote
موجود باشند؛ صرف ذخیره در workspace باعث ایجاد workflow روی GitHub نمی‌شود.

### بار اول: فقط کامپایل، بدون حساب و Secret اپل

- `version`: مثلاً `1.1.0`
- `build_number`: خالی؛ پیش‌فرض شمارهٔ run به‌همراه attempt، مثل `12.1`
- `upload_testflight`: **false**
- `publish_release`: **false** (بدون امضا IPA‌ای برای انتشار وجود ندارد)
- `distribution_rights_reviewed`: **false**

job روی macOS و Xcode 26، Flutter **3.35.7**، Rust پین‌شده در `scripts/pins.json` و
sourceهای پین‌شده ساخته می‌شود. Runner و PacketTunnel واقعاً compile و archive
می‌شوند، اما آرشیو **بدون امضا قابل نصب نیست**. این حالت فقط برای بررسی build است؛
خروجی موفق به معنی تست موفق data plane روی آیفون نیست.

### سپس: امضا و ارسال

پس از سبزشدن build، بررسی مجوز و آماده‌کردن موارد اپل:

- `upload_testflight`: **true**
- `publish_release`: اختیاری؛ با **true** همان بیلد امضاشده به‌صورت GitHub **pre-release**
  زیر تگ `ios-vX.Y.Z` منتشر می‌شود (پیش‌فرض **false**). این ورودی بدون
  `upload_testflight: true` خطا می‌دهد، چون بیلد بدون امضا IPA ندارد.
- `distribution_rights_reviewed`: فقط پس از بررسی واقعی **true**
- `version`: نسخهٔ موردنظر؛ فرمت `x.y.z`
- `build_number`: یکتا و بزرگ‌تر از شمارهٔ قبلی همان نسخه. اگر قبلاً با روش دیگری build
  آپلود کرده‌اید، مقدار مناسب را دستی وارد کنید؛ صرف rerun تضمین افزایش نسبت به آن نیست.

مراحل job:

1. اعتبارسنجی ورودی، SDK و profileهای app/extension؛ import گواهی در keychain موقت.
2. تولید scaffold iOS، اضافه‌کردن target افزونه، entitlements، iconها و privacy manifest.
3. تست Flutter و validatorها، ساخت arm64 واقعی Aether و HEV.
4. archive، بررسی embed افزونه، امضای جداگانهٔ هر دو target و export فایل IPA.
5. ذخیرهٔ IPA و **corresponding-source archive** در Actions Artifacts (۳۰ روز نگه‌داری).
6. ارسال با API key به App Store Connect از طریق `xcrun altool`.
7. پاک‌کردن keychain، profileهای نصب‌شده و فایل‌های موقت Secret حتی در مسیر خطا.
8. اگر `publish_release` روشن باشد، job جداگانهٔ **Publish GitHub Release** همان IPA
   امضاشده، corresponding-source و `SHA256SUMS.txt` را در یک GitHub **pre-release** زیر
   تگ `ios-vX.Y.Z` منتشر (یا برای همان نسخه به‌روزرسانی) می‌کند. اجرای دوبارهٔ همان نسخه
   assetها را جایگزین می‌کند و release تکراری نمی‌سازد.

فایل IPA را از لینک GitHub نمی‌توان مثل APK روی آیفون نصب کرد؛ نصب فقط از
TestFlight/App Store یا ابزار sideload ممکن است. به‌صورت پیش‌فرض این workflow هیچ
GitHub Release یا tag ریلیز Android ایجاد نمی‌کند. اگر `publish_release` را روشن کنید،
خروجی یک **pre-release** با تگ `ios-vX.Y.Z` است؛ چون pre-release است، `releases/latest` —
همان چیزی که updater می‌خواند — همچنان به ریلیز `v*` اندروید/ویندوز اشاره می‌کند و
نسخه‌های دیگر اشتباه بازنشسته نمی‌شوند. source artifact را هم پیش از انقضای Actions
نگه دارید و مطابق تعهدات مجوز در اختیار دریافت‌کنندگان قرار دهید.

## ۴. مرحلهٔ نهایی داخل App Store Connect

موفقیت upload یعنی «اپل فایل را دریافت کرده»، **نه نصب خودکار برای همه**:

1. منتظر پایان Processing شوید و در صورت نیاز export compliance را تکمیل کنید.
2. TestFlight → Internal Testing: گروه داخلی را انتخاب و بیلد را به آن اضافه کنید؛
   می‌توانید automatic distribution را در همان گروه فعال کنید.
3. External Testing: اطلاعات beta و review را تکمیل، بیلد را اضافه و برای Beta Review
   ارسال کنید. پس از تأیید، گروه خارجی و public invitation link قابل استفاده است.
4. تستر برنامهٔ TestFlight اپل را نصب می‌کند، دعوت را می‌پذیرد و VoidrauVPN را نصب می‌کند.
5. انتشار عمومی App Store مرحلهٔ جداگانهٔ metadata، screenshots، privacy و App Review دارد.

workflow عمداً تستر، public link، پاسخ حقوقی و انتشار عمومی را بدون تأیید شما ایجاد نمی‌کند.

## تست روی آیفون — قبل از دعوت عمومی الزامی

- [ ] نصب تازه؛ متن consent؛ قبول/رد درخواست VPN سیستم؛ رفتن دوباره به اپ.
- [ ] MASQUE H3، H2، WireGuard و پروتکل‌های چندلایه؛ خطای endpoint و timeout واقعی.
- [ ] مرور وب و دانلود با یک **اپ دیگر**؛ UDP و DNS؛ مقایسهٔ IP قبل/بعد.
- [ ] IPv4-only، IPv6-only/NAT64، Wi-Fi و Cellular؛ تست DNS/IPv6 leak در هر دو حالت IPv6.
- [ ] تعویض Wi-Fi ↔ Cellular، airplane mode، sleep/wake، نبود اینترنت، تغییر endpoint.
- [ ] توقف از داخل اپ و Settings؛ بدون reconnect ناخواسته؛ حداقل ۲۰ بار connect/disconnect.
- [ ] بازکردن مجدد UI در حالی که تونل فعال است؛ صحت IP، زمان اتصال و آمار.
- [ ] kill switch و bypass LAN جداگانه؛ تست crash افزونه و تغییر route هنگام reconnect.
- [ ] اجرای طولانی و تعداد زیاد اتصال؛ بررسی jetsam/memory pressure با Instruments.
- [ ] بررسی حافظهٔ افزونه: بودجهٔ آن محدود است؛ استفادهٔ Aether + HEV و به‌ویژه پروتکل‌های
  دو‌لایه باید روی دستگاه اندازه‌گیری شود. محدودیت session/buffer جای این آزمون را نمی‌گیرد.
- [ ] فیلتر کشور، لغو حین اتصال، watchdog در foreground؛ بدون ادعای تضمین کشور خاص.
- [ ] دسترس‌پذیری، RTL، اندازه‌های مختلف iPhone/iPad و حذف اطلاعات حساس از diagnostics.
- [ ] Privacy report، مجوزهای dependencyها و سازگاری مقررات ناشر/محل انتشار.

## ساخت محلی روی مک

ابزارها: Xcode 26 با Command Line Tools، Flutter 3.35.7، Ruby/CocoaPods، Rustup،
CMake/Ninja، Python3 و Pillow. برای تست VPN از دستگاه واقعی استفاده کنید؛ این اسکریپت
کتابخانهٔ arm64 شبیه‌ساز تولید نمی‌کند.

```sh
gem install xcodeproj -v 1.27.0 --no-document
gem install cocoapods -v 1.16.2 --no-document
# Pillow را در virtualenv نصب کنید.
export IOS_BUNDLE_ID=pm.dnschanger.voidrauvpn
bash scripts/ios/bootstrap.sh
bash scripts/ios/build_native.sh
export IOS_VERSION=1.1.0 IOS_BUILD_NUMBER=1 IOS_UPLOAD=false
bash scripts/ios/archive.sh
```

برای اجرای توسعه‌ای روی دستگاه، workspace `ios/Runner.xcworkspace` را در Xcode باز
کنید و signing هر دو target را با profile توسعهٔ معتبر خودتان تنظیم کنید. اسکریپت
TestFlight فقط distribution profile می‌پذیرد. تغییرات پایدار بومی را در `overlays/ios`
و اسکریپت تنظیم پروژه اعمال کنید؛ `/ios` خروجی تولیدشده و در gitignore است.

## عیب‌یابی

- **Missing secrets / capability / expired profile:** هر دو App ID، Team ID و profile
  را بررسی کنید. profile بعد از فعال‌کردن capability باید دوباره ساخته شود.
- **Signing certificate not found:** P12 باید private key و certificate متناظر با profile
  را داشته باشد؛ گواهی `.cer` تنها کافی نیست.
- **Build number already used:** شمارهٔ جدید بدهید؛ اپل بیلد قبلی را overwrite نمی‌کند.
- **Xcode 26 unavailable:** image runner تغییر کرده؛ انتخاب SDK در workflow را با
  الزامات روز اپل و runner موجود هماهنگ کنید، نه با حذف validation.
- **Rust/source compilation failure:** فایل‌های باینری سیستم‌های دیگر جایگزین iOS نیستند؛
  خطای اصلی Cargo/Clang و revision پین‌شده را بررسی کنید. job نباید از core جعلی عبور کند.
- **Connected ولی ترافیک ندارد:** تست device route، DNS، IPv6، SOCKS proof و Console
  دستگاه برای process افزونه را بررسی کنید؛ خطای HEV/core باعث توقف تونل می‌شود.
- **ناپدیدشدن VPN در پس‌زمینه:** گزارش crash/jetsam و مصرف حافظهٔ افزونه را بررسی کنید؛
  Flutter UI در پس‌زمینه تضمین اجرای timer و watchdog ندارد.
- **Uploaded اما TestFlight خالی/غیرفعال است:** Processing، Missing Compliance، قراردادها،
  انتخاب گروه تست و Beta App Review را در پنل اپل بررسی کنید.

## نقشهٔ کد

- `overlays/ios/Runner`: bridge کانال Flutter و مدیریت پروفایل/consent سیستم.
- `overlays/ios/PacketTunnel`: lifecycle، data-plane proof، flow ↔ HEV و آمار.
- `overlays/ios/Shared`: validator مشترک app/extension.
- `native/ios-core`: مالکیت runtime و shutdown همهٔ taskهای Aether قبل از شروع دوباره.
- `scripts/ios`: تولید Xcode project، native build، signing، archive و source package.
- `lib/services/ios_policy.dart`: سیاست قابلیت‌ها و غیرفعال‌کردن updater مخصوص APK/EXE.
- `scripts/ios/tests`, `test/ios_policy_test.dart`: تست validator، signing، قراردادها و Dart.
