#!/bin/bash
# smoke test of the helpers without the app: a page window, the watcher on it, one mouse move
cd /tmp/r117/first117
./tools/pagewin data/page-b.png 40 70 1184 640 > data/pf-pw.txt &
PW=$!; sleep 1.5
./tools/watch $PW 100 120 560 320 > data/pf-watch.txt &
WT=$!; sleep 1.2
kill -USR1 $WT; sleep 0.6
echo "move 600 400" | ./tools/post > data/pf-post.txt
sleep 0.6
kill $WT $PW
