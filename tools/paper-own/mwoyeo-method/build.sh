#!/bin/bash
# Builds the paper: the listings are cut from the repository's sources by line range (so a listing is the file, not a copy that can
# drift), then tectonic builds main.pdf. SOURCE_DATE_EPOCH is the date of the commit the paper was written at, so two builds give the
# same PDF bytes.
#   usage: build.sh [out dir]      (default: this directory; writes main.pdf; needs `brew install tectonic`)
#   env:   SOURCE_DATE_EPOCH       (default 1792368936 = 2026-10-19T09:15:36+09:00, the commit 499e312 the paper describes)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../.." && pwd)
OUT=${1:-$HERE}
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1792368936}
mkdir -p "$OUT" "$HERE/listings"

# listing <file in listings/> <repo path> <first line> <last line>: the lines, verbatim, ASCII only (listings under XeTeX).
listing() {
    local name=$1 path=$2 a=$3 b=$4
    sed -n "${a},${b}p" "$ROOT/$path" > "$HERE/listings/$name"
    if LC_ALL=C grep -q '[^[:print:][:space:]]' "$HERE/listings/$name"; then echo "build.sh: $name has non-ASCII text ($path:$a-$b)" >&2; exit 2; fi
    [ -s "$HERE/listings/$name" ] || { echo "build.sh: $name is empty ($path:$a-$b)" >&2; exit 2; }
}
listing ScrollPredictor_core.swift      Core/Sources/MwoyeoCore/ScrollPredictor.swift 31 68
listing CodeRegion_verdict.swift        Core/Sources/MwoyeoCore/CodeRegion.swift      251 267
listing Text_isFormula_decision.swift   Core/Sources/MwoyeoCore/Text.swift            559 566

cd "$HERE"
tectonic -X compile --outdir "$OUT" --keep-logs main.tex
echo "build.sh: $OUT/main.pdf $(shasum -a 256 "$OUT/main.pdf" | cut -d' ' -f1) pages=$(pdfinfo "$OUT/main.pdf" | awk '/^Pages:/{print $2}')"
