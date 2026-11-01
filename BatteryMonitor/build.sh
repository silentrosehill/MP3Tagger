#!/bin/bash
# Builds Battery Monitor.app next to this script.
#   ./build.sh           build it
#   ./build.sh install   build it and copy it into /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="Battery Monitor.app"

# App icon: drawn by Icon/make_icon.swift the first time you build
if [ ! -f Icon/AppIcon.icns ]; then
  TMP=$(mktemp -d)
  swiftc -O Icon/make_icon.swift -o "$TMP/make_icon"
  "$TMP/make_icon" Icon/icon_1024.png >/dev/null
  ICONSET="$TMP/AppIcon.iconset"
  mkdir "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Icon/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d Icon/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o Icon/AppIcon.icns
  rm -rf "$TMP"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"

swiftc -O -wmo -parse-as-library -swift-version 5 \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/BatteryMonitor"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Battery Monitor</string>
  <key>CFBundleDisplayName</key><string>Battery Monitor</string>
  <key>CFBundleIdentifier</key><string>local.batterymonitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>BatteryMonitor</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSHumanReadableCopyright</key><string>Battery levels for your wireless devices — built with Claude.</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $(pwd)/$APP"

if [ "${1:-}" = "install" ]; then
  osascript -e 'quit app "Battery Monitor"' 2>/dev/null || true
  rm -rf "/Applications/$APP"
  cp -R "$APP" /Applications/
  echo "Installed /Applications/$APP"
  open "/Applications/$APP"
fi
