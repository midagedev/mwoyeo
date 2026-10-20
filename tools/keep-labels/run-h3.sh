#!/bin/bash
# The rules report on H3 with the report tools: rules_report.py and h2_report.py read the own-screens set of a labels dir from the labels themselves (the header
# names the set), so H3's labels are copied into a SCRATCH dir under their own name (h3.jsonl) and the reports say H3. Nothing is written to labels-h3/ or the repo.
# The picture link stays $S/work/h2 -> H3's pictures: the regionfeed binary reads only work/code and work/h2, and that binary is being edited in another round.
#   usage: run-h3.sh <scratch dir>        env: H3_WORK=<KEEP_WORK of a make-h3.sh run> (its h3/ holds the pictures and reads), KEEP_BUILD (swift scratch path),
#                                              KEEP_LABELS=<h3.jsonl> (default labels-h3/h3.jsonl beside this script)
#   writes <scratch>/rules-report.txt (rules_report.py: tables, CodeRegion section), <scratch>/rules.jsonl, <scratch>/h2-report.txt (h2_report.py: size, verdict per slice, cuts, clusters)
HERE=$(cd "$(dirname "$0")" && pwd)
S=${1:?usage: run-h3.sh <scratch dir>}
W=${H3_WORK:?set H3_WORK to the KEEP_WORK of a make-h3.sh run}
BUILD=${KEEP_BUILD:-/tmp/l0/build}
LABELS=${KEEP_LABELS:-$HERE/labels-h3/h3.jsonl}
NAME=${LABELS##*/}
set -e
rm -rf "$S"; mkdir -p "$S/labels" "$S/work"
cp "$LABELS" "$S/labels/$NAME"
ln -sfn "$W/h3" "$S/work/h2"
KEEP_BUILD="$BUILD" KEEP_WORK="$S/work" KEEP_FEED="$S/feed.jsonl" "$HERE/run-rules.sh" "$S/labels" > "$S/rules-report.txt" 2> "$S/run-rules.err"
KEEP_FEED="$S/feed.jsonl" "$BUILD/release/keeprules" "$S/labels/$NAME" > "$S/rules.jsonl"
python3 -B -I "$HERE/h2_report.py" "$S/labels" "$S/rules.jsonl" --pics "$W/h3" > "$S/h2-report.txt"
echo "run-h3: $S/rules-report.txt ($(wc -l < "$S/rules-report.txt") lines), $S/h2-report.txt ($(wc -l < "$S/h2-report.txt") lines)"
