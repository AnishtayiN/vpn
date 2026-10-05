#!/usr/bin/env bash
# Download pinned Aether, HEV, tun2socks and Wintun binaries.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-${TARGET:-all}}"
TARGET="$(echo "$TARGET" | tr '[:upper:]' '[:lower:]')"
AETHER_TAG="${AETHER_TAG:-v2.1.0}"
HEV_TAG="${HEV_TAG:-2.17.1}"
TUN2SOCKS_TAG="${TUN2SOCKS_TAG:-v2.6.0}"
# v2.5.1 is the last tun2socks release built with Go 1.20 — the last Go that
# still runs on Windows 7/8/8.1. Everything newer needs Windows 10+, so the
# old build is staged separately as the bridge for those PCs.
TUN2SOCKS_LEGACY_TAG="${TUN2SOCKS_LEGACY_TAG:-v2.5.1}"
WINTUN_URL="${WINTUN_URL:-https://www.wintun.net/builds/wintun-0.14.1.zip}"

if command -v python3 >/dev/null 2>&1; then
  PYTHON="python3"
elif command -v python >/dev/null 2>&1; then
  PYTHON="python"
else
  echo "Error: Neither python3 nor python found" >&2
  exit 1
fi

mkdir -p "$ROOT/third_party/windows" "$ROOT/android/app/src/main/jniLibs"

# Read a pinned digest from scripts/pins.json: pin_sha256 <key>
pin_sha256() {
  "$PYTHON" - "$ROOT/scripts/pins.json" "$1" <<'PIN_PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(data.get("sha256", {}).get(sys.argv[2], ""))
PIN_PY
}

download() {
  local url="$1" dest="$2" expected="${3:-}"
  echo ">> $url"
  curl -fsSL --retry 5 -o "$dest" "$url"
  # Supply-chain check: verify against a pinned digest when one is provided.
  # An empty/unset expected hash FAILS the build instead of passing silently —
  # shipping an unverified binary that later runs elevated is worse than a
  # broken release.
  if [[ -z "$expected" ]]; then
    echo "::error::no pinned sha256 for $url — add it to scripts/pins.json" >&2
    exit 1
  fi
  local got
  got="$(sha256sum "$dest" | awk '{print $1}')"
  if [[ "$got" != "$expected" ]]; then
    echo "::error::sha256 mismatch for $dest (expected $expected, got $got)" >&2
    exit 1
  fi
}

# download_raw: for checksum files themselves — no hash-of-hash.
download_raw() {
  local url="$1" dest="$2"
  echo ">> $url"
  curl -fsSL --retry 5 -o "$dest" "$url"
}

stage_aether_android() {
  local abi="$1" asset="$2" jni="$3"
  local tmp="$ROOT/third_party/aether-$abi"
  mkdir -p "$tmp" "$ROOT/android/app/src/main/jniLibs/$jni"
  local pinned
  pinned="$(pin_sha256 "aether_android_${abi}")"
  download "https://github.com/CluvexStudio/Aether/releases/download/${AETHER_TAG}/${asset}" "$tmp/$asset" "$pinned"
  download_raw "https://github.com/CluvexStudio/Aether/releases/download/${AETHER_TAG}/${asset}.sha256" "$tmp/$asset.sha256"
  # A failed or skipped checksum used to pass silently and shipped a corrupt
  # (or truncated) core — the app then "connected" to nothing. Hard fail.
  (cd "$tmp" && sha256sum -c "$asset.sha256")
  tar -xzf "$tmp/$asset" -C "$tmp"
  local bin
  bin="$(find "$tmp" -type f -name 'aether' | head -n1)"
  if [[ -z "$bin" || ! -f "$bin" ]]; then
    echo "Error: no 'aether' executable inside $asset" >&2
    tar -tzf "$tmp/$asset" >&2 || true
    exit 1
  fi
  cp "$bin" "$ROOT/android/app/src/main/jniLibs/$jni/libaether.so"
  chmod 755 "$ROOT/android/app/src/main/jniLibs/$jni/libaether.so"
  # Sanity: the staged payload must really be an ELF executable, otherwise
  # ProcessBuilder fails at runtime on the device.
  if ! head -c 4 "$ROOT/android/app/src/main/jniLibs/$jni/libaether.so" | grep -q $'\x7fELF'; then
    echo "Error: $asset did not contain an ELF binary" >&2
    exit 1
  fi
  echo "staged $jni/libaether.so ($(du -h "$ROOT/android/app/src/main/jniLibs/$jni/libaether.so" | cut -f1))"
}

