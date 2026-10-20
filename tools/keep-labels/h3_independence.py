#!/usr/bin/env python3
"""H3 must stay clear of what the rules were tuned on and of what H2 showed (round h3, 2026-10-20):
  1. the k-cases, RESULTS-*, CODE-FEATURES-*, CodeRegion.swift (h2_independence.py's check: no unit shares a passage with a k-case line; no such source in the manifest);
  3. addendum A1.2: no InlineMath / Text / CodeRegion / TranslationFilter source or test, nor the keep tools, among the sources.
  2. H2: no source of h2/MANIFEST.tsv (same id or same path / command) in H3's manifest, and no unit of H3 shares a passage with a unit of H2's generator output
     (units of 4+ words and 20+ normalized characters: a shell idiom such as `set -euo pipefail` is not a quoted passage).
usage: h3_independence.py <dir with h3.py's output>     prints `<k-case units checked> <k-case overlaps> <excluded sources> <H2 units checked> <H2 overlaps> <sources shared with H2> <rule-code sources>`; exit 1 when an overlap or a source count is not 0"""
import glob, json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import re
import h2_independence as ind

# addendum A1.2 of round h3: the rule code and the keep / translate tests k3b fixes against are not material
RULE_CODE = re.compile(r'InlineMath|MwoyeoCore/Text\.swift|CodeRegion|TextTests|TranslationFilter|FormulaLiteral|MathHeavy|ProtectedSpans|keep-boundary|keep-labels|usecase-bench')


def units(d):
    out = []
    for f in sorted(glob.glob(os.path.join(d, '*.units.json'))):
        for u in json.load(open(f))['units']:
            out.append((os.path.basename(f), u['text']))
    return out


def sources(manifest):
    rows = [l.rstrip('\n').split('\t') for l in open(manifest) if not l.startswith('#') and l.strip()]
    return {(r[0], r[2]) for r in rows if len(r) > 2 and r[1] in ('repo-file', 'tool-output')}


def main():
    d = sys.argv[1]
    ks = subprocess.run([sys.executable, '-B', '-I', os.path.join(HERE, 'h2_independence.py'), d], capture_output=True, text=True)
    kn, kover, kbad = (ks.stdout.strip().split('\n')[-1].split() + ['0', '0', '0'])[:3]
    if ks.returncode: print(ks.stdout, end='')
    with tempfile.TemporaryDirectory() as t:
        subprocess.run([sys.executable, '-B', '-I', os.path.join(HERE, 'h2.py'), t], check=True, capture_output=True)
        h2u = [(f, ind.norm(x)) for f, x in units(t) if len(x.split()) >= 4 and any(c.isalpha() for c in x)]
        h2u = [(f, x) for f, x in h2u if len(x) >= 20]
        h2_manifest_sources = sources(os.path.join(HERE, 'h2', 'MANIFEST.tsv'))
    n = over = 0
    for f, text in units(d):
        if len(text.split()) < 4 or not any(c.isalpha() for c in text): continue                 # a gutter (1 2 3 ...) is not a passage
        t = ind.norm(text)
        if len(t) < 20: continue
        n += 1
        hit = next((g for g, x in h2u if t in x or x in t), None)
        if hit:
            over += 1; print(f'  {f}: {text[:70]!r} shares a passage with a unit of H2 ({hit})')
    mine = sources(os.path.join(d, 'MANIFEST.tsv'))
    ids, srcs = {a for a, _ in h2_manifest_sources}, {b for _, b in h2_manifest_sources}
    shared = sorted(a for a, b in mine if a in ids or b in srcs)
    for a in shared: print(f'  source also used by H2: {a}')
    rule = sorted(a for a, b in mine if RULE_CODE.search(a + ' ' + b))
    for a in rule: print(f'  rule code or keep test as a source: {a}')
    print(kn, kover, kbad, n, over, len(shared), len(rule))
    sys.exit(1 if ks.returncode or over or shared or rule else 0)


if __name__ == '__main__':
    main()
