#!/bin/bash
# Healthy-machine gate for the OCR fallback ladder (round ocr-stall) and the paragraph grouping (round ocr-vn). Needs the Bash
# sandbox off (headless --render), and a quiet machine (no other --render running: the Neural Engine compiler service takes
# one compile at a time).
#   build: cd /Users/hckim/repo/mwoyeo-wt-ocrvn && xcodegen generate && xcodebuild -scheme Mwoyeo -destination 'platform=macOS' \
#          -derivedDataPath /tmp/ocr-vn/dd build
#   run:   SP=<dir with in/chat.png, in/vn.png, in/article.png, in/sub-mid.png> NEW=<binary> MAIN=<baseline binary> bash healthy.sh
#          (QUICK=1 skips the 200 s ja check)
# One PASS/FAIL line per check, a summary line at the end. Outputs: $OUT/*.out (stdout) and *.err (stderr), default /tmp/ocr-stall/healthy.
# 2026-10-17 (ocr-vn): the app asked no Swift Vision request (they seemed to stall the whole process, tools/ocr-probe/inprocess.swift);
# every read was the Objective-C VNRecognizeTextRequest, lines grouped into paragraphs by ParagraphGrouper. The checks of the child
# warm-up (--warm-vision, --assume-vision-ready, slow-child, fail-child) and of the Swift path are gone; `stall` and `stall-vn` both
# stall revision 3 now (checks 2 and 5), `slow:<ms>` makes revision 3 answer late (check 4).
# 2026-10-18 (vision-revive): the stall was a cold ANE compile, and the app loads the Swift document model itself at launch and
# reads paragraphs with it once loaded. These checks run on that default; MWOYEO_OCR_PATH=vn (never a Swift model) must pass them too.
SP=${SP:?set SP to a folder holding in/chat.png (English chat), in/vn.png (Japanese), in/article.png and in/sub-mid.png (Japanese)}
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
# Sum of every ocr.fallback.<rung>=<n> in the work lines, for the rungs after the first (revision 2, fast).
older() { grep -oE 'ocr\.fallback\.(rev2|fast)=[0-9]*' "$1" | awk -F= '{s+=$2} END {print s+0}'; }
# First value of one counter anywhere in the output (0 if absent).
count() { local v; v=$(grep -o "$2=[0-9]*" "$1" | head -1 | cut -d= -f2); echo "${v:-0}"; }
verdict() { # <ok 0|1> <label> <detail>
    if [ "$1" = 0 ]; then echo "PASS $2 ($3)"; else echo "FAIL $2 ($3)"; fails=$((fails + 1)); fi
}

# Warm-up, not a check. The text models compile once per app binary (up to a minute for revision 3) and the compiler service
# takes one at a time; a run that exits mid-compile makes it start over. So let each binary load them completely first: --warm,
# as the app does at launch.
EXTRA="--warm" run w "$NEW" "" vn.png ja 600
echo "warm-up new: $(cat $OUT/w.s) s  (stalled=$(count $OUT/w.out ocr.stalled.vn3) recovered=$(count $OUT/w.out ocr.recovered.vn3))"

# Healthy: every read through revision 3, nothing older, no stall.
run a "$NEW" "" chat.png en 90
n=$(arrows "$OUT/a.out"); o=$(older "$OUT/a.out"); st=$(count "$OUT/a.out" ocr.stalled.vn3); b=$(count "$OUT/a.out" ocr.blocks)
[ "$n" -ge 27 ] && [ "$o" -eq 0 ] && [ "$st" -eq 0 ] && [ "$b" -ge 1 ]; verdict $? "1 chat.png en>ko, healthy: >=27 arrows, ocr.fallback.rev2|fast=0, ocr.stalled.vn3=0, ocr.blocks>=1" "arrows=$n older=$o stalled=$st blocks-reads=$b wall=$(cat $OUT/a.s)s"

# Revision 3 never answers (what the stalled Mac does; until 2026-10-17 `stall` meant the Swift models, now it is the same as
# stall-vn): the read goes down the ladder to revision 2 after 8 s.
run b "$NEW" stall chat.png en 90
n=$(arrows "$OUT/b.out"); f=$(count "$OUT/b.out" ocr.fallback.rev2); st=$(count "$OUT/b.out" ocr.stalled.vn3)
[ "$n" -ge 25 ] && [ "$f" -gt 0 ] && [ "$st" -ge 1 ]; verdict $? "2 chat.png en>ko, MWOYEO_FAKE_OCR=stall: >=25 arrows, ocr.fallback.rev2>0, ocr.stalled.vn3>=1" "arrows=$n rev2=$f stalled=$st wall=$(cat $OUT/b.s)s"

# Recovery: revision 3 answers 12 s late. The read goes to revision 2 at 8 s; the late answer ends the stall.
EXTRA="--then wait8000" run d "$NEW" slow:12000 chat.png en 90   # the wait keeps the process alive past the late answer
n=$(arrows "$OUT/d.out"); st=$(count "$OUT/d.out" ocr.stalled.vn3); rc=$(count "$OUT/d.out" ocr.recovered.vn3)
[ "$n" -ge 25 ] && [ "$st" -eq 1 ] && [ "$rc" -eq 1 ]; verdict $? "4 chat.png en>ko, MWOYEO_FAKE_OCR=slow:12000: >=25 arrows, ocr.stalled.vn3=1, ocr.recovered.vn3=1" "arrows=$n stalled=$st recovered=$rc wall=$(cat $OUT/d.s)s"

