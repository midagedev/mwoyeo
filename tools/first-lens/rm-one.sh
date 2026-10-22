#!/bin/bash
# one headless read of a full-display picture: rm-one.sh <label> <png> <path: swift|vn|auto>
cd /tmp/r117/first117
L=$1; PNG=$2; P=$3
APP=/tmp/latin-runs/dd-first117/Build/Products/Release/Mwoyeo.app/Contents/MacOS/Mwoyeo
E=(MWOYEO_TRACE=1 MWOYEO_MEMORY_SECRETS=1 MWOYEO_FAKE_ENGINE=fail MWOYEO_SETTINGS_FILE=$PWD/data/rm/settings.json MWOYEO_DEFAULTS_SUITE=first117.rm)
[ "$P" != auto ] && E+=(MWOYEO_OCR_PATH=$P)
echo "load $(uptime | sed 's/.*averages: //' | cut -d' ' -f1)" > data/rm/$L.load
S=$(python3 -c "import time; print(time.clock_gettime_ns(time.CLOCK_UPTIME_RAW))")
env "${E[@]}" /Users/hckim/repo/mwoyeo/tools/ane-env.sh run pool -- $APP --render $PNG data/rm/$L.png --src en --tgt ko --no-inpaint --warm --max-wait 8 --no-drain > data/rm/$L.out 2> data/rm/$L.err < /dev/null
echo "wall_ms $(( ($(python3 -c "import time; print(time.clock_gettime_ns(time.CLOCK_UPTIME_RAW))") - S) / 1000000 ))" >> data/rm/$L.load
