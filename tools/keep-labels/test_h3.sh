#!/bin/bash
# Gates of the H3 generator and labeller (round h3, 2026-10-20). No Vision, no clock: each check has its FAIL-first line (the mutation that must make it fail),
# printed as `FAIL-first ...`. The same shape as test_h2.sh.
#   usage: test_h3.sh [<KEEP_WORK of leg A>/h3 <KEEP_WORK of leg B>/h3]      (two make-h3.sh runs with different KEEP_WORK: adds the G-e checks of the reads)
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "test_h3: PASS $1"; }
bad() { echo "test_h3: FAIL $1"; fails=$((fails + 1)); }
py() { python3 -B -I "$@"; }

# G-a: the generator is deterministic (byte-identical html, units, index, manifest) and the check sees a difference
py "$HERE/h3.py" "$T/a" > /dev/null && py "$HERE/h3.py" "$T/b" > /dev/null
if diff -r "$T/a" "$T/b" > /dev/null; then ok "the generator run twice writes byte-identical files ($(ls "$T/a" | wc -l | tr -d ' ') files)"; else bad "the generator is not deterministic"; fi
H2_MUTATE=1 py "$HERE/h3.py" "$T/m" > /dev/null
if diff -r "$T/a" "$T/m" > /dev/null; then bad "FAIL-first: a mutated generator output was not noticed"; else echo "test_h3: FAIL-first fired: a mutated generator output differs (diff -r exits 1)"; fi

# G-b: the sources are frozen: the manifest the generator writes is the one in the repo; a changed fixture changes it
if cmp -s "$T/a/MANIFEST.tsv" "$HERE/h3/MANIFEST.tsv"; then ok "MANIFEST.tsv equals the frozen h3/MANIFEST.tsv ($(grep -c . "$HERE/h3/MANIFEST.tsv") lines, sha256 $(shasum -a 256 "$HERE/h3/MANIFEST.tsv" | cut -c1-16)...)"; else bad "MANIFEST.tsv differs from h3/MANIFEST.tsv"; fi
cp -R "$HERE/h3/src" "$T/src"; echo "x" >> "$T/src/git-blame.txt"
H3_SRC="$T/src" py "$HERE/h3.py" "$T/t" > /dev/null
if cmp -s "$T/t/MANIFEST.tsv" "$HERE/h3/MANIFEST.tsv"; then bad "FAIL-first: a changed fixture was not noticed by the manifest"; else echo "test_h3: FAIL-first fired: a changed fixture changes MANIFEST.tsv"; fi

