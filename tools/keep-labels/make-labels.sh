#!/bin/bash
# Regenerates the label files of the papers in papers.tsv from their arXiv ids: fetch (fetch.sh), render the pages the way pages.sh
# does (scale 2.67), trace the glyphs of the PDF, read the pages with Vision (ocrdump: both reads of VisionExec), label (label.py).
# Neither PDFs nor page pictures are kept: they live in the cache and are fetched/drawn again. Headless Vision needs the Bash sandbox
# off, and the Neural Engine to itself: one run at a time (the first read of a new binary compiles its programs, minutes).
#   usage: make-labels.sh [out dir]           (default: labels/ beside this script)
#   env:   KEEP_CACHE=<dir>   downloads (default /tmp/l0/keep-labels-cache)      KEEP_BUILD=<dir>  swift scratch path (default /tmp/l0/build)
#          KEEP_WORK=<dir>    pages, glyphs and OCR (default /tmp/l0/keep-labels-work); a stage whose output exists is not run again
#          ONLY=<id>          one paper
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/labels}
CACHE=${KEEP_CACHE:-/tmp/l0/keep-labels-cache}
BUILD=${KEEP_BUILD:-/tmp/l0/build}
WORK=${KEEP_WORK:-/tmp/l0/keep-labels-work}
mkdir -p "$OUT" "$WORK" "$CACHE"
set -e
"$HERE/fetch.sh" "$CACHE"
(cd "$HERE" && swift build -c release --scratch-path "$BUILD" --product pdfglyphs --product ocrdump > "$WORK/build.log" 2>&1) || { echo "swift build failed: $WORK/build.log"; exit 1; }
[ -x "$WORK/pdfpages" ] || swiftc -O "$HERE/../paper-bench/pdfpages.swift" -o "$WORK/pdfpages"
while IFS=$'\t' read -r id ver set license pages pdf_sha src_sha; do
    [ "$id" = id ] && continue
    [ -n "$ONLY" ] && [ "$ONLY" != "$id" ] && continue
    w="$WORK/$id"; mkdir -p "$w/pages"
    first=${pages%-*}; last=${pages#*-}
    list=$(seq "$first" "$last" | tr '\n' ' ')
    [ -s "$w/pages/p$last.png" ] || "$WORK/pdfpages" "$CACHE/$id.pdf" "$w/pages" 2.67 $list
    "$BUILD/release/pdfglyphs" "$CACHE/$id.pdf" > "$w/glyphs.jsonl"
    python3 -B -I "$HERE/latex_math.py" "$CACHE/$id.src" --spans > "$w/latex.json"
    if [ ! -s "$w/ocr.jsonl" ]; then
        pngs=(); for p in $list; do pngs+=("$w/pages/p$p.png"); done
        "$BUILD/release/ocrdump" "$w/ocr.jsonl.part" en "${pngs[@]}" 2> "$w/ocr.err" && mv "$w/ocr.jsonl.part" "$w/ocr.jsonl"
    fi
    python3 -B -I "$HERE/label.py" "$id" "$w/glyphs.jsonl" "$w/ocr.jsonl" "$w/latex.json" "$OUT/$id.jsonl" --report
done < "$HERE/papers.tsv"
