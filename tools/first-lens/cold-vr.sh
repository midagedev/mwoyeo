#!/bin/bash
# what a lens sees during a cold compile, per language (the app's own probe `vision-reads`: it starts the initialization and reads the picture every half second until every step is done; no window)
# usage: cold-vr.sh <label> <src> <image>
cd /tmp/r117/first117
L=$1; SRC=$2; IMG=$3; ID=$(cat data/cold-id.txt); OUT=data/vr/$L; mkdir -p $OUT
for s in "" .reader.lines .reader.docs; do rm -rf ~/Library/Caches/$ID$s; done
APP=/tmp/latin-runs/dd-first117/Build/Products/Release/Mwoyeo.app/Contents/MacOS/Mwoyeo
echo "load $(uptime | sed 's/.*averages: //')" > $OUT/load.txt
MWOYEO_MEMORY_SECRETS=1 MWOYEO_SETTINGS_FILE=$PWD/$OUT/settings.json MWOYEO_DEFAULTS_SUITE=first117.vr$L \
  /Users/hckim/repo/mwoyeo/tools/ane-env.sh run cold -- $APP --capture-ui $PWD/$OUT vision-reads --src $SRC --image $IMG --for 400 > $OUT/out.txt 2> $OUT/err.txt < /dev/null
echo "rc=$?" > $OUT/rc
echo "load $(uptime | sed 's/.*averages: //')" >> $OUT/load.txt
