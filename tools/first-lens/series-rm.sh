#!/bin/bash
cd /tmp/r117/first117
S=data/screens
for rep in 1 2 3; do
  for sc in paper preview chat web; do
    for p in swift vn; do ./rm-one.sh $sc-$p-$rep $S/$sc.png $p; done
  done
  for c in web-560x320 web-800x600; do ./rm-one.sh $c-swift-$rep $S/$c.png swift; done
done
echo done > data/series-rm.done
