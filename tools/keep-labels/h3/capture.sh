#!/bin/bash
# Captures the tool-output fixtures of H3 (src/*.txt). Run once, 2026-10-20; the generator (h3_scenes.py) reads only these files, never a tool, so a later
# run cannot differ because a tool printed something else (the same rule as h2/capture.sh). The commands are the manifest's rows. Every git command
# names a commit that is not one of the twelve H2 showed (h2/src/git-log.txt), and the history is midagedev's own.
#   usage: capture.sh <swift-build-snap.log> <swift-build-ocrdump.log>     (the raw logs of `swift build -c release --scratch-path <scratch> --product snap|ocrdump`
#                                                                            run in tools/keep-labels on 2026-10-20; the scratch path is replaced)
HERE=$(cd "$(dirname "$0")" && pwd)
PIN=5c25067
REPO=$(cd "$HERE/../../.." && pwd)
SRC=$HERE/src
mkdir -p "$SRC"
sanitize() {
    sed -E -e "s#$REPO#/Users/dev/mwoyeo#g" -e "s#/Users/[A-Za-z0-9_.-]+#/Users/dev#g" -e 's#/(private/)?tmp/[A-Za-z0-9_.-]+/build#/tmp/build#g' | expand -t 4
}
git -C "$REPO" diff b459840~1 b459840 > "$SRC/git-diff-perm.txt"
git -C "$REPO" diff 63d28f6~1 63d28f6 | head -n 44 > "$SRC/git-diff-settings.txt"
git -C "$REPO" show --stat=100 --format='%h %s' 3871352 > "$SRC/git-show-stat.txt"
git -C "$REPO" blame -L 14,33 --date=short "$PIN" -- scripts/release.sh | cut -c1-150 > "$SRC/git-blame.txt"
git -C "$REPO" grep -n 'MWOYEO_FAKE_READER' "$PIN" -- Core/Tests | head -n 12 | cut -c1-150 > "$SRC/git-grep.txt"
( cd "$REPO/tools/engine-bench" && python3 -I report.py results | head -n 14 ) > "$SRC/bench-report.txt"
( cd "$REPO" && ls -l scripts | sed -E 's/ [A-Za-z0-9_.-]+  staff /  dev  staff /' ) > "$SRC/ls-scripts.txt"
if [ -n "$1" ] && [ -n "$2" ]; then
    { cat "$1"; cat "$2"; } | tr -d '\r' | sed -E 's/[[:space:]]+$//' | LC_ALL=C grep -v -E '^\[[0-9]+[^0-9/]*/[^0-9/]*[0-9]+\]$' | sanitize > "$SRC/swift-build.txt"
fi
( cd "$SRC" && shasum -a 256 *.txt )
