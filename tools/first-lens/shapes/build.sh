#!/bin/bash
# Builds the shapes probe (main.swift) with LensShape.swift and the column owner it chains after (LensTarget with the seam, ColumnFit and
# what they use). COLUMN=<Core sources dir holding LensTarget.swift and LensTarget+Shapes.swift> (the seam round's scratch tree, see
# seam/README: /tmp/r117/shapes117/seam/Core/Sources/MwoyeoCore until the seam lands in LensTarget).
#   usage: build.sh <out binary>
HERE=$(cd "$(dirname "$0")" && pwd)
CORE=$HERE/../../../Core/Sources/MwoyeoCore
COLUMN=${COLUMN:-$CORE}
OUT=${1:?usage: build.sh <out binary>}
swiftc -O -o "$OUT" "$HERE/main.swift" "$CORE/LensShape.swift" \
    "$COLUMN/LensTarget.swift" "$COLUMN/LensTarget+Shapes.swift" "$COLUMN/ColumnFit.swift" "$COLUMN/LensAccess.swift" "$COLUMN/LensGesture.swift" \
    "$COLUMN/BlockLayout.swift" "$COLUMN/ReadingOrder.swift" "$COLUMN/ColumnBreak.swift"
