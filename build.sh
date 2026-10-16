#!/bin/sh
# Builds Screamr.app (menu bar only) into ./build.
set -e
cd "$(dirname "$0")"
swift build -c release
app=build/Screamr.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp .build/release/Screamr "$app/Contents/MacOS/Screamr"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.screamr.app</string>
  <key>CFBundleName</key><string>Screamr</string>
  <key>CFBundleExecutable</key><string>Screamr</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Screamr records your voice while you hold Fn and sends it to ElevenLabs for transcription.</string>
</dict>
</plist>
PLIST
# Ad-hoc signature: macOS ties Accessibility/Mic grants to it, so a rebuild may need re-granting.
codesign --force --sign - "$app"
echo "Built $app"