stage_aether_windows() {
  local tmp="$ROOT/third_party/aether-win"
  mkdir -p "$tmp"
  download "https://github.com/CluvexStudio/Aether/releases/download/${AETHER_TAG}/aether-windows-x86_64.zip" "$tmp/aether-windows-x86_64.zip" "$(pin_sha256 aether_windows_x86_64)"
  download_raw "https://github.com/CluvexStudio/Aether/releases/download/${AETHER_TAG}/aether-windows-x86_64.zip.sha256" "$tmp/aether-windows-x86_64.zip.sha256"
  (cd "$tmp" && sha256sum -c aether-windows-x86_64.zip.sha256)
  "$PYTHON" - "$tmp" <<'AETHER_PY'
import zipfile, sys
from pathlib import Path

def _safe_extract(zf, dest):
    dest = dest.resolve()
    for m in zf.infolist():
        t = (dest / m.filename).resolve()
        if not str(t).startswith(str(dest)):
            raise SystemExit(f"zip-slip member rejected: {m.filename}")
    zf.extractall(dest)
z = Path(sys.argv[1]) / "aether-windows-x86_64.zip"
with zipfile.ZipFile(z) as f:
    _safe_extract(f, z.parent)
AETHER_PY
  find "$tmp" -name 'aether.exe' -exec cp {} "$ROOT/third_party/windows/aether.exe" \;
  if [[ ! -s "$ROOT/third_party/windows/aether.exe" ]]; then
    echo "Error: aether.exe missing after extraction" >&2
    exit 1
  fi
}

# Windows TUN bridges. Two rules learned the hard way:
#
#   1. Take the *baseline* amd64 asset. GitHub lists
#      `tun2socks-windows-amd64-v3.zip` before `tun2socks-windows-amd64.zip`,
#      so "the first asset whose name mentions amd64" is a GOAMD64=v3 binary.
#      That one dies with an illegal instruction on any pre-Haswell CPU — most
#      Windows 8.1 hardware — and the app could only report that the WinTUN
#      adapter "never appeared".
#   2. Take a *pinned* tag, never "latest". Current tun2socks releases are
#      built with Go >= 1.21, which requires Windows 10+; on Windows 8.1 the
#      process is gone before it can create the adapter.
#
# The Go toolchain and the GOAMD64 target are read out of the binary's embedded
# build info, so a wrong asset fails the release build here instead of failing
# on somebody's 2013 laptop.
stage_tun2socks_build() {
  local url="$1" dest_name="$2" require_go="${3:-}"
  local tmp="$ROOT/third_party/tun2socks-${dest_name%.exe}"
  mkdir -p "$tmp" "$ROOT/third_party/windows"
  local pinned
  if [[ "$dest_name" == *"legacy"* ]]; then
    pinned="$(pin_sha256 tun2socks_legacy_windows_amd64)"
  else
    pinned="$(pin_sha256 tun2socks_windows_amd64)"
  fi
  download "$url" "$tmp/tun2socks.zip" "$pinned"
  "$PYTHON" - "$tmp" "$ROOT/third_party/windows/$dest_name" "$require_go" <<'TUN_PY'
import re, shutil, sys, zipfile
from pathlib import Path

def _safe_extract(zf, dest):
    dest = dest.resolve()
    for m in zf.infolist():
        t = (dest / m.filename).resolve()
        if not str(t).startswith(str(dest)):
            raise SystemExit(f"zip-slip member rejected: {m.filename}")
    zf.extractall(dest)

src, dest = Path(sys.argv[1]), Path(sys.argv[2])
require = sys.argv[3] if len(sys.argv) > 3 else ""

with zipfile.ZipFile(src / "tun2socks.zip") as z:
    _safe_extract(z, src / "x")
exes = sorted((src / "x").rglob("*.exe"))
if not exes:
    raise SystemExit("Error: no .exe inside the tun2socks Windows zip")
exe = exes[0]
data = exe.read_bytes()
if not data.startswith(b"MZ"):
    raise SystemExit(f"Error: {exe.name} is not a Windows PE executable")
if b"GOAMD64=v3" in data:
    raise SystemExit(
        f"Error: {exe.name} is a GOAMD64=v3 build and needs an AVX2 CPU. "
        "Stage tun2socks-windows-amd64.zip (baseline x86-64) instead."
    )
# Go embeds its own version in the build-info blob ("go1.24.2"). Three
# components keep the match specific enough to be trusted.
m = re.search(rb"go(\d+)\.(\d+)\.(\d+)", data)
if m:
    major, minor = int(m.group(1)), int(m.group(2))
    toolchain = f"go{major}.{minor}.{int(m.group(3))}"
else:
    major = minor = 0
    toolchain = "unknown"
if require and m:
    rm = re.match(r"(\d+)\.(\d+)", require)
    if rm and (major, minor) > (int(rm.group(1)), int(rm.group(2))):
        raise SystemExit(
            f"Error: {exe.name} was built with {toolchain}; Windows 8.1 and "
            f"older need go{require} or earlier."
        )
shutil.copy2(exe, dest)
print(f"staged {dest.name} ({len(data) // 1024} KiB, toolchain {toolchain})")
TUN_PY
}

stage_tun2socks() {
  local url="${TUN2SOCKS_URL:-https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_TAG}/tun2socks-windows-amd64.zip}"
  stage_tun2socks_build "$url" "tun2socks.exe"
}

