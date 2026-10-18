#!/bin/bash
# Equivalence gate of the reader services (docs/design/recognition.md §6 R1): renders the use-case pictures and the paper pages with
# Vision in this process and through the XPC services (MWOYEO_READER=xpc), traces the lines of every read, and compares the runs
# picture by picture with same-lines.py. The third run, MWOYEO_FAKE_READER=shift1, moves every rect 1 px: it must be
# `same: 0/<n>`, or the comparison cannot see a difference.
#   usage: reader-equal.sh <Mwoyeo binary> <out dir> <swift|vn> [inprocess] [xpc] [mutation]     (default: all three, in that order)
#          reader-equal.sh <Mwoyeo binary> <out dir> direct                                        (every kind on every picture, no pipeline)
# `direct` runs `Mwoyeo --reader-check equal <lang> <pictures>` per language: each read of every kind (rev3, rev2, fast, fast on Docs,
# doc) in this process and through the service, compared to 0 px. It has no deadline, so it is also the warm-up: the first pass compiles
# whatever a picture needs (the document networks, a width class) in the cache of this process and of both services.
#   env:   PNGS   the use-case pictures of tools/usecase-bench/set/index.tsv   (default /Users/hckim/.cache/mwoyeo-gates/usecases/set)
#          PAGES  the paper pages p<N>.png                                      (default /tmp/paper-quality/paper)
#          ONLY   run only the pictures whose name starts with this
# swift = MWOYEO_OCR_PATH=swift (the document model reads), vn = MWOYEO_OCR_PATH=vn (revision 3 lines grouped). Needs the Bash sandbox
# off (headless --render), one render at a time, and warm models: a cold compile is minutes (run a warm-up first, e.g. `Mwoyeo
# --reader-check warm en` for the services, and one render for this process). A picture whose .rc exists is skipped, so a cut run resumes.
# Outputs <out>/<path>-<mode>/<picture>.{out,err,png,rc}; the .err holds the [read] records and, for the process shape,
# the .out holds `reader: <role> pid=<p> gui pid=<q>` per service.
BIN=${1:?usage: reader-equal.sh <Mwoyeo binary> <out dir> <swift|vn|direct> [inprocess] [xpc] [mutation]}; OUT=${2:?out dir}; OCR=${3:?swift, vn or direct}; shift 3
MODES=${*:-inprocess xpc mutation}
HERE=$(cd "$(dirname "$0")" && pwd)
PNGS=${PNGS:-/Users/hckim/.cache/mwoyeo-gates/usecases/set}
PAGES=${PAGES:-/tmp/paper-quality/paper}
mkdir -p "$OUT"
pictures() {   # name, picture path, src, tgt
    tail -n +2 "$HERE/../usecase-bench/set/index.tsv" | while IFS=$'\t' read -r n uc l w h; do
        T=ko; [ "$l" = ko ] && T=en
        printf '%s\t%s\t%s\t%s\n' "$n" "$PNGS/$n.png" "$l" "$T"
    done
    for f in $(cd "$PAGES" && ls | grep -E '^p[0-9]+\.png$' | sed 's/\.png$//' | sort -V); do
        printf '%s\t%s\ten\tko\n' "$f" "$PAGES/$f.png"
    done
}
if [ "$OCR" = direct ]; then
    mkdir -p "$OUT/direct"
    for lang in en ko ja zh-Hans; do
        list=()
        while IFS=$'\t' read -r n png l t; do
            [[ -n "$ONLY" && "$n" != "$ONLY"* ]] && continue
            [ "$l" = "$lang" ] && list+=("$png")
        done < <(pictures)
        [ ${#list[@]} -gt 0 ] || continue
        [ -e "$OUT/direct/$lang.rc" ] && continue
        env MWOYEO_MEMORY_SECRETS=1 MWOYEO_TRACE=1 "$BIN" --reader-check equal "$lang" "${list[@]}" > "$OUT/direct/$lang.log" 2> "$OUT/direct/$lang.err" < /dev/null
        echo $? > "$OUT/direct/$lang.rc"
        grep -E 'check: equal (same:|PASS|FAIL)' "$OUT/direct/$lang.log"
    done
    exit 0
fi
for mode in $MODES; do
    dir="$OUT/$OCR-$mode"; mkdir -p "$dir"
    env=(MWOYEO_TRACE=1 MWOYEO_TRACE_READS=1 MWOYEO_MEMORY_SECRETS=1 MWOYEO_DEFAULTS_SUITE=r1.equal MWOYEO_SETTINGS_FILE="$OUT/settings.json" MWOYEO_OCR_PATH=$OCR)
    case $mode in
        inprocess) ;;
        xpc) env+=(MWOYEO_READER=xpc) ;;
        mutation) env+=(MWOYEO_READER=xpc MWOYEO_FAKE_READER=shift1) ;;
        *) echo "unknown mode $mode" >&2; exit 2 ;;
    esac
    pictures | while IFS=$'\t' read -r n png l t; do
        [[ -n "$ONLY" && "$n" != "$ONLY"* ]] && continue
        o="$dir/$n"
        [ -e "$o.rc" ] && continue
        s=$(date +%s)
        env "${env[@]}" "$BIN" --render "$png" "$o.png" --src "$l" --tgt "$t" --no-inpaint --warm --max-wait 120 > "$o.out" 2> "$o.err" < /dev/null
        echo "$? $(( $(date +%s) - s )) s" > "$o.rc"
    done
done
for mode in $MODES; do
    [ "$mode" = inprocess ] && continue
    [ -d "$OUT/$OCR-inprocess" ] || continue
    printf '%s %s vs inprocess: ' "$OCR" "$mode"
    python3 -I "$HERE/same-lines.py" "$OUT/$OCR-inprocess" "$OUT/$OCR-$mode" -v 2> "$OUT/$OCR-$mode.diff"
    head -3 "$OUT/$OCR-$mode.diff"
done
