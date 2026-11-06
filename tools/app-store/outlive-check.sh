#!/bin/zsh
# App Review 2.4.5(iii) (rejection of 1.1.9 (708), 2026-11-05): "The app spawns processes that continue running after the user has quit
# the app" — MwoyeoReader-lines and MwoyeoReader-docs. This runs the app's own checks that start its worker services, lets the app exit,
# and fails when any process of the app's XPCServices is alive WAIT_S seconds later.
#   usage: outlive-check.sh <Mwoyeo.app>          (the Bash sandbox off; a build with a scratch MWOYEO_APP_ID)
#
# FAILURE MODE IT BLOCKS
#   A worker service that turns off automatic and sudden termination (Reader/main.swift, Script/main.swift) and is never told the app is
#   gone: it stays, parented to launchd, after the app quits. FAIL-first, 2026-11-06 on f81478c: `--reader-check hello` exited and both
#   readers (ppid 1) were alive 3 s later. The fix is Core ServiceLifetime (exit 1 s after the last connection; ServiceLifetimeTests).
#   The script service is started by `--capture-ui <dir> rewrite-checks`.
set -u
APP=${1:?usage: outlive-check.sh <Mwoyeo.app>}
BIN=$APP/Contents/MacOS/Mwoyeo
SERVICES=$APP/Contents/XPCServices
WAIT_S=${WAIT_S:-3}
OUT=${OUT:-${TMPDIR:-/tmp}/outlive-check}
mkdir -p "$OUT"
fail=0

alive() {   # the pids of processes whose executable is inside this app's XPCServices
    ps -axo pid=,comm= | awk -v dir="$SERVICES/" 'index($2, dir) == 1 { print $1 }'
}

run() {   # name, args…
    local name=$1; shift
    "$BIN" "$@" > "$OUT/$name.out" 2> "$OUT/$name.err" < /dev/null
    local rc=$?
    sleep "$WAIT_S"
    local left=($(alive))
    if [ ${#left[@]} -eq 0 ]; then
        echo "PASS $name rc=$rc: no service alive ${WAIT_S}s after the app exited"
    else
        echo "FAIL $name rc=$rc: alive ${WAIT_S}s after the app exited:"
        for p in $left; do ps -o pid=,ppid=,etime=,comm= -p $p; done
        fail=1
        kill $left 2> /dev/null
    fi
}

before=($(alive))
[ ${#before[@]} -eq 0 ] || { echo "FAIL services of this app already run before the check: $before"; exit 1; }
run readers --reader-check hello
run script --capture-ui "$OUT/capture" rewrite-checks
exit $fail
