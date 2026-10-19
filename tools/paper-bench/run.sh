#!/bin/bash
# Paper bench (--scale 2: the pages are a 2x screen showing the page ~ 820 pt wide): renders the pages and crops of pages.sh with one binary, one render at a time (headless --render needs the Bash
# sandbox off and the Neural Engine to itself), then scores them (score.py).
#   usage: run.sh <Mwoyeo binary> <out dir> [pattern ...]   (patterns pick names, e.g. p5 p4-c1; default every page and crop)
#   env:   PAGES=<dir of pages.sh output> (default /tmp/paper-quality/pages-own: our own paper; the 1706.03762 pages need their own dir)
# Outputs <out>/<name>.out (the render's stdout: sources, translations, the layout and block lines), .err (the trace: among its
# lines `kept math`, the blocks left as written because they are mostly inline mathematics), .png, and .load (the
# machine load and ANECompilerService CPU at start). A name whose .out exists is skipped, so a cut run resumes. Every run sets
# MWOYEO_MEMORY_SECRETS and a scratch defaults suite: nothing of the user's settings is read or written.
BIN=${1:?usage: run.sh <Mwoyeo binary> <out dir> [pattern ...]}; OUT=${2:?out dir}; shift 2
PAGES=${PAGES:-/tmp/paper-quality/pages-own}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$OUT"
names=$(cd "$PAGES" && ls *.png | sed 's/\.png$//' | awk '/^p[0-9]+$/{print 1, $0; next} {print 2, $0}' | sort -k1,1n -k2,2V | cut -d' ' -f2)
for n in $names; do
    if [ $# -gt 0 ]; then ok=; for p in "$@"; do [[ "$n" == "$p" || "$n" == "$p"-* ]] && ok=1; done; [ -z "$ok" ] && continue; fi
    o="$OUT/$n"
    [ -s "$o.out" ] && continue
    echo "load=$(uptime | sed 's/.*averages: //' | cut -d' ' -f1) ane_cpu=$(ps -Ao pcpu,comm | awk '/ANECompilerService/{s+=$1} END{print s+0}') start=$(date +%s)" > "$o.load"
    MWOYEO_TRACE=1 MWOYEO_MEMORY_SECRETS=1 MWOYEO_DEFAULTS_SUITE=paperq.bench MWOYEO_SETTINGS_FILE="$OUT/settings.json" \
        "$BIN" --render "$PAGES/$n.png" "$o.png" --src en --tgt ko --scale 2 --warm --max-wait 300 > "$o.out" 2> "$o.err" < /dev/null
    echo "rc=$? end=$(date +%s) ane_cpu=$(ps -Ao pcpu,comm | awk '/ANECompilerService/{s+=$1} END{print s+0}')" >> "$o.load"
done
python3 -I "$HERE/score.py" "$OUT"
