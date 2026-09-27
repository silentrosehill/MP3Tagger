#!/bin/bash
# Builds MP3 Tagger.app next to this script.
set -euo pipefail
cd "$(dirname "$0")"

APP="MP3 Tagger.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"
cp CHANGELOG.md "$APP/Contents/Resources/"

swiftc -O -wmo -parse-as-library -swift-version 5 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/MP3Tagger"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>MP3 Tagger</string>
  <key>CFBundleDisplayName</key><string>MP3 Tagger</string>
  <key>CFBundleIdentifier</key><string>local.mp3tagger</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>MP3Tagger</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>3.8.2</string>
  <key>CFBundleVersion</key><string>43</string>
  <key>NSHumanReadableCopyright</key><string>Tagging, cover art, playback, loudness and downloads — built with Claude.</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppTransportSecurity</key>
  <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
</dict>
</plist>
EOF

codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"
