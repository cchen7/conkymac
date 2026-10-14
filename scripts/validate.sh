#!/bin/zsh
set -euo pipefail
CONKYMAC_ROOT=${0:A:h:h}
CONKYMAC_BUILD_DIR=${CONKYMAC_BUILD_DIR:-/private/tmp/conkymac-build}
CONKYMAC_RESULTS=${CONKYMAC_RESULTS:-/private/tmp/conkymac-validation}
export CONKYMAC_BUILD_DIR
mkdir -p "$CONKYMAC_RESULTS"
zsh "$CONKYMAC_ROOT/scripts/swift.sh" test -c release > "$CONKYMAC_RESULTS/tests.log" 2>&1
zsh "$CONKYMAC_ROOT/scripts/build-app.sh" > "$CONKYMAC_RESULTS/build.log" 2>&1
CONKYMAC_BIN=$(zsh "$CONKYMAC_ROOT/scripts/swift.sh" build -c release --show-bin-path)
CONKYMAC_EXEC="$CONKYMAC_BIN/ConkyMac"
"$CONKYMAC_EXEC" --render "$CONKYMAC_RESULTS/simple-1x.png" --scale 1
"$CONKYMAC_EXEC" --render "$CONKYMAC_RESULTS/simple-2x.png" --scale 2
"$CONKYMAC_EXEC" --probe 5 > "$CONKYMAC_RESULTS/probe.jsonl"
python3 "$CONKYMAC_ROOT/scripts/check-samples.py" "$CONKYMAC_RESULTS/probe.jsonl"
if [[ ${1:-} == --gui ]]; then
  "$CONKYMAC_BUILD_DIR/ConkyMac.app/Contents/MacOS/ConkyMac" --preview --smoke 15 > "$CONKYMAC_RESULTS/gui.log" 2>&1
  python3 "$CONKYMAC_ROOT/scripts/check-samples.py" "$CONKYMAC_RESULTS/gui.log"
fi
print -r -- "Validation artifacts: $CONKYMAC_RESULTS"
