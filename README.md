# VoidrauVPN

Free, open-source **Flutter** VPN client for **Android 7+** and **Windows 8.1–11**, with an **iOS 16+ native packet-tunnel implementation and TestFlight build workflow**. iOS requires Apple signing and real-device validation; see the [iOS guide](IOS-TESTFLIGHT.md).

Telegram channel (releases, install files, notes and support): **[t.me/Voidrau](https://t.me/Voidrau)**

[English](#english) · [فارسی](#فارسی)

---

## English

### What you get

| | Android | Windows |
| --- | --- | --- |
| UI | Flutter | Flutter (compact 420×780 window) |
| Device VPN | `VpnService` + userspace TUN bridge | WinTUN adapter + one of three staged bridges |
| Proxy | SOCKS5 `127.0.0.1:1819` (configurable) | SOCKS5 `127.0.0.1:1819` (configurable) + system-proxy automation |
| Protocols | Smart Connect: MASQUE HTTP/3 → MASQUE HTTP/2 → WireGuard → gool → MASQUE×2 | same |
| Extras | Quick Settings tile, home-screen widget, LAN sharing, split tunneling (per app + per destination), speed page with a live meter and a throughput test, second hop (Psiphon/Tor), MTU/timeouts/watchdog, battery-optimization helper | Bypass-LAN routes, system-proxy save/restore, split tunneling (per destination), speed page, second hop, timeouts, watchdog, one-tap “run as Administrator” |
| Language | Persian & English (RTL aware) | Persian & English |
| Exit info | Country flag + exit IP card after connecting | Country flag + exit IP card after connecting |
| Exit country | Choose it: any IP but Iran, or a preferred country (Germany by default) | same |
| Minimum OS | Android 7.0 (API 24) | Windows 8.1 (6.3), x64 |

### Exit country: pick where you land

The tunnel core chooses its own gateway, so the exit country cannot be
requested as a launch parameter. The client enforces it instead:

- **Configurations → Exit IP country** offers *Any country*, *Any IP but Iran*
  (the default) and *Preferred country* (Germany first, then any country except
  Iran; both lists are editable with flag chips).
- **The rule is handed to the core first** (`AETHER_EXIT_LOC`, on by default).
  Core 2.1.0 checks it *inside the tunnel* before the SOCKS5 listener opens and
  again every minute, and re-dials the gateway itself when the exit is in a
  blocked country. That is one or two seconds of work for the core, against a
  full teardown, rescan and re-handshake for the client — so the app waits out a
  short window when it sees a wrong exit, and only re-dials if the core does not
  move. Turn the switch off to go back to client-side enforcement only.
- After the core reports `connected`, the exit IP is still looked up through the
  tunnel itself (Cloudflare trace, geo API as fallback), because the client must
  know where it landed. If the country does not match, the tunnel is torn down
  and re-dialled — walking the protocol ladder
  and flipping the MASQUE carrier between HTTP/3 and HTTP/2, because a different
  carrier means a different gateway pool.
- The status line reports the search: which countries have already been
  rejected and which attempt is running.
- If the search takes longer than the configured patience (3 minutes by
  default, editable), the app asks instead of spinning on: **Keep scanning** or
  **Connect with the Iran IP**. The second choice switches the rule off and
  redials the gateway that already produced that exit, so it is back in seconds
  rather than after a fresh scan. Choosing *Keep scanning* brings the question
  back after another interval.
- An exit whose country cannot be determined is accepted, so a broken geo
  lookup can never become an endless re-dial loop.

### Split tunneling: which apps, and which destinations

**Navigation → Split tunneling** (also reachable from *Configurations*). The page
has two halves because the two halves of the feature run in different places:

**Per app (Android).** *Everything*, *Only these apps* or *Everything except
these apps*. Android's own `addAllowedApplication`/`addDisallowedApplication`
enforces it in the kernel, so a bypassed app never even reaches the tunnel — it
keeps the raw connection, with the raw latency and the raw IP. The picker lists
the apps the device can open (preinstalled ones included, so a preinstalled
browser can be bypassed), with search, *Invert*, a *System apps* filter and a
running count. VoidrauVPN itself is always kept out of its own tunnel: the core
shares this app's UID, and looping its egress back into the tunnel is what
“connected but nothing works” looks like.

**Per destination (every platform).** Domain, IP, port and `private` rules that
the core applies to the connection it dials: *direct* sends the destination out
of the physical interface, *block* refuses it. This works on Android, where the
core's own sockets are outside the tunnel, and on Windows it is limited — under a
full-device tunnel the core's “direct” socket would be captured and handed back
to it, so only rules the routing table can honour are used there (an IPv4
address, a network, or `private`), and the app adds the matching bypass routes
instead of promising something that cannot work. Domain rules are logged as
Android-only on Windows rather than silently doing nothing.

Rules are typed in the core's own syntax: `example.com`, `full:example.com`,
`keyword:ads`, `regexp:^ad[0-9]`, `10.0.0.0/8`, `1.2.3.4`, `port:25`, `private`.
Everything is validated before it is stored (a comma or a space inside an entry
would split the environment list the core reads), and IPv6 is rewritten to the
`ip:`/`cidr:` spelling the core's rule parser expects. Two presets cover the
common cases: *LAN* (`private`) and *SMTP* (`port:25`). Changes apply on the next
dial; the page offers *Apply now* when a tunnel is running.

### Speed: the profile, the meter and the test

Three quarters of “the VPN is slow” is one number: the TCP receive window
divided by the round trip. The core picks its own tier from the CPU and the RAM
(`sysprofile`) — a 4-core phone gets a 1 MiB window, which is about 9 MB/s on a
110 ms path — so the app lets you raise it:

- **Eco** → `AETHER_PERF_PROFILE=low`: fewest buffers, for an old phone or a
  battery you would rather keep.
- **Auto** (default) → the core detects the machine.
- **Turbo** → `high`: 2 MiB TCP window, unlimited scan concurrency, wide HTTP/2
  windows.
- **Extreme** → `high` plus explicit `AETHER_NETSTACK_TCP_RX/TX` (4 MiB / 1 MiB)
  for a fast line that still feels capped.

The same choice is honoured by the TUN front-end on the device side: the
packet bridge's splice buffer, UDP socket buffer and stack size are raised with
it (`131072`/`1048576` vs `65536`/`524288`), because the core cannot hand over
traffic the bridge has not moved yet.

Smart Connect escalates on a filtered network rather than retrying the same
handshake: the second pass changes the carrier, the ClientHello and the SNI
(see above), which is what turns a timeout into a connection — and a connection
into the speed the profile promised.

The page also shows a **live up/down meter** (smoothed over 4 s, so the number
does not jump as samples land) with a 48-sample sparkline, and runs a **real
throughput test**: a download through the tunnel's own SOCKS5 listener — the
exact path the apps on the device use — reported in Mbps with time-to-first-byte,
ping and jitter. It stops at 25 MB or 12 s, whichever comes first, so a fast line
cannot eat a data plan.

**MTU is two settings, not one.** The *device MTU* (default 1500, 1280–9000) is
the size apps segment at before the bridge sees the packet; that side is
terminated inside the bridge, so a larger value only means fewer packets to move.
The *inner MTU* (`AETHER_MASQUE_MTU`, 0 = automatic) is what the core puts on the
wire, and its own default is protocol aware: 1280 on QUIC, 1500 on the TCP
carrier. Overriding it is rarely needed, which is why the default is “let the
core decide”.

### Tunnel core 2.1.0

`scripts/pins.json` pins Aether **v2.1.0** (and the iOS source revision built
from it). What the app uses from it:

- **exit lock** — `AETHER_EXIT_LOC` / `AETHER_EXIT_LOC_SECS` (see above);
- **second hop** — Psiphon or Tor inside the core
  (`AETHER_PSIPHON`/`AETHER_TOR` = `chain`, `reverse` or `only`), with region,
  CDN mode and per-hop binds pinned two ports above SOCKS5 so they can never
  collide with the extra HTTP listener;
- **traffic counters** — `AETHER_STATS` / `AETHER_STATS_SECS=5`, which is the
  only byte source on Windows and feeds the live meter;
- **speed** — `AETHER_PERF_PROFILE`, the netstack window overrides, TCP
  connect/keepalive/half-close timeouts;
- **routing rules** — `AETHER_ROUTE_DIRECT` / `AETHER_ROUTE_BLOCK` for split
  tunneling by destination;
- **censorship workarounds** — the QUIC v2 opener on by default
  (`AETHER_QUIC_V2=0` turns it off) and `AETHER_ECH=auto`;
- **a faster HTTP/2 scan** and gateway memory across reconnects.

Everything is passed as `AETHER_*` environment variables; the app never uses
command-line flags, and the iOS extension's validator only accepts that prefix.

### Is it the app, or the filtering?

Two of the usual reports have one honest answer each, and the app tries to give
the evidence instead of a guess:

- **"Only the Iran IP connects / no other exit IPs exist."** The one-tap
  *connect with the Iran IP* answer pauses the exit rule instead of deleting it,
  so the countries the user picked are still there and one tap (**turn the rule
  back on and search**) restores the search. That is what keeps the local exit
  from quietly becoming the only exit: *Diagnostics →
  Tunnel reality check* reads the public IP twice: once on the raw line
  (deliberately outside every proxy) and once through the tunnel. If the two
  addresses are the same, the traffic the phone sends is not going through the
  tunnel at all — the "exit IP" being shown is the line's own, and the fix is a
  reconnect or a different protocol, not a different exit. If they differ, the
  tunnel really is carrying the traffic, and a local-looking *country* is a
  geolocation answer about the exit address, not a leak. (Some Iranian carriers
  run their own transparent proxies and even tunnel "sanctioned" destinations
  through WARP themselves, which is why an address on the raw line can look like
  somebody else's.)
- **"WireGuard connects, everything else does not."** That is the carrier, not
  the client: WireGuard is unrecognised UDP traffic, while MASQUE is QUIC/TLS to
  Cloudflare's own ranges — and Cloudflare's addresses and the
  `cloudflareclient` server name are exactly what Iranian DPI blocks, most
  aggressively on MCI. No client can make a blocked handshake complete, but the
  app can stop looking like the thing being blocked, and Smart Connect now does:
  the first pass is a plain MASQUE handshake, the second takes the **TCP 443
  carrier with a fragmented ClientHello and ECH** (SNI matching is what these
  filters do), later passes keep ECH on, and the ladder ends on WireGuard —
  which is why WireGuard is what still works there. The second hop (Psiphon or
  Tor inside the core) exists for the same reason: it carries the tunnel itself
  past a network that refuses to carry WARP.

### iOS / TestFlight

Use **Actions → iOS - Build and TestFlight**. Start with `upload_testflight=false`
to compile an unsigned iPhone archive without Apple secrets. Signed uploads need
Apple Developer membership, separate app/extension distribution profiles, and an
App Store Connect API key. TestFlight is not a free signing workaround and does
not publish an App Store release automatically.

**Read [IOS-TESTFLIGHT.md](IOS-TESTFLIGHT.md)** for setup, secrets, platform limits,
device tests and the **Aether AGPL distribution/licensing gate**. macOS compilation
and actual iPhone networking must pass before calling this production-ready.

### Mandatory updates (Android / Windows only)

When a new version is published, **older builds stop working immediately**:

- the app checks the release feed on launch, when it returns to the foreground and before every connection;
- as soon as a newer release exists, the tunnel is torn down, connecting is refused and the app switches to a full-screen notice;
- that notice links straight to the Telegram channel for the installer and the release notes — install the new version and the app works again;
- the state is stored locally, so even starting the app offline cannot bring a retired version back to life.

### Where the releases live

Installers and notes are published on the [Telegram channel](https://t.me/Voidrau) and as GitHub Releases of this repository (`https://github.com/AnishtayiN/VoidrauVPN/releases`). The in-app updater reads the latest GitHub Release of this repository.

Build and publish with **GitHub Actions → Release APK and EXE → Run workflow**:

- **App version** (required, e.g. `1.1.0`) — baked into the APK/EXE and used as the release tag
- **Release notes** (optional) — shown on GitHub *and inside the app* on the update screen
- **Pre-release** (optional) — drafts are excluded from the update check

Pushing a `v1.1.0` tag publishes too. Artifacts:

- `VoidrauVPN-vX.Y.Z-Android-Universal.apk`
- `VoidrauVPN-vX.Y.Z-Android-arm64-v8a.apk` / `armeabi-v7a` / `x86_64`
- `VoidrauVPN-vX.Y.Z-Android.aab`
- `VoidrauVPN-vX.Y.Z-Windows-x64-Installer.exe`
- `VoidrauVPN-vX.Y.Z-Windows-x64-Portable.zip`
- `SHA256SUMS.txt`

iOS builds are published separately by **Actions → iOS - Build and TestFlight** with the
**Publish GitHub Release** step (`publish_release` input): the signed IPA, its
corresponding source and the checksums land as a **pre-release** tagged `ios-vX.Y.Z`, so
`releases/latest` — the feed the in-app updater reads — keeps pointing at the
Android/Windows `v*` release. See [IOS-TESTFLIGHT.md](IOS-TESTFLIGHT.md).

The updater verifies SHA-256 when GitHub provides a digest, and on Android checks that the downloaded APK carries the same signing certificate as the installed app before handing it to the system installer.

### Build locally

```bash
# Flutter 3.27+, Android SDK/NDK, Windows 10 SDK for the desktop target
./scripts/bootstrap.sh
bash scripts/fetch_cores.sh        # tunnel core + platform sidecars (pinned tags)
bash scripts/build_hev.sh          # Android JNI bridge
flutter pub get
flutter test
flutter build apk --release        # --dart-define=VOIDRAU_VERSION=1.1.0
flutter build windows --release    # on Windows
```

Notes for maintainers:

- `scripts/pins.json` pins every staged binary; the CI job fails if a pin drifts.
- The Android application id is **frozen** (`pm.dnschanger.nimbus`) so a new build upgrades an existing install instead of installing next to it. The user-visible name is `VoidrauVPN` everywhere else.
- The release keystore must stay the same across releases: the updater refuses an APK signed with a different certificate.
- Bundled third-party components and their licenses are listed in [NOTICE.md](NOTICE.md).

### Windows device VPN: three bridges

A WinTUN adapter needs a userspace bridge, and no single bridge covers Windows 8.1 → 11, so the app stages all three next to the executable and picks per machine:

| Bridge | Used on | Why |
| --- | --- | --- |
| current release | Windows 10/11 | baseline x86-64 build |
| legacy build (Go 1.20) | Windows 7/8/8.1 | newer Go runtimes require Windows 10+ and die before creating the adapter |
| C bridge | any | no Go runtime floor |

If no bridge can create the adapter, the app reports each bridge's exit status and last output line, falls back to SOCKS5 + system proxy so the machine keeps working, and shows the reason on the Diagnostics page.

### Windows system proxy

- **SOCKS5 proxy mode** → the system proxy is pointed at `127.0.0.1:<port>` automatically.
- **Device VPN** → the system proxy is turned off; every app rides the TUN adapter.
- **Disconnect** → the exact pre-VoidrauVPN proxy settings are restored. If the app was hard-closed mid-session, the next launch removes any leftover proxy pointing at its listener.

### Troubleshooting

- **Nothing connects.** Try Stealth or Ironclad scan mode, or switch obfuscation to `aggressive`.
- **MASQUE fails on a filtered network.** Smart Connect retries MASQUE over HTTP/2 with TLS fragmentation, which survives QUIC/UDP blocking.
- **Windows device VPN is down.** Run as Administrator (the app offers a one-tap relaunch) and check the Diagnostics page for the bridge error.
- **Android kills the tunnel.** Disable battery optimization for VoidrauVPN (button in Settings → Battery optimization).
- **“This version has been disabled”.** A newer release exists — install it from [t.me/Voidrau](https://t.me/Voidrau).

---

## فارسی

**VoidrauVPN** یک کلاینت وی‌پی‌ان رایگان و متن‌باز با فلاتر برای **اندروید ۷ به بالا** و **ویندوز ۸.۱ تا ۱۱** است؛ با حالت VPN سراسری یا پروکسی SOCKS5 محلی.

کانال تلگرام (فایل نصبی، توضیحات نسخه‌ها و پشتیبانی): **[t.me/Voidrau](https://t.me/Voidrau)**

### امکانات

- اتصال هوشمند: MASQUE روی HTTP/3 → MASQUE روی HTTP/2 → WireGuard → gool → MASQUE×2
- **VPN دستگاه** روی اندروید و ویندوز، یا **پروکسی SOCKS5** روی `127.0.0.1:1819`
- در ویندوز پروکسی سیستمی خودکار مدیریت می‌شود: در حالت پروکسی به پورت محلی وصل می‌شود، در حالت VPN دستگاه خاموش می‌شود و هنگام قطع اتصال تنظیمات قبلی برمی‌گردد
- بعد از اتصال، **پرچم کشور و آی‌پی خروجی** (همان آی‌پی که سایت‌ها می‌بینند) در بالای صفحه نمایش داده می‌شود؛ با یک لمس کپی می‌شود
- **انتخاب کشور آی‌پی خروجی**: «هر آی‌پی غیر ایران» (پیش‌فرض) یا «کشور دلخواه» (آلمان و هر کشور دیگر به‌جز ایران)؛ این قانون به خود هسته هم داده می‌شود (`AETHER_EXIT_LOC`) تا خروجی اشتباه هرگز به پروکسی نرسد، و اگر خروجی مطابق نبود تونل بسته و مسیر دیگری امتحان می‌شود
- اگر جست‌وجوی خروجی بیش از حد تنظیم‌شده (پیش‌فرض ۳ دقیقه) طول بکشد، برنامه می‌پرسد: **ادامه اسکن** یا **اتصال با آی‌پی ایران**
- **تونل تفکیکی برنامه‌ها**: در اندروید «فقط این برنامه‌ها» یا «همه جز این برنامه‌ها» (جست‌وجو، انتخاب همه، برعکس‌کردن و فیلتر برنامه‌های سیستمی)، و **تفکیک بر اساس مقصد** روی همهٔ پلتفرم‌ها (دامنه، آی‌پی، پورت و `private`) که هستهٔ تونل خودش آن را اعمال می‌کند
- **قفل کشور خروجی داخل هسته**: هسته پیش از باز شدن پروکسی و هر دقیقه یک‌بار بررسی می‌کند و خودش مسیر را عوض می‌کند، پس اتصال فیلترشده چند ثانیه‌ای آماده می‌شود
- **صفحهٔ سرعت**: نمای زندهٔ بالا/پایین، آزمون سرعت واقعی از داخل تونل (Mbps + پینگ + جیتر) و پروفایل سرعت (کم‌مصرف / خودکار / توربو / اکستریم) که پنجرهٔ TCP هسته و بافرهای پل TUN را بالا می‌برد
- **پرش دوم** با Psiphon یا Tor داخل خود هسته (زنجیره‌ای، معکوس یا فقط پروکسی) برای شبکه‌های بسیار محدود
- دور زدن شبکه محلی، اشتراک LAN، DNS خصوصی، MTU دستگاه و MTU داخلی، keepalive، تایم‌اوت‌ها و نگهبان اتصال
- کاشی تنظیمات سریع و ویجت صفحه اصلی در اندروید
- رابط فارسی و انگلیسی

### تونل تفکیکی: کدام برنامه‌ها، کدام مقصدها

دو نیمهٔ این قابلیت در دو جای مختلف اجرا می‌شوند، پس هر دو در یک صفحه («تونل تفکیکی» در منو) آمده‌اند:

- **برنامه‌ها (اندروید)** — «همه»، «فقط این برنامه‌ها» یا «همه جز این برنامه‌ها». خود اندروید با
  `addAllowedApplication`/`addDisallowedApplication` آن را در کرنل اعمال می‌کند، پس برنامهٔ مستثنی
  هرگز به تونل نمی‌رسد و با همان آی‌پی و تأخیر عادی کار می‌کند. فهرست شامل برنامه‌های پیش‌نصب
  (مثل مرورگر پیش‌فرض) است، با جست‌وجو، «انتخاب همه»، «برعکس کن» و فیلتر برنامه‌های سیستمی.
  خود VoidrauVPN همیشه بیرون از تونل خودش می‌ماند تا حلقهٔ مسیریابی ساخته نشود.
- **مقصدها (همهٔ پلتفرم‌ها)** — قواعد دامنه/آی‌پی/پورت/`private` که هسته روی اتصالی که خودش می‌سازد
  اعمال می‌کند: «مستقیم» یعنی از اینترنت عادی، «مسدود» یعنی اصلاً وصل نشود. روی ویندوز فقط
  قواعدی که جدول مسیریابی می‌تواند اجرا کند (آی‌پی، شبکه یا `private`) استفاده می‌شوند و مسیر
  عبوری متناظر هم اضافه می‌شود؛ قواعد دامنه‌ای آنجا کار نمی‌کنند و در لاگ همین را می‌گویند.

قالب قواعد همان قالب خود هسته است: `example.com`، `full:example.com`، `keyword:ads`،
`regexp:^ad[0-9]`، `10.0.0.0/8`، `1.2.3.4`، `port:25`، `private`. ورودی‌ها پیش از ذخیره بررسی
می‌شوند (کاما یا فاصله در یک قاعده، فهرست محیطی هسته را می‌شکند) و IPv6 به شکل `ip:`/`cidr:`
بازنویسی می‌شود. دو پیش‌تنظیم آماده: «شبکه محلی» و «SMTP». تغییرات با اتصال بعدی اعمال می‌شوند و
در صورت اتصال، دکمهٔ «اعمال کن» نمایش داده می‌شود.

### سرعت: پروفایل، نمای زنده و آزمون سرعت

بیشتر کندی حس‌شده یک عدد است: پنجرهٔ دریافت TCP تقسیم بر زمان رفت‌وبرگشت. هسته سطح خود را از
روی پردازنده و حافظه انتخاب می‌کند و روی یک گوشی چهارهسته‌ای پنجرهٔ ۱ مگابایتی می‌گیرد (حدود
۹ مگابایت بر ثانیه روی مسیر ۱۱۰ میلی‌ثانیه‌ای)، پس این انتخاب در دست شماست:

- **کم‌مصرف** (`low`) — کمترین بافر، برای گوشی قدیمی یا مصرف باتری؛
- **خودکار** (پیش‌فرض) — هسته خودش تشخیص می‌دهد؛
- **توربو** (`high`) — پنجرهٔ ۲ مگابایتی، اسکن بدون محدودیت و پنجره‌های پهن HTTP/2؛
- **اکستریم** — همان توربو با بافرهای صریح ۴ مگابایت دریافت و ۱ مگابایت ارسال.

همین انتخاب روی خود دستگاه هم اعمال می‌شود: بافر برش و سوکت UDP پل TUN و اندازهٔ پشتهٔ آن بالا
می‌رود (`131072`/`1048576` در برابر `65536`/`524288`)، چون هسته نمی‌تواند بسته‌ای را که پل هنوز
جابه‌جا نکرده سریع‌تر کند.

صفحهٔ سرعت نمای زندهٔ بالا/پایین (با میانگین ۴ ثانیه‌ای و نمودار ۴۸ نمونه‌ای) و یک **آزمون سرعت
واقعی** دارد: دانلود از داخل همان پروکسی SOCKS5 تونل، دقیقاً همان مسیری که برنامه‌های دستگاه
استفاده می‌کنند؛ نتیجه به Mbps با زمان اولین بایت، پینگ و جیتر. آزمون در ۲۵ مگابایت یا ۱۲ ثانیه
(هرکدام اول رسید) می‌ایستد تا بستهٔ دادهٔ کسی تمام نشود.

**MTU دو تنظیم جداست**: «MTU دستگاه» (پیش‌فرض ۱۵۰۰) اندازه‌ای است که برنامه‌ها بسته‌ها را با آن
می‌بُرند و همان‌جا در پل خاتمه می‌یابد، پس بزرگ‌تر بودنش فقط یعنی بسته‌های کمتر؛ «MTU داخلی»
(`AETHER_MASQUE_MTU`، صفر = خودکار) اندازهٔ روی سیم است و پیش‌فرض خود هسته هوشمند است: ۱۲۸۰ روی
QUIC و ۱۵۰۰ روی TCP.

### هستهٔ تونل 2.1.0

`scripts/pins.json` نسخهٔ Aether را روی **v2.1.0** ثابت می‌کند (و revision مبدأ برای iOS). آنچه
برنامه از آن استفاده می‌کند: **قفل کشور خروجی** داخل هسته، **پرش دوم** با Psiphon/Tor
(`chain`/`reverse`/`only`) با منطقه، حالت CDN و پورت‌های اختصاصی، **شمارنده‌های ترافیک**
(`AETHER_STATS`) که تنها منبع آمار در ویندوز و خوراک نمای زنده است، **پروفایل سرعت** و
بافرهای netstack، **قواعد مسیریابی** برای تفکیک مقصد، **QUIC v2** (پیش‌فرض روشن) و
**ECH**، و اسکن سریع‌تر HTTP/2 با یادسپاری دروازه‌های قبلی.

همهٔ تنظیمات فقط از طریق متغیرهای محیطی `AETHER_*` به هسته داده می‌شود؛ برنامه هیچ‌وقت از
فلگ‌های خط فرمان استفاده نمی‌کند و اعتبارسنج افزونهٔ iOS هم فقط همین پیشوند را می‌پذیرد.

### باگ برنامه است یا فیلترینگ؟

- **«فقط آی‌پی ایران وصل می‌شود / آی‌پی دیگری وجود ندارد»** — در *عیب‌یابی ← آزمون
  واقعی تونل* آی‌پی عمومی دو بار خوانده می‌شود: یک‌بار روی خط عادی (کاملاً بیرون از هر
  پروکسی) و یک‌بار از داخل تونل. اگر هر دو یکی باشند، ترافیک از تونل عبور نمی‌کند و همان
  آی‌پی نمایش‌داده‌شده آی‌پی خود خط است؛ راه‌حل اتصال دوباره یا تغییر پروتکل است، نه
  تغییر کشور خروجی. اگر متفاوت باشند، تونل واقعاً کار می‌کند و «کشور» یک پاسخ
  مکان‌یابی دربارهٔ آی‌پی خروجی است، نه نشت. (برخی اپراتورهای ایران خودشان پروکسی
  شفاف دارند و حتی مقصدهای تحریمی را از تونل WARP خودشان عبور می‌دهند؛ به همین دلیل
  آی‌پی خط عادی هم می‌تواند شبیه آی‌پی دیگری باشد.)
- **«وایرگارد وصل می‌شود، بقیه پروتکل‌ها نه»** — این کار اپراتور است، نه باگ برنامه:
  وایرگارد یک UDP ناشناس است، اما MASQUE همان QUIC/TLS به محدودهٔ خود کلادفلر است و
  آی‌پی‌های کلادفلر و نام سرور `cloudflareclient` دقیقاً همان چیزی است که DPI ایران
  (به‌ویژه روی همراه‌اول) مسدود می‌کند. هیچ کلاینتی نمی‌تواند دست‌دادنی را که مسدود شده
  کامل کند، اما می‌تواند شبیه چیزی که مسدود می‌شود نباشد؛ حالا Smart Connect همین کار
  را می‌کند: تلاش اول دست‌دادن سادهٔ MASQUE است، تلاش دوم **حامل TCP ۴۴۳ با ClientHello
  تکه‌تکه و ECH** (این فیلترها روی SNI کار می‌کنند)، تلاش‌های بعدی ECH را روشن نگه
  می‌دارند و آخرین پلهٔ نردبان وایرگارد است — به همین دلیل روی این شبکه‌ها وایرگارد
  وصل می‌شود. «پرش دوم» (Psiphon یا Tor داخل هسته) هم برای همین وضعیت است: خود تونل را
  از شبکه‌ای عبور می‌دهد که حاضر نیست WARP را حمل کند.

### iOS و TestFlight

مسیر بومی iOS 16+ و workflow **iOS - Build and TestFlight** اضافه شده است.
ابتدا با `upload_testflight=false` کامپایل را بررسی کنید؛ برای ارسال نسخهٔ امضاشده،
حساب Apple Developer، دو profile اپ/افزونه و کلید API اپل لازم است. TestFlight هزینهٔ
عضویت را حذف نمی‌کند. **[راهنمای کامل فارسی](IOS-TESTFLIGHT.md)** شامل Secretها، مجوز
AGPL موتور، محدودیت‌های iOS، مراحل پنل اپل و چک‌لیست تست آیفون است. تا بیلد macOS و
تست واقعی موفق نشوند، آماده‌بودن برای انتشار عمومی تأییدشده نیست.

### به‌روزرسانی اجباری (فقط Android و Windows)

به‌محض انتشار نسخه جدید، **نسخه‌های قبلی از کار می‌افتند**:

- بررسی انتشار در زمان اجرا، هنگام بازگشت به برنامه و پیش از هر اتصال انجام می‌شود؛
- اگر نسخه جدیدی منتشر شده باشد، تونل فوراً قطع می‌شود، اتصال ممکن نیست و صفحه‌ای تمام‌صفحه با راهنمای نصب نمایش داده می‌شود؛
- آن صفحه مستقیم به کانال تلگرام می‌رود؛ فایل نصبی و توضیحات کامل نسخه آنجا منتشر می‌شود؛
- این وضعیت روی دستگاه ذخیره می‌شود، پس حتی بدون اینترنت هم نسخه قدیمی دوباره فعال نمی‌شود.

### انتشار نسخه

در GitHub Actions ورک‌فلو **Release APK and EXE** را Run کنید؛ **نسخه برنامه** (مثلاً `1.1.0`)، **توضیحات نسخه** (اختیاری — در گیت‌هاب و همچنین در صفحه به‌روزرسانی داخل برنامه نمایش داده می‌شود) و **Pre-release** پرسیده می‌شود. با پوش کردن تگ `v1.1.0` هم انتشار انجام می‌شود.

فایل‌ها: `VoidrauVPN-vX.Y.Z-Android-Universal.apk`، نسخه‌های per-ABI، `VoidrauVPN-vX.Y.Z-Android.aab`، `VoidrauVPN-vX.Y.Z-Windows-x64-Installer.exe`، نسخه Portable و `SHA256SUMS.txt`.

### ساخت محلی

```bash
./scripts/bootstrap.sh
bash scripts/fetch_cores.sh
flutter pub get
flutter test
flutter build apk --release --dart-define=VOIDRAU_VERSION=1.1.0
```

نکته‌ها: شناسه اندروید عمداً ثابت مانده است (`pm.dnschanger.nimbus`) تا نسخه جدید روی نسخه قبلی نصب شود و تنظیمات و امضای برنامه حفظ شود. کلید امضا را بین نسخه‌ها تغییر ندهید؛ برنامه APK با امضای متفاوت را نصب نمی‌کند. فهرست اجزای شخص ثالث در [NOTICE.md](NOTICE.md) است.
