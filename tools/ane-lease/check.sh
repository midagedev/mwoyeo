#!/bin/bash
# Gate of tools/ane-env.sh (the dev ANE lease, cache seeding, id pool and disk floor) and tools/ane-census. Seconds, no real compile:
# every run here starts a dummy "app" (a script under a fake Contents/MacOS with its own Info.plist) against a scratch cache root
# (ANE_CACHE_ROOT) and a scratch lock (ANE_LOCK); the user's caches and the shared lease are never touched.
#   usage: check.sh            env: TOOLS=<a tools dir>  (default: this tree's; the FAIL-first points it at main's, which has none)
#                                   OUT=<scratch dir>    (default /tmp/ane-dev/check)
# FAILURE MODES IT BLOCKS
#   (i)   a script starts the app without the helper: its cold start queues in the system's one compile lane beside every other round's
#         (2026-10-19 22:01-22:20), or picks a fresh id by hand and compiles the same networks again. The lint reads the ten scripts that
#         start Mwoyeo; each is also broken on a scratch copy (the helper stripped) and the lint must flag the copy.
#   (ii)  two cold starts at once: three holders started together never overlap; with ANE_LEASE=off they do (the instrument sees it).
#   (iii) a compile on a nearly full disk fails and retries every 40-55 s: below the floor the run is refused with one line.
#   (iv)  the helper writes where it must not: it only reads the cache root (E4 2026-10-20: seeding a fresh id with a warm id's cache
#         removed no compile, so there is none) and gives ids: pool<N> is stable, cold ids are fresh.
#   (v)   the census numbers the lead reads incident times from: a synthetic service log with known busy seconds.
# One PASS/FAIL line per check; exit 0 when all pass.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
TOOLS=${TOOLS:-$(cd "$HERE/.." && pwd)}
ANE=$TOOLS/ane-env.sh
S=${OUT:-/tmp/ane-dev/check}
rm -rf "$S"; mkdir -p "$S"
fail=0
say() { echo "$@" | tee -a "$S/summary.txt"; }
check() {   # name, 0|1 (1 = ok), detail
    if [ "$2" = 1 ]; then say "PASS $1 $3"; else say "FAIL $1 $3"; fail=1; fi
}

SCRIPTS="ocr-probe/healthy.sh ocr-probe/reader-cold.sh ocr-probe/host-gates.sh ocr-probe/reader-equal.sh ocr-probe/relaunch-cold.sh
ocr-probe/trace-render.sh paper-bench/run.sh usecase-bench/bench.sh app-store/previews/take.sh app-store/screenshots/render.sh"

# (i) lint. A logical line (continuations joined, comments dropped) that starts the app must go through `"$ANE" run <kind> --`; a
# script that names MWOYEO_APP_ID must take the id from `"$ANE" id`; every wired script defines ANE.
lint() {   # file -> prints one line per violation
    awk '
        /^[ \t]*#/ { next }
        { line = $0; while (line ~ /\\$/) { sub(/\\$/, "", line); if ((getline nxt) <= 0) break; line = line nxt }
          if (line ~ /[ \t](--render|--capture-ui|--reader-check|--add-region)[ \t]/ && line !~ /"\$ANE" run (pool|cold) -- /) print "starts the app without the helper: " substr(line, 1, 90)
          if (line ~ /MWOYEO_APP_ID=/) idline = line }
        /"\$ANE" id/ { id = 1 }
        END { if (idline != "" && !id) print "names MWOYEO_APP_ID without `\"$ANE\" id`: " substr(idline, 1, 90) }
    ' "$1"
    grep -qE '(^|[ ;])ANE=' "$1" || echo "no ANE= line"
}
lint_all() {   # dir -> number of violations; the lines go to $S/lint.txt
    local f n=0 v
    : > "$S/lint.txt"
    for f in $SCRIPTS; do
        v=$(lint "$1/$f" 2>&1) || true
        [ -z "$v" ] && continue
        echo "$f: $v" >> "$S/lint.txt"; n=$((n + $(echo "$v" | wc -l)))
    done
    echo $n
}
n=$(lint_all "$TOOLS")
check "(i) lint: ten scripts start the app through the helper" $([ "$n" = 0 ] && echo 1 || echo 0) "violations=$n $(head -1 "$S/lint.txt" | cut -c1-120)"
m=0; broken=0
for f in $SCRIPTS; do
    [ -f "$TOOLS/$f" ] && [ -z "$(lint "$TOOLS/$f")" ] || continue
    mkdir -p "$S/mut/$(dirname "$f")"
    sed 's/"\$ANE" run [a-z]* -- //g; s/"\$ANE" id [a-z]*/echo x/g' "$TOOLS/$f" > "$S/mut/$f"
    m=$((m + 1)); [ -n "$(lint "$S/mut/$f")" ] && broken=$((broken + 1))
