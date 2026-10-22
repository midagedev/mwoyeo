#!/bin/bash
# usage: run-render.sh <build label> <png> <outprefix> <extra render args...>   (headless --render through the scratch-env wrapper)
HERE=$(cd "$(dirname "$0")" && pwd)
W=$1; PNG=$2; O=$3; shift 3
SD=${FAST117_DIR:-/tmp/fast117}; mkdir -p "$SD"
BIN=/tmp/latin-runs/dd-$W/Build/Products/Debug/Mwoyeo.app/Contents/MacOS/Mwoyeo
export MWOYEO_MEMORY_SECRETS=1 MWOYEO_SETTINGS_FILE=$SD/settings-$W.json MWOYEO_DEFAULTS_SUITE=fast117.$W MWOYEO_TRACE=1
echo "load=$(uptime | sed 's/.*averages: //' | cut -d' ' -f1) start=$(date +%s)" > $O.load
if [ -n "${STAMP:-}" ]; then   # STAMP=1: every stderr line gets the uptime in ms (the clock of Trace.now and the probe's start_uptime_ms), for timeline.py
  $HERE/app.sh $BIN --render $PNG $O.png "$@" 2>&1 >$O.out < /dev/null | python3 -u $HERE/stamp.py > $O.err
else
  $HERE/app.sh $BIN --render $PNG $O.png "$@" > $O.out 2> $O.err < /dev/null
fi
echo "rc=$? end=$(date +%s) load=$(uptime | sed 's/.*averages: //' | cut -d' ' -f1)" >> $O.load
