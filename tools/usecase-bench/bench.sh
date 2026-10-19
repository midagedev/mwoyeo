#!/bin/bash
# Use-case bench for the paragraph reader: renders the 40 pictures of set/ with one binary and scores the paragraphs it reads against
# set/<name>.expected.txt (units: one expected paragraph, table cell or title each).
#   usage: bench.sh <Mwoyeo binary> [vn|swift|auto ...]        (default: vn swift auto)
#   env:   PNGS=<dir with the <name>.png of index.tsv>  (default /Users/hckim/.cache/mwoyeo-gates/usecases/set; the pictures are
#                                                        drawn from set/*.html, not kept in the repo)
#          OUT=<dir for outputs>  (default /tmp/usecase-bench)       ONLY=<name prefix>  render only those (e.g. p0)
#          LINES=1    auto traces the recognized lines of every decision (<name>-auto.err, for tune.sh)
# vn = MWOYEO_OCR_PATH=vn (lines grouped by ParagraphGrouper), swift = MWOYEO_OCR_PATH=swift (document model), auto = settings default
# (Automatic; the pictures carry no app, so it reads the layout only: `--lens-app <bundleID> [--lens-category <type>]` adds one). Needs the Bash sandbox off (headless --render) and no other --render at the same time on a quiet Neural Engine.
# Korean sources translate to en, all others to ko (a --tgt equal to --src waits 120 s in SelfTest).
# One summary line per use case and path (all 40, odd-numbered pictures, even-numbered): score.py.
BIN=${1:?usage: bench.sh <Mwoyeo binary> [vn|swift|auto ...]}; shift
PATHS=${*:-vn swift auto}
HERE=$(cd "$(dirname "$0")" && pwd); ANE=$HERE/../ane-env.sh
PNGS=${PNGS:-/Users/hckim/.cache/mwoyeo-gates/usecases/set}
OUT=${OUT:-/tmp/usecase-bench}
mkdir -p "$OUT/out"
tail -n +2 "$HERE/set/index.tsv" | while IFS=$'\t' read -r n uc l w h; do
    [[ -n "$ONLY" && "$n" != "$ONLY"* ]] && continue
    T=ko; [ "$l" = ko ] && T=en
    for p in $PATHS; do
        o="$OUT/out/$n-$p"
        [ -s "$o.out" ] && continue
        echo "$(uptime | sed 's/.*averages: //' | cut -d' ' -f1)" > "$o.load"
        env=(MWOYEO_TRACE=1); [ "$p" != auto ] && env+=(MWOYEO_OCR_PATH=$p)
        [ "$p" = auto ] && [ -n "$LINES" ] && env+=(MWOYEO_TRACE_LINES=1)
        env "${env[@]}" "$ANE" run pool -- "$BIN" --render "$PNGS/$n.png" "$o.png" --src "$l" --tgt "$T" --no-inpaint --warm --max-wait 120 \
            > "$o.out" 2> "$o.err" < /dev/null
    done
done
python3 "$HERE/score.py" "$OUT" $PATHS
