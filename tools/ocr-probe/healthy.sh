#!/bin/bash
# Healthy-machine gate for the OCR fallback ladder (round ocr-stall) and the Swift-model isolation (round ocr-iso). Needs the
# Bash sandbox off (headless --render), and a quiet machine (no other --render running: the Neural Engine compiler service
# takes one compile at a time).
#   build: cd /Users/hckim/repo/mwoyeo-wt-ocriso && xcodegen generate && xcodebuild -scheme Mwoyeo -destination 'platform=macOS' \
#          -derivedDataPath /tmp/ocr-iso/dd build
#   run:   SP=<dir with in/chat.png, in/vn.png> NEW=<binary> MAIN=<baseline binary> bash healthy.sh   (QUICK=1 skips the 200 s ja check)
# One PASS/FAIL line per check, a summary line at the end. Outputs: $OUT/*.out (stdout) and *.err (stderr), default /tmp/ocr-stall/healthy.
# A fresh --render gates the Swift text models until a child process (`Mwoyeo --warm-vision`) has loaded them; the checks
# that exercise the Swift path itself (1, 2, 4) pass --assume-vision-ready, the others run as the app does.
SP=${SP:?set SP to a folder holding in/chat.png (English chat) and in/vn.png (Japanese)}
NEW=${NEW:-/tmp/ocr-stall/dd/Build/Products/Debug/Mwoyeo.app/Contents/MacOS/Mwoyeo}
MAIN=${MAIN:-/tmp/mwoyeo-main/dd/Build/Products/Debug/Mwoyeo.app/Contents/MacOS/Mwoyeo}
OUT=${OUT:-/tmp/ocr-stall/healthy}
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
# 2026-10-17 (ocr-iso): --assume-vision-ready, so that this run loads the Swift models in its own process as before.
EXTRA="--warm --assume-vision-ready --then wait120000" run w "$NEW" "" vn.png ja 600
echo "warm-up new: $(cat $OUT/w.s) s  (stalled=$(count $OUT/w.out ocr.stalled) recovered=$(count $OUT/w.out ocr.recovered))"
run mw "$MAIN" "" vn.png ja 400
echo "warm-up main: $(cat $OUT/mw.s) s"

# 2026-10-17 (ocr-iso): the Swift path is gated in a fresh process now, so check 1 asks for it (--assume-vision-ready); check 7
# covers the gated default.
EXTRA="--assume-vision-ready" run a "$NEW" "" chat.png en 90
n=$(arrows "$OUT/a.out"); f=$(fallback "$OUT/a.out"); gt=$(count "$OUT/a.out" ocr.swift.gated)
[ "$n" -eq 29 ] && [ "$f" -eq 0 ] && [ "$gt" -eq 0 ]; verdict $? "1 chat.png en>ko, healthy, Swift path: 29 arrows, ocr.fallback=0, ocr.swift.gated=0" "arrows=$n fallback=$f gated=$gt wall=$(cat $OUT/a.s)s"

# The Swift models never answer (the stall seen on macOS 27): the read goes to VNRecognizeTextRequest revision 3 after 8 s.
# 2026-10-17 (ocr-iso): the fake stalls the Swift model in this process, which a fresh render only asks with --assume-vision-ready.
EXTRA="--assume-vision-ready" run b "$NEW" stall chat.png en 90
n=$(arrows "$OUT/b.out"); f=$(count "$OUT/b.out" ocr.fallback.vn3); st=$(count "$OUT/b.out" ocr.stalled)
[ "$n" -ge 25 ] && [ "$f" -gt 0 ] && [ "$st" -ge 1 ]; verdict $? "2 chat.png en>ko, MWOYEO_FAKE_OCR=stall: >=25 arrows, ocr.fallback.vn3>0, ocr.stalled>=1" "arrows=$n vn3=$f stalled=$st wall=$(cat $OUT/b.s)s"

# 2026-10-17 (ocr-iso): c asks for the Swift path (as main reads), c2 is the default, gated read of the same picture: its lines go
# through VNRecognizeTextRequest revision 3, and must give a translation for each block it finds, without an issue.
EXTRA="--assume-vision-ready" run c "$NEW" "" vn.png ja 90
run m "$MAIN" "" vn.png ja 90
n=$(arrows "$OUT/c.out"); nm=$(arrows "$OUT/m.out"); is=$(grep -c '^issue:' "$OUT/c.err")
[ "$n" -eq "$nm" ] && [ "$n" -gt 0 ] && [ "$is" -eq 0 ]; verdict $? "3 vn.png ja>ko, healthy, Swift path: same arrows as main, no issue" "arrows=$n main=$nm issues=$is wall=$(cat $OUT/c.s)s main-wall=$(cat $OUT/m.s)s"
run c2 "$NEW" "" vn.png ja 90
n=$(arrows "$OUT/c2.out"); is=$(grep -c '^issue:' "$OUT/c2.err"); gt=$(count "$OUT/c2.out" ocr.swift.gated); v3=$(count "$OUT/c2.out" ocr.fallback.vn3)
[ "$n" -gt 0 ] && [ "$is" -eq 0 ] && [ "$gt" -ge 1 ] && [ "$v3" -ge 1 ]; verdict $? "8 vn.png ja>ko, default (gated): arrows>0, no issue, ocr.swift.gated>=1, ocr.fallback.vn3>=1" "arrows=$n main=$nm issues=$is gated=$gt vn3=$v3 wall=$(cat $OUT/c2.s)s"

