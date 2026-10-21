#!/bin/bash
# fit117: every measurement of the design, in one go (no app needed; the data are the benches' outputs copied to ../data). Writes ../data/*.txt.
cd "$(dirname "$0")" || exit 1
for p in eval1 eval1b eval3 eval4 eval5 eval6 eval7; do python3 -I $p.py > ../data/$p.txt 2>&1; echo "$p rc=$?"; done
python3 -I sim1.py > ../data/sim1.txt 2>&1; echo "sim1 rc=$?"
python3 -I eval2.py > ../data/eval2.txt 2>&1; echo "eval2 rc=$?"
