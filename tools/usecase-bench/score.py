#!/usr/bin/env python3
"""Scores the bench outputs: for every expected unit, was it read whole (correct), cut in pieces (split), joined with other text
(merged), read with wrong glyphs (misread) or not at all (missing). Usage: score.py <out dir> [path ...]
Prints one line per use case and path for all pictures, the odd-numbered ones (the pictures the decider was tuned on) and the
even-numbered ones (held out). Per-picture detail goes to <out dir>/detail.txt."""
import re, sys, os, difflib, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
S = os.path.join(HERE, 'set')

def norm(s):
    return re.sub(r'\s+', '', unicodedata.normalize('NFKC', s)).lower()

def units(path):
    U = []
    for ln in open(path):
        ln = ln.rstrip('\n')
        if not ln: continue
        opt = 'optional' in ln
        ln = re.sub(r'\s*\((?:[^()]*(?:optional|header|row|merged|vertical|each|one sentence|figure labels|controls|timestamps|columns|table)[^()]*)\)\s*$', '', ln)
        if '|' in ln and not ln.startswith('$') and not ln.startswith('Feature'):
            parts = [p.strip() for p in ln.split('|')]
        else:
            parts = [ln]
        for p in parts:
            if p: U.append((p, opt))
    return U

def blocks(path):
    return [ln.rstrip('\n')[2:] for ln in open(path) if not ln.startswith('    → ') and re.match(r'^  \S', ln)]

def score(out, lang, name):
    if not os.path.exists(out): return None
    B = blocks(out); NB = [norm(b) for b in B]
    r = dict(units=0, correct=0, split=0, merged=0, misread=0, missing=0, detail=[])
    for u, opt in units(f'{S}/{name}.expected.txt'):
        nu = norm(u)
        if opt and not any(nu in b for b in NB): continue
        r['units'] += 1
        if nu in NB: r['correct'] += 1; continue
        if any(nu in b and len(b) > len(nu) for b in NB): r['merged'] += 1; r['detail'].append(('merged', u[:50])); continue
        parts = [b for b in NB if len(b) >= 2 and b in nu]
        if len(parts) >= 2 and len(''.join(parts)) >= 0.8 * len(nu): r['split'] += 1; r['detail'].append(('split', u[:50])); continue
        best = max((difflib.SequenceMatcher(None, nu, b).ratio() for b in NB), default=0)
        if best >= 0.75: r['misread'] += 1; r['detail'].append(('misread', u[:50]))
        else: r['missing'] += 1; r['detail'].append(('missing', u[:60]))
    return r

def main():
    out = sys.argv[1]; paths = sys.argv[2:] or ['vn', 'swift', 'auto']
    rows = [l.rstrip('\n').split('\t') for l in open(f'{S}/index.tsv')][1:]
    tot = {}; detail = open(f'{out}/detail.txt', 'w')
    for name, uc, lang, *_ in rows:
        for p in paths:
            f = f'{out}/out/{name}-{p}.out'
            r = score(f, lang, name)
            if not r: continue
            detail.write(f'{name} {p} {r["correct"]}/{r["units"]}\n' + ''.join(f'    {k}: {t}\n' for k, t in r['detail']))
            idx = int(re.search(r'\d+', name.split('-')[0]).group())
            for h in ('all', 'odd' if idx % 2 else 'even'):
                t = tot.setdefault((uc, p, h), dict(n=0, units=0, correct=0, split=0, merged=0, misread=0, missing=0))
                t['n'] += 1
                for k in ('units', 'correct', 'split', 'merged', 'misread', 'missing'): t[k] += r[k]
    for (uc, p, h), t in sorted(tot.items()):
        print(f'{uc:10s} {p:6s} {h:4s} n={t["n"]:2d} correct {t["correct"]:3d}/{t["units"]:3d} split {t["split"]} merged {t["merged"]} misread {t["misread"]} missing {t["missing"]}')
    # the totals over every use case
    for p in paths:
        for h in ('all', 'odd', 'even'):
            ts = [t for (uc, q, k), t in tot.items() if q == p and k == h]
            if ts: print(f'{"TOTAL":10s} {p:6s} {h:4s} n={sum(t["n"] for t in ts):2d} correct {sum(t["correct"] for t in ts):3d}/{sum(t["units"] for t in ts):3d}')

if __name__ == '__main__': main()
