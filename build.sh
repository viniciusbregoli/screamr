#!/bin/sh
# Builds Screamr.app (menu bar only) into ./build. `./build.sh install` also copies it to
# ~/Applications, where Raycast and Spotlight find it.
set -e
cd "$(dirname "$0")"
swift build -c release
app=build/Screamr.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/Screamr "$app/Contents/MacOS/Screamr"
iconset=build/AppIcon.iconset
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z $size $size assets/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) assets/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.screamr.app</string>
  <key>CFBundleName</key><string>Screamr</string>
  <key>CFBundleExecutable</key><string>Screamr</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>LSUIElement</key><true/>
  <key>NSAudioCaptureUsageDescription</key><string>Screamr records call audio during meeting recordings so the other participants appear in the transcript.</string>
  <key>NSMicrophoneUsageDescription</key><string>Screamr records your voice while you hold Fn and sends it to ElevenLabs for transcription.</string>
</dict>
</plist>
PLIST
# Ad-hoc signature: macOS ties Accessibility/Mic grants to it, so a rebuild may need re-granting.
codesign --force --sign - "$app"
echo "Built $app"
if [ "$1" = install ]; then
  pkill -x Screamr || true
  rm -rf ~/Applications/Screamr.app
  mkdir -p ~/Applications
  cp -R "$app" ~/Applications/
  open ~/Applications/Screamr.app
  echo "Installed ~/Applications/Screamr.app"
fi
