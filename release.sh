#!/bin/bash
# Builds a universal (Apple silicon + Intel, macOS 14+) MP3 Tagger.app and zips it into dist/ for a GitHub release.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh >/dev/null            # app bundle, Info.plist, icon, changelog
APP="MP3 Tagger.app"
BIN="$APP/Contents/MacOS/MP3Tagger"
TMP=$(mktemp -d)
for arch in arm64 x86_64; do
  swiftc -O -wmo -parse-as-library -swift-version 5 -target "$arch-apple-macos14" Sources/*.swift -o "$TMP/$arch"
done
lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$BIN"
rm -rf "$TMP"
codesign --force --sign - "$APP" >/dev/null

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
mkdir -p dist
ZIP="dist/MP3-Tagger-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Built $ZIP"
