#!/bin/bash
# Labels of the code use cases (set/k*.html): draw the pictures (render-cases.sh), read each with Vision (ocrdump, both reads), label the
# blocks from the notes of the expected.txt files (code_labels.py). Needs the Bash sandbox off and the Neural Engine to itself.
#   usage: make-code-labels.sh [out file]        (default: labels/code.jsonl beside this script)
#   env:   KEEP_WORK=<dir> pictures and OCR (default /tmp/l0/keep-labels-work/code)   KEEP_BUILD=<dir> swift scratch path (default /tmp/l0/build)
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/labels/code.jsonl}
WORK=${KEEP_WORK:-/tmp/l0/keep-labels-work}/code
BUILD=${KEEP_BUILD:-/tmp/l0/build}
SET=$HERE/../usecase-bench/set
set -e
mkdir -p "$WORK" "$(dirname "$OUT")"
"$HERE/render-cases.sh" "$WORK" > /dev/null
(cd "$HERE" && swift build -c release --scratch-path "$BUILD" --product ocrdump > "$WORK/build.log" 2>&1)
tail -n +2 "$SET/index.tsv" | while IFS=$'\t' read -r n uc l w h; do
    [ "$uc" = code ] || continue
    [ -s "$WORK/$n.ocr.jsonl" ] || "$BUILD/release/ocrdump" "$WORK/$n.ocr.jsonl" "$l" "$WORK/$n.png" 2>> "$WORK/ocr.err"
done
python3 -B -I "$HERE/code_labels.py" "$WORK" "$OUT"
