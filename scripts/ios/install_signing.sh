#!/usr/bin/env bash
set -euo pipefail
# No shell xtrace: certificates, passwords and API keys must stay out of logs.
: "${IOS_SIGNING_DIR:?}" "${APPLE_TEAM_ID:?}" "${IOS_BUNDLE_ID:?}" "${KEYCHAIN_PASSWORD:?}"
umask 077
mkdir -p "$IOS_SIGNING_DIR"
python3 - <<'PY'
import base64, os, re
from pathlib import Path
p = Path(os.environ['IOS_SIGNING_DIR'])
if not re.fullmatch(r'[A-Z0-9]{10}', os.environ.get('ASC_KEY_ID', '')):
    raise SystemExit('ASC_KEY_ID must be a 10-character App Store Connect key ID')
for key, name in [('IOS_CERTIFICATE_P12_BASE64', 'certificate.p12'),
                  ('IOS_APP_PROFILE_BASE64', 'Runner.mobileprovision'),
                  ('IOS_TUNNEL_PROFILE_BASE64', 'PacketTunnel.mobileprovision'),
                  ('ASC_PRIVATE_KEY_BASE64', 'AuthKey_' + os.environ['ASC_KEY_ID'] + '.p8')]:
    value = os.environ.get(key, '')
    if not value:
        raise SystemExit(f'Missing secret: {key}')
    (p / name).write_bytes(base64.b64decode(''.join(value.split()), validate=True))
PY
KEYCHAIN="$IOS_SIGNING_DIR/build.keychain-db"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$IOS_SIGNING_DIR/certificate.p12" -k "$KEYCHAIN" \
  -P "$IOS_CERTIFICATE_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
# Preserve the existing keychain search list for Flutter/CocoaPods.
security list-keychains -d user > "$IOS_SIGNING_DIR/original-keychains.txt"
python3 - <<'PY'
import os, shlex, subprocess
from pathlib import Path
p = Path(os.environ['IOS_SIGNING_DIR'])
old = shlex.split((p / 'original-keychains.txt').read_text())
subprocess.run(['security','list-keychains','-d','user','-s',str(p/'build.keychain-db'),*old], check=True)
PY
python3 scripts/ios/signing.py
