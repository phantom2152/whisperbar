#!/bin/bash
# Builds WhisperBar.app (no Xcode needed, Command Line Tools are enough) and launches it.
#   ./build.sh                       ad-hoc signature
#   SIGN_ID="WhisperBar Dev" ./build.sh   sign with a self-signed cert (keeps mic permission across rebuilds)
set -euo pipefail
cd "$(dirname "$0")"

APP="WhisperBar.app"
SIGN_ID="${SIGN_ID:--}"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/WhisperBar"

# Stop the running copy and wait until it is really gone (avoids LaunchServices error -600)
pkill -x WhisperBar 2>/dev/null || true
while pgrep -x WhisperBar >/dev/null; do sleep 0.1; done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WhisperBar"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.anish.whisperbar</string>
  <key>CFBundleName</key><string>WhisperBar</string>
  <key>CFBundleDisplayName</key><string>WhisperBar</string>
  <key>CFBundleExecutable</key><string>WhisperBar</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>WhisperBar records your voice so your local whisper server can transcribe it.</string>
</dict></plist>
PLIST

codesign --force --sign "$SIGN_ID" "$APP"
sleep 0.5
open "$APP"
echo "Launched $APP"
