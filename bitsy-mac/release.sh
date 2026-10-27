#!/bin/bash
# Builds a notarized, double-clickable dist/Bitsy-<version>.dmg.
#
# Needs, once:
#   1. A "Developer ID Application" certificate (Xcode › Settings › Accounts › Manage Certificates › +).
#   2. Notary credentials saved in your keychain:
#        xcrun notarytool store-credentials bitsy-notary --apple-id <you@example.com> --team-id <TEAMID>
#      (it asks for an app-specific password from account.apple.com)
#
# DRY_RUN=1 ./release.sh  signs with whatever certificate you have and skips notarization (for testing).
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
PROFILE=${NOTARY_PROFILE:-bitsy-notary}
if [ "${DRY_RUN:-}" = 1 ]; then
    ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application|Apple Development/ {print $2; exit}')
else
    ID=$(security find-identity -v -p codesigning | awk '/Developer ID Application/ {print $2; exit}')
    [ -n "$ID" ] || { echo "No Developer ID Application certificate found. See the top of this script."; exit 1; }
fi

./build.sh >/dev/null
APP=build/Bitsy.app

# Re-sign everything with the hardened runtime and a secure timestamp (both required by notarization).
TS=--timestamp; [ "${DRY_RUN:-}" = 1 ] && TS=--timestamp=none
for exe in bitsy-mcp bitsy-fand bitsy-statusline; do
    codesign --force $TS --options runtime -s "$ID" -i "io.bitsy.pet.$exe" "$APP/Contents/MacOS/$exe"
done
codesign --force $TS --options runtime --entitlements Bitsy.entitlements -s "$ID" "$APP"
codesign --verify --strict --deep "$APP"

# Disk image with a shortcut to /Applications to drag onto.
mkdir -p dist
DMG="dist/Bitsy-$VERSION.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Bitsy $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --force $TS -s "$ID" "$DMG"

if [ "${DRY_RUN:-}" = 1 ]; then echo "Dry run: built $DMG (not notarized)"; exit 0; fi

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature -v "$DMG"
echo "Ready: $DMG"
