# CHANGELOG — VoidrauVPN

## v1.5.3: نشست‌ها و پلن‌های چندکاربره

- `LicenseService`: شناسهٔ پایدار دستگاه (`device.id` در secure storage،
  ۳۲ کاراکتر hex از `Random.secure`، بدون پکیج جدید) + نام دستگاه از
  سیستم‌عامل، پلتفرم و نسخهٔ اپ در هر `check()` به `/api/license` فرستاده
  می‌شود. پاسخ `maxUsers`، `sessions`، `sessionId` و `sessionActive` را
  ذخیره می‌کند؛ اگر نشست این دستگاه حذف شده باشد (`sessionActive == false`
  یا دستگاه در لیست نشست‌ها نباشد) کلید پاک و کاربر به صفحهٔ لایسنس
  برمی‌گردد با پیام «نشست این دستگاه حذف شد».
- خطای 409 `session-limit` به‌صورت ساخت‌یافته (`lastLimitError`: سقف + لیست
  دستگاه‌های فعال) نگه داشته می‌شود؛ صفحهٔ فعال‌سازی لیست دستگاه‌ها را
  نشان می‌دهد و حذف یکی و تلاش دوباره را پیشنهاد می‌کند (یا مدیریت از ربات
  @VoidRauBot).
- صفحهٔ جدید «نشست‌ها» (`lib/ui/pages/sessions_page.dart`، از صفحهٔ لایسنس):
  لیست نشست‌ها با نام دستگاه، پلتفرم، نسخهٔ اپ و آخرین فعالیت به تاریخ
  شمسی، نشان «این دستگاه»، برچسب «غیرفعال» برای نشست‌های بی‌فعالیت بیش از
  ۳۰ روز، حذف یک نشست و حذف همه به‌جز این دستگاه (هر دو با تأیید).
  صفحهٔ لایسنس «تا N دستگاه» را نشان می‌دهد.
- متدهای `revokeSession(sessionId)` و `revokeAllSessions(keepCurrent: true)`
  با همان API ورکر (`POST /api/sessions/revoke` و `revoke-all`).
- تست‌ها: `test/sessions_test.dart` (شکل deviceId، تجزیهٔ نشست‌ها، خطای
  session-limit، مسیرهای check/revoke با HTTP ساختگی).

## Unreleased — v1.5.2: Psiphon/Tor actually work + connection-mode UX

Root cause (see `../bpb-audit/psiphon-tor-diagnosis-fa.md` in the audit notes):
the app never shipped Aether's `pt/` helper binaries, so Psiphon died at
startup ("psiphon needs the psiphon-tunnel-core console client") and Tor
could only use plain bridges. Verified against the real 2.4.0 binary
(release notes, tarball contents, binary strings, live `aether --help` and
live runs with/without `pt/`). The Dart wiring (model, env, controller, UI)
was correct and PR #5 broke nothing.

- `scripts/fetch_cores.sh`: stages `pt/psiphon-tunnel-core` and `pt/lyrebird`
  from the same sha256-verified tarball — Android per-ABI as
  `jniLibs/<abi>/libpsiphon.so` / `liblyrebird.so`, Windows as
  `third_party/windows/pt/*.exe`. A missing helper fails the build instead of
  shipping modes that can never connect. Cost: ~35 MB per single-ABI APK.
- Native launchers point the core at the helpers explicitly
  (`AETHER_PSIPHON_BIN` / `AETHER_TOR_PT`): Android
  `NimbusVpnService.resolveHelper()` (native library dir, with a
  `filesDir/pt/` copy fallback), Windows `WindowsEngine.start()` from the exe
  dir. `release.yml` verifies the helpers on both jobs and copies
  `third_party/windows` with `-Recurse`.
- Reverse hops no longer dial WireGuard: `CoreLaunch.smartVariant` rewrites a
  WireGuard rung to MASQUE over HTTP/2 and `smartLadder` drops the WireGuard
  rung; the controller now starts (and pins) the variant's protocol, not the
  raw ladder rung.
- Psiphon mode defaults to `auto` (was `direct`); `cdn` only when the CDN
  switch is on.
