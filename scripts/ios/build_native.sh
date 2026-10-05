#!/usr/bin/env bash
# Real arm64 iPhone libraries only; a simulator cannot validate a device VPN.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ "$(uname)" == Darwin ]] || { echo 'iOS native builds require macOS + Xcode'; exit 1; }
read -r AETHER_REV HEV_REV RUST_VERSION < <(python3 - <<'PY'
import json
p = json.load(open('scripts/pins.json'))
print(p['ios_aether_revision'], p['ios_hev_revision'], p['ios_rust'])
PY
)
fetch() {
  local dir="$1" url="$2" rev="$3"
  if [[ ! -d "$dir/.git" ]]; then git init "$dir"; git -C "$dir" remote add origin "$url"; fi
  git -C "$dir" fetch --depth=1 origin "$rev"
  # Only isolated, ignored dependency checkouts, never the app's working branch.
  git -C "$dir" checkout --detach -f FETCH_HEAD
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$rev" ]]
  git -C "$dir" submodule update --init --recursive --depth=1
}
fetch third_party/aether https://github.com/CluvexStudio/Aether.git "$AETHER_REV"
fetch third_party/hev-ios https://github.com/heiher/hev-socks5-tunnel.git "$HEV_REV"
# App extensions must never fork/exec (post-up scripts, daemon()). The patch
# stubs those two call sites exactly as upstream already does for tvOS.
patch -p1 -d third_party/hev-ios < scripts/ios/hev-ios.patch
rustup toolchain install "$RUST_VERSION" --profile minimal
rustup target add --toolchain "$RUST_VERSION" aarch64-apple-ios
export IPHONEOS_DEPLOYMENT_TARGET=16.0
export SDKROOT
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER
CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$(xcrun --sdk iphoneos --find clang)"
# Use upstream lockfile as the seed for our tiny embedding crate. Cargo only
# adds the local wrapper package; transitive constraints retain pinned versions.
if [[ ! -f native/ios-core/Cargo.lock ]]; then
  cp third_party/aether/aether/Cargo.lock native/ios-core/Cargo.lock
fi
cargo +"$RUST_VERSION" build --manifest-path native/ios-core/Cargo.toml --lib --release --target aarch64-apple-ios
mkdir -p ios/Native
cp native/ios-core/target/aarch64-apple-ios/release/libvoidrau_ios_core.a ios/Native/
pushd third_party/hev-ios
make clean
make -j"$(sysctl -n hw.ncpu)" \
  PP="xcrun --sdk iphoneos clang" CC="xcrun --sdk iphoneos clang" \
  CFLAGS="-arch arm64 -isysroot $SDKROOT -miphoneos-version-min=16.0 -Wno-error" static
xcrun libtool -static -o ../../ios/Native/libhev-socks5-tunnel.a \
  bin/libhev-socks5-tunnel.a third-part/lwip/bin/liblwip.a \
  third-part/yaml/bin/libyaml.a third-part/hev-task-system/bin/libhev-task-system.a
popd
# Prove both actual libraries exist and have the required architecture/symbols.
for want in ios/Native/libvoidrau_ios_core.a ios/Native/libhev-socks5-tunnel.a; do
  [[ -f "$want" ]] || { echo "missing $want"; exit 1; }
done
for lib in ios/Native/*.a; do
  # lipo prints usage on a bare `-verify_arch arm64 file` form; -archs + match
  # works on every Xcode and reports the actual architecture list on failure.
  archs="$(lipo -archs "$lib")"
  case " $archs " in
    *" arm64 "*) echo "$lib: $archs" ;;
    *) echo "$lib lacks arm64 (has: $archs)"; exit 1 ;;
  esac
done
# Apple's nm cannot read every object Rust's newer LLVM produces ("Unknown
# attribute kind" on compiler_builtins members). Search the archives' symbol
# strings directly — the real proof is the Xcode link in the archive step.
grep -a -q 'voidrau_core_start' ios/Native/libvoidrau_ios_core.a \
  || { echo 'voidrau_core_start missing from the core library'; exit 1; }
grep -a -q 'hev_socks5_tunnel_main_from_str' ios/Native/libhev-socks5-tunnel.a \
  || { echo 'hev_socks5_tunnel_main_from_str missing from the bridge library'; exit 1; }
