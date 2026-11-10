# Xray engine — release notes (Phase 1b)

The Xray engine is VoidrauVPN's second engine, beside Aether. It is
**Android-only** and opt-in: `XrayMode.off` (the default) is Aether exactly
as before, and Windows/iOS never see the Xray modes.

## What ships in this phase (scaffold + first slice)

- Dart: `lib/services/xray_engine.dart` (config builder + platform-channel
  client), `cloudflare_api.dart` (deploy the user's own Worker),
  `warp.dart` (WARP registration, keys generated on device),
  `chain_proxy.dart` + `proxy_uri.dart` (user-entered share links),
  `secure_store.dart` (secrets live only in secure storage).
- Worker: `worker/worker.js` (VLESS-over-WebSocket; no hardcoded fallback
  host, no bundled UUID/domain/key).
- Go: `xray/go.mod` + `xray/xray.go` (gomobile wrapper around Xray-core),
  built by `scripts/build_xray.sh` into `android/app/libs/xray.aar`.
- Native: `overlays/android/.../XrayCoreManager.kt` (CoreManager-equivalent)
  + `startXray` / `stopXray` / `xrayStatus` methods in `NimbusPlugin.kt`.
- UI: `lib/ui/pages/setup_wizard.dart` (Worker deploy / WARP register /
  Serverless toggles) and `lib/ui/pages/chain_proxies_page.dart`, wired into
  Settings and the Connect page (Android only).
- Tests: `test/xray_engine_test.dart` (pure Dart, no device).

## What is NOT done yet (blocking a real Xray connection)

1. ~~**`xray.aar` has never been built in this VM** (no Go/Flutter here).
   Run `scripts/build_xray.sh` once on a machine with Go 1.27 + Android
   SDK/NDK, then commit the generated `xray/go.sum` (`go mod tidy`).~~
   **Done 2026-11-11 in this VM:** Go 1.27.4 + Flutter 3.27.4 + JDK 17 +
   NDK 27.0.12077973 installed under `~/workspace/tools/`; `go mod tidy`
   generated `xray/go.sum` (commit it); `scripts/build_xray.sh` produced
   `android/app/libs/xray.aar` (52 MB, all 4 ABIs). Two real bugs found and
   fixed by the build: `go install` of gomobile needed `-mod=mod`, and
   `Controller.Traffic() (int64, int64, error)` is not bindable — it is now
   `TrafficUp()` / `TrafficDown() (int64, error)`. `flutter analyze` is
   clean and `flutter test` passes 168/168.
2. ~~**`XrayCoreManager.kt` is a stub**: it answers `xray_unavailable` until
   the `.aar` is linked. The file itself lists the three steps to finish it
   (import the gomobile package, wire `Start`/`Stop`, open a VpnService in
   `vpn` mode and pass the TUN fd).~~
   **Done 2026-11-11:** `XrayCoreManager.kt` is complete — it imports the
   gomobile package, creates the controller, calls `initEnv` / `Start` /
   `Stop`, and reports real status + traffic counters. New sibling service
   `XrayVpnService.kt` (declared in the manifest) establishes the TUN and
   passes its fd to the core in `vpn` mode; `proxy` mode starts the core
   with fd 0. The stub's `xray_unavailable` path is gone.
3. **No on-phone test yet**: no real Worker deploy, no real WARP
   registration, no Xray connection has been run. The first phone test is:
   deploy a Worker from the wizard → pick Worker mode → connect → the exit
   IP must change (dashboard leak check), then repeat for WARP and
   Serverless, on Android 10+ and on a `-Legacy` (Android 7–9) build.
   The `flutter build apk` step itself has NOT been run here either
   (Gradle needs the Android Gradle plugin download + daemon; not attempted
   in this VM).
4. **Windows / iOS**: no Xray build exists for them, by design in this
   phase. The modes are hidden there; Aether is untouched.

## Release-workflow steps (Go + NDK + gomobile)

The existing `release.yml` is NOT modified in this phase — it keeps
building Aether exactly as before. Xray has its own workflow,
`.github/workflows/xray-android.yml` (manual dispatch, builds only the
`.aar` artifact so the step can be proven alone). To fold the `.aar` into a
real release later, add these steps to the `android` job of `release.yml`,
**after** "Install NDK" and **before** `flutter build apk`:

```yaml
- name: Set up Go
  uses: actions/setup-go@v5
  with:
    go-version: "1.27"
    cache-dependency-path: xray/go.mod
- name: Build Xray core (.aar)
  env:
    ANDROID_HOME: ${{ env.ANDROID_HOME }}
    ANDROID_NDK_HOME: ${{ env.ANDROID_NDK_HOME }}
  run: |
    bash scripts/build_xray.sh
    test -s android/app/libs/xray.aar
- name: Verify Xray module checksums
  run: cd xray && go mod verify
```

Notes:

- Go 1.27 is pinned by `xray/go.mod`; the runner's Go must be >= that.
- The NDK version stays 27.0.12077973 (same as the Aether job); gomobile
  needs `ANDROID_NDK_HOME` set, which the "Install NDK" step already does.
- `gomobile bind -androidapi 24` matches `minSdk 24` (Android 7): the same
  `.aar` works for both the legacy and the modern matrix entries.
- The `.aar` is ~tens of MB and is a build artifact, not a git file: do not
  commit `android/app/libs/xray.aar`. The release job rebuilds it every time.
- `go.sum` MUST be committed after the first `go mod tidy`; without it the
  `GOFLAGS=-mod=readonly` build fails. Never hand-write `go.sum`.
- Secrets: none new. The Cloudflare token, Worker UUID and WARP keys are
  per-user, per-device values in secure storage — they are never CI secrets
  and never appear in a workflow.

## Licence / attribution

- Xray-core is MPL-2.0 (`github.com/xtls/xray-core`); the gomobile wrapper
  and the Dart config builder are VoidrauVPN's own code.
- The Worker relay logic, the Cloudflare deploy flow, the WARP registration
  flow and the share-link parsing follow the approach of BPB-VPN
  (GNU GPL v3.0) and are re-implemented in VoidrauVPN's own code — see
  README "Attribution" and CHANGELOG. No BPB code was copied verbatim, no
  BPB name/logo/brand is used, and the MITM domain-fronting part of BPB
  (CA install, TLS decryption) was deliberately NOT implemented.