done
check "(i) lint: every clean script, copied with the helper stripped, is flagged" $([ "$m" = 10 ] && [ "$broken" = "$m" ] && echo 1 || echo 0) "flagged $broken of $m clean scripts"

# A dummy app: Contents/MacOS/dummy appends BEGIN/END to $LOG around a fixed work loop (no sleep, no clock), Info.plist names its id.
mkapp() {   # name id -> path of the dummy under */Contents/MacOS/
    local d=$S/$1/Contents
    mkdir -p "$d/MacOS"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>%s</string></dict></plist>\n' "$2" > "$d/Info.plist"
    cat > "$d/MacOS/dummy" <<'EOF'
#!/bin/bash
echo "BEGIN $1 $(date +%s)" >> "$LOG"
i=0; while [ $i -lt 150000 ]; do i=$((i + 1)); done
echo "END $1 $(date +%s)" >> "$LOG"
EOF
    chmod +x "$d/MacOS/dummy"
    echo "$d/MacOS/dummy"
}
export ANE_CACHE_ROOT=$S/caches ANE_LOCK=$S/lock FREE_KB=20971520
W=dev.midagedev.mwoyeo.pool1   # a warm pool member, the one entry the cache root starts with; no helper run below may add another
mkdir -p "$ANE_CACHE_ROOT/$W/com.apple.e5rt.e5bundlecache/26A428/KEY1"
echo one > "$ANE_CACHE_ROOT/$W/com.apple.e5rt.e5bundlecache/26A428/KEY1/x.bundle"
before=$(find "$ANE_CACHE_ROOT" | sort | tr '\n' ' ')
overlaps() {   # log -> BEGINs that came while another run was open
    awk '$1 == "BEGIN" { if (open > 0) o++; open++ } $1 == "END" { open-- } END { print o + 0 }' "$1"
}
three() {   # three holders started at once on three fresh ids (each cache missing, so the lease engages); prints the overlap count
    local k pids= log=$S/overlap-$1.log
    : > "$log"
    for k in a b c; do
        LOG=$log "$ANE" run cold -- "$(mkapp app-$1-$k dev.midagedev.mwoyeo.gate-$1-$k)" "$k" 2> "$S/lease-$1-$k.err" &
        pids="$pids $!"
    done
    wait $pids
    overlaps "$log"
}
# (ii)
on=$(three on); ln=$(cat "$S"/lease-on-?.err | grep -c '^ane-lease: \(wait\|held\) [0-9.]* s$')
check "(ii) lease: three holders started at once never overlap" $([ -x "$ANE" ] && [ "$on" = 0 ] && [ "$ln" = 6 ] && echo 1 || echo 0) "overlap=$on lease-lines=$ln/6 $(head -1 "$S/lease-on-a.err")"
off=$(ANE_LEASE=off three off)
check "(ii) lease: with ANE_LEASE=off they overlap (FAIL-first of the lock)" $([ -x "$ANE" ] && [ "$off" -ge 1 ] && echo 1 || echo 0) "overlap=$off"

