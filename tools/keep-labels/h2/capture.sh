#!/bin/bash
# Captures the tool-output fixtures of H2 (src/*.txt). Run once, 2026-10-20; the generator (h2.py) reads only these files, never a tool, so a
# later run of the generator cannot differ because a tool printed something else (addendum A1.3). The commands are the manifest's rows.
#   usage: capture.sh <swift-test.log> <xcodebuild.log>        (raw logs of the two commands below; the path in the first one is a scratch dir)
#     swift test:   cd Core && swift test --scratch-path <scratch>/core-build                                    (rc 0, 811 tests)
#     xcodebuild:   cd Core && xcodebuild -scheme MwoyeoCore -destination 'platform=macOS' -derivedDataPath <scratch>/dd build   (rc 0)
# The windows are cut by rule, not by choice: swift test = the first 12 lines that are not progress lines ("[12 / 93]") and the last 8; xcodebuild =
# the first 28 non-blank lines and the last 4. Personal paths and the machine id are replaced (sanitize).
HERE=$(cd "$(dirname "$0")" && pwd)
PIN=d8e50d8
REPO=$(cd "$HERE/../../.." && pwd)
SRC=$HERE/src
mkdir -p "$SRC"
sanitize() {
    sed -E -e "s#$REPO#/Users/dev/mwoyeo#g" -e "s#/Users/[A-Za-z0-9_.-]+#/Users/dev#g" -e 's#/tmp/[A-Za-z0-9_.-]+/dd#/tmp/dd#g' \
        -e 's#/tmp/[A-Za-z0-9_.-]+/core-build#/tmp/build#g' -e 's#id:[0-9A-F]{8}-[0-9A-F]{16}#id:00000000-0000000000000000#g' | expand -t 4
}
git -C "$REPO" log "$PIN" --author=midagedev@gmail.com -n 12 --format='%h %<(88,trunc)%s' > "$SRC/git-log.txt"
git -C "$REPO" diff ad2ad15~1 ad2ad15 > "$SRC/git-diff.txt"
if [ -n "$1" ]; then
    grep -v '^\[' "$1" | { head -n 12; tail -n 8; } | sanitize > "$SRC/swift-test.txt"
fi
if [ -n "$2" ]; then
    grep -v '^$' "$2" | sanitize | { head -n 28; tail -n 4; } > "$SRC/xcodebuild.txt"
fi
( cd "$SRC" && shasum -a 256 *.txt )
