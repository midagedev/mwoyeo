#!/bin/bash
# The decisive cold test of the reader services (docs/design/recognition.md §1, §6; r3-docs-xpc 2026-10-18, r3a-host-lines 2026-10-19).
#
# FAILURE MODE IT BLOCKS: a document read compiles in the GUI process, or a lens goes silent behind it. On a figure page the first
# document read compiles two networks (34 s + 26 s on p13) and every Vision request of the process that compiles them waits: in the
# GUI the lens was silent for ~90 s (ocr-stall-112). The reader must take the read in the Docs service, read with VN meanwhile, and
# never leave the lens silent for more than N = 8 s.
#
# NOT PER LANDING (g2-fast-host-gates, 2026-10-19). Its wall is real work, not policy waits: the build of a fresh id, then the cold
# compiles of the Lines service (rev3, ~65 s), the Docs service (~85 s) and, on p13, the figure page's two networks (~60 s), 5-8 min
# on a quiet Mac. The policy it used to carry along (no silence over 8 s behind a slow Docs, the preparing hint after S, the rest of a
# rung or a restart) is Core unit tests now (`cd Core && swift test --filter ReaderHostTests`, a fake clock, milliseconds). What only
# this script shows, and is kept: that NO network compiles in the GUI process (the GUI's e5rt cache stays empty from a fresh id on),
# that the services' caches gain the entries, and that nothing is aborted (drain, no new .tmp). Run it when a change touches which
# process reads (App/Reader/, Reader/, Shared/VisionExec.swift, TextRecognizer), never for a change of policy. Its silence and hint
# asserts stay: they are measured in the same run and cost nothing more.
#
#   usage: reader-cold.sh [p13]                      (a page of $PAGES; default p13, the figure page that compiles both networks)
#          reader-cold.sh ja[:<picture>]             (the ja variant: a use-case picture of $PNGS, default d02-timetable-ja, read on a
#                                                     fresh id: rev3 for ja compiles in the Lines service and the lens must say
#                                                     `hint: preparingRecognition` within 3500 ms and never be silent for more than 8 s)
#   env:   SRC    the tree to build and test         (default: this repository; the FAIL-first run points it at a tree before the change)
#          OUT    where everything goes              (default /tmp/reader-cold/<stamp>)
#          DD     derived data of the build          (default $OUT/dd; reuse one to make the next run's build incremental)
#          PAGES  the paper pages p<N>.png           (default /tmp/paper-quality/paper)
#          PNGS   the use-case pictures              (default /Users/hckim/.cache/mwoyeo-gates/usecases/set)
#          BIN    skip the build, use this binary    (it must be built with MWOYEO_APP_ID=$ID, ID given as well)
#          ID     the bundle id (default fresh: `tools/ane-env.sh id cold`)
#          WARM   "--warm" (default) or empty: see step 3
# Needs the Bash sandbox off (the Neural Engine, headless --render). Every launch is `ane-env.sh run cold`: no cache seeding (the empty
# cache is the point) and the Neural Engine lease, so no other leased cold start compiles in the one lane meanwhile.
#
# 1. Builds the app AND its two services with a fresh id (`xcodebuild … MWOYEO_APP_ID=<id>`, the services become <id>.reader.lines
#    and <id>.reader.docs): each has its own e5rt cache under ~/Library/Caches/<that id>/, all empty. No copied bundle is re-signed.
# 2. Warms what a user has after the first launch: revision 3 in the Lines service and the document model in the Docs service, on
#    the drawn probe picture only (`--capture-ui vision-reads`). This does not compile the networks of a figure page (ocr-stall-112, F4).
# 3. Renders the page in `--mode adaptive` (what a lens runs) and waits for Docs to be ready, then reads again:
#      --render <page> --src en --tgt ko --mode adaptive --max-wait 600 --warm --then reader-ready,again
#    `--warm` makes the pass start after the warm-up, as a lens started long after launch finds Docs: warm for the key, idle, and cold
#    for this page's networks, so the read is SENT and the lens waits S before it reads with VN. Without it (WARM= empty) the first
#    pass races the warm-up and finds Docs still warming, which falls back at once (a gentler case, also silent for no more than N).
# 4. Prints and asserts:
#      silence: longest <= 8000 ms                                  (the lens is never silent for more than N)
#      the GUI's e5rt cache has no entry, from the fresh id on      (neither a document nor a text network compiled in this process)
#      the Lines service's cache gained entries (the warm-up), and the Docs service's (the figure page's networks; p13 only)
#      reader-ready: <ms>                                           (not a timeout)
#      work[again] ocr.blocks.swift >= 1, work[still] has none      (a doc-path read after Docs was ready; the first pass was VN)
#      drain: ... in-flight=0, and no new .tmp entry in any cache   (nothing was aborted)
# Exit 0 when every assertion holds. On a tree where documents are read in the GUI process it prints FAIL silence (~90 s).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=${SRC:-$(cd "$HERE/../.." && pwd)}
PAGE=${1:-p13}
JA=0; PIC=
case $PAGE in ja|ja:*) JA=1; PIC=${PAGE#ja}; PIC=${PIC#:}; PIC=${PIC:-d02-timetable-ja} ;; esac
PNGS=${PNGS:-/Users/hckim/.cache/mwoyeo-gates/usecases/set}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${OUT:-/tmp/reader-cold/$STAMP}
ANE=$HERE/../ane-env.sh
ID=${ID:-$("$ANE" id cold)}
PAGES=${PAGES:-/tmp/paper-quality/paper}
DD=${DD:-$OUT/dd}
LIMIT=8000
mkdir -p "$OUT"
fail=0
say() { echo "$@" | tee -a "$OUT/summary.txt"; }
check() {   # name, 0|1 (1 = ok), detail
    if [ "$2" = 1 ]; then say "PASS $1 $3"; else say "FAIL $1 $3"; fail=1; fi
}
bundles() { find "$1" -name '*.bundle' 2>/dev/null | wc -l | tr -d ' '; }
tmps() { find "$1" -name '*.tmp' 2>/dev/null | wc -l | tr -d ' '; }
caches=("$HOME/Library/Caches/$ID/com.apple.e5rt.e5bundlecache" "$HOME/Library/Caches/$ID.reader.docs/com.apple.e5rt.e5bundlecache" "$HOME/Library/Caches/$ID.reader.lines/com.apple.e5rt.e5bundlecache")
fp() { footprint -p "$1" 2>/dev/null | sed -n 's/.*Footprint: \([0-9.]*\) \([KMG]B\).*/\1 \2/p' | head -1 | awk '{v=$1; if ($2=="KB") v/=1024; else if ($2=="GB") v*=1024; printf "%.0f", v}'; }
snapshot() { echo "gui=$(bundles "${caches[0]}") docs=$(bundles "${caches[1]}") lines=$(bundles "${caches[2]}") tmp=$(( $(tmps "${caches[0]}") + $(tmps "${caches[1]}") + $(tmps "${caches[2]}") ))"; }

say "reader-cold: tree=$SRC page=$PAGE id=$ID out=$OUT"
if [ -z "${BIN:-}" ]; then
    # A fresh id changes the plist and the signature only: with a derived data dir that exists, the build is a link and a sign.
    ( cd "$SRC" && xcodegen generate > "$OUT/gen.log" 2>&1 ) || { say "FAIL xcodegen"; exit 2; }
    ( cd "$SRC" && xcodebuild -scheme Mwoyeo -configuration Release -destination 'platform=macOS' -derivedDataPath "$DD" MWOYEO_APP_ID="$ID" build > "$OUT/build.log" 2>&1 )
    rc=$?
    say "build: rc=$rc (xcodebuild MWOYEO_APP_ID, services <id>.reader.lines|docs)"
    [ $rc = 0 ] || exit 2
    BIN="$DD/Build/Products/Release/Mwoyeo.app/Contents/MacOS/Mwoyeo"
fi
APP=${BIN%/Contents/MacOS/*}
for s in lines docs; do
    got=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/XPCServices/MwoyeoReader-$s.xpc/Contents/Info.plist" 2>/dev/null)
    [ "$got" = "$ID.reader.$s" ] || { say "FAIL service id: MwoyeoReader-$s is '$got', wanted $ID.reader.$s"; exit 2; }
done
say "caches: gui=${caches[0]}"
say "        docs service=${caches[1]}"
say "        lines service=${caches[2]}"

export MWOYEO_MEMORY_SECRETS=1 MWOYEO_SETTINGS_FILE="$OUT/s.json" MWOYEO_DEFAULTS_SUITE=readercold.test MWOYEO_TRACE=1
# Banned by the contract: killing a process that is loading. This script only waits for its own children.
fresh=$(snapshot); say "cache fresh:  $fresh"
t0=$(date +%s)
"$ANE" run cold -- "$BIN" --capture-ui "$OUT/capW" vision-reads --src en --for 900 > "$OUT/warm.out" 2> "$OUT/warm.err" < /dev/null &
pid=$!
wait $pid; rc=$?
say "warm-up: rc=$rc $(( $(date +%s) - t0 )) s ($(grep -c 'read ' "$OUT/warm.out") probe reads) $(grep 'vision-reads: end' "$OUT/warm.out" | sed 's/^\[ *[0-9.]*\] //')"
before=$(snapshot); say "cache before: $before"

export MWOYEO_TRACE_READS=1
t0=$(date +%s)
if [ $JA = 1 ]; then
    "$ANE" run cold -- "$BIN" --render "$PNGS/$PIC.png" "$OUT/$PIC.png" --src ja --tgt ko --mode adaptive --max-wait 600 --then reader-ready > "$OUT/render.out" 2> "$OUT/render.err" < /dev/null &
else
    "$ANE" run cold -- "$BIN" --render "$PAGES/$PAGE.png" "$OUT/$PAGE.png" --src en --tgt ko --mode adaptive --max-wait 600 ${WARM---warm} --then reader-ready,again > "$OUT/render.out" 2> "$OUT/render.err" < /dev/null &
fi
pid=$!
echo $pid > "$OUT/render.pid"
# Footprint (MB, footprint -p) of the app and of the Docs service every 3 s: numbers for the report, not an assertion. (The app is the
# child of the lease's parent process when ane-env.sh holds the lease, else the pid itself.)
( while kill -0 $pid 2>/dev/null; do
      kid=$(pgrep -P $pid); echo "gui $(fp "${kid:-$pid}")" >> "$OUT/footprint.txt"
      dp=$(sed -n 's/^reader: docs pid=\([0-9]*\) .*/\1/p' "$OUT/render.out" | head -1)
      [ -n "$dp" ] && echo "docs $(fp "$dp")" >> "$OUT/footprint.txt"
      sleep 3
  done ) &
sampler=$!
wait $pid; rc=$?
wait $sampler 2>/dev/null
say "render: rc=$rc $(( $(date +%s) - t0 )) s"
for who in gui docs; do
    v=$(awk -v w=$who '$1==w && $2!="" {print $2}' "$OUT/footprint.txt" 2>/dev/null)
    [ -n "$v" ] && say "footprint $who (MB, footprint -p): first $(echo "$v" | head -1), max $(echo "$v" | sort -n | tail -1), last $(echo "$v" | tail -1)"
done
after=$(snapshot); say "cache after:  $after"
grep -E '^(hint:|silence:|drain:|reader-ready:|reader: (docs|lines) state)' "$OUT/render.out" | while read -r line; do say "  $line"; done

num() { echo "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }
longest=$(sed -n 's/^silence: longest=\([0-9]*\).*/\1/p' "$OUT/render.out" | head -1)
check "render exits 0" $([ "$rc" = 0 ] && echo 1 || echo 0) "rc=$rc"
check "silence: longest <= $LIMIT" $([ -n "$longest" ] && [ "$longest" -le $LIMIT ] && echo 1 || echo 0) "longest=${longest:-n/a} ms"
check "the GUI's e5rt cache has no entry (no network compiled in this process)" $([ "$(num "$fresh" gui)" = 0 ] && [ "$(num "$before" gui)" = 0 ] && [ "$(num "$after" gui)" = 0 ] && echo 1 || echo 0) "gui $(num "$fresh" gui) -> $(num "$before" gui) -> $(num "$after" gui)"
check "the Lines service compiled the text network (its cache gained entries)" $([ "$(num "$after" lines)" -gt "$(num "$fresh" lines)" ] && echo 1 || echo 0) "lines service $(num "$fresh" lines) -> $(num "$before" lines) -> $(num "$after" lines), in ${caches[2]}"
check "drain: in-flight=0" $(grep -q '^drain: [0-9]* in-flight=0$' "$OUT/render.out" && echo 1 || echo 0) "$(grep '^drain:' "$OUT/render.out")"
check "no new .tmp entry in any cache" $([ "$(num "$before" tmp)" = "$(num "$after" tmp)" ] && echo 1 || echo 0) "tmp $(num "$before" tmp) -> $(num "$after" tmp)"
ready=$(sed -n 's/^reader-ready: \([0-9]*\)$/\1/p' "$OUT/render.out" | head -1)
check "reader-ready came (no timeout)" $([ -n "$ready" ] && echo 1 || echo 0) "reader-ready=${ready:-$(grep '^reader-ready:' "$OUT/render.out" | head -1)} ms"
if [ $JA = 1 ]; then
    prep=$(sed -n 's/^hint: preparingRecognition at \([0-9]*\)$/\1/p' "$OUT/render.out" | head -1)
    check "ja: hint preparingRecognition at <= 3500 ms" $([ -n "$prep" ] && [ "$prep" -le 3500 ] && echo 1 || echo 0) "at=${prep:-n/a} ms"
else
    check "the Docs service compiled the document networks (its cache gained entries)" $([ "$(num "$after" docs)" -gt "$(num "$before" docs)" ] && echo 1 || echo 0) "docs service $(num "$before" docs) -> $(num "$after" docs), in ${caches[1]}"
    first=$(sed -n 's/^work\[still\]: .*ocr\.blocks\.swift=\([0-9]*\).*/\1/p' "$OUT/render.out" | head -1)
    again=$(sed -n 's/^work\[again\]: .*ocr\.blocks\.swift=\([0-9]*\).*/\1/p' "$OUT/render.out" | head -1)
    check "the first pass read with VN (no document read answered before Docs was ready)" $([ -z "$first" ] || [ "$first" = 0 ] && echo 1 || echo 0) "ocr.blocks.swift in work[still]=${first:-0}"
    check "a doc-path read after Docs was ready" $([ -n "$again" ] && [ "$again" -ge 1 ] && echo 1 || echo 0) "ocr.blocks.swift in work[again]=${again:-0}"
fi
say "$([ $fail = 0 ] && echo 'reader-cold: all PASS' || echo 'reader-cold: FAIL')"
exit $fail
