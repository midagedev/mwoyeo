#!/bin/bash
# Healthy-machine gate for the OCR fallback ladder (round ocr-stall). Needs the Bash sandbox off (headless --render), and a
# quiet machine (no other --render running: the Neural Engine compiler service takes one compile at a time).
#   build: cd /Users/hckim/repo/mwoyeo-wt-ocr && xcodegen generate && xcodebuild -scheme Mwoyeo -destination 'platform=macOS' \
#          -derivedDataPath /tmp/ocr-stall/dd build
#   run:   bash ocr-healthy.sh            (QUICK=1 skips the 200 s ja check)
# One PASS/FAIL line per check, a summary line at the end. Outputs: /tmp/ocr-stall/healthy/*.out (stdout) and *.err (stderr).
SP=${SP:?set SP to a folder holding in/chat.png (English chat) and in/vn.png (Japanese)}
NEW=${NEW:-/tmp/ocr-stall/dd/Build/Products/Debug/Mwoyeo.app/Contents/MacOS/Mwoyeo}
MAIN=${MAIN:-/tmp/mwoyeo-main/dd/Build/Products/Debug/Mwoyeo.app/Contents/MacOS/Mwoyeo}
OUT=/tmp/ocr-stall/healthy
mkdir -p "$OUT"
fails=0

# run <name> <binary> <fake-ocr or ""> <image> <src> <max-wait>: stdout to $OUT/<name>.out, stderr to .err, wall seconds to .s.
# EXTRA adds arguments.
run() {
    local t0=$SECONDS
    MWOYEO_FAKE_OCR="$3" "$2" --render "$SP/in/$4" "$OUT/$1.png" --src "$5" --tgt ko --max-wait "$6" $EXTRA > "$OUT/$1.out" 2> "$OUT/$1.err" < /dev/null
    echo $((SECONDS - t0)) > "$OUT/$1.s"
}
# Lines "    → text" that carry a translation.
arrows() { local n z; n=$(grep -c '^    → ' "$1"); z=$(grep -c '^    → (no translation)' "$1"); echo $((n - z)); }
# Sum of every ocr.fallback.<rung>=<n> in the work lines.
fallback() { grep -o 'ocr\.fallback\.[a-z0-9]*=[0-9]*' "$1" | awk -F= '{s+=$2} END {print s+0}'; }
# First value of one counter anywhere in the output (0 if absent).
count() { local v; v=$(grep -o "$2=[0-9]*" "$1" | head -1 | cut -d= -f2); echo "${v:-0}"; }
verdict() { # <ok 0|1> <label> <detail>
    if [ "$1" = 0 ]; then echo "PASS $2 ($3)"; else echo "FAIL $2 ($3)"; fails=$((fails + 1)); fi
}

# Warm-up, not a check. The text models compile once per app binary (about half a minute each, the document recognizer
# longer) and the compiler service takes one at a time; a run that exits mid-compile makes it start over. So let each
# binary load them completely first: --warm (as the app does at launch), then stay alive while the Swift models finish.
EXTRA="--warm --then wait120000" run w "$NEW" "" vn.png ja 600
echo "warm-up new: $(cat $OUT/w.s) s  (stalled=$(count $OUT/w.out ocr.stalled) recovered=$(count $OUT/w.out ocr.recovered))"
run mw "$MAIN" "" vn.png ja 400
echo "warm-up main: $(cat $OUT/mw.s) s"

run a "$NEW" "" chat.png en 90
n=$(arrows "$OUT/a.out"); f=$(fallback "$OUT/a.out")
[ "$n" -eq 29 ] && [ "$f" -eq 0 ]; verdict $? "1 chat.png en>ko, healthy: 29 arrows, ocr.fallback=0" "arrows=$n fallback=$f wall=$(cat $OUT/a.s)s"

# The Swift models never answer (the stall seen on macOS 27): the read goes to VNRecognizeTextRequest revision 3 after 8 s.
run b "$NEW" stall chat.png en 90
n=$(arrows "$OUT/b.out"); f=$(count "$OUT/b.out" ocr.fallback.vn3); st=$(count "$OUT/b.out" ocr.stalled)
[ "$n" -ge 25 ] && [ "$f" -gt 0 ] && [ "$st" -ge 1 ]; verdict $? "2 chat.png en>ko, MWOYEO_FAKE_OCR=stall: >=25 arrows, ocr.fallback.vn3>0, ocr.stalled>=1" "arrows=$n vn3=$f stalled=$st wall=$(cat $OUT/b.s)s"

run c "$NEW" "" vn.png ja 90
run m "$MAIN" "" vn.png ja 90
n=$(arrows "$OUT/c.out"); nm=$(arrows "$OUT/m.out"); is=$(grep -c '^issue:' "$OUT/c.err")
[ "$n" -eq "$nm" ] && [ "$n" -gt 0 ] && [ "$is" -eq 0 ]; verdict $? "3 vn.png ja>ko, healthy: same arrows as main, no issue" "arrows=$n main=$nm issues=$is wall=$(cat $OUT/c.s)s main-wall=$(cat $OUT/m.s)s"

# Recovery: the Swift models answer 12 s late. The read goes to revision 3 at 8 s; the late answer ends the stall.
EXTRA="--then wait8000" run d "$NEW" slow:12000 chat.png en 90   # the wait keeps the process alive past the late answer
n=$(arrows "$OUT/d.out"); st=$(count "$OUT/d.out" ocr.stalled); rc=$(count "$OUT/d.out" ocr.recovered)
[ "$n" -ge 25 ] && [ "$st" -eq 1 ] && [ "$rc" -eq 1 ]; verdict $? "4 chat.png en>ko, MWOYEO_FAKE_OCR=slow:12000: >=25 arrows, ocr.stalled=1, ocr.recovered=1" "arrows=$n stalled=$st recovered=$rc wall=$(cat $OUT/d.s)s"

# Revision 3 stalls too: the ladder goes on to revision 2 (English has one; Japanese has not).
run e "$NEW" stall-vn chat.png en 90
n=$(arrows "$OUT/e.out"); f=$(count "$OUT/e.out" ocr.fallback.rev2); st=$(count "$OUT/e.out" ocr.stalled.vn3)
[ "$n" -ge 25 ] && [ "$f" -gt 0 ] && [ "$st" -ge 1 ]; verdict $? "5 chat.png en>ko, MWOYEO_FAKE_OCR=stall-vn: >=25 arrows, ocr.fallback.rev2>0, ocr.stalled.vn3>=1" "arrows=$n rev2=$f vn3-stalled=$st wall=$(cat $OUT/e.s)s"

if [ -z "$QUICK" ]; then
    # Nothing else reads Japanese: it waits for revision 3 ("still preparing" after 8 s), and after 3 minutes says "not responding".
    run g "$NEW" stall-vn vn.png ja 300
    p=$(grep -c -e "^issue: macOS is still preparing text recognition for" -e "^issue: macOS가 아직" "$OUT/g.err"); r=$(grep -c -e "isn't responding" -e "응답하지 않아요" "$OUT/g.err"); w=$(cat "$OUT/g.s")
    [ "$p" -eq 1 ] && [ "$r" -eq 1 ] && [ "$w" -lt 290 ]; verdict $? "6 vn.png ja>ko, MWOYEO_FAKE_OCR=stall-vn: 'still preparing' line, then 'not responding' after 3 min, exits before max-wait" "preparing=$p not-responding=$r wall=${w}s"
fi

echo "ocr-healthy: $([ $fails -eq 0 ] && echo ALL PASS || echo "$fails FAILED")"
