#!/bin/bash
# E4/E3 helper: one `vision-reads` (ja) of the probe picture through the app's normal read path, with the log window around it.
#   usage: e4-run.sh <label> <pool|cold> <built Mwoyeo.app>      (Bash sandbox off; scratch settings; output in $OUT/<label>/)
# Prints the wall time and the lease/read lines; the compiles and e5rt lookups of the window come from
#   /usr/bin/log show --start "$(cat $OUT/<label>/start.txt)" --end "$(cat $OUT/<label>/end.txt)" --info --debug --style compact \
#       --predicate 'process BEGINSWITH "MwoyeoReader" OR process == "ANECompilerService"'
# (`Start of compilation of network` = a compile; `E5BundleCache Lookup: ... exists=1|0` = a cache hit|miss). 2026-10-20 (ane-dev, E4).
L=$1; K=$2; APP=$3; OUT=${OUT:-/tmp/ane-e4}; D=$OUT/$L; mkdir -p "$D"
HERE=$(cd "$(dirname "$0")/../.." && pwd)
export MWOYEO_MEMORY_SECRETS=1 MWOYEO_TRACE=1 MWOYEO_SETTINGS_FILE=$D/s.json MWOYEO_DEFAULTS_SUITE=e4.$L
echo '{}' > "$D/s.json"
date '+%Y-%m-%d %H:%M:%S' > "$D/start.txt"; s=$(date +%s)
"$HERE/ane-env.sh" run "$K" -- "$APP/Contents/MacOS/Mwoyeo" --capture-ui "$D/cap" vision-reads --src ja --for 600 > "$D/out.txt" 2> "$D/err.txt" < /dev/null
echo "rc=$? wall=$(( $(date +%s) - s )) s" > "$D/rc.txt"
date '+%Y-%m-%d %H:%M:%S' > "$D/end.txt"
cat "$D/rc.txt"; grep -E 'ane-lease|vision-reads: end' "$D/out.txt" "$D/err.txt" | cut -c1-260; grep -m1 -E 'read [0-9]+: [0-9]+ blocks' "$D/out.txt"
