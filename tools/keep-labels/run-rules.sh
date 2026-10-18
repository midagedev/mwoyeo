#!/bin/bash
# Today's Core rules (InlineMath, TranslationFilter) on every labelled unit, and the precision / recall report.
#   usage: run-rules.sh [labels dir]            (default: labels/ beside this script)    env: KEEP_BUILD (default /tmp/l0/build), KEEP_REPORT=<file> also writes the report there
#   KEEP_WORK=<dir>  the pictures and Vision reads the labels came from (make-labels.sh / make-code-labels.sh work dir): adds the CODE REGIONS section
#                    (Core CodeRegion on every labelled read; the inputs are read off the pictures by regionfeed, about 2 minutes, no Vision needed).
#   KEEP_FEED=<file> a regionfeed output to reuse (written there when missing).   KEEP_SETS="cases dev,papers dev" limits the section to those sets.
HERE=$(cd "$(dirname "$0")" && pwd)
LABELS=${1:-$HERE/labels}
BUILD=${KEEP_BUILD:-/tmp/l0/build}
set -e
(cd "$HERE" && swift build -c release --scratch-path "$BUILD" --product keeprules > "$BUILD/keeprules-build.log" 2>&1) || { echo "swift build failed: $BUILD/keeprules-build.log"; exit 1; }
RULES=$(mktemp); trap 'rm -f "$RULES"' EXIT
if [ -n "$KEEP_WORK" ]; then
    FEED=${KEEP_FEED:-$(mktemp)}
    if [ ! -s "$FEED" ]; then
        (cd "$HERE" && swift build -c release --scratch-path "$BUILD" --product regionfeed > "$BUILD/regionfeed-build.log" 2>&1) || { echo "swift build failed: $BUILD/regionfeed-build.log"; exit 1; }
        "$BUILD/release/regionfeed" "$KEEP_WORK" > "$FEED"
    fi
    export KEEP_FEED=$FEED
fi
"$BUILD/release/keeprules" "$LABELS"/*.jsonl > "$RULES"
if [ -n "$KEEP_REPORT" ]; then python3 -B -I "$HERE/rules_report.py" "$LABELS" "$RULES" | tee "$KEEP_REPORT"; else python3 -B -I "$HERE/rules_report.py" "$LABELS" "$RULES"; fi
