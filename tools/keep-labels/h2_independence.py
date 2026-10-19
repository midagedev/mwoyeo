#!/usr/bin/env python3
"""H2 must not quote what the rules were tuned on (addendum A1.2): no unit of a screen shares a passage (12 characters or more, normalized) with a line of
the k-cases' expected.txt files (units of three words or more: a bare file name such as CONTRIBUTING.md is not a quoted line), and the manifest names none of the excluded sources (k-case files, RESULTS-*, CODE-FEATURES-*, CodeRegion.swift).
usage: h2_independence.py <dir with h2.py's output>       prints `<units checked> <overlaps> <excluded sources>`; exit 1 when either is not 0"""
import glob, json, os, re, sys, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '..', 'usecase-bench'))
import score

EXCLUDED = re.compile(r'usecase-bench/set/k\d|/RESULTS-|^RESULTS-|CODE-FEATURES|CodeRegion\.swift')


def norm(s):
    return re.sub(r'\s+', '', unicodedata.normalize('NFKC', s)).lower()


def main():
    d = sys.argv[1]
    k = [norm(t) for f in sorted(glob.glob(os.path.join(HERE, '..', 'usecase-bench', 'set', 'k*.expected.txt'))) for t, *_ in score.rows(f)]
    k = [t for t in k if len(t) >= 12]
    n = over = 0
    for f in sorted(glob.glob(os.path.join(d, '*.units.json'))):
        for u in json.load(open(f))['units']:
            t = norm(u['text'])
            if len(t) < 12 or len(u['text'].split()) < 3: continue                  # a file name or an identifier is not a quoted line
            n += 1
            if any(t in x or x in t for x in k):
                over += 1; print(f'  overlap in {os.path.basename(f)}: {u["text"][:70]!r}')
    bad = [l.split('\t')[0] for l in open(os.path.join(d, 'MANIFEST.tsv')) if not l.startswith('#') and EXCLUDED.search(l.split('\t')[0] + ' ' + (l.split('\t')[2] if len(l.split('\t')) > 2 else ''))]
    print(n, over, len(bad))
    sys.exit(1 if over or bad else 0)


if __name__ == '__main__':
    main()