# G-c: an excerpt line that is not in the repo file at the pinned commit is refused
if (cd "$HERE" && py -c "
import sys; sys.path.insert(0, '.')
import h2, h3_scenes
h2.verify(h2.lines_of('public let nonexistent: Int', 'swift'), 'Core/Tests/MwoyeoCoreTests/MenuBarIconTests.swift', 'swift')" > /dev/null 2>&1); then
    bad "FAIL-first: an invented code line was accepted by verify"
else echo "test_h3: FAIL-first fired: an invented code line is refused by verify (exit non-zero)"; fi
if (cd "$HERE" && py -c "
import sys; sys.path.insert(0, '.')
import h2, h3_scenes
h2.verify(h2.lines_of('@Suite struct MenuBarIconTests {', 'swift'), 'Core/Tests/MwoyeoCoreTests/MenuBarIconTests.swift', 'swift')" > /dev/null 2>&1); then ok "a real line of MenuBarIconTests.swift is accepted by verify"; else bad "verify refused a real line"; fi
if (cd "$HERE" && py -c "
import sys; sys.path.insert(0, '.')
import h3_scenes as s
s.catalog('Not set', ['ko', 'ja'])
s.must_have('CONTRIBUTING.md', 'Keep a PR to one change.')" > /dev/null 2>&1); then ok "a catalog entry and a sentence of CONTRIBUTING.md are found at the pin"; else bad "catalog / must_have refused a real text"; fi
if (cd "$HERE" && py -c "
import sys; sys.path.insert(0, '.')
import h3_scenes as s
s.must_have('CONTRIBUTING.md', 'Keep a PR to ten changes.')" > /dev/null 2>&1); then bad "FAIL-first: an invented sentence was accepted by must_have"; else echo "test_h3: FAIL-first fired: an invented sentence is refused by must_have (exit non-zero)"; fi

# G-d: the labeller takes the class of the construction (fake OCR); with every keep unit flipped the checks fail
if py "$HERE/test_h3_labels.py" "$T/a" > "$T/l.out"; then ok "test_h3_labels.py: $(grep -c PASS "$T/l.out") checks pass"; else cat "$T/l.out"; bad "test_h3_labels.py"; fi
if py "$HERE/test_h3_labels.py" "$T/a" --mutate > "$T/lm.out"; then bad "FAIL-first: flipped keep units were not noticed by the label test"; else echo "test_h3: FAIL-first fired: with every keep unit flipped, test_h3_labels.py reports $(grep -c 'FAIL ' "$T/lm.out") failing checks"; fi

# G-f: H3 does not quote the k-cases, the rule code, or H2 (addenda A1.2, spec); a unit copied from k09 / from H2 is caught
if py "$HERE/h3_independence.py" "$T/a" > "$T/ind.out"; then ok "independence: $(tail -1 "$T/ind.out") (k-case units checked, overlaps, excluded sources, H2 units checked, overlaps, sources shared with H2, rule-code sources)"; else cat "$T/ind.out"; bad "H3 quotes an excluded source"; fi
cp -R "$T/a" "$T/q"; py - "$T/q/cards-ko.card-light.units.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d['units'][1]['text'] = 'a3f9c21 Fix rounding of negative balances'
json.dump(d, open(sys.argv[1], 'w'), ensure_ascii=False)
PY
if py "$HERE/h3_independence.py" "$T/q" > /dev/null; then bad "FAIL-first: a unit copied from a k-case was not noticed"; else echo "test_h3: FAIL-first fired: a unit copied from the k09 case is reported (exit 1)"; fi
cp -R "$T/a" "$T/r"
py "$HERE/h2.py" "$T/h2x" > /dev/null
py - "$T/h2x/shell-ko.term-dark.units.json" "$T/r/cards-ko.card-light.units.json" <<'PY'
import json, sys
h2u = [u['text'] for u in json.load(open(sys.argv[1]))['units'] if len(u['text'].split()) >= 4 and len(u['text']) >= 20][0]
d = json.load(open(sys.argv[2])); d['units'][1]['text'] = h2u
json.dump(d, open(sys.argv[2], 'w'), ensure_ascii=False)
PY
if py "$HERE/h3_independence.py" "$T/r" > /dev/null; then bad "FAIL-first: a unit copied from H2 was not noticed"; else echo "test_h3: FAIL-first fired: a unit copied from an H2 screen is reported (exit 1)"; fi
cp "$T/a/MANIFEST.tsv" "$T/q/MANIFEST.tsv"; printf 'tools/keep-labels/Sources/keeprules/CodeRegion.swift\trepo-file\tgit show 5c25067:Core/Sources/MwoyeoCore/CodeRegion.swift\t-\t\n' >> "$T/q/MANIFEST.tsv"
cp -R "$T/a" "$T/s"; cp "$T/q/MANIFEST.tsv" "$T/s/MANIFEST.tsv"
if py "$HERE/h3_independence.py" "$T/s" > /dev/null; then bad "FAIL-first: CodeRegion.swift in the manifest was not noticed"; else echo "test_h3: FAIL-first fired: CodeRegion.swift among the sources is reported (exit 1)"; fi

# G-g: H2 is unchanged by the helpers H3 added to h2.py / h2_labels.py (pre-h3 digests of the generator's 94 files; the labeller's default set is h2)
py "$HERE/h2.py" "$T/h2" > /dev/null
if (cd "$T/h2" && shasum -a 256 -c "$HERE/h3/h2-generator.sha256" > "$T/h2.sha" 2>&1); then ok "H2's generator output is byte-identical to the pre-h3 digests ($(grep -c OK "$T/h2.sha") files)"; else bad "H2's generator output changed"; fi
H2_MUTATE=1 py "$HERE/h2.py" "$T/h2m" > /dev/null
if (cd "$T/h2m" && shasum -a 256 -c "$HERE/h3/h2-generator.sha256" > /dev/null 2>&1); then bad "FAIL-first: a mutated H2 output passed the digest check"; else echo "test_h3: FAIL-first fired: a mutated H2 output fails the digest check"; fi
mkdir -p "$T/lab"; for n in swift-ko.ide-light; do cp "$T/h2/$n.units.json" "$T/lab/"; done
py - "$HERE" "$T/lab" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from test_h2_labels import fake_ocr
n = 'swift-ko.ide-light'
m = json.load(open(f'{sys.argv[2]}/{n}.units.json'))
json.dump(fake_ocr(m['units']), open(f'{sys.argv[2]}/{n}.ocr.jsonl', 'w'), ensure_ascii=False)
open(f'{sys.argv[2]}/index.tsv', 'w').write(f'name\tlook\tsrc\twidth\theight\n{n}\tide\tko\t1000\t0\n')
PY
py "$HERE/h2_labels.py" "$T/lab" "$T/lab/default.jsonl" > /dev/null 2>&1; py "$HERE/h2_labels.py" "$T/lab" "$T/lab/explicit.jsonl" --set h2 > /dev/null 2>&1
if cmp -s "$T/lab/default.jsonl" "$T/lab/explicit.jsonl" && head -1 "$T/lab/default.jsonl" | grep -q '"id":"h2"'; then ok "h2_labels.py without --set writes the set h2, byte-identical to --set h2"; else bad "h2_labels.py default set changed"; fi
py "$HERE/h2_labels.py" "$T/lab" "$T/lab/h3.jsonl" --set h3 > /dev/null 2>&1
if cmp -s "$T/lab/default.jsonl" "$T/lab/h3.jsonl"; then bad "FAIL-first: --set h3 wrote the same header as h2"; else echo "test_h3: FAIL-first fired: --set h3 writes another header than the default (cmp exits 1)"; fi

# G-e (optional): two legs of make-h3.sh with fresh pictures and fresh Vision reads (KEEP_WORK/h3 of each).
#   - the label pass is deterministic: h2_labels.py --set h3 twice on the same reads gives byte-identical files (cmp); FAIL-first: one added byte
#   - the document read of Vision is not byte-stable on the same picture (H2: 1, 1 and 2 screens of 46 differ between three legs), so two legs may differ on
#     at most 2 screens (h2_legs.py); FAIL-first: a leg with the blocks of 6 screens altered
if [ -n "$1" ] && [ -n "$2" ]; then
    for leg in "$1" "$2"; do
        py "$HERE/h2_labels.py" "$leg" "$T/l1.jsonl" --set h3 > /dev/null 2>&1 && py "$HERE/h2_labels.py" "$leg" "$T/l2.jsonl" --set h3 > /dev/null 2>&1
        if cmp -s "$T/l1.jsonl" "$T/l2.jsonl"; then ok "the label pass twice on the reads of $(basename "$(dirname "$leg")") is byte-identical ($(grep -c . "$T/l1.jsonl") lines)"; else bad "the label pass is not deterministic on $leg"; fi
        cp "$T/l1.jsonl" "$T/leg-$(basename "$(dirname "$leg")").jsonl"
    done
    A="$T/leg-$(basename "$(dirname "$1")").jsonl"; B="$T/leg-$(basename "$(dirname "$2")").jsonl"
    sed '2s/^/ /' "$A" > "$T/mut2.jsonl"
    if cmp -s "$T/mut2.jsonl" "$A"; then bad "FAIL-first: a label file with one added byte was not noticed by cmp"; else echo "test_h3: FAIL-first fired: a label file with one added byte differs from the original under cmp"; fi
    read -r d n < <(py "$HERE/h2_legs.py" "$A" "$B")
    if [ "$d" -le 2 ]; then ok "two legs with fresh Vision reads differ on $d of $n screens (at most 2 allowed)"; else bad "two legs differ on $d of $n screens"; fi
    py - "$B" "$T/mut.jsonl" <<'PY'
import sys, json
seen, out = set(), open(sys.argv[2], 'w')
for line in open(sys.argv[1]):
    if line.startswith('{"kind":"block"'):
        r = json.loads(line)
        if len(seen) < 6 or r['paper'] in seen:
            seen.add(r['paper']); r['text'] += ' x'
        line = json.dumps(r, ensure_ascii=False, separators=(',', ':')) + '\n'
    out.write(line)
PY
    read -r d2 n2 < <(py "$HERE/h2_legs.py" "$A" "$T/mut.jsonl")
    if [ "$d2" -le 2 ]; then bad "FAIL-first: a leg with 6 altered screens passed the leg check ($d2 of $n2)"; else echo "test_h3: FAIL-first fired: a leg with the blocks of 6 screens altered differs on $d2 of $n2 screens (more than 2)"; fi
fi
echo "test_h3: $([ $fails -eq 0 ] && echo ALL PASS || echo "$fails FAIL")"
exit $fails
