#!/bin/sh
# Builds the iOS app and runs it on the booted simulator, or on a connected iPhone with `./run.sh device`.
set -e
cd "$(dirname "$0")"
xcodegen generate --quiet

if [ "$1" = device ]; then
  device=${DEVICE:-$(xcrun devicectl list devices | grep physical | grep -oE '[0-9A-F]{8}-[0-9A-F]{16}' | head -1)}
  [ -n "$device" ] || { echo "No iPhone found: connect it or set DEVICE"; exit 1; }
  xcodebuild -project ScreamrMobile.xcodeproj -scheme Screamr -configuration Release \
    -destination generic/platform=iOS -derivedDataPath build -allowProvisioningUpdates -quiet
  xcrun devicectl device install app --device "$device" build/Build/Products/Release-iphoneos/Screamr.app
  xcrun devicectl device process launch --device "$device" dev.screamr.ios
else
  xcodebuild -project ScreamrMobile.xcodeproj -scheme Screamr -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath build -quiet
  xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/Screamr.app
  xcrun simctl launch booted dev.screamr.ios
fi
