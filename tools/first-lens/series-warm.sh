#!/bin/bash
cd /tmp/r117/first117
for k in warm1 warm2 warm3; do rm -rf data/runs/$k; ./run-live.sh $k warm --key-after 12 --wait 120 --picker-loop 5 --no-frames --second; done
for k in new1 new2 new3; do rm -rf data/runs/$k; ./run-live.sh $k warm --rm-mark --key-after 6 --wait 120 --no-frames --second; done
echo done > data/series-warm.done
