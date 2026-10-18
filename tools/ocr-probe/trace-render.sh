#!/bin/bash
# A render with the trace on must finish. FAILURE MODE IT BLOCKS: a value in a trace line that traps (`Int(_:)` of an infinite Double),
# which only a run with MWOYEO_TRACE=1 can see: the vn render of p6 ended rc=133 after all its reads (r1-reader-service found it,
# r3-docs-xpc fixed it with `TraceNumber.px`; the pure rule has Core tests).
#   usage: trace-render.sh <Mwoyeo binary> [page ...]        (default p6)
#   env:   PAGES  the paper pages p<N>.png   (default /tmp/paper-quality/paper)      OUT  where the outputs go (default /tmp/trace-render)
#          OCR    MWOYEO_OCR_PATH of the run (default vn: the grouper reads, no Docs service involved)
# Prints `PASS <page> rc=0` or `FAIL <page> rc=<n>`; exit 0 when every page passed. Needs the Bash sandbox off (headless --render).
BIN=${1:?usage: trace-render.sh <Mwoyeo binary> [page ...]}; shift
PAGES=${PAGES:-/tmp/paper-quality/paper}; OUT=${OUT:-/tmp/trace-render}; OCR=${OCR:-vn}
mkdir -p "$OUT"; fail=0
for page in ${*:-p6}; do
    MWOYEO_TRACE=1 MWOYEO_MEMORY_SECRETS=1 MWOYEO_DEFAULTS_SUITE=tracerender.test MWOYEO_SETTINGS_FILE="$OUT/s.json" MWOYEO_OCR_PATH=$OCR \
        "$BIN" --render "$PAGES/$page.png" "$OUT/$page.png" --src en --tgt ko --scale 2 --warm --max-wait 120 > "$OUT/$page.out" 2> "$OUT/$page.err" < /dev/null
    rc=$?
    if [ $rc = 0 ] && grep -q '^silence:' "$OUT/$page.out"; then echo "PASS $page rc=0"; else echo "FAIL $page rc=$rc $(grep -m1 'cannot be converted' "$OUT/$page.err")"; fail=1; fi
done
exit $fail
