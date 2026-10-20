#!/bin/bash
# The stage2 page's checks (check.py on shoot.mjs captures), each with its FAIL-first mutation: a check that passes a page it should
# reject is no check. Needs Chrome and the Bash sandbox off; headless only. The log lines are the evidence.
#   1. the page: LINES equal the sequence; all 36 lines revealed in at most two lines; contrast >= 7:1 with solid ink on 4 lines (one a
#      speaker); text and name pixels still once revealed over 6 s of play (also kept as the review video, video.mp4 when ffmpeg is there)
#   2. 72 u text                     -> wrap must fail (L4 needs 3 lines)
#   3. one character changed in LINES -> lines must fail
#   4. a light panel                  -> contrast must fail
#   5. the scene not frozen under the panel (the shader's still rect off, every frame redrawn whole) -> still must fail (the
#      background's motion reaches the text's pixels)
# usage: check.sh            SCRATCH=<dir> (default /tmp/film2/stage2/check)
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
SEQ=$REPO/tools/translation-bench/sequences/film-ja-ko-1.json
S=${SCRATCH:-/tmp/film2/stage2/check}; rm -rf "$S"; mkdir -p "$S/mut"; ln -s "$HERE/assets" "$S/mut/assets"
fail=0
say() { echo "check: $1 $2"; [ "$1" = PASS ] || fail=1; }
shoot() { SCRATCH=$S node "$HERE/shoot.mjs" "$@"; }
py() { python3 -I "$HERE/check.py" "$@"; }

# 1. the page
{ py lines "$HERE/game.html" "$SEQ" \
  && shoot still --out "$S/all" && py wrap "$S/all" \
  && shoot still --out "$S/hide" --lines 1,4,10,13 --query hide=text && py contrast "$S/all" "$S/hide" 7 \
  && shoot frames --out "$S/frames" --seconds 6 --fps 30 --query play=1\&dwell=2\&from=1 && py still "$S/frames"; } > "$S/page.log" 2>&1 \
  && say PASS "the page: $(grep -h '^lines:\|^wrap:\|^contrast: worst\|^still: [0-9]' "$S/page.log" | tr '\n' ';')" \
  || say FAIL "the page ($(grep -m3 'FAIL\|shoot:' "$S/page.log" | tr '\n' ';'))"
if command -v ffmpeg >/dev/null; then
  ffmpeg -loglevel error -y -framerate 30 -i "$S/frames/f%05d.png" -c:v libx264 -pix_fmt yuv420p -crf 18 "$S/video.mp4" && echo "check: video $S/video.mp4"
fi

python3 -I - "$HERE/game.html" "$S/mut" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read(); m = sys.argv[2]
def write(name, old, new, *more):
    t = s
    for a, b in ((old, new),) + tuple(zip(more[::2], more[1::2])):
        assert a in t, a
        t = t.replace(a, b, 1)
    open("%s/%s.html" % (m, name), "w", encoding="utf-8").write(t)
write("big", "font-size: calc(44 * var(--u)); line-height: 1.6", "font-size: calc(72 * var(--u)); line-height: 1.6")
write("drift", "シュザンヌ様、お急ぎになりませぬよう", "シュザンヌ様、お急ぎになりませんよう")
write("light", "--glass-bottom: rgba(8, 11, 25, 0.92)", "--glass-bottom: rgba(150, 158, 190, 0.92)")
write("thaw", "float still = 1.0 - smoothstep(0.0, uFeather, length(out2));", "float still = 0.0;",   # the shader draws the scene moving
      "if (stillDrawn && liveFrom > 0)", "if (false)")                                                   # under the panel, and redraws it
PY
shoot still --page "$S/mut/big.html" --out "$S/big" --lines 4 > "$S/big.log" 2>&1; py wrap "$S/big" >> "$S/big.log" 2>&1; rc=$?
[ $rc -eq 1 ] && grep -q "FAIL wrap: L4 needs [3-9]" "$S/big.log" && say PASS "72 u text rejected: $(grep -m1 'FAIL wrap' "$S/big.log")" || say FAIL "72 u text not rejected (rc $rc)"
py lines "$S/mut/drift.html" "$SEQ" > "$S/drift.log" 2>&1; rc=$?
[ $rc -eq 1 ] && grep -q "FAIL lines" "$S/drift.log" && say PASS "drifted LINES rejected: $(grep -m1 FAIL "$S/drift.log")" || say FAIL "drifted LINES not rejected (rc $rc)"
{ shoot still --page "$S/mut/light.html" --out "$S/light" --lines 4 && shoot still --page "$S/mut/light.html" --out "$S/light-hide" --lines 4 --query hide=text; } > "$S/light.log" 2>&1
py contrast "$S/light" "$S/light-hide" 7 >> "$S/light.log" 2>&1; rc=$?
[ $rc -eq 1 ] && grep -q "FAIL contrast" "$S/light.log" && say PASS "light panel rejected: $(grep -m1 'FAIL contrast' "$S/light.log")" || say FAIL "light panel not rejected (rc $rc)"
shoot frames --page "$S/mut/thaw.html" --out "$S/thaw" --seconds 2 --fps 10 --query play=1\&dwell=2\&from=4 > "$S/thaw.log" 2>&1; py still "$S/thaw" >> "$S/thaw.log" 2>&1; rc=$?
[ $rc -eq 1 ] && grep -q "FAIL still" "$S/thaw.log" && say PASS "moving scene under the text rejected: $(grep -m1 'FAIL still' "$S/thaw.log")" || say FAIL "moving scene under the text not rejected (rc $rc)"
exit $fail
