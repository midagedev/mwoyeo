#!/bin/bash
# The gates of the reader host (App/Reader/RecognitionHost.swift; r3a-host-lines, 2026-10-19), on a binary built with a scratch
# MWOYEO_APP_ID whose services are warm (run `reader-equal.sh <bin> <dir> direct` once). Fakes run inside the services
# (MWOYEO_FAKE_READER), so the host meets a slow, failing or dying worker on a healthy Mac.
#   usage: host-gates.sh <Mwoyeo binary> [g1 g1m g2 g3 g4]        (default: all; one render at a time, the Bash sandbox off)
#   env:   PAGE   a paper page for g1 (default /tmp/paper-quality/paper/p13.png, the figure page whose networks compile)
#          PNGS   the use-case pictures (default /Users/hckim/.cache/mwoyeo-gates/usecases/set)
#          OUT    where everything goes (default /tmp/host-gates/<stamp>)
#
# FAILURE MODES IT BLOCKS
#   g1  docs-slow:40000  A document read that takes 40 s must not silence the lens: the pass waits S = 2 s, the read is routed again
#                        to Lines + ParagraphGrouper (`reader.reroute.docs.lines`), and the slow read runs on, never cancelled
#                        (`reader: docs state=idle` at the end). silence: longest <= 8000 ms.
#   g1m  FAIL-first of g1: MWOYEO_DOCS_WAIT=1 makes the pass wait for Docs however long, as the in-process path did.
#                        silence: longest >= 38000 ms. A g1 that does not fail under it measures nothing.
#   g2  lines-slow:40000 A Lines read that takes 40 s on a language no other rung reads (ja) must say so: `hint:
#                        preparingRecognition` within 3500 ms, and the pass waits for `readerReady`, not for a timer.
#   g3  lines-e5rt:40    Programs-not-ready errors (Code 13) rest the rev3 rung on 1, 2, 4, 8, 16, 30 s (the logged waits), the lens
#                        is filled by rev2 or `.fast`, and no minute sees more than 6 errors (56 a minute before 1.1.2).
#   g4  crash            The Lines service dies on its first job: the host restarts it after Backoff.workerRestart, the render
#                        completes with blocks > 0 (Docs' `.fast` reads meanwhile), one crash is counted.
set -u
BIN=${1:?usage: host-gates.sh <Mwoyeo binary> [g1 g1m g2 g3 g4]}; shift
GATES=${*:-g1 g1m g2 g3 g4}
PAGE=${PAGE:-/tmp/paper-quality/paper/p13.png}
PNGS=${PNGS:-/Users/hckim/.cache/mwoyeo-gates/usecases/set}
OUT=${OUT:-/tmp/host-gates/$(date +%Y%m%d-%H%M%S)}
mkdir -p "$OUT"
fail=0
say() { echo "$@" | tee -a "$OUT/summary.txt"; }
check() {   # name, 0|1 (1 = ok), detail
    if [ "$2" = 1 ]; then say "PASS $1 $3"; else say "FAIL $1 $3"; fail=1; fi
}
# One render: gate name, extra env (K=V …), then the arguments of --render after the picture and the output path.
run() {
    local g=$1 pic=$2; shift 2
    mkdir -p "$OUT/$g"
    date '+%Y-%m-%d %H:%M:%S' > "$OUT/$g/start.txt"
    env MWOYEO_MEMORY_SECRETS=1 MWOYEO_SETTINGS_FILE="$OUT/$g/s.json" MWOYEO_DEFAULTS_SUITE=hostgates.$g MWOYEO_TRACE=1 "${ENVS[@]}" \
        "$BIN" --render "$pic" "$OUT/$g/out.png" "$@" > "$OUT/$g/render.out" 2> "$OUT/$g/render.err" < /dev/null
    echo $? > "$OUT/$g/rc"
}
longest() { sed -n 's/^silence: longest=\([0-9]*\).*/\1/p' "$OUT/$1/render.out" | head -1; }
logfor() { /usr/bin/log show --start "$(cat "$OUT/$1/start.txt")" --predicate 'subsystem == "dev.midagedev.mwoyeo" AND category == "reader"' --info --style compact 2>/dev/null; }