- Slow hops get time to start: Android traffic validation is longer for
  standalone/reverse hops with no core re-roll (there is no gateway to
  re-roll), the Dart connect budget is 300 s for slow hops, Windows waits
  240 s for SOCKS and probes longer.
- Honest errors: `lib/services/core_errors.dart` translates known core
  failures into Persian, applied on every error path; the Connect page links
  to Diagnostics on error.
- UX: one "connection mode" line on the Connect page (engine + mode); the
  second-hop picker is disabled with a note while a standalone mode is set;
  the protocol section notes the automatic MASQUE switch for reverse hops;
  the stale "unverified on 2.4.0" warning is replaced by a slow-start note.
  Full review in `../bpb-audit/ux-audit-fa.md`.
- Tests: 190/190 (was 181; +4 core-env, +5 core-errors). `flutter analyze`
  clean. `flutter build apk` not attempted locally (Gradle daemon blocked);
  Kotlin compiles on CI and the release runner is the proof.
- Still NOT tested on a phone: no on-phone Psiphon/Tor connection has been
  run by the agent — the user must test on his Poco and report back.

## Unreleased — Xray engine, Phase 1b (scaffold + first slice, Android only)

Second engine beside Aether: Xray-core for Worker/VLESS, WARP and
Serverless modes, plus user-entered chain proxies. Aether is untouched and
remains the default (`XrayMode.off`); Windows and iOS never see the Xray
modes. No code was pushed or released in this phase; the native Xray core
(`xray.aar`) has not been built yet, so an on-phone Xray connection has not
been tested — see `docs/xray-release-notes.md`.

- Xray config builder (`lib/services/xray_engine.dart`): Worker (VLESS over
  WebSocket + TLS, optional TLS-fragment variant), WARP (WireGuard, optional
  UDP-noise obfuscation) and Serverless (freedom + TLS fragment + UDP noise
  only — no MITM, no domain fronting, no CA install).
- Cloudflare deploy (`lib/services/cloudflare_api.dart` + setup wizard):
  deploys the user's OWN Worker from `worker/worker.js` with the user's own
  API token; the token and the VLESS UUID live only in secure storage.
- WARP registration (`lib/services/warp.dart`): account registered on the
  device, keys generated on the device, private key in secure storage only.
- Chain proxies (`lib/services/chain_proxy.dart`, `proxy_uri.dart`):
  VLESS / VMess / Trojan / Shadowsocks / SOCKS / HTTP / WireGuard /
  Hysteria2 share links entered by the user, plus WireGuard config files.
  UDP-only proxies ride on WARP only (the Worker relays TCP only).
- Settings models, Persian + English strings, setup-wizard and chain-proxy
  pages, Connect-page mode chips and a Settings section (Android only).
- Go: `xray/go.mod` + `xray/xray.go` + `scripts/build_xray.sh` (gomobile
  `.aar`, Android API 24); `.github/workflows/xray-android.yml` builds only
  the `.aar`. The existing `release.yml` is unchanged.
- Tests: `test/xray_engine_test.dart`.

### Attribution

The Worker relay logic, the Cloudflare deploy flow, the WARP registration
flow and the share-link parsing follow the approach of BPB-VPN
(github.com/bia-pain-bache/BPB-VPN, GNU General Public License v3.0) and are
re-implemented in VoidrauVPN's own code — no BPB code was copied verbatim,
and no BPB name, logo or brand is used. Xray-core itself is MPL-2.0
(github.com/xtls/xray-core). The MITM domain-fronting part of BPB (own CA,
TLS decryption) was deliberately NOT implemented.

### Licence check note

VoidrauVPN's existing licences (Aether AGPL-3.0, hev MIT — see
`assets/legal/`) are unaffected: the Xray pieces added here are VoidrauVPN's
own code plus the MPL-2.0 Xray-core library, and the BPB-derived logic is
re-implemented rather than copied, so no GPLv3 code enters the tree. If a
future change ever copies BPB code verbatim, that file must carry the GPLv3
header and the change must be recorded here first.
