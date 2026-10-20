#!/bin/bash
# The keep judge comparison (round m-bench, 2026-10-20): today's rules and light learned judges, H2 train / H3 test.
#   usage: run.sh <judge>            a learned judge key (gbt gbt-nopix ngram potion potion+layout e5 e5+layout e5-int8 eg2 eg2+layout eg2-256 eg2-128) = run.sh train <judge>
#          run.sh rules              judge 1 on THIS tree: swift build of keeprules + regionfeed, the feeds of H2 / H3 (and the cases + papers when X_WORK is there), keeprules records,
#                                    the scored rows (needs only numpy + PIL: any python3 will do; MB_PY overrides)
#          run.sh train <judge>...   train.py + evaluate.py for gbt gbt-nopix gbt-shuffled ngram potion potion+layout e5 e5+layout e5-int8 eg2 eg2+layout eg2-int8 eg2-256 eg2-128
#                                    (needs the venv: numpy scikit-learn lightgbm sentence-transformers model2vec torch pillow; weights in MB_SCRATCH/hf)
#          run.sh embed [name...]    the embeddings the embedding judges read (potion e5 eg2 e5-int8 eg2-int8)
#          run.sh time               bench_time.py: every exported judge + judge 1, interleaved, single thread
#          run.sh table              the RESULTS tables from the cached numbers
#          run.sh check              check_mbench.py: scorer reproduction, split, forbidden fields, negative control, h2_report cross-check, each with its FAIL-first line
#   env: MB_SCRATCH (default /tmp/m-bench)   KEEP_BUILD (swift scratch path, default $MB_SCRATCH/build)   KEEP_WORK (parent of the H2 dir `h2`, default /tmp/k3a/wb)
#        H3_WORK (parent of the H3 dir `h3`, default /tmp/h3/legA)   X_WORK (parent of code/ 2401.10066/ 2310.06142/, default /tmp/l0/g4b-work)
#   Vision is never run: the pictures and reads are fixed inputs. The H3 labels are read here as `h3`; run-h3.sh's rename to `h2` only matters for rules_report / h2_report.
HERE=$(cd "$(dirname "$0")" && pwd)
KL=$(dirname "$HERE")
export MB_SCRATCH=${MB_SCRATCH:-/tmp/m-bench}
S=$MB_SCRATCH
BUILD=${KEEP_BUILD:-$S/build}
PY=${MB_PY:-$S/venv/bin/python}
[ -x "$PY" ] || PY=python3
cmd=${1:?usage: run.sh rules|train <judge>...|embed|time|table|check}; shift
set -e
mkdir -p "$S" "$BUILD"
case "$cmd" in
rules)
    (cd "$KL" && swift build -c release --scratch-path "$BUILD" --product keeprules > "$BUILD/keeprules-build.log" 2>&1) || { echo "swift build failed: $BUILD/keeprules-build.log"; exit 1; }
    (cd "$KL" && swift build -c release --scratch-path "$BUILD" --product regionfeed > "$BUILD/regionfeed-build.log" 2>&1) || { echo "swift build failed: $BUILD/regionfeed-build.log"; exit 1; }
    mkdir -p "$S/work/h2root" "$S/work/h3root" "$S/work/xroot"
    ln -sfn "${KEEP_WORK:-/tmp/k3a/wb}/h2" "$S/work/h2root/h2"
    ln -sfn "${H3_WORK:-/tmp/h3/legA}/h3" "$S/work/h3root/h2"          # regionfeed reads KEEP_WORK/h2: H3's pictures are linked under that name (run-h3.sh does the same)
    XW=${X_WORK:-/tmp/l0/g4b-work}
    for d in code 2401.10066 2310.06142; do ln -sfn "$XW/$d" "$S/work/xroot/$d"; done
    for s in h2 h3 x; do "$BUILD/release/regionfeed" "$S/work/${s}root" > "$S/feed-$s.jsonl"; done
    KEEP_FEED="$S/feed-h2.jsonl" "$BUILD/release/keeprules" "$KL/labels-h2/h2.jsonl" > "$S/rules-h2.jsonl"
    KEEP_FEED="$S/feed-h3.jsonl" "$BUILD/release/keeprules" "$KL/labels-h3/h3.jsonl" > "$S/rules-h3.jsonl"
    KEEP_FEED="$S/feed-x.jsonl" "$BUILD/release/keeprules" "$KL/labels/code.jsonl" "$KL/labels/2401.10066.jsonl" "$KL/labels/2310.06142.jsonl" > "$S/rules-x.jsonl"
    rm -f "$S"/cache/h2.pkl "$S"/cache/h3.pkl "$S"/cache/code.pkl "$S"/cache/p2401.pkl "$S"/cache/p2310.pkl "$S"/cache/ds-*.pkl         # rebuilt from the pictures when missing
    "$PY" -B -I "$HERE/score.py" repro
    "$PY" -B -I "$HERE/evaluate.py" rules
    "$PY" -B -I "$HERE/report.py" rules
    ;;
train)
    for k in "$@"; do "$PY" -B -I "$HERE/train.py" "$k"; "$PY" -B -I "$HERE/evaluate.py" "$k"; done
    ;;
embed)
    "$PY" -B -I "$HERE/embed.py" "$@"
    ;;
time)
    mkdir -p "$S/rt"
    swiftc -O -I "$BUILD/release" "$HERE/rulestime.swift" "$BUILD/release/MwoyeoCore.o" -o "$S/rt/rulestime"
    "$PY" -B -I "$HERE/bench_time.py" "$@"
    ;;
table)
    "$PY" -B -I "$HERE/report.py" "$@"
    ;;
check)
    "$PY" -B -I "$HERE/check_mbench.py" "$@"
    ;;
gbt|gbt-nopix|gbt-shuffled|ngram|potion|potion+layout|e5|e5+layout|e5-int8|eg2|eg2+layout|eg2-int8|eg2-256|eg2-128)
    for k in "$cmd" "$@"; do "$PY" -B -I "$HERE/train.py" "$k"; "$PY" -B -I "$HERE/evaluate.py" "$k"; done
    ;;
*)
    echo "unknown command $cmd"; exit 2
    ;;
esac