# (ii) a pool run takes the lease only when its caches hold no bundle: a warm id (a bundle in .reader.lines only: a warm id has no app cache
# and a lines-only id no docs cache) passes through, a fresh one takes it
lease_lines() {   # root id -> number of `ane-lease:` lines the pool run printed
    LOG=$S/pool.log ANE_CACHE_ROOT=$1 "$ANE" run pool -- "$(mkapp "pool-$2" "$2")" "$2" 2>&1 >/dev/null | grep -c '^ane-lease:'
}
mkdir -p "$S/caches-lease/dev.midagedev.mwoyeo.gate-warm.reader.lines/com.apple.e5rt.e5bundlecache/26A428/K"
touch "$S/caches-lease/dev.midagedev.mwoyeo.gate-warm.reader.lines/com.apple.e5rt.e5bundlecache/26A428/K/N.bundle"
mkdir -p "$S/caches-lease/dev.midagedev.mwoyeo.gate-half.reader.lines/com.apple.e5rt.e5bundlecache/26A428/K"
touch "$S/caches-lease/dev.midagedev.mwoyeo.gate-half.reader.lines/com.apple.e5rt.e5bundlecache/26A428/K/N.tmp.9_9.bundle"
w=$(lease_lines "$S/caches-lease" dev.midagedev.mwoyeo.gate-warm); f=$(lease_lines "$S/caches-lease" dev.midagedev.mwoyeo.gate-fresh); h=$(lease_lines "$S/caches-lease" dev.midagedev.mwoyeo.gate-half)
check "(ii) lease: a pool run leases a fresh id (or one with only an aborted .tmp bundle), not a warm one" $([ -x "$ANE" ] && [ "$w" = 0 ] && [ "$f" = 2 ] && [ "$h" = 2 ] && echo 1 || echo 0) "warm-lease-lines=$w fresh=$f aborted-only=$h"

# (iii) disk floor
app=$(mkapp disk dev.midagedev.mwoyeo.gate-disk)
msg=$(FREE_KB=4194304 LOG=$S/disk.log "$ANE" run pool -- "$app" disk 2>&1); rc=$?
check "(iii) disk: 4 GiB free is refused with one line" $([ -x "$ANE" ] && [ "$rc" != 0 ] && [ "$(echo "$msg" | wc -l | tr -d ' ')" = 1 ] && echo "$msg" | grep -q 'floor is 8 GiB' && [ ! -s "$S/disk.log" ] && echo 1 || echo 0) "rc=$rc $msg"
msg=$(FREE_KB=20971520 LOG=$S/disk.log "$ANE" run pool -- "$app" disk 2>&1); rc=$?
check "(iii) disk: 20 GiB free starts the command" $([ -x "$ANE" ] && [ "$rc" = 0 ] && grep -q '^END disk' "$S/disk.log" 2>/dev/null && echo 1 || echo 0) "rc=$rc"

# (iv) the cache root is only read: every run above and these (a pool and a cold run on fresh ids, the user's own id) created no cache dir
for id in dev.midagedev.mwoyeo.gate-seed dev.midagedev.mwoyeo; do
    LOG=$S/seed.log "$ANE" run pool -- "$(mkapp "seed-$id" "$id")" "$id" > /dev/null 2>&1
done
LOG=$S/seed.log "$ANE" run cold -- "$(mkapp seed-cold dev.midagedev.mwoyeo.gate-cold)" cold > /dev/null 2>&1
after=$(find "$ANE_CACHE_ROOT" | sort | tr '\n' ' ')
check "(iv) cache root: pool, cold and the user's own id runs write nothing under it (a warm pool member stays the only entry)" $([ -x "$ANE" ] && [ -f "$S/seed-dev.midagedev.mwoyeo.gate-seed/Contents/Info.plist" ] && [ "$(grep -c '^END' "$S/seed.log")" = 3 ] && [ "$before" = "$after" ] && echo 1 || echo 0) "ran=$(grep -c '^END' "$S/seed.log" 2>/dev/null) entries before=$(echo "$before" | wc -w | tr -d ' ') after=$(echo "$after" | wc -w | tr -d ' ')"
id1=$(ANE_SLOT= "$ANE" id pool 2>/dev/null); id2=$("$ANE" id cold 2>/dev/null); id3=$("$ANE" id cold 2>/dev/null)
check "(iv) ids: pool<N> is stable, cold ids are fresh each call" $([ -x "$ANE" ] && echo "$id1" | grep -q '^dev\.midagedev\.mwoyeo\.pool[1-4]$' && [ "$id1" = "$("$ANE" id pool)" ] && [ "$id2" != "$id3" ] && echo "$id2" | grep -q '^dev\.midagedev\.mwoyeo\.cold[0-9a-f]*$' && echo 1 || echo 0) "pool=$id1 cold=$id2 $id3"

