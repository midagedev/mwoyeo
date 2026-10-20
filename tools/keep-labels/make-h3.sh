#!/bin/bash
# H3 labels: draw the screens (h3.py -> snap), read each with Vision (ocrdump, both reads, through ane-env.sh), label the words from the units the generator wrote
# (h2_labels.py --set h3). The same flow as make-h2.sh, with H3's scenes and manifest. Needs the Bash sandbox off. Vision reads go through `tools/ane-env.sh run pool`
# one at a time.
#   usage: make-h3.sh [out file]          (default: labels-h3/h3.jsonl beside this script)
#   env:   KEEP_WORK=<dir> html, units, pictures and OCR land in $KEEP_WORK/h3 (default /tmp/h3/keep-labels-work)   KEEP_BUILD=<dir> swift scratch path
#          (default /tmp/h3/build)   H3_REREAD=1 reads every picture again (default: a picture that has its .ocr.jsonl is not read again)
# The second leg of the determinism check: run it again with another KEEP_WORK (fresh html, pictures, Vision reads) and compare with test_h3.sh <A/h3> <B/h3>.
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/labels-h3/h3.jsonl}
WORK=${KEEP_WORK:-/tmp/h3/keep-labels-work}/h3
BUILD=${KEEP_BUILD:-/tmp/h3/build}
ANE=$HERE/../ane-env.sh
set -e
mkdir -p "$WORK" "$(dirname "$OUT")"
for p in snap ocrdump; do
    (cd "$HERE" && swift build -c release --scratch-path "$BUILD" --product $p > "$WORK/build-$p.log" 2>&1) || { echo "swift build failed: $WORK/build-$p.log"; exit 1; }
done
python3 -B -I "$HERE/h3.py" "$WORK"
# the sources are frozen: the manifest the generator just wrote must be the one in the repo
cmp "$WORK/MANIFEST.tsv" "$HERE/h3/MANIFEST.tsv" || { echo "h3: MANIFEST.tsv differs from the frozen one (h3/MANIFEST.tsv)"; exit 1; }
tail -n +2 "$WORK/index.tsv" | while IFS=$'\t' read -r n look l w h; do
    [ -s "$WORK/$n.png" ] || "$BUILD/release/snap" "$WORK/$n.html" "$WORK/$n.png" "$w" "$h" > /dev/null || { echo "snap failed: $n"; exit 1; }
    if [ -n "$H3_REREAD" ] || [ ! -s "$WORK/$n.ocr.jsonl" ]; then
        # a cold network compile that a neighbour's compile disturbs ends in e5rtError 13 (seen 2026-10-20 in H2): one more try, never a loop
        for try in 1 2; do
            "$ANE" run pool -- "$BUILD/release/ocrdump" "$WORK/$n.ocr.jsonl" "$l" "$WORK/$n.png" 2>> "$WORK/ocr.err" < /dev/null && break
            [ $try = 2 ] && { echo "ocrdump failed twice: $n (see $WORK/ocr.err)"; exit 1; }
        done
    fi
done
python3 -B -I "$HERE/h2_labels.py" "$WORK" "$OUT" --set h3
