#!/bin/zsh
set -euo pipefail
CONKYMAC_ROOT=${0:A:h:h}
CONKYMAC_BUILD_DIR=${CONKYMAC_BUILD_DIR:-/private/tmp/conkymac-build}
export CONKYMAC_BUILD_DIR
zsh "$CONKYMAC_ROOT/scripts/swift.sh" build -c release
CONKYMAC_BIN=$(zsh "$CONKYMAC_ROOT/scripts/swift.sh" build -c release --show-bin-path)
CONKYMAC_APP="$CONKYMAC_BUILD_DIR/ConkyMac.app"
mkdir -p "$CONKYMAC_APP/Contents/MacOS" "$CONKYMAC_APP/Contents/Resources"
cp "$CONKYMAC_BIN/ConkyMac" "$CONKYMAC_APP/Contents/MacOS/ConkyMac"
cp "$CONKYMAC_ROOT/Resources/Info.plist" "$CONKYMAC_APP/Contents/Info.plist"
cp "$CONKYMAC_ROOT/THIRD_PARTY_NOTICES.md" "$CONKYMAC_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
codesign --force --sign - "$CONKYMAC_APP"
print -r -- "$CONKYMAC_APP"
