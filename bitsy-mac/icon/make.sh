#!/bin/bash
# Renders AppIcon.icns from the pet's own pixel rig (Sources/Bitsy/Rig.swift), so the icon can never
# drift from how Bitsy actually looks. Pose: laptop (default, "coding with Claude"), wave, plain.
# Style: white (default, flat), dark (the popup's charcoal) or cream (clay on parchment).
#   icon/make.sh [laptop|wave|plain] [white|dark|cream]
set -euo pipefail
cd "$(dirname "$0")"
VARIANT=${1:-laptop}
STYLE=${2:-white}
T=$(mktemp -d)
swiftc -O -o "$T/render" main.swift ../Sources/Bitsy/Rig.swift
"$T/render" "$T/icon.png" "$VARIANT" "$STYLE"
mkdir -p "$T/AppIcon.iconset"
for n in 16 32 128 256 512; do
  sips -z $n $n "$T/icon.png" --out "$T/AppIcon.iconset/icon_${n}x${n}.png" >/dev/null
  sips -z $((n*2)) $((n*2)) "$T/icon.png" --out "$T/AppIcon.iconset/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$T/AppIcon.iconset" -o ../AppIcon.icns
cp "$T/icon.png" ../AppIcon.png
rm -rf "$T"
echo "Wrote AppIcon.icns ($VARIANT, $STYLE)"
