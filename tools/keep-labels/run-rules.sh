#!/bin/bash
# Today's Core rules (InlineMath, TranslationFilter) on every labelled unit, and the precision / recall report.
#   usage: run-rules.sh [labels dir]            (default: labels/ beside this script)    env: KEEP_BUILD (default /tmp/l0/build), KEEP_REPORT=<file> also writes the report there
HERE=$(cd "$(dirname "$0")" && pwd)
LABELS=${1:-$HERE/labels}
BUILD=${KEEP_BUILD:-/tmp/l0/build}
set -e
(cd "$HERE" && swift build -c release --scratch-path "$BUILD" --product keeprules > "$BUILD/keeprules-build.log" 2>&1) || { echo "swift build failed: $BUILD/keeprules-build.log"; exit 1; }
RULES=$(mktemp); trap 'rm -f "$RULES"' EXIT
"$BUILD/release/keeprules" "$LABELS"/*.jsonl > "$RULES"
if [ -n "$KEEP_REPORT" ]; then python3 -B -I "$HERE/rules_report.py" "$LABELS" "$RULES" | tee "$KEEP_REPORT"; else python3 -B -I "$HERE/rules_report.py" "$LABELS" "$RULES"; fi
