#!/bin/bash
# Renders every line of film-ja-ko-1 on the stage (scene.html?line=<id>) to ../plates/out/stage/L<id>.png: 960x960 CSS px at device
# scale 2.25 = 2160x2160 px (the flags of tools/film/plates/make-vn960.sh in the film worktree). Headless Chrome, own scratch profile.
#   usage: shoot.sh [id ...]      all 36 lines without arguments;  PLATE=tag shoots the variant whose plate text is gold (kept as written by
#                                 the app, a name tag) to out/stage-tag instead
# It first checks that the LINES copy inside scene.html is the sequence's (id, speaker, text), and then writes out/stage/lines.txt:
# `L<id> <n>` with n the lines the text needs in the box (the box holds two); it exits 1 when a line needs more than two, or when a
# shot is missing. FAILURE MODES IT BLOCKS: a stage that drifted from the sequence (the film would show other words than the bench
# measured); a line that wraps to three and runs out of the box (hidden by overflow, the film would lose its last words).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
OUT=${OUT:-$HERE/../plates/out/stage${PLATE:+-$PLATE}}; SCR=${SCRATCH:-/tmp/film2/plates/chrome}; SC=2.25
SEQ=$REPO/tools/translation-bench/sequences/film-ja-ko-1.json; STAGE=${STAGE:-$HERE/scene.html}   # STAGE: a mutated copy, for check.sh
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
mkdir -p "$OUT" "$SCR"

python3 -I - "$STAGE" "$SEQ" <<'PY' || exit 1
import json, re, sys
html = open(sys.argv[1], encoding="utf-8").read()
embedded = json.loads(re.search(r'<script type="application/json" id="lines">(.*?)</script>', html, re.S).group(1).replace("<\\/", "</"))
seq = json.load(open(sys.argv[2], encoding="utf-8"))
want = [{"id": l["id"], "speaker": l.get("speaker"), "text": l["text"]} for l in seq["lines"]]
if embedded != want:
    bad = [w["id"] for e, w in zip(embedded, want) if e != w] or ["count %d vs %d" % (len(embedded), len(want))]
    sys.exit("stage: scene.html LINES differ from the sequence at %s" % bad)
print("stage: LINES equal the sequence (%d lines)" % len(want))
PY

ids=("$@"); [ ${#ids[@]} -gt 0 ] || ids=($(seq 1 36))
FLAGS=(--headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=$SC --window-size=960,960 --virtual-time-budget=3000 --user-data-dir="$SCR")
: > "$OUT/lines.txt"; bad=0
for id in "${ids[@]}"; do
    url="file://$STAGE?line=$id${PLATE:+&plate=$PLATE}"
    "$CHROME" "${FLAGS[@]}" --screenshot="$OUT/L$id.png" "$url" >/dev/null 2>&1
    n=$("$CHROME" "${FLAGS[@]}" --dump-dom "$url" 2>/dev/null | grep -o 'data-lines="[0-9]*"' | head -1 | tr -dc 0-9)
    echo "L$id ${n:-?}" >> "$OUT/lines.txt"
    [ -s "$OUT/L$id.png" ] || { echo "stage: L$id.png missing" >&2; bad=1; }
    [ "${n:-9}" -le 2 ] 2>/dev/null || { echo "stage: L$id needs ${n:-?} lines (the box holds two)" >&2; bad=1; }
done
echo "stage: ${#ids[@]} shots in $OUT, lines needing 3 or more: $(awk '$2>2' "$OUT/lines.txt" | wc -l | tr -d ' ')"
exit $bad
