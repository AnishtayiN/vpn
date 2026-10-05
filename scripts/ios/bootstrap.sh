#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Scaffold generation can update pubspec/lib on first create; preserve app code.
flutter create . --project-name voidrauvpn --org pm.dnschanger --platforms=ios --no-pub
cp -R overlays/ios/. ios/
# Flutter templates may default to an older deployment target.
python3 - <<'PY'
from pathlib import Path
p = Path('ios/Podfile')
s = p.read_text()
import re
s = re.sub(r"#?\s*platform :ios, '[^']+'", "platform :ios, '16.0'", s)
p.write_text(s)
PY
if [[ "$(uname)" == Darwin ]]; then
  # Writes ios/Flutter/Generated.xcconfig so CocoaPods and Xcode validation work.
  flutter build ios --config-only --release --no-codesign
fi
ruby scripts/ios/configure_project.rb
python3 scripts/ios/icons.py
flutter pub get
