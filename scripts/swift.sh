#!/bin/zsh
set -euo pipefail
CONKYMAC_ROOT=${0:A:h:h}
CONKYMAC_BUILD_DIR=${CONKYMAC_BUILD_DIR:-/private/tmp/conkymac-build}
mkdir -p "$CONKYMAC_BUILD_DIR/module-cache" "$CONKYMAC_BUILD_DIR/cache" "$CONKYMAC_BUILD_DIR/config" "$CONKYMAC_BUILD_DIR/security"
export CLANG_MODULE_CACHE_PATH="$CONKYMAC_BUILD_DIR/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CONKYMAC_BUILD_DIR/module-cache"
CONKYMAC_ACTION=${1:-build}
if (( $# > 0 )); then shift; fi
exec swift "$CONKYMAC_ACTION" --package-path "$CONKYMAC_ROOT" \
  --scratch-path "$CONKYMAC_BUILD_DIR/build" --cache-path "$CONKYMAC_BUILD_DIR/cache" \
  --config-path "$CONKYMAC_BUILD_DIR/config" --security-path "$CONKYMAC_BUILD_DIR/security" \
  --disable-sandbox -j 16 "$@"
