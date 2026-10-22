#!/bin/bash
# usage: record.sh <Mwoyeo binary> <out dir> [seconds=150]
# `resize-hold-checks` (App/Support/ResizeHoldChecks.swift) under a screen recording, for luma.py. Take the shared screen lock first (the lens windows
# and the page go on the screen; `screencapture -V` cannot be stopped early, so the lock is held for the whole of <seconds>):
#   lockf -t 0 /tmp/r117/screen.lock tools/lens-hold/record.sh <binary> <out dir>
# Scratch settings and defaults suite, MWOYEO_MEMORY_SECRETS=1 (no keys are read). Writes <out dir>/run.mov, run.log, run.timeline and run.timeline.page.png.
BIN=$1; OUT=$2; SECS=${3:-150}
mkdir -p "$OUT"; rm -f "$OUT/run.mov"
screencapture -V "$SECS" "$OUT/run.mov" > "$OUT/rec.log" 2>&1 &
REC=$!
sleep 3
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
MWOYEO_TRACE=1 MWOYEO_MEMORY_SECRETS=1 MWOYEO_SETTINGS_FILE="$OUT/s.json" MWOYEO_DEFAULTS_SUITE=lens-hold.$$ MWOYEO_HOLD_TIMELINE="$OUT/run.timeline" \
  "$ROOT/tools/ane-env.sh" run pool -- "$BIN" --capture-ui "$OUT" resize-hold-checks --lang en > "$OUT/run.log" 2>&1 < /dev/null
rc=$?
wait $REC
echo "check rc=$rc; python3 tools/lens-hold/luma.py $OUT/run.mov $OUT/run.timeline.page.png $OUT/run.luma.txt"
exit $rc
