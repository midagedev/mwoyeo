#!/bin/bash
# merge gates under the shared screen lock, one at a time. usage: BIN=<Mwoyeo> run.sh <tag> <check>...
BIN=${BIN:?BIN=<Mwoyeo binary>}
R=/Users/hckim/repo/mwoyeo; G=/tmp/film5/gates; T=$1; shift
for c in "$@"; do
  O=$G/$T-$c; rm -rf $O; mkdir -p $O
  MWOYEO_TRACE=1 MWOYEO_HOLD_TIMELINE=$O/timeline MWOYEO_MEMORY_SECRETS=1 MWOYEO_SETTINGS_FILE=$O/s.json MWOYEO_DEFAULTS_SUITE=film5gate.$c \
    lockf /tmp/r117/screen.lock "$R/tools/ane-env.sh" run pool -- "$BIN" --capture-ui $O $c --lang en > $O/run.log 2>&1 < /dev/null
  echo "$T $c rc=$? pass=$(grep -c ': PASS' $O/run.log) fail=$(grep -c ': FAIL' $O/run.log)" >> $G/summary.txt
done
echo done > $G/$T.rc
