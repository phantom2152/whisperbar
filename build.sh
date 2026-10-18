#!/bin/bash
set -e
swift build -c release
APP=WhisperBar.app
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp .build/release/WhisperBar $APP/Contents/MacOS/
cat > $APP/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>dev.anish.whisperbar</string>
  <key>CFBundleName</key><string>WhisperBar</string>
  <key>CFBundleExecutable</key><string>WhisperBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Record speech to transcribe locally.</string>
</dict></plist>
EOF
codesign --force --sign - $APP
pkill -x WhisperBar || true
while pgrep -x WhisperBar >/dev/null; do sleep 0.1; done
sleep 0.5   # let LaunchServices notice it's gone
open WhisperBar.app