for g in $GATES; do
    case $g in
    g1)
        ENVS=(MWOYEO_FAKE_READER=docs-slow:40000)
        run g1 "$PAGE" --src en --tgt ko --mode adaptive --max-wait 600 --warm
        l=$(longest g1)
        check "g1 render exits 0" $([ "$(cat "$OUT/g1/rc")" = 0 ] && echo 1 || echo 0) "rc=$(cat "$OUT/g1/rc")"
        check "g1 silence: longest <= 8000" $([ -n "$l" ] && [ "$l" -le 8000 ] && echo 1 || echo 0) "longest=${l:-n/a} ms"
        check "g1 reader.reroute.docs.lines >= 1" $(grep -q 'reader\.reroute\.docs\.lines=[1-9]' "$OUT/g1/render.out" && echo 1 || echo 0) "$(grep -o 'reader\.reroute\.docs\.lines=[0-9]*' "$OUT/g1/render.out" | head -1)"
        # The slow request is never cancelled or killed (invariant I3): it ends in an answer (`idle`, or `suspect` while a re-read
        # sent after the last recovery is still in flight when the drain ends), never in a failure, a stuck recycle or a crash.
        check "g1 the slow reads ran on: Docs failed=0 stuck=0 crashes=0, same service" $(grep -q '^reader: docs state=[a-z]* .* failed=0 suspects=[0-9]* stuck=0 crashes=0 ' "$OUT/g1/render.out" && echo 1 || echo 0) "$(grep '^reader: docs state=' "$OUT/g1/render.out" | head -1 | cut -c1-160)"
        ;;
    g1m)
        ENVS=(MWOYEO_FAKE_READER=docs-slow:40000 MWOYEO_DOCS_WAIT=1)
        run g1m "$PAGE" --src en --tgt ko --mode adaptive --max-wait 600 --warm
        l=$(longest g1m)
        check "g1m (FAIL-first of g1) silence: longest >= 38000 under MWOYEO_DOCS_WAIT=1" $([ -n "$l" ] && [ "$l" -ge 38000 ] && echo 1 || echo 0) "longest=${l:-n/a} ms"
        ;;
    g2)
        ENVS=(MWOYEO_FAKE_READER=lines-slow:40000)
        run g2 "$PNGS/d02-timetable-ja.png" --src ja --tgt ko --mode adaptive --max-wait 15
        at=$(sed -n 's/^hint: preparingRecognition at \([0-9]*\)$/\1/p' "$OUT/g2/render.out" | head -1)
        check "g2 hint: preparingRecognition at <= 3500 ms" $([ -n "$at" ] && [ "$at" -le 3500 ] && echo 1 || echo 0) "at=${at:-n/a} ms"
        check "g2 the pass said 'no reader' and did not read again by itself (ocr.unavailable counted, no timeout error)" $(grep -q 'ocr\.unavailable=' "$OUT/g2/render.out" && ! grep -q 'ReadTimeout\|Timeout' "$OUT/g2/render.err" && echo 1 || echo 0) "$(grep -o 'ocr\.unavailable=[0-9]*' "$OUT/g2/render.out" | head -1)"
        ;;
    g3)
        ENVS=(MWOYEO_FAKE_READER=lines-e5rt:40)
        run g3 "$PNGS/c01-slack-en.png" --src en --tgt ko --mode adaptive --max-wait 300 --warm
        waits=$(logfor g3 | sed -n 's/.*reader rung resting role=lines via=rev3 for=\([0-9]*\) s.*/\1/p' | head -6 | tr '\n' ' ')
        check "g3 logged rung waits 1 2 4 8 16 30" $([ "$waits" = "1 2 4 8 16 30 " ] && echo 1 || echo 0) "waits=$waits"
        worst=$(logfor g3 | grep 'reader failed role=lines via=rev3 why=programsNotReady' | awk '{split($2,t,":"); s=t[1]*3600+t[2]*60+int(t[3]); m=int(s/60); c[m]++} END{w=0; for(k in c) if(c[k]>w) w=c[k]; print w+0}')
        check "g3 Code-13 errors <= 6 in any minute" $([ "$worst" -le 6 ] && echo 1 || echo 0) "worst minute=$worst"
        check "g3 the lens was filled by rev2 or .fast (blocks > 0)" $(grep -q 'ocr\.blocks=[1-9]' "$OUT/g3/render.out" && echo 1 || echo 0) "$(grep -o 'ocr\.blocks=[0-9]*' "$OUT/g3/render.out" | head -1)"
        ;;
    g4)
        ENVS=(MWOYEO_FAKE_READER=crash)
        run g4 "$PNGS/c01-slack-en.png" --src en --tgt ko --mode adaptive --max-wait 120
        check "g4 render exits 0" $([ "$(cat "$OUT/g4/rc")" = 0 ] && echo 1 || echo 0) "rc=$(cat "$OUT/g4/rc")"
        check "g4 one crash counted, blocks > 0" $(grep -q 'reader\.lines\.crash=1' "$OUT/g4/render.out" && grep -q 'ocr\.blocks=[1-9]' "$OUT/g4/render.out" && echo 1 || echo 0) "$(grep -o 'reader\.lines\.crash=[0-9]*\|ocr\.blocks=[0-9]*' "$OUT/g4/render.out" | head -2 | tr '\n' ' ')"
        check "g4 the service was usable again after its backoff" $(logfor g4 | grep -q 'reader usable again role=lines' && echo 1 || echo 0) ""
        ;;
    *) say "unknown gate $g"; fail=1 ;;
    esac
done
say "$([ $fail = 0 ] && echo 'host-gates: all PASS' || echo 'host-gates: FAIL')"
exit $fail