# Revision 3 stalls: the ladder goes on to revision 2 (English has one; Japanese has not).
run e "$NEW" stall-vn chat.png en 90
n=$(arrows "$OUT/e.out"); f=$(count "$OUT/e.out" ocr.fallback.rev2); st=$(count "$OUT/e.out" ocr.stalled.vn3)
[ "$n" -ge 25 ] && [ "$f" -gt 0 ] && [ "$st" -ge 1 ]; verdict $? "5 chat.png en>ko, MWOYEO_FAKE_OCR=stall-vn: >=25 arrows, ocr.fallback.rev2>0, ocr.stalled.vn3>=1" "arrows=$n rev2=$f vn3-stalled=$st wall=$(cat $OUT/e.s)s"

# Programs not ready (2026-10-18, vision-setup): revision 3 throws e5rtError twenty times (what a Mac logs for ~90 s after a long cold
# compile). The reads fall down the ladder in the same call (revision 2 for English): every block still translates, the pass never
# fails, and the log has no "document OCR failed" line (that was the message of an ended pass).
since=$(date '+%Y-%m-%d %H:%M:%S')
run x "$NEW" e5rt chat.png en 90
n=$(arrows "$OUT/x.out"); f=$(count "$OUT/x.out" ocr.fallback.notready); ft=$(/usr/bin/log show --start "$since" --predicate 'eventMessage CONTAINS "document OCR failed"' 2>/dev/null | grep -c 'document OCR failed:')
[ "$n" -ge 27 ] && [ "$ft" -eq 0 ]; verdict $? "8 chat.png en>ko, MWOYEO_FAKE_OCR=e5rt: >=27 arrows (29 on revision 3, 30 on revision 2), no 'document OCR failed'" "arrows=$n notready-fallbacks=$f failed-lines=$ft wall=$(cat $OUT/x.s)s"

# A pass that fails on "programs not ready" (2026-10-18, rc 1.1.1): Japanese has no revision 2, so revision 3's e5rtError ends the
# pass. It must leave the still picture unread and read it again after the 1 s backoff; before, the frame counted as read and a
# still lens stayed empty until its pixels changed (measured on 7ad1e24: 0 arrows; fixed: 19).
run y "$NEW" e5rt:3 article.png ja 300
n=$(arrows "$OUT/y.out"); f=$(count "$OUT/y.out" ocr.failed_pass.notready)
[ "$n" -ge 10 ] && [ "$f" -ge 1 ]; verdict $? "9 article.png ja>ko, MWOYEO_FAKE_OCR=e5rt:3: a pass failed on programs not ready, then >=10 arrows" "arrows=$n notready-passes=$f wall=$(cat $OUT/y.s)s"

# Paragraphs (ParagraphGrouper): the three-line body paragraph of article.png is one block, and the two centred subtitle lines
# of sub-mid.png are one block.
if [ -f "$SP/in/article.png" ] && [ -f "$SP/in/sub-mid.png" ]; then
    run p "$NEW" "" article.png ja 90
    run q "$NEW" "" sub-mid.png ja 90
    body=$(grep -c '^  .*海外のゲームや漫画.*おもしろいところ.*見比べるしかなかった' "$OUT/p.out")
    sub=$(grep -c '^  .*今日はとても楽しかった.*また明日も一緒に遊ぼう' "$OUT/q.out"); sb=$(grep -c '^    → ' "$OUT/q.out")
    [ "$body" -eq 1 ] && [ "$sub" -eq 1 ] && [ "$sb" -eq 1 ]; verdict $? "7 article.png ja>ko: the 3-line body is 1 block; sub-mid.png ja>ko: the 2 subtitle lines are 1 block" "body-blocks=$body subtitle-blocks=$sub sub-total-blocks=$sb arrows(article)=$(arrows "$OUT/p.out")"
fi

if [ -z "$QUICK" ]; then
    # Nothing else reads Japanese: it waits for revision 3 ("still preparing" after 8 s), and after 3 minutes says "not responding".
    run g "$NEW" stall-vn vn.png ja 300
    p=$(grep -c -e "^issue: macOS is still preparing text recognition for" -e "^issue: macOS가 아직" "$OUT/g.err"); r=$(grep -c -e "isn't responding" -e "응답하지 않아요" "$OUT/g.err"); w=$(cat "$OUT/g.s")
    [ "$p" -eq 1 ] && [ "$r" -eq 1 ] && [ "$w" -lt 290 ]; verdict $? "6 vn.png ja>ko, MWOYEO_FAKE_OCR=stall-vn: 'still preparing' line, then 'not responding' after 3 min, exits before max-wait" "preparing=$p not-responding=$r wall=${w}s"
fi

# Japanese, healthy: nothing else reads it, so every block is a revision 3 paragraph. Last, because MAIN (gated: its lines are read by
# the same request, one block per line) starts a child process that loads the Swift models, which holds the compiler service.
# The grouping gives no more blocks than main has lines, and not fewer than half.
run c "$NEW" "" vn.png ja 90
run mw "$MAIN" "" vn.png ja 400
run m "$MAIN" "" vn.png ja 90
n=$(arrows "$OUT/c.out"); nm=$(arrows "$OUT/m.out"); is=$(grep -c '^issue:' "$OUT/c.err")
[ "$n" -gt 0 ] && [ "$n" -le "$nm" ] && [ $((2 * n)) -ge "$nm" ] && [ "$is" -eq 0 ]; verdict $? "3 vn.png ja>ko, healthy: arrows>0, <= main's one-per-line and >= half of it, no issue" "arrows=$n main=$nm issues=$is wall=$(cat $OUT/c.s)s main-wall=$(cat $OUT/m.s)s"

echo "ocr-healthy: $([ $fails -eq 0 ] && echo ALL PASS || echo "$fails FAILED")"
