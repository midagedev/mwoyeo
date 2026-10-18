#!/bin/bash
# Renders the pages of the paper bench: every page of the PDF at scale 2.67 (Safari at 2x with the page ~ 820 pt wide), and per page
# two lens-sized crops whose top and bottom edges run through the middle of a line (D3: a line cut by the lens edge), plus a
# side-cut crop of pages 4 and 5 (words cut at the left and right edge).
#   usage: pages.sh [out dir]                   (default /tmp/paper-quality/paper)
#   env:   PDF=<pdf>                            (default /Users/hckim/.cache/mwoyeo-gates/paper/1706.03762.pdf, arXiv 1706.03762)
#          TOOLS=<dir for the compiled helpers> (default /tmp/paper-quality)
# The pdf is not kept in the repo; the pages and crops are written once and kept (the manifest lists every crop rect).
OUT=${1:-/tmp/paper-quality/paper}
PDF=${PDF:-/Users/hckim/.cache/mwoyeo-gates/paper/1706.03762.pdf}
TOOLS=${TOOLS:-/tmp/paper-quality}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT" "$TOOLS"
[ -x "$TOOLS/pdfpages" ] || swiftc -O "$HERE/pdfpages.swift" -o "$TOOLS/pdfpages"
[ -x "$TOOLS/crops" ] || swiftc -O "$HERE/crops.swift" -o "$TOOLS/crops"
[ -s "$OUT/p15.png" ] || "$TOOLS/pdfpages" "$PDF" "$OUT" 2.67 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15
: > "$OUT/manifest.txt"
for p in $(seq 1 15); do
    "$TOOLS/crops" "$OUT/p$p.png" "$OUT" "p$p" >> "$OUT/manifest.txt"
done
for p in 4 5; do "$TOOLS/crops" "$OUT/p$p.png" "$OUT" "p$p" side >> "$OUT/manifest.txt"; done
cat "$OUT/manifest.txt"
