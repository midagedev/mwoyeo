#!/bin/bash
cd /tmp/r117/first117
for k in cold2 cold3; do
  rm -rf data/runs/$k
  ./run-live.sh $k cold --key-after 20 --wait 420 --second
done
echo done > data/series-cold.done
