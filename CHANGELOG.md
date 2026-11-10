# CHANGELOG — VoidrauVPN

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
