#!/usr/bin/env bash
# Accompany binary distribution with the exact build inputs, not just a link to
# a mutable upstream tag. This is not a substitute for reviewing AGPL obligations.
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/ios/source
stage="$(mktemp -d "${RUNNER_TEMP:-/tmp}/voidrau-source.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
# CI has all app code committed. Local modifications should be committed before
# making a corresponding-source release bundle.
git archive HEAD | tar -x -C "$stage"
mkdir -p "$stage/third_party"
for dir in aether hev-ios; do
  rsync -a --exclude=.git --exclude=target --exclude=build --exclude=bin \
    "third_party/$dir/" "$stage/third_party/$dir/"
done
RUST_VERSION="$(python3 -c 'import json; print(json.load(open("scripts/pins.json"))["ios_rust"])')"
mkdir -p "$stage/.cargo"
cargo +"$RUST_VERSION" vendor --locked --manifest-path native/ios-core/Cargo.toml \
  "$stage/vendor" > "$stage/.cargo/config.toml"
# Cargo emits an absolute vendor path; make the archive relocatable.
python3 - "$stage/.cargo/config.toml" "$stage/vendor" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1]); p.write_text(p.read_text().replace(sys.argv[2], 'vendor'))
PY
cp native/ios-core/Cargo.lock "$stage/native/ios-core/Cargo.lock"
git rev-parse HEAD > "$stage/SOURCE_COMMIT.txt"
tar -czf build/ios/source/VoidrauVPN-ios-source.tar.gz -C "$stage" .
cp NOTICE.md build/ios/source/
