#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${IOS_VERSION:?}" "${IOS_BUILD_NUMBER:?}"
mkdir -p build/ios/logs
flutter build ios --config-only --release --no-codesign \
  --build-name "$IOS_VERSION" --build-number "$IOS_BUILD_NUMBER" \
  --dart-define="VOIDRAU_VERSION=$IOS_VERSION"
(cd ios && pod install)
if [[ "${IOS_UPLOAD:-false}" != true ]]; then
  xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/ios/VoidrauVPN.xcarchive \
    CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO archive 2>&1 | tee build/ios/logs/archive.log
else
  xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner -configuration Release \
    -destination 'generic/platform=iOS' -archivePath build/ios/VoidrauVPN.xcarchive \
    archive 2>&1 | tee build/ios/logs/archive.log
fi
APP=build/ios/VoidrauVPN.xcarchive/Products/Applications/Runner.app
[[ -d "$APP/PlugIns/PacketTunnel.appex" ]] || { echo 'Missing embedded packet tunnel'; exit 1; }
if [[ "${IOS_UPLOAD:-false}" == true ]]; then
  codesign --verify --deep --strict --verbose=2 "$APP"
  xcodebuild -exportArchive -archivePath build/ios/VoidrauVPN.xcarchive \
    -exportOptionsPlist "$IOS_SIGNING_DIR/ExportOptions.plist" -exportPath build/ios/ipa \
    2>&1 | tee build/ios/logs/export.log
fi