stage_tun2socks_legacy() {
  local url="${TUN2SOCKS_LEGACY_URL:-https://github.com/xjasonlyu/tun2socks/releases/download/${TUN2SOCKS_LEGACY_TAG}/tun2socks-windows-amd64.zip}"
  stage_tun2socks_build "$url" "tun2socks-legacy.exe" "1.20"
}

# The C bridge (heiher/hev-socks5-tunnel) — the same project the Android side
# links against. No Go runtime, so it is a third option for a device VPN on old
# Windows. Its MSYS runtime DLL must sit next to the exe or it dies with
# STATUS_DLL_NOT_FOUND (0xC0000135) before it ever touches WinTUN.
stage_hev_windows() {
  local tmp="$ROOT/third_party/hev-win"
  mkdir -p "$tmp" "$ROOT/third_party/windows"
  download "https://github.com/heiher/hev-socks5-tunnel/releases/download/${HEV_TAG}/hev-socks5-tunnel-win64.zip" "$tmp/hev-win64.zip" "$(pin_sha256 hev_windows_win64)"
  "$PYTHON" - "$tmp" "$ROOT/third_party/windows" <<'HEV_PY'
import shutil, sys, zipfile
from pathlib import Path

def _safe_extract(zf, dest):
    dest = dest.resolve()
    for m in zf.infolist():
        t = (dest / m.filename).resolve()
        if not str(t).startswith(str(dest)):
            raise SystemExit(f"zip-slip member rejected: {m.filename}")
    zf.extractall(dest)

src, dest = Path(sys.argv[1]), Path(sys.argv[2])
with zipfile.ZipFile(src / "hev-win64.zip") as z:
    _safe_extract(z, src / "x")
files = {p.name.lower(): p for p in (src / "x").rglob("*") if p.is_file()}
exe = next(
    (p for n, p in files.items()
     if n.startswith("hev-socks5-tunnel") and n.endswith(".exe")),
    None,
)
if exe is None:
    raise SystemExit("Error: hev-socks5-tunnel.exe missing from the win64 zip")
data = exe.read_bytes()
if not data.startswith(b"MZ"):
    raise SystemExit("Error: the hev Windows binary is not a PE executable")
shutil.copy2(exe, dest / "hev-socks5-tunnel.exe")
print(f"staged hev-socks5-tunnel.exe ({len(data) // 1024} KiB)")

runtime = files.get("msys-2.0.dll")
if runtime is not None:
    shutil.copy2(runtime, dest / "msys-2.0.dll")
    print("staged msys-2.0.dll")
else:
    print("Warning: msys-2.0.dll not in the zip; hev would die with 0xC0000135")

# hev loads wintun.dll from its own directory. Keep the pinned WinTUN build when
# it is already staged, otherwise take the copy that ships in this zip.
if not (dest / "wintun.dll").exists():
    bundled = files.get("wintun.dll")
    if bundled is not None:
        shutil.copy2(bundled, dest / "wintun.dll")
        print("staged wintun.dll (from the hev zip)")
HEV_PY
}

stage_wintun() {
  local tmp="$ROOT/third_party/wintun"
  mkdir -p "$tmp" "$ROOT/third_party/windows"
  download "$WINTUN_URL" "$tmp/wintun.zip" "$(pin_sha256 wintun_0_14_1)"
  "$PYTHON" - "$tmp" "$ROOT/third_party/windows" <<'WINTUN_PY'
import zipfile, shutil, sys
from pathlib import Path

def _safe_extract(zf, dest):
    dest = dest.resolve()
    for m in zf.infolist():
        t = (dest / m.filename).resolve()
        if not str(t).startswith(str(dest)):
            raise SystemExit(f"zip-slip member rejected: {m.filename}")
    zf.extractall(dest)
src, dest = Path(sys.argv[1]), Path(sys.argv[2])
with zipfile.ZipFile(src / "wintun.zip") as z:
    _safe_extract(z, src)
dll = next((p for p in src.rglob("wintun.dll") if "amd64" in str(p).lower() or "x64" in str(p).lower()), None)
if not dll:
    dll = next(src.rglob("wintun.dll"))
shutil.copy2(dll, dest / "wintun.dll")
WINTUN_PY
}

echo "Fetching Aether ${AETHER_TAG} ($TARGET)"
if [[ "$TARGET" == "all" || "$TARGET" == "android" ]]; then
  stage_aether_android arm64 aether-android-arm64.tar.gz arm64-v8a
  stage_aether_android armv7 aether-android-armv7.tar.gz armeabi-v7a
  stage_aether_android x64 aether-android-x86_64.tar.gz x86_64
fi
if [[ "$TARGET" == "all" || "$TARGET" == "windows" ]]; then
  stage_aether_windows
  stage_tun2socks
  stage_tun2socks_legacy
  stage_wintun
  stage_hev_windows
fi
echo "cores staged"
