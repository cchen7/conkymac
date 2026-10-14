#!/bin/zsh
# Developer ID signed, notarized and stapled DMG (Apple Silicon only).
#   CONKYMAC_SIGN_IDENTITY   "Developer ID Application: …" (default: the only one in the keychain);
#                            "-" rehearses with an ad-hoc signature and skips notarization
#   CONKYMAC_NOTARY_PROFILE  notarytool keychain profile (default: conkymac-notary)
#   CONKYMAC_DIST_DIR        output directory (default: ~/Local/my-proj-temp/conkymac/dist)
set -euo pipefail
CONKYMAC_ROOT=${0:A:h:h}
export CONKYMAC_BUILD_DIR=${CONKYMAC_BUILD_DIR:-/private/tmp/conkymac-build}
DIST=${CONKYMAC_DIST_DIR:-$HOME/Local/my-proj-temp/conkymac/dist}
PROFILE=${CONKYMAC_NOTARY_PROFILE:-conkymac-notary}
IDENTITY=${CONKYMAC_SIGN_IDENTITY:-}
if [[ -z $IDENTITY ]]; then
  identities=(${(f)"$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p')"})
  if (( ${#identities} != 1 )); then
    print -u2 "Found ${#identities} Developer ID Application identities; set CONKYMAC_SIGN_IDENTITY."
    print -u2 "Install one via Xcode > Settings > Accounts > Manage Certificates > + Developer ID Application."
    exit 1
  fi
  IDENTITY=$identities[1]
fi
REHEARSAL=$([[ $IDENTITY == "-" ]] && print 1 || print 0)
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$CONKYMAC_ROOT/Resources/Info.plist")
STAGE="$CONKYMAC_BUILD_DIR/dmg-stage"
APP="$STAGE/ConkyMac.app"
DMG="$DIST/ConkyMac-$VERSION.dmg"

notarize() {
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait --timeout 30m
}

zsh "$CONKYMAC_ROOT/scripts/build-app.sh" > /dev/null
rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
ditto "$CONKYMAC_BUILD_DIR/ConkyMac.app" "$APP"
[[ $(lipo -archs "$APP/Contents/MacOS/ConkyMac") == arm64 ]] || { print -u2 "Expected an arm64-only binary"; exit 1; }
# The scratch build may carry a 077 umask; installed apps must be readable by every user.
chmod -R u=rwX,go=rX "$APP"

# Hardened runtime, no entitlements: SMC/IOReport reads, /bin/ps and Lua need none.
if (( REHEARSAL )); then
  codesign --force --options runtime --timestamp=none --sign - "$APP"
else
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

if (( ! REHEARSAL )); then
  # Notarize and staple the app itself too, so a copy in /Applications passes Gatekeeper offline.
  # A rerun with unchanged code already has a ticket for this cdhash: staple it and skip the queue.
  if ! xcrun stapler staple "$APP" > /dev/null 2>&1; then
    ditto -c -k --keepParent "$APP" "$STAGE.zip"
    notarize "$STAGE.zip"
    rm -f "$STAGE.zip"
    xcrun stapler staple "$APP"
  fi
fi

ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
diskutil image create from --format UDZO --volumeName "ConkyMac $VERSION" "$STAGE" "$DMG" > /dev/null

if (( REHEARSAL )); then
  print -r -- "REHEARSAL_OK (ad-hoc, not notarized) $DMG"
else
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
  print -r -- "PACKAGE_OK $DMG"
fi
shasum -a 256 "$DMG"
