#!/bin/sh
# The blind judge pairs of the product-layout round (runs/RESULTS-2026-10-19-t3-product-layout.md), regenerated from the preserved
# runs: one `judge.py prompts` directory per pair under <out dir>, in the order the decision rule needs them. A pair whose runs are not
# preserved is skipped. The judge pass itself is the lead's (one call per prompt file, both orders; `judge.py tally` counts).
#
#   judge-pairs.sh <out dir>
#
# Order: first the pairs that decide a default (against A, then the memory over B2, then neighbours over the transcript), then the layout
# check (the product layout against the bench's reference layout for the same condition).
set -eu
[ $# -eq 1 ] || { echo "usage: judge-pairs.sh <out dir>" >&2; exit 2; }
cd "$(dirname "$0")"
OUT="$1"
pair() {   # name, run a, run b
  if [ -d "runs/$2" ] && [ -d "runs/$3" ]; then
    printf '%-26s ' "$1"
    python3 -I judge.py prompts --a "runs/$2" --b "runs/$3" --out "$OUT/$1" | head -1
  else
    echo "$1: skipped, runs/$2 or runs/$3 is not preserved"
  fi
}
for m in gemma3-4b gemma4-e4b gemma4-26b haiku-5-5; do
  pair "$m-A-vs-M-t2" "A-$m" "M-$m-t2"
  pair "$m-A-vs-B2-t2" "A-$m" "B2-$m-t2"
  pair "$m-B2-t2-vs-M-t2" "B2-$m-t2" "M-$m-t2"
  pair "$m-A-vs-B2+2-t2" "A-$m" "B2+2-$m-t2"
  pair "$m-B2-t2-vs-B2+2-t2" "B2-$m-t2" "B2+2-$m-t2"
  pair "$m-M-ref-vs-M-t2" "M-$m" "M-$m-t2"
  pair "$m-B2-ref-vs-B2-t2" "B2-$m" "B2-$m-t2"
done