# Recovery: the Swift models answer 12 s late. The read goes to revision 3 at 8 s; the late answer ends the stall.
# (2026-10-17, ocr-iso: --assume-vision-ready, as for check 2.)
EXTRA="--assume-vision-ready --then wait8000" run d "$NEW" slow:12000 chat.png en 90   # the wait keeps the process alive past the late answer
n=$(arrows "$OUT/d.out"); st=$(count "$OUT/d.out" ocr.stalled); rc=$(count "$OUT/d.out" ocr.recovered)
[ "$n" -ge 25 ] && [ "$st" -eq 1 ] && [ "$rc" -eq 1 ]; verdict $? "4 chat.png en>ko, MWOYEO_FAKE_OCR=slow:12000: >=25 arrows, ocr.stalled=1, ocr.recovered=1" "arrows=$n stalled=$st recovered=$rc wall=$(cat $OUT/d.s)s"

# Revision 3 stalls too: the ladder goes on to revision 2 (English has one; Japanese has not).
run e "$NEW" stall-vn chat.png en 90
n=$(arrows "$OUT/e.out"); f=$(count "$OUT/e.out" ocr.fallback.rev2); st=$(count "$OUT/e.out" ocr.stalled.vn3)
[ "$n" -ge 25 ] && [ "$f" -gt 0 ] && [ "$st" -ge 1 ]; verdict $? "5 chat.png en>ko, MWOYEO_FAKE_OCR=stall-vn: >=25 arrows, ocr.fallback.rev2>0, ocr.stalled.vn3>=1" "arrows=$n rev2=$f vn3-stalled=$st wall=$(cat $OUT/e.s)s"

# The default, as the app runs: a fresh process gates the Swift models, reads through VNRecognizeTextRequest revision 3 and
# is not blocked (the in-process block of a pending Swift request is what this isolation removes; tools/ocr-probe/inprocess.swift).
run f "$NEW" "" chat.png en 90
n=$(arrows "$OUT/f.out"); gt=$(count "$OUT/f.out" ocr.swift.gated); v3=$(count "$OUT/f.out" ocr.fallback.vn3); st=$(count "$OUT/f.out" ocr.stalled)
[ "$n" -ge 25 ] && [ "$gt" -ge 1 ] && [ "$v3" -ge 1 ] && [ "$st" -eq 0 ]; verdict $? "7 chat.png en>ko, default (gated): >=25 arrows, ocr.swift.gated>=1, ocr.fallback.vn3>=1, ocr.stalled=0" "arrows=$n gated=$gt vn3=$v3 stalled=$st wall=$(cat $OUT/f.s)s $(grep -h '^swift-vision:' "$OUT/f.out")"

# A child that loads slowly (a cold compile): the fake makes it wait 90 s first. The reads must not wait for it or be blocked
# by it: they go through VNRecognizeTextRequest revision 3, no stall, no notice, and the run ends with the child still loading.
run h "$NEW" slow-child:90000 chat.png en 90
n=$(arrows "$OUT/h.out"); gt=$(count "$OUT/h.out" ocr.swift.gated); st=$(count "$OUT/h.out" ocr.stalled); is=$(grep -c '^issue:' "$OUT/h.err"); w=$(cat "$OUT/h.s")
sv=$(grep -h '^swift-vision:' "$OUT/h.out")
[ "$n" -ge 25 ] && [ "$gt" -ge 1 ] && [ "$st" -eq 0 ] && [ "$is" -eq 0 ] && [ "$w" -lt 60 ] && echo "$sv" | grep -q 'ready=- child=[0-9]'; verdict $? "10 chat.png en>ko, MWOYEO_FAKE_OCR=slow-child:90000: >=25 arrows, ocr.swift.gated>=1, ocr.stalled=0, no issue, exits in <60 s with the child still loading" "arrows=$n gated=$gt stalled=$st issues=$is wall=${w}s $sv"

# The child itself: Mwoyeo --warm-vision [key] loads both Swift requests on a drawn picture and exits 0 (it is never killed here: a
# client that goes away restarts the system's compile; it only waits, up to 10 minutes).
"$NEW" --warm-vision > "$OUT/child.out" 2> "$OUT/child.err" < /dev/null &
cpid=$!
c0=$SECONDS
while kill -0 $cpid 2> /dev/null && [ $((SECONDS - c0)) -lt 600 ]; do sleep 2; done
if kill -0 $cpid 2> /dev/null; then crc="running"; else wait $cpid; crc=$?; fi
[ "$crc" = 0 ]; verdict $? "9 Mwoyeo --warm-vision: exits 0" "rc=$crc wall=$((SECONDS - c0))s"

if [ -z "$QUICK" ]; then
    # Nothing else reads Japanese: it waits for revision 3 ("still preparing" after 8 s), and after 3 minutes says "not responding".
    run g "$NEW" stall-vn vn.png ja 300
    p=$(grep -c -e "^issue: macOS is still preparing text recognition for" -e "^issue: macOS가 아직" "$OUT/g.err"); r=$(grep -c -e "isn't responding" -e "응답하지 않아요" "$OUT/g.err"); w=$(cat "$OUT/g.s")
    [ "$p" -eq 1 ] && [ "$r" -eq 1 ] && [ "$w" -lt 290 ]; verdict $? "6 vn.png ja>ko, MWOYEO_FAKE_OCR=stall-vn: 'still preparing' line, then 'not responding' after 3 min, exits before max-wait" "preparing=$p not-responding=$r wall=${w}s"
fi

echo "ocr-healthy: $([ $fails -eq 0 ] && echo ALL PASS || echo "$fails FAILED")"
