#!/bin/zsh
# Regenerates Resources/AppIcon.icns from Resources/AppIcon.svg (AppKit + iconutil, no extra tools).
set -euo pipefail
CONKYMAC_ROOT=${0:A:h:h}
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
swiftc -O "$CONKYMAC_ROOT/scripts/render-svg.swift" -o "$WORK/render-svg"
ICONSET="$WORK/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
  "$WORK/render-svg" "$CONKYMAC_ROOT/Resources/AppIcon.svg" "$ICONSET/icon_${size}x${size}.png" $size
  "$WORK/render-svg" "$CONKYMAC_ROOT/Resources/AppIcon.svg" "$ICONSET/icon_${size}x${size}@2x.png" $((size * 2))
done
iconutil --convert icns --output "$CONKYMAC_ROOT/Resources/AppIcon.icns" "$ICONSET"
print -r -- "$CONKYMAC_ROOT/Resources/AppIcon.icns"
