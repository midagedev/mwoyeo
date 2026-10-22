#!/bin/bash
# Builds the method paper (tools/paper-own/mwoyeo-method, unchanged) with one added subsection, threats.tex ("What the numbers do not show"), at the end of its
# Measurement section: written for film 3 (a lens over a paragraph of it in Preview), true to the paper's own numbers (each figure in it is one of the paper's).
# The paper's own files are never written: a scratch copy is built (its committed listings are used as they are, not recut).
#   usage: build.sh [out dir]      (default /tmp/film3/paper-build; writes main.pdf; needs `brew install tectonic`)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../../paper-own/mwoyeo-method" && pwd)
OUT=${1:-/tmp/film3/paper-build}
WORK=$(mktemp -d /tmp/film3-paper.XXXXXX)
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1792368936}
cp -R "$SRC/." "$WORK/"
cp "$HERE/threats.tex" "$WORK/sections/threats.tex"
printf '\n\\input{sections/threats}\n' >> "$WORK/sections/measure.tex"
mkdir -p "$OUT"
(cd "$WORK" && tectonic -X compile --outdir "$OUT" --keep-logs main.tex) > "$OUT/build.log" 2>&1 || { tail -20 "$OUT/build.log" >&2; exit 1; }
rm -rf "$WORK"
echo "build.sh: $OUT/main.pdf pages=$(pdfinfo "$OUT/main.pdf" | awk '/^Pages:/{print $2}')"
