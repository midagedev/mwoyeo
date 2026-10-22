#!/bin/bash
# shapes117: the seam between LensTarget and LensShape (docs/design/lens-shapes.md section 6) on a scratch copy of a tree that has LensTarget
# (the one-click round's worktree until it lands), with this tree's LensShape.swift, LensTarget+Shapes.swift, the Target patch and
# LensSeamTests.swift laid over it. The unmutated seam must pass; each named mutant must fail at least one test. Never edits either tree.
#   usage: check.sh <tree with LensTarget.swift> [scratch dir (default /tmp/r117/shapes117/seam)] [mutant names...]
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
TREE=${1:?usage: check.sh <tree with LensTarget.swift> [scratch dir] [mutants...]}
SCR=${2:-/tmp/r117/shapes117/seam}
shift; shift || true
mkdir -p "$SCR"
rsync -a --delete --exclude .build "$TREE/Core/" "$SCR/Core/"
S="$SCR/Core/Sources/MwoyeoCore"
cp "$ROOT/Core/Sources/MwoyeoCore/LensShape.swift" "$HERE/LensTarget+Shapes.swift" "$S/"
cp "$HERE/LensSeamTests.swift" "$SCR/Core/Tests/MwoyeoCoreTests/"
(cd "$SCR" && patch -p1 < "$HERE/LensTarget.patch" > patch.log 2>&1) || { echo "patch failed: $SCR/patch.log"; exit 2; }
cp "$S/LensTarget+Shapes.swift" "$SCR/seam.orig"
OUT="$SCR/summary.txt"; : > "$OUT"

mutate() {
python3 - "$1" "$SCR/seam.orig" "$S/LensTarget+Shapes.swift" <<'EOF'
import sys
name, src, dst = sys.argv[1:4]
M = {
 'no-deep-test': [('if let here, around(p).allSatisfy({ column($0) != nil }) { return here }', 'if let here { return here }')],
 'no-release': [('if let heldColumn, here?.column != heldColumn.column, around(p).contains(where: { column($0)?.column == heldColumn.column }) { return heldColumn }', '')],
 'no-hold-between-columns': [('here?.column != heldColumn.column, around(p)', 'here == nil, around(p)')],
 'shape-hold-forgotten': [('return fallback(p, heldShape).map(Target.init(shape:)) ?? here', 'return fallback(p, nil).map(Target.init(shape:)) ?? here')],
 'column-held-over-shape': [('let heldShape = held?.shape, heldColumn = held.flatMap { $0.shape == nil ? $0 : nil }', 'let heldShape: LensShape.Shape? = nil, heldColumn = held')],
}[name]
s = open(src).read()
for old, new in M:
    if s.count(old) != 1:
        print('mutant %s: pattern found %d times: %r' % (name, s.count(old), old[:70])); sys.exit(3)
    s = s.replace(old, new)
open(dst, 'w').write(s)
EOF
}

run() {
  cp "$SCR/seam.orig" "$S/LensTarget+Shapes.swift"
  if [ "$1" != "original" ]; then
    mutate "$1" || { echo "$1: BAD MUTANT" >> "$OUT"; return; }
    cmp -s "$S/LensTarget+Shapes.swift" "$SCR/seam.orig" && { echo "$1: unchanged source" >> "$OUT"; return; }
  fi
  (cd "$SCR/Core" && swift test --filter LensSeamTests > "$SCR/$1.log" 2>&1; echo $? > "$SCR/$1.rc")
  failed=$(grep -o "^✘ Test [A-Za-z0-9_]*()" "$SCR/$1.log" | sed 's/✘ Test //; s/()//' | sort -u | tr '\n' ' ')
  echo "$1: rc=$(cat "$SCR/$1.rc") failing: ${failed:-none}" >> "$OUT"
}

names=("$@"); [ ${#names[@]} -eq 0 ] && names=(original no-deep-test no-release no-hold-between-columns shape-hold-forgotten column-held-over-shape)
for n in "${names[@]}"; do run "$n"; done
cp "$SCR/seam.orig" "$S/LensTarget+Shapes.swift"
cat "$OUT"