# (v) census
CENSUS=$TOOLS/ane-census/census.py
cat > "$S/svc.log" <<'EOF'
2026-10-19 10:00:00.000 Df ANECompilerService[100:a1] (ANECompiler) Start of compilation of network from file: <private>
2026-10-19 10:00:00.500 Df ANECompilerService[100:a1] (ANECompiler) Dram Required for procedure <private> is 4096
2026-10-19 10:00:00.600 Df ANECompilerService[100:a1] (ANECompiler) Dram Required for procedure <private> is 8192
2026-10-19 10:00:30.000 Df ANECompilerService[100:a1] (ANECompiler) End of compilation of network from file: <private>
2026-10-19 10:00:40.000 Df ANECompilerService[100:a1] (ANECompiler) Start of compilation of network from file: <private>
2026-10-19 10:01:00.000 Df ANECompilerService[100:a1] (ANECompiler) End of compilation of network from file: <private>
2026-10-19 11:00:00.000 Df ANECompilerService[100:a1] (ANECompiler) Start of compilation of network from file: <private>
2026-10-19 11:00:10.000 Df ANECompilerService[100:a1] (ANECompiler) End of compilation of network from file: <private>
2026-10-19 11:30:00.000 Df ANECompilerService[200:b1] (ANECompiler) Start of compilation of network from file: <private>
EOF
out=$(python3 -I "$CENSUS" net "$S/svc.log" 2>&1)
check "(v) census net: 3 networks, 60 s busy, 2 bursts, the unfinished one named" $([ -f "$CENSUS" ] && echo "$out" | grep -q 'pid 100: 3 networks, busy 60 s' && echo "$out" | grep -q 'n=2 busy=50 s' && echo "$out" | grep -q "unfinished.*'200'" && echo 1 || echo 0) "$(echo "$out" | grep 'pid 100' | head -1)"
mkdir -p "$S/cc/dev.midagedev.mwoyeo.tmpa/com.apple.e5rt.e5bundlecache/26A428/K" "$S/cc/dev.midagedev.mwoyeo.tmpb.reader.lines/com.apple.e5rt.e5bundlecache/26A428/K"
touch "$S/cc/dev.midagedev.mwoyeo.tmpa/com.apple.e5rt.e5bundlecache/26A428/K/ABC.bundle" "$S/cc/dev.midagedev.mwoyeo.tmpa/com.apple.e5rt.e5bundlecache/26A428/K/ABC.tmp.4242_99.bundle"
out=$(python3 -I "$CENSUS" tmp "$S/cc" 2>&1)
check "(v) census tmp: the leftover is listed with its pid" $([ -f "$CENSUS" ] && echo "$out" | grep -q 'pid 4242' && echo 1 || echo 0) "$(echo "$out" | head -1)"
out=$(python3 -I "$CENSUS" caches "$S/cc" 2>&1)
check "(v) census caches: bundles per id" $([ -f "$CENSUS" ] && echo "$out" | grep -q 'dev.midagedev.mwoyeo.tmpa .*bundles=1' && echo 1 || echo 0) "$(echo "$out" | head -2 | tr '\n' ';')"
printf 'Date/Time:        2026-10-19 22:01:33.946 +0900\nPID:              95258\nCommand:          ANECompilerService\nEvent:            cpu usage\nCPU:              90 seconds cpu time over 108 seconds (83%% cpu average), exceeding limit of 50%% cpu over 180 seconds\nOn Behalf Of:     12 samples UNKNOWN [52941]\n' > "$S/x.cpu_resource.diag"
out=$(python3 -I "$CENSUS" diag "$S/x.cpu_resource.diag" 2>&1)
check "(v) census diag: header fields" $([ -f "$CENSUS" ] && echo "$out" | grep -q '95258' && echo "$out" | grep -q '90 seconds cpu time over 108' && echo 1 || echo 0) "$(echo "$out" | head -1 | cut -c1-120)"

say "ane-lease: $([ $fail = 0 ] && echo 'all PASS' || echo 'FAIL')"
exit $fail
