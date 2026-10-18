#!/bin/bash
# Draws the pictures of the code use cases (set/k*.html, use case `code` of set/index.tsv) at 2x, the way the other cases were drawn
# (snap, WKWebView). Needs the Bash sandbox off. The pictures are not kept in the repo.
#   usage: render-cases.sh [png dir]          (default /tmp/l0/png; bench.sh reads them from PNGS=<dir>)
#   env:   KEEP_BUILD=<dir>  swift scratch path (default /tmp/l0/build)
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-/tmp/l0/png}
BUILD=${KEEP_BUILD:-/tmp/l0/build}
SET=$HERE/../usecase-bench/set
mkdir -p "$OUT"
(cd "$HERE" && swift build -c release --scratch-path "$BUILD" --product snap > "$OUT/snap-build.log" 2>&1) || { echo "swift build failed: $OUT/snap-build.log"; exit 1; }
tail -n +2 "$SET/index.tsv" | while IFS=$'\t' read -r n uc l w h; do
    [ "$uc" = code ] || continue
    "$BUILD/release/snap" "$SET/$n.html" "$OUT/$n.png" "$w" "$h" > /dev/null || { echo "snap failed: $n"; exit 1; }
done
ls "$OUT"/k*.png
