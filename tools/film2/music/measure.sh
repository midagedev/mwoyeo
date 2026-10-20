#!/usr/bin/env bash
# Screen and measure every clip of a run: flac -> mp3 (192 kbit/s, what the film and the listening read), screen.py,
# then beats.py per prompt with the prompt's asked BPM as the prior and 0.8x..1.25x of it as the range (the range
# screen.py reads), BEATS_DROP_WIN=8. Usage: bash tools/film2/music/measure.sh RAWDIR [PROMPTS.json]
# beats.py runs with stdin from /dev/null: its ffmpeg reads stdin, and in film 2's first run it swallowed the loop's remaining
# prompt line (koto) and the script ended rc 0 with 16 of 24 rows. The last step names every clip without a beats row, exit 1.
# Writes RAWDIR/screen.tsv and (BEATS_OUT, default tools/film2/music/beats.json) the beat rows.
set -euo pipefail
RAW=${1:?raw dir}; HERE=$(cd "$(dirname "$0")" && pwd); PROMPTS=${2:-$HERE/../musicgen/prompts.json}
for f in "$RAW"/*.flac; do
  m=${f%.flac}.mp3
  [ -s "$m" ] && [ "$m" -nt "$f" ] || ffmpeg -v error -y -i "$f" -b:a 192k "$m"
done
python3 -I "$HERE/../musicgen/screen.py" "$RAW" > "$RAW/screen.txt"
while IFS=' ' read -r id bpm; do
  files=("$RAW/$id"-s*.mp3)
  [ -e "${files[0]}" ] || continue
  BEATS_PRIOR=$bpm BEATS_RANGE=$(python3 -c "print(f'{int($bpm * .8)}-{int($bpm * 1.25)}')") BEATS_DROP_WIN=8 \
    python3 -I "$HERE/beats.py" "${files[@]}" < /dev/null
done < <(python3 -I -c "import json,sys; [print(p['id'], p['bpm']) for p in json.load(open(sys.argv[1]))]" "$PROMPTS")
BEATS_JSON=${BEATS_OUT:-$HERE/beats.json}
python3 -I - "$RAW" "$BEATS_JSON" <<'PY'
import json, sys
from pathlib import Path
have = set(json.loads(Path(sys.argv[2]).read_text()))
missing = sorted(p.stem for p in Path(sys.argv[1]).glob("*.mp3") if p.stem not in have)
if missing:
    sys.exit(f"measure.sh: no beats row for {len(missing)} clip(s): {', '.join(missing)}")
print(f"measure.sh: every one of {len(have)} beats rows has its clip")
PY
