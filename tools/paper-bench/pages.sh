#!/bin/bash
# Renders the pages of the paper bench: every page of the PDF at scale 2.67 (Safari at 2x with the page ~ 820 pt wide), and per page
# two lens-sized crops whose top and bottom edges run through the middle of a line (D3: a line cut by the lens edge), plus a
# side-cut crop of the SIDE pages (words cut at the left and right edge).
#   usage: pages.sh [out dir]                   (default /tmp/paper-quality/pages-own; required when PDF is set, so pages of two
#                                                documents never share a directory)
#   env:   PDF=<pdf>                            (default: our own paper, tools/paper-own/mwoyeo-method/main.pdf, built by its build.sh when
#                                                it is not there; the number of pages is read from the PDF)
#          SIDE="<page> <page>"                 (default "7 12": the pages of our paper that are densest in inline mathematics,
#                                                found by tools/paper-own/mathdense.py)
#          TOOLS=<dir for the compiled helpers> (default /tmp/paper-quality)
# The results before 2026-10-19 were made on arXiv 1706.03762 (licence: arXiv non-exclusive, so nothing of it can be shown in public); the
# same pages come back with
#   PDF=/Users/hckim/.cache/mwoyeo-gates/paper/1706.03762.pdf SIDE="4 5" pages.sh <out dir>
# The pdf is not kept in the repo; the pages and crops are written once and kept (the manifest lists every crop rect).
if [ -n "$PDF" ] && [ -z "$1" ]; then echo "pages.sh: give an out dir when PDF is set" >&2; exit 2; fi
OUT=${1:-/tmp/paper-quality/pages-own}
HERE=$(cd "$(dirname "$0")" && pwd)
OWN=$HERE/../paper-own/mwoyeo-method
if [ -z "$PDF" ]; then
    PDF=$OWN/main.pdf
    [ -s "$PDF" ] || "$OWN/build.sh" >&2 || exit 1
fi
SIDE=${SIDE:-"7 12"}
TOOLS=${TOOLS:-/tmp/paper-quality}
mkdir -p "$OUT" "$TOOLS"
[ -x "$TOOLS/pdfpages" ] || swiftc -O "$HERE/pdfpages.swift" -o "$TOOLS/pdfpages"
[ -x "$TOOLS/pdfcount" ] || swiftc -O "$HERE/pdfcount.swift" -o "$TOOLS/pdfcount"
[ -x "$TOOLS/crops" ] || swiftc -O "$HERE/crops.swift" -o "$TOOLS/crops"
N=$("$TOOLS/pdfcount" "$PDF") || { echo "pages.sh: cannot read $PDF" >&2; exit 1; }
[ -s "$OUT/p$N.png" ] || "$TOOLS/pdfpages" "$PDF" "$OUT" 2.67 $(seq 1 "$N")
: > "$OUT/manifest.txt"
for p in $(seq 1 "$N"); do
    "$TOOLS/crops" "$OUT/p$p.png" "$OUT" "p$p" >> "$OUT/manifest.txt"
done
for p in $SIDE; do "$TOOLS/crops" "$OUT/p$p.png" "$OUT" "p$p" side >> "$OUT/manifest.txt"; done
cat "$OUT/manifest.txt"
