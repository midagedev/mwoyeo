#!/bin/bash
# The real-process smoke of the reader host (App/Reader/RecognitionHost.swift; r3a-host-lines 2026-10-19, cut down by
# g2-fast-host-gates 2026-10-19). NOT PER LANDING: the policy gates are unit tests now; run this when a change touches how the app
# meets a service (App/Reader/, Reader/, Shared/VisionExec.swift, the XPC plists), on a binary built with a scratch MWOYEO_APP_ID
# whose services are warm (run `reader-equal.sh <bin> <dir> direct` once). A fake inside the service (MWOYEO_FAKE_READER) makes the
# service exit, so the host meets a dying worker on a healthy Mac.
#   usage: host-gates.sh <Mwoyeo binary> [crash crash-m]        (default: crash; the Bash sandbox off)
#   env:   PNGS   the use-case pictures (default /Users/hckim/.cache/mwoyeo-gates/usecases/set)
#          OUT    where everything goes (default /tmp/host-gates/<stamp>)
#
# WHERE THE OLD GATES WENT (Core/Tests/MwoyeoCoreTests/ReaderHostTests.swift, `cd Core && swift test --filter ReaderHostTests`, ~25 ms;
# the host's decisions run on a fake clock and fake services that take the same MWOYEO_FAKE_READER spec strings):
#   g1  docs-slow:40000 -> aSlowDocsIsWaitedForSecondsThenTheReadGoesToLines (silence 2.3 s, reroute, Docs never cancelled)
#   g1m MWOYEO_DOCS_WAIT=1 -> waitingForDocsHoweverLongFailsTheSilenceAssertion (silence 40.4 s: the same instrument sees the wait)
#   g2  lines-slow:40000 -> aLinesThatIsWarmingForJapaneseSaysPreparingAtOnce... (the shell run: warm-up in flight, hint at 0 s) and
#                           aLinesThatTakes40sForJapaneseSaysPreparingAtSAndReads... (no warm-up: hint at S = 3.0 s); one read, no timer
#   g3  lines-e5rt:40 -> theRevThreeRungRestsOnTheBackoffAndTheLensIsFilledMeanwhile (rests 1 2 4 8 16 30, 6 errors a minute at most)
#   g4  crash -> aServiceThatDiesOnItsFirstJobIsRestartedAfterTheBackoff (+ the warm-up variants): the policy half of this smoke
# The shipped durations are ReaderTiming.standard (pinned in ReaderTimingTests); this smoke runs the real services with a scaled-down
# restart (MWOYEO_READER_TIMING=restart=0.2/1, a non-MAS build) so that it takes seconds, not the 1 s backoff plus launchd's start.
#
# FAILURE MODE IT BLOCKS
#   crash   The Lines service exits on its first job. What only a real process shows: the connection is interrupted and the host
#           learns of it, the render completes with blocks > 0 (Docs' `.fast` reads meanwhile), one crash is counted, the host
#           restarts the service after Backoff.workerRestart (`reader usable again`, within 0.6 s of the crash with the scaled
#           0.2 s: the injected duration reached the real host), and the whole smoke takes under 20 s.
#   crash-m FAIL-first of the restart-time check: the same run without MWOYEO_READER_TIMING waits the shipped 1 s, and the check
#           `usable again within 0.6 s` must FAIL. A smoke whose timing check this does not break measures nothing.
set -u
BIN=${1:?usage: host-gates.sh <Mwoyeo binary> [crash crash-m]}; shift
GATES=${*:-crash}
PNGS=${PNGS:-/Users/hckim/.cache/mwoyeo-gates/usecases/set}
OUT=${OUT:-/tmp/host-gates/$(date +%Y%m%d-%H%M%S)}
LIMIT_S=20
ANE=$(cd "$(dirname "$0")/.." && pwd)/ane-env.sh
mkdir -p "$OUT"
fail=0
say() { echo "$@" | tee -a "$OUT/summary.txt"; }
check() {   # name, 0|1 (1 = ok), detail
    if [ "$2" = 1 ]; then say "PASS $1 $3"; else say "FAIL $1 $3"; fail=1; fi
}
# One render: gate name, extra env (K=V …) in ENVS, the picture, then the arguments of --render after the output path.
run() {
    local g=$1 pic=$2; shift 2
    mkdir -p "$OUT/$g"
    date '+%Y-%m-%d %H:%M:%S' > "$OUT/$g/start.txt"
    env MWOYEO_MEMORY_SECRETS=1 MWOYEO_SETTINGS_FILE="$OUT/$g/s.json" MWOYEO_DEFAULTS_SUITE=hostgates.$g MWOYEO_TRACE=1 "${ENVS[@]}" \
        "$ANE" run pool -- "$BIN" --render "$pic" "$OUT/$g/out.png" "$@" > "$OUT/$g/render.out" 2> "$OUT/$g/render.err" < /dev/null
    echo $? > "$OUT/$g/rc"
}
logfor() { /usr/bin/log show --start "$(cat "$OUT/$1/start.txt")" --predicate 'subsystem == "dev.midagedev.mwoyeo" AND category == "reader"' --info --style compact 2>/dev/null; }
# Seconds of day of the first log line that contains $2 (millisecond stamps: `2026-10-19 12:34:56.789 …`).
stamp() { logfor "$1" | grep -m1 "$2" | awk '{split($2, t, ":"); printf "%.3f", t[1]*3600 + t[2]*60 + t[3]}'; }

