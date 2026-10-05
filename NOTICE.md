# Third-party notices

VoidrauVPN is an independent client, not endorsed by Cloudflare or the upstream
projects. The repository's MIT LICENSE covers its original source, not the
third-party components nor every obligation applying to combined binaries.

## iOS native engine

The iOS extension **statically links** these components, rather than launching
independent programs:

- **Aether 2.1.0 — CluvexStudio — AGPL-3.0-only**. Pinned source revision:
  `a9703a723dff6d820252799a2ff32bd26d6638ee` (tag `v2.1.0`).
  <https://github.com/CluvexStudio/Aether>. See `assets/legal/Aether-AGPL-3.0.txt`.
- **hev-socks5-tunnel 2.17.1 — hev/heiher — MIT**. Pinned source revision:
  `9a06bc6e7989da54e3d32ff701ef7a7ce4995d3a`.
  <https://github.com/heiher/hev-socks5-tunnel>. See `assets/legal/Hev-MIT.txt`.
- Their vendored/submodule/Rust dependencies retain their own licenses, including
  quiche, BoringSSL, boringtun, smoltcp, lwIP, libyaml and hev-task-system.
  Preserve their notices and license files from the corresponding-source bundle.

The previous notices incorrectly described Aether as MIT and HEV as GPL-2.0.
The licenses above reflect the actual pinned source used for iOS.

**Distribution gate:** linking an AGPL core changes the obligations of distributing
this combined binary. Apple's TestFlight/App Store terms may be incompatible with
those obligations. Before uploading, obtain a suitable alternative license from
all necessary rightsholders or have the proposed distribution reviewed for
compliance. A workflow checkbox does not grant a license. Merely publishing this
repository or attaching source does not establish App Store compatibility.

The iOS signing workflow includes a corresponding-source archive, resolved Rust
lockfile, vendored Rust sources, upstream source/submodules and build scripts.
Preserve and provide this archive with every distributed build, including builds
shared outside GitHub; Actions artifacts expire. It does not contain Apple's SDK,
Xcode, credentials, or an assurance of legal compliance.

## Android / Windows sidecars

Aether and HEV retain the licenses above when redistributed as sidecars as well.
Other staged components include:

- tun2socks — xjasonlyu — GPL-3.0 (<https://github.com/xjasonlyu/tun2socks>)
- WinTUN — WireGuard LLC — see the license in the redistributed package
  (<https://www.wintun.net/>)

Keep each component's notices with its binaries. Audit dependency notices and
privacy manifests before public release; this is not legal advice.
