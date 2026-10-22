#!/bin/bash
cd /tmp/r117/first117
while kill -0 $(cat data/trwarm.pid) 2>/dev/null; do sleep 5; done
./cold-vr.sh ja ja /tmp/r117/first117/data/page-ja.png
./cold-vr.sh en en /tmp/r117/first117/data/page-en.png
echo done > data/series-vr.done
