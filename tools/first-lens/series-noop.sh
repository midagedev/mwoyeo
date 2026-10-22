#!/bin/bash
# launch only (no lens): the cost of a launch's warm-up. 3 with the programs-verified mark, 3 with it removed (a new build)
cd /tmp/r117/first117
for k in noop1 noop2 noop3; do rm -rf data/runs/$k; ./run-live.sh $k warm --key-after 20 --no-key --no-frames; done
for k in noopn1 noopn2 noopn3; do rm -rf data/runs/$k; ./run-live.sh $k warm --rm-mark --key-after 20 --no-key --no-frames; done
echo done > data/series-noop.done
