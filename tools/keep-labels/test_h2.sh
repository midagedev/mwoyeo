#!/bin/bash
# Gates of the H2 generator and labeller (round k3a, 2026-10-20). No Vision, no clock: each check has its FAIL-first line (the mutation that
# must make it fail), printed as `FAIL-first ...`.
#   usage: test_h2.sh [<KEEP_WORK of leg A>/h2 <KEEP_WORK of leg B>/h2]      (two make-h2.sh runs with different KEEP_WORK: adds the G1 checks of the reads)
HERE=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
ok() { echo "test_h2: PASS $1"; }
bad() { echo "test_h2: FAIL $1"; fails=$((fails + 1)); }
py() { python3 -B -I "$@"; }

# G-a: the generator is deterministic (byte-identical html, units, index, manifest) and the check sees a difference
py "$HERE/h2.py" "$T/a" > /dev/null && py "$HERE/h2.py" "$T/b" > /dev/null
if diff -r "$T/a" "$T/b" > /dev/null; then ok "the generator run twice writes byte-identical files ($(ls "$T/a" | wc -l | tr -d ' ') files)"; else bad "the generator is not deterministic"; fi
H2_MUTATE=1 py "$HERE/h2.py" "$T/m" > /dev/null
if diff -r "$T/a" "$T/m" > /dev/null; then bad "FAIL-first: a mutated generator output was not noticed"; else echo "test_h2: FAIL-first fired: a mutated generator output differs (diff -r exits 1)"; fi

# G-b: the sources are frozen: the manifest the generator writes is the one in the repo; a changed fixture changes it
if cmp -s "$T/a/MANIFEST.tsv" "$HERE/h2/MANIFEST.tsv"; then ok "MANIFEST.tsv equals the frozen h2/MANIFEST.tsv ($(grep -c . "$HERE/h2/MANIFEST.tsv") lines)"; else bad "MANIFEST.tsv differs from h2/MANIFEST.tsv"; fi
cp -R "$HERE/h2/src" "$T/src"; echo "x" >> "$T/src/git-log.txt"
H2_SRC="$T/src" py "$HERE/h2.py" "$T/t" > /dev/null
if cmp -s "$T/t/MANIFEST.tsv" "$HERE/h2/MANIFEST.tsv"; then bad "FAIL-first: a changed fixture was not noticed by the manifest"; else echo "test_h2: FAIL-first fired: a changed fixture changes MANIFEST.tsv"; fi

# G-c: an excerpt line that is not in the repo file at the pinned commit is refused
if (cd "$HERE" && py -c "
import sys; sys.path.insert(0, '.')
import h2
h2.verify(h2.lines_of('public let nonexistent: Int', 'swift'), 'Core/Sources/MwoyeoCore/Backoff.swift', 'swift')" > /dev/null 2>&1); then
    bad "FAIL-first: an invented code line was accepted by verify"
else echo "test_h2: FAIL-first fired: an invented code line is refused by verify (exit non-zero)"; fi
if (cd "$HERE" && py -c "
import sys; sys.path.insert(0, '.')
import h2
h2.verify(h2.lines_of('public let base: TimeInterval', 'swift'), 'Core/Sources/MwoyeoCore/Backoff.swift', 'swift')" > /dev/null 2>&1); then ok "a real line of Backoff.swift is accepted by verify"; else bad "verify refused a real line"; fi

# G-d: the labeller takes the class of the construction (fake OCR); with every keep unit flipped the checks fail
if py "$HERE/test_h2_labels.py" "$T/a" > "$T/l.out"; then ok "test_h2_labels.py: $(grep -c PASS "$T/l.out") checks pass"; else cat "$T/l.out"; bad "test_h2_labels.py"; fi
if py "$HERE/test_h2_labels.py" "$T/a" --mutate > "$T/lm.out"; then bad "FAIL-first: flipped keep units were not noticed by the label test"; else echo "test_h2: FAIL-first fired: with every keep unit flipped, test_h2_labels.py reports $(grep -c 'FAIL ' "$T/lm.out") failing checks"; fi

# G-f: H2 does not quote the k-cases, the RESULTS files or CodeRegion.swift (addendum A1.2); a unit copied from k09 is caught
if py "$HERE/h2_independence.py" "$T/a" > "$T/ind.out"; then ok "no unit of H2 shares a passage with the k-cases; no excluded source in the manifest ($(cut -d' ' -f1 "$T/ind.out") units of 3+ words and 12+ characters checked)"; else cat "$T/ind.out"; bad "H2 quotes an excluded source"; fi
cp -R "$T/a" "$T/q"; py - "$T/q/chat-ko.chat-dark.units.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d['units'][1]['text'] = 'a3f9c21 Fix rounding of negative balances'
json.dump(d, open(sys.argv[1], 'w'), ensure_ascii=False)
PY
if py "$HERE/h2_independence.py" "$T/q" > /dev/null; then bad "FAIL-first: a unit copied from a k-case was not noticed"; else echo "test_h2: FAIL-first fired: a unit copied from the k09 case is reported (exit 1)"; fi

# G-e (optional): two legs of make-h2.sh with fresh pictures and fresh Vision reads (KEEP_WORK/h2 of each).
#   - the label pass is deterministic: h2_labels.py twice on the same reads gives byte-identical files (cmp); FAIL-first: one added byte
#   - the document read of Vision is not byte-stable on the same picture (measured 2026-10-20: 1, 1 and 2 screens of 46 differ between three legs),
#     so two legs may differ on at most 2 screens (h2_legs.py); FAIL-first: a leg with the blocks of 6 screens altered
if [ -n "$1" ] && [ -n "$2" ]; then
    for leg in "$1" "$2"; do
        py "$HERE/h2_labels.py" "$leg" "$T/l1.jsonl" > /dev/null 2>&1 && py "$HERE/h2_labels.py" "$leg" "$T/l2.jsonl" > /dev/null 2>&1
        if cmp -s "$T/l1.jsonl" "$T/l2.jsonl"; then ok "the label pass twice on the reads of $(basename "$(dirname "$leg")") is byte-identical ($(grep -c . "$T/l1.jsonl") lines)"; else bad "the label pass is not deterministic on $leg"; fi
        cp "$T/l1.jsonl" "$T/leg-$(basename "$(dirname "$leg")").jsonl"
    done
    A="$T/leg-$(basename "$(dirname "$1")").jsonl"; B="$T/leg-$(basename "$(dirname "$2")").jsonl"
    sed '2s/^/ /' "$A" > "$T/mut2.jsonl"
    if cmp -s "$T/mut2.jsonl" "$A"; then bad "FAIL-first: a label file with one added byte was not noticed by cmp"; else echo "test_h2: FAIL-first fired: a label file with one added byte differs from the original under cmp"; fi
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
    if [ "$d2" -le 2 ]; then bad "FAIL-first: a leg with 6 altered screens passed the leg check ($d2 of $n2)"; else echo "test_h2: FAIL-first fired: a leg with the blocks of 6 screens altered differs on $d2 of $n2 screens (more than 2)"; fi
fi
echo "test_h2: $([ $fails -eq 0 ] && echo ALL PASS || echo "$fails FAIL")"
exit $fails
