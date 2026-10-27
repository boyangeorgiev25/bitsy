#!/bin/bash
# Builds a notarized, double-clickable dist/Bitsy.dmg.
#
# Needs, once:
#   1. A "Developer ID Application" certificate (Xcode › Settings › Accounts › Manage Certificates › +).
#   2. Notary credentials saved in your keychain:
#        xcrun notarytool store-credentials bitsy-notary --apple-id <you@example.com> --team-id <TEAMID>
#      (it asks for an app-specific password from account.apple.com)
#
# NOTARIZE=0 ./release.sh  signs with whatever certificate you have and skips notarization. People who
# download that build have to click Open Anyway (System Settings › Privacy & Security) the first time.
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
PROFILE=${NOTARY_PROFILE:-bitsy-notary}
if [ "${NOTARIZE:-1}" = 0 ]; then
    ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application|Apple Development/ {print $2; exit}')
else
    ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
    [ -n "$ID" ] || { echo "No Developer ID Application certificate found. See the top of this script."; exit 1; }
fi

./build.sh >/dev/null
APP=build/Bitsy.app

# Re-sign everything with the hardened runtime and a secure timestamp (both required by notarization).
TS=--timestamp; [ "${NOTARIZE:-1}" = 0 ] && TS=--timestamp=none
for exe in bitsy-mcp bitsy-fand bitsy-statusline; do
    codesign --force $TS --options runtime -s "$ID" -i "io.bitsy.pet.$exe" "$APP/Contents/MacOS/$exe"
done
codesign --force $TS --options runtime --entitlements Bitsy.entitlements -s "$ID" "$APP"
codesign --verify --strict --deep "$APP"

# Disk image: a styled window (dmg/) with Bitsy, an arrow and a shortcut to /Applications.
mkdir -p dist
DMG="dist/Bitsy.dmg"   # stable name, so releases/latest/download/Bitsy.dmg always works
VENV=.build/dmg-venv
[ -x "$VENV/bin/dmgbuild" ] || { python3 -m venv "$VENV" && "$VENV/bin/pip" install -q dmgbuild==1.6.5; }
if [ ! -f dmg/background.png ]; then (cd dmg && swift background.swift .); fi
tiffutil -cathidpicheck dmg/background.png dmg/background@2x.png -out .build/dmg-background.tiff >/dev/null 2>&1
rm -f "$DMG"
"$VENV/bin/dmgbuild" -s dmg/settings.py -D app="$APP" -D background=.build/dmg-background.tiff -D volicon=AppIcon.icns \
    "Bitsy" "$DMG" >/dev/null
codesign --force $TS -s "$ID" "$DMG"

if [ "${NOTARIZE:-1}" = 0 ]; then echo "Built $DMG (not notarized)"; exit 0; fi

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Ready: $DMG"
