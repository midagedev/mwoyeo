#!/bin/bash
# shapes117: builds the probe (build.sh) and measures every scene of data/shapes/scenes.txt in the five modes the design doc compares:
# the seam (the picker's chain), the bare `column ?? shape` chain, the column owner alone, LensShape alone, and LensShape alone without its
# hold (the mutant: every number must differ from the real one by the hold). Output: data/shapes/{seam,plain,column,alone,alone-nohold}.txt
# and data/shapes/sweep.txt (the stage's planned pointer path). COLUMN as in build.sh.
#   usage: COLUMN=<dir with LensTarget.swift and LensTarget+Shapes.swift> measure.sh [scratch dir for the binary]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
DATA=$HERE/../data/shapes
BIN=${1:-/tmp/shapes117-probe}/shapes
mkdir -p "$(dirname "$BIN")"
"$HERE/build.sh" "$BIN" || exit 1
S=$DATA/scenes.txt
"$BIN" measure "$S" --why > "$DATA/seam.txt"
"$BIN" measure "$S" --plain > "$DATA/plain.txt"
"$BIN" measure "$S" --column > "$DATA/column.txt"
"$BIN" measure "$S" --alone --why > "$DATA/alone.txt"
"$BIN" measure "$S" --alone --mutant nohold > "$DATA/alone-nohold.txt"
"$BIN" sweep "$S" stage "$HERE/../stage/path.json" > "$DATA/sweep.txt"
for f in seam plain column alone alone-nohold; do echo "$f: $(grep '^ALL' "$DATA/$f.txt")"; done
