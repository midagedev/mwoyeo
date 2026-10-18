#!/bin/bash
# The whole M0 measurement: build, read the pages once with Vision (cached as JSON), measure the crops of the paper pages under
# the base metrics and the two FAIL-first mutants, cross-check the metrics with an independent implementation, and score the
# verbatim locate rate of the bench outputs. Vision needs the Bash sandbox off; the first `read` of a new binary compiles the
# Neural Engine networks (VN ~230 s, then the document model ~240 s; later runs 1-3 s a page). Never kill it while it compiles.
#   usage: run.sh <out dir> [bench dir with p3.out…, for the locate rate]
#   env:   PAGES=<dir of tools/paper-bench/pages.sh output> (default /tmp/paper-quality/paper)
OUT=${1:?usage: run.sh <out dir> [bench dir]}; BENCH=${2:-}
PAGES=${PAGES:-/tmp/paper-quality/paper}
HERE=$(cd "$(dirname "$0")" && pwd)
ALL=p1,p2,p3,p4,p5,p6,p7,p8,p9,p10,p11,p12,p13,p14,p15
mkdir -p "$OUT"
swift build -c release --package-path "$HERE" --scratch-path "$OUT/build" > "$OUT/build.log" 2>&1 || { echo "build failed: $OUT/build.log"; exit 1; }
BIN=$OUT/build/release
if [ ! -s "$OUT/ocr/docs-p15.json" ]; then
    "$BIN/read" "$OUT/ocr" $(for p in ${ALL//,/ }; do echo "$PAGES/$p.png"; done) > "$OUT/read.log" 2>&1 || { echo "read failed: $OUT/read.log"; exit 1; }
fi
m() { tag=$1; shift; "$BIN/probe" measure --ocr "$OUT/ocr" --pages "$PAGES" --out "$OUT/$tag" "$@" > "$OUT/measure-$tag.txt" 2>&1; echo "$tag rc=$?"; }
m base-p3-6 --sens                                   # the spec's pages
m shrink-p3-6 --mutate shrink                        # G2: −30 % height must drop the clean %
m grow-p3-6 --mutate grow                            # G2: the box grown into the next line must raise (c)
m base-p1-15 --sens --names $ALL                     # the larger sample
python3 -I "$HERE/crosscheck.py" "$OUT/base-p1-15/spans-base.tsv" "$PAGES" "$OUT/ocr" | tail -3
grep -h "ALL" "$OUT"/measure-*.txt
if [ -n "$BENCH" ]; then "$BIN/probe" locate "$BENCH"; fi
