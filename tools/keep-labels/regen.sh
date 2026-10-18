#!/bin/bash
# Regenerates every label file (papers and code cases) from the arXiv ids and the use-case sources: make-labels.sh, then make-code-labels.sh.
#   usage: regen.sh [out dir]          (default: labels/ beside this script)      env: KEEP_CACHE, KEEP_WORK, KEEP_BUILD as in make-labels.sh
# G1: run it twice with different KEEP_CACHE / KEEP_WORK (a fresh download, fresh pictures, fresh Vision reads) and compare the outputs.
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${1:-$HERE/labels}
set -e
"$HERE/make-labels.sh" "$OUT" > "$OUT.papers.log" 2>&1 || { cat "$OUT.papers.log"; exit 1; }
"$HERE/make-code-labels.sh" "$OUT/code.jsonl" > "$OUT.code.log" 2>&1 || { cat "$OUT.code.log"; exit 1; }
grep -E "^(blocks|  blocks|code)" "$OUT.papers.log" "$OUT.code.log" | cut -c1-300
ls -l "$OUT"
