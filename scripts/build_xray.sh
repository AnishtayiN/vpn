#!/usr/bin/env bash
# Builds VoidrauVPN's Xray core (xray/: Xray-core and a small Android API
# around it) with gomobile into android/app/libs/xray.aar, for every Android
# ABI. Needs the Android SDK and NDK; Go is the version in xray/go.mod
# (Xray-core's), and gomobile the one pinned there too.
#
# First run on a new machine: `go mod tidy` inside xray/ generates go.sum —
# commit it, and the workflow's `go mod verify` keeps the build honest.
# Verification: the script prints `go version` and the .aar size, and the
# release workflow checks the .aar exists and is non-empty before Flutter
# builds. The Xray-core module itself is verified by Go's module checksum
# database (GONOSUMDB is never set; GOFLAGS=-mod=readonly in CI).
set -euo pipefail
cd "$(dirname "$0")/../xray"

export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:?Set ANDROID_HOME to the Android SDK}}"
export ANDROID_NDK_HOME="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)}"
OUT=../android/app/libs/xray.aar

# gomobile and gobind at go.mod's version, in a local bin directory; gomobile
# also runs javac (JAVA_HOME's, when set).
export GOBIN="$PWD/.bin"
export PATH="$GOBIN${JAVA_HOME:+:$JAVA_HOME/bin}:$PATH"
# The install step must run with -mod=mod: `go mod tidy` only records sums
# for packages the module imports, and cmd/gomobile + cmd/gobind are tools,
# not imports — under -mod=readonly their lookup is refused (seen on the
# first build: "import lookup disabled by -mod=readonly"). The bind below
# still runs with -mod=readonly, so the .aar build itself stays reproducible.
GOFLAGS=-mod=mod go install golang.org/x/mobile/cmd/gomobile golang.org/x/mobile/cmd/gobind
# Go puts its build work dir ($WORK) under /tmp by default; on machines
# where /tmp is a small tmpfs (this VM: 512 MB) the 4-ABI gomobile bind
# dies with "no space left on device". Point it at the home disk unless
# the caller already set GOTMPDIR.
export GOTMPDIR="${GOTMPDIR:-$HOME/.cache/voidrau-gotmp}"
mkdir -p "$GOTMPDIR"
export GOFLAGS=-mod=readonly
gomobile init

mkdir -p "$(dirname "$OUT")"
# -checklinkname=0: a dependency (wlynxg/anet) links into net internals, as in
# Psiphon's build.
gomobile bind -target=android -androidapi 24 -trimpath -ldflags "-s -w -buildid= -checklinkname=0" -o "$OUT" .
rm -f "${OUT%.aar}-sources.jar"
go version
ls -la "$OUT"
