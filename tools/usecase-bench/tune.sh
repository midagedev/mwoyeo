#!/bin/bash
# Fits the reader decider to a bench run without rendering: tune.sh <out dir of `LINES=1 bench.sh <binary> auto`> [bundleID category]
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d)
mkdir "$T/m" && cp "$HERE/tune.swift" "$T/m/main.swift"
swiftc -O -o "$T/tune" "$T/m/main.swift" "$HERE/../../Core/Sources/MwoyeoCore/ParagraphReader.swift" 2>&1 | grep -E "error" 
"$T/tune" "$@"
