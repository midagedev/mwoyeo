#!/bin/bash
# The rules report on H3 with the unchanged report tools: rules_report.py and h2_report.py know one own-screens set, `h2` (a labels dir with h2.jsonl, pictures in
# KEEP_WORK/h2), so H3's labels are rewritten to that name in a SCRATCH dir (set / id h3 -> h2) and its pictures are linked as KEEP_WORK/h2. The report headings
# therefore say H2; the numbers are H3's. Nothing is written to labels-h3/ or the repo.
#   usage: run-h3.sh <scratch dir>        env: H3_WORK=<KEEP_WORK of a make-h3.sh run> (its h3/ holds the pictures and reads), KEEP_BUILD (swift scratch path),
#                                              KEEP_LABELS=<h3.jsonl> (default labels-h3/h3.jsonl beside this script)
#   writes <scratch>/rules-report.txt (rules_report.py: tables, CodeRegion section), <scratch>/rules.jsonl, <scratch>/h2-report.txt (h2_report.py: size, verdict per slice, cuts, clusters)
HERE=$(cd "$(dirname "$0")" && pwd)
S=${1:?usage: run-h3.sh <scratch dir>}
W=${H3_WORK:?set H3_WORK to the KEEP_WORK of a make-h3.sh run}
BUILD=${KEEP_BUILD:-/tmp/l0/build}
LABELS=${KEEP_LABELS:-$HERE/labels-h3/h3.jsonl}
set -e
rm -rf "$S"; mkdir -p "$S/labels" "$S/work"
sed -e 's/"id":"h3"/"id":"h2"/' -e 's/"set":"h3"/"set":"h2"/g' "$LABELS" > "$S/labels/h2.jsonl"
ln -sfn "$W/h3" "$S/work/h2"
KEEP_BUILD="$BUILD" KEEP_WORK="$S/work" KEEP_FEED="$S/feed.jsonl" "$HERE/run-rules.sh" "$S/labels" > "$S/rules-report.txt" 2> "$S/run-rules.err"
KEEP_FEED="$S/feed.jsonl" "$BUILD/release/keeprules" "$S/labels/h2.jsonl" > "$S/rules.jsonl"
python3 -B -I "$HERE/h2_report.py" "$S/labels" "$S/rules.jsonl" --pics "$W/h3" > "$S/h2-report.txt"
echo "run-h3: $S/rules-report.txt ($(wc -l < "$S/rules-report.txt") lines), $S/h2-report.txt ($(wc -l < "$S/h2-report.txt") lines)"
