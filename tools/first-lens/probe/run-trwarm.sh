#!/bin/bash
# interleaved: 5 rounds x (none, ja-first, en-first) x (hf, ll); one fresh process each. warm_ms batch_ms, with the 1-min load beside it
cd /tmp/r117/first117/probe
for r in 1 2 3 4 5; do
  for st in hf ll; do
    for m in none ja-first en-first; do
      L=$(uptime | sed 's/.*averages: //' | cut -d' ' -f1)
      echo "$r $st $m load=$L $(./trwarm $m $st)"
    done
  done
done
