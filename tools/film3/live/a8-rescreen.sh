#!/bin/bash
# A8 re-screen of the equation windows of the method paper on one build: BIN=<app binary> D=<out dir> a8-rescreen.sh   then   cd $D && python3 -I <this dir>/a8-score.py A B C D E F G H P S2 S3
HERE=$(cd "$(dirname "$0")" && pwd); D=${D:-/tmp/film3/a8b}; export D; rm -f "$D/screen.rc"
for spec in "A 6 312 505 250 175" "B 7 312 345 250 160" "C 6 312 340 250 140" "D 6 50 95 250 140" "E 5 50 340 250 150" "F 4 312 358 250 190" "G 5 50 370 250 150" "H 3 312 405 250 180" \
            "P 3 50 420 250 175" "S2 2 312 438 250 175" "S3 2 312 395 250 175" "D3 6 50 62 250 143" "D4 6 50 80 250 135"; do
    "$HERE/a8-screen.sh" $spec
done
echo done >> "$D/screen.rc"
