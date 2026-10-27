#!/bin/bash
# Builds build/Bitsy.app: release, universal (Apple Silicon + Intel), signed.
set -euo pipefail
cd "$(dirname "$0")"
# Universal binary: runs on Apple Silicon and Intel Macs.
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)
APP=build/Bitsy.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN"/Bitsy "$APP/Contents/MacOS/Bitsy"
cp "$BIN"/bitsy-mcp "$APP/Contents/MacOS/bitsy-mcp"
cp "$BIN"/bitsy-fand "$APP/Contents/MacOS/bitsy-fand"
cp "$BIN"/bitsy-statusline "$APP/Contents/MacOS/bitsy-statusline"
cp Info.plist "$APP/Contents/Info.plist"
[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Sign with your Apple Development certificate when there is one: a stable identity means macOS keeps
# Screen Recording / Accessibility permissions across rebuilds. Falls back to ad-hoc signing.
ID=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
for exe in bitsy-mcp bitsy-fand bitsy-statusline; do codesign --force --timestamp=none -s "${ID:--}" -i "io.bitsy.pet.$exe" "$APP/Contents/MacOS/$exe"; done
codesign --force --timestamp=none -s "${ID:--}" "$APP"
echo "Built $APP"
