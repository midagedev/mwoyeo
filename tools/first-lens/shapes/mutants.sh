#!/bin/bash
# shapes117 FAIL-first: LensShapeTests against a stub (choose finds nothing) and named mutants of LensShape.swift. Every mutant must fail at
# least one named test; the unmutated source must pass. Runs on a scratch copy of Core (never edits the tree). Each mutated line must exist
# exactly once in the source: a refactor that moves one fails here, not silently.
#   usage: mutants.sh [scratch dir (default /tmp/r117/shapes117/mut)] [mutant names...]
set -u
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SCR=${1:-/tmp/r117/shapes117/mut}
shift || true
mkdir -p "$SCR"
rsync -a --delete --exclude .build "$ROOT/Core/" "$SCR/Core/"
SRC="$SCR/Core/Sources/MwoyeoCore/LensShape.swift"
cp "$SRC" "$SCR/LensShape.orig"
OUT="$SCR/summary.txt"; : > "$OUT"

mutate() { # name -> writes the mutated source, or exits 3 when a pattern is not found exactly once
python3 - "$1" "$SCR/LensShape.orig" "$SRC" <<'EOF'
import sys
name, src, dst = sys.argv[1:4]
M = {
 'stub': [('for a in anchors(map, p, held: held) {', 'for a in [Int]() {')],
 'no-hysteresis': [('guard let held, map.blocks.indices.contains(held.anchor) else { return taken }', 'guard let held = Optional<Shape>.none else { return taken }')],
 'cut-a-block-allowed': [('for _ in map.blocks.indices {\n            guard let i = map.blocks.indices.first(where: { !members.contains($0) && cuts(r, map.blocks[$0].core) }) else { break }', 'for _ in 0..<0 {\n            guard let i = map.blocks.indices.first(where: { !members.contains($0) && cuts(r, map.blocks[$0].core) }) else { break }'),
                         ('guard out.width >= minSize.width - 1 / grid, out.height >= minSize.height - 1 / grid,\n              !map.blocks.indices.contains(where: { !members.contains($0) && !map.blocks[$0].core.intersects(core) && cuts(out, map.blocks[$0].core) })', 'guard out.width >= minSize.width - 1 / grid, out.height >= minSize.height - 1 / grid')],
 'heading-is-dialog': [('static let nameGap: CGFloat = 0.85', 'static let nameGap: CGFloat = 3'), ('static let dialogEm: CGFloat = 16', 'static let dialogEm: CGFloat = 0')],
 'page-line-is-subtitle': [('static let subtitleClear: CGFloat = 3', 'static let subtitleClear: CGFloat = 0'), ('static let subtitleEm: CGFloat = 16', 'static let subtitleEm: CGFloat = 0')],
 'no-pad': [('public static let pad: CGFloat = 6', 'public static let pad: CGFloat = 0')],
 'reach-unbounded': [('public static let reach: CGFloat = 40', 'public static let reach: CGFloat = 4000')],
 'label-takes-held-lens': [('taken + [held.anchor]', 'taken')],
 'table-without-min-rows': [('static let minRows = 3', 'static let minRows = 1')],
}[name]
s = open(src).read()
for old, new in M:
    if s.count(old) != 1:
        print('mutant %s: pattern found %d times: %r' % (name, s.count(old), old[:70])); sys.exit(3)
    s = s.replace(old, new)
open(dst, 'w').write(s)
EOF
}

run() { # name
  cp "$SCR/LensShape.orig" "$SRC"
  if [ "$1" != "original" ]; then
    mutate "$1" || { echo "$1: BAD MUTANT" >> "$OUT"; return; }
    cmp -s "$SRC" "$SCR/LensShape.orig" && { echo "$1: unchanged source" >> "$OUT"; return; }
  fi
  (cd "$SCR/Core" && swift test --filter LensShapeTests > "$SCR/$1.log" 2>&1; echo $? > "$SCR/$1.rc")
  rc=$(cat "$SCR/$1.rc")
  failed=$(grep -o "^✘ Test [A-Za-z0-9_]*()" "$SCR/$1.log" | sed 's/✘ Test //; s/()//' | sort -u | tr '\n' ' ')
  echo "$1: rc=$rc failing: ${failed:-none}" >> "$OUT"
}

names=("$@"); [ ${#names[@]} -eq 0 ] && names=(original stub no-hysteresis cut-a-block-allowed heading-is-dialog page-line-is-subtitle no-pad reach-unbounded label-takes-held-lens table-without-min-rows)
for n in "${names[@]}"; do run "$n"; done
cp "$SCR/LensShape.orig" "$SRC"
cat "$OUT"