smoke() {   # crash | crash-m
    local g=$1
    if [ "$g" = crash-m ]; then ENVS=(MWOYEO_FAKE_READER=crash); else ENVS=(MWOYEO_FAKE_READER=crash MWOYEO_READER_TIMING=restart=0.2/1); fi
    local t0=$(date +%s)
    run "$g" "$PNGS/c01-slack-en.png" --src en --tgt ko --mode adaptive --max-wait 60
    local wall=$(( $(date +%s) - t0 ))
    check "$g render exits 0" $([ "$(cat "$OUT/$g/rc")" = 0 ] && echo 1 || echo 0) "rc=$(cat "$OUT/$g/rc")"
    check "$g one crash counted, blocks > 0" $(grep -q 'reader\.lines\.crash=1' "$OUT/$g/render.out" && grep -q 'ocr\.blocks=[1-9]' "$OUT/$g/render.out" && echo 1 || echo 0) "$(grep -o 'reader\.lines\.crash=[0-9]*\|ocr\.blocks=[0-9]*' "$OUT/$g/render.out" | head -2 | tr '\n' ' ')"
    local died usable gap
    died=$(stamp "$g" 'reader service crashed role=lines'); usable=$(stamp "$g" 'reader usable again role=lines')
    check "$g the service was usable again after its backoff" $([ -n "$died" ] && [ -n "$usable" ] && echo 1 || echo 0) "crashed at ${died:-n/a}, usable at ${usable:-n/a}"
    gap=$(awk -v a="${died:-0}" -v b="${usable:-0}" 'BEGIN { printf "%.3f", b - a }')
    local fast=$(awk -v g="$gap" -v d="${died:-0}" -v u="${usable:-0}" 'BEGIN { print (d > 0 && u > 0 && g >= 0.15 && g < 0.6) ? 1 : 0 }')
    check "$g usable again within 0.6 s of the crash (the scaled restart reached the host)" "$fast" "gap=$gap s"
    check "$g smoke wall <= $LIMIT_S s" $([ "$wall" -le $LIMIT_S ] && echo 1 || echo 0) "wall=$wall s"
}

for g in $GATES; do
    case $g in
    crash) smoke crash ;;
    crash-m)
        before=$fail
        smoke crash-m
        # The FAIL-first is the point: the unscaled run must fail the timing check (and only it), and that failure is this gate's PASS.
        expected=$(grep -c '^FAIL crash-m usable again within 0.6 s' "$OUT/summary.txt")
        others=$(grep '^FAIL crash-m' "$OUT/summary.txt" | grep -vc 'usable again within 0.6 s')
        sed -i.bak '/^FAIL crash-m usable again within 0.6 s/s/^FAIL/EXPECTED-FAIL/' "$OUT/summary.txt"; rm -f "$OUT/summary.txt.bak"
        if [ "$expected" = 1 ] && [ "$others" = 0 ]; then
            fail=$before; say "PASS crash-m (FAIL-first): the timing check fails on the shipped 1 s restart"
        else
            fail=1; say "FAIL crash-m: the timing check must fail alone on the shipped restart (failed: $expected, others: $others)"
        fi
        ;;
    *) say "unknown gate $g"; fail=1 ;;
    esac
done
say "$([ $fail = 0 ] && echo 'host-gates: all PASS' || echo 'host-gates: FAIL')"
exit $fail
