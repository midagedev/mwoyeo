#!/usr/bin/env bash
# Listen (listen.py: agy gemini-3.8-flash-high, both field orders per clip) to the top N rows of fit.json, which fit.py ranked.
# Needs listen/calibration.json (python3 -I tools/film2/musicgen/listen.py --calibrate CALDIR first). One clip at a time:
# agy shares one ~/.gemini config. Usage: bash tools/film2/music/listen_top.sh RAWDIR [N=6]
set -euo pipefail
RAW=${1:?raw dir}; N=${2:-6}; HERE=$(cd "$(dirname "$0")" && pwd)
while read -r c; do
  python3 -I "$HERE/../musicgen/listen.py" "$RAW/$c.mp3"
done < <(python3 -I -c "import json,sys; [print(r['clip']) for r in json.load(open(sys.argv[1]))[:int(sys.argv[2])]]" "$HERE/fit.json" "$N")
