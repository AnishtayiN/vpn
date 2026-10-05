#!/usr/bin/env bash
# Build hev-socks5-tunnel JNI shared libraries with the Android NDK.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HEV_TAG="${HEV_TAG:-2.17.1}"
NDK="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
if [[ -z "$NDK" && -n "${ANDROID_HOME:-}" ]]; then
  NDK="$(ls -d "$ANDROID_HOME"/ndk/* 2>/dev/null | tail -n1 || true)"
fi
if [[ -z "$NDK" ]]; then
  echo "Android NDK not found" >&2
  exit 1
fi
export NDK_HOME="$NDK"
WORKDIR="$ROOT/third_party/hev-socks5-tunnel"
rm -rf "$WORKDIR"
git clone https://github.com/heiher/hev-socks5-tunnel.git "$WORKDIR"
# Immutable commit — a mutable tag is a supply-chain hole; this is tag 2.17.1.
git -C "$WORKDIR" checkout --detach 9a06bc6e7989da54e3d32ff701ef7a7ce4995d3a
git -C "$WORKDIR" submodule update --init --recursive --depth 1
pushd "$WORKDIR" >/dev/null
"$NDK/ndk-build" -j"$(nproc)" APP_ABI="armeabi-v7a arm64-v8a x86_64" NDK_PROJECT_PATH=. APP_BUILD_SCRIPT=Android.mk
popd >/dev/null
for abi in armeabi-v7a arm64-v8a x86_64; do
  dest="$ROOT/android/app/src/main/jniLibs/$abi"
  mkdir -p "$dest"
  so="$(find "$WORKDIR" -path "*$abi*" -name 'libhev-socks5-tunnel.so' | head -n1)"
  if [[ -z "$so" ]]; then
    so="$(find "$WORKDIR/libs/$abi" -name 'libhev-socks5-tunnel.so' 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$so" ]]; then
    echo "missing libhev-socks5-tunnel.so for $abi" >&2
    find "$WORKDIR" -name '*.so' | head
    exit 1
  fi
  cp "$so" "$dest/libhev-socks5-tunnel.so"
  echo "installed $abi/libhev-socks5-tunnel.so"
done
