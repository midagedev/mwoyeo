#!/usr/bin/env python3
"""Scores the bench outputs: for every expected unit, was it read whole (correct), cut in pieces (split), joined with other text
(merged), read with wrong glyphs (misread) or not at all (missing). Usage: score.py <out dir> [path ...]
Prints one line per use case and path for all pictures, the odd-numbered ones (the pictures the decider was tuned on) and the
even-numbered ones (held out). Per-picture detail goes to <out dir>/detail.txt.

Keep columns (only for pictures whose expected.txt carries notes; the lines of every other picture are unchanged): a unit marked
`(keep)` (or `(keep:math)`) must stay as written, one marked `(inline: a ; b)` is translated but the substrings must come back
verbatim, an unmarked one is translated, `(optional)` ones are not judged. From the render's source/translation pairs:
  kept_ok        keep units shown as written (the block that holds the unit has its translation equal to its source)
  translated_ok  unmarked units translated (translation differs from the source)
  inline_ok      inline substrings found verbatim in the translation of a unit that was translated
Each is counted over the units whose block was read (a unit not read is the segmentation score's missing)."""
import re, sys, os, difflib, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
S = os.path.join(HERE, 'set')

def norm(s):
    return re.sub(r'\s+', '', unicodedata.normalize('NFKC', s)).lower()

NOTE = re.compile(r'\s*\((keep(?::\w+)?|inline:.*)\)\s*$')

def rows(path):
    """(text, optional, keep, class, inline substrings) of every expected unit; a line with a keep / inline note is one unit."""
    U = []
    for ln in open(path):
        ln = ln.rstrip('\n')
        if not ln: continue
        m = NOTE.search(ln)
        if m:
            note = m.group(1)
            keep = note.startswith('keep')
            inline = [t.strip() for t in note[len('inline:'):].split(' ; ')] if note.startswith('inline:') else []
            if ln[:m.start()].strip(): U.append((ln[:m.start()].strip(), False, keep, note[5:] or 'code' if keep else '', inline))
            continue
        opt = 'optional' in ln
        ln = re.sub(r'\s*\((?:[^()]*(?:optional|header|row|merged|vertical|each|one sentence|figure labels|controls|timestamps|columns|table)[^()]*)\)\s*$', '', ln)
        if '|' in ln and not ln.startswith('$') and not ln.startswith('Feature'):
            parts = [p.strip() for p in ln.split('|')]
        else:
            parts = [ln]
        for p in parts:
            if p: U.append((p, opt, False, '', []))
    return U

def units(path):
    return [(t, o) for t, o, *_ in rows(path)]

def blocks(path):
    return [ln.rstrip('\n')[2:] for ln in open(path) if not ln.startswith('    → ') and re.match(r'^  \S', ln)]

def pairs(path):
    """(source, translation or None) of every block of a render, in the order blocks() has them."""
    L = [ln.rstrip('\n') for ln in open(path)]
    P = []
    for i, ln in enumerate(L):
        if ln.startswith('    → ') or not re.match(r'^  \S', ln): continue
        t = L[i + 1][6:] if i + 1 < len(L) and L[i + 1].startswith('    → ') else None
        P.append((ln[2:], t))
    return P

def keep_score(out, name):
    """kept_ok / translated_ok / inline_ok of one picture, or None when its expected.txt carries no notes."""
    R = rows(f'{S}/{name}.expected.txt')
    if not any(keep or inline for _, _, keep, _, inline in R): return None
    P = pairs(out); NB = [norm(b) for b, _ in P]
    k = dict(kept=[0, 0], translated=[0, 0], inline=[0, 0], detail=[])
    for u, opt, keep, cls, inline in R:
        if opt: continue
        nu = norm(u)
        hit = [i for i, b in enumerate(NB) if nu in b]                                   # read whole, or merged with other text
        if not hit:
            parts = [i for i, b in enumerate(NB) if len(b) >= 2 and b in nu]              # cut in pieces
            if len(parts) >= 2 and sum(len(NB[i]) for i in parts) >= 0.8 * len(nu): hit = parts
        if not hit:
            best = max(range(len(NB)), key=lambda i: difflib.SequenceMatcher(None, nu, NB[i]).ratio(), default=None)   # misread
            if best is not None and difflib.SequenceMatcher(None, nu, NB[best]).ratio() >= 0.75: hit = [best]
        done = [P[i] for i in hit if P[i][1] not in (None, '(no translation)')]
        if not done: continue
        same = [norm(t) == norm(b) for b, t in done]
        if keep:
            k['kept'][1] += 1
            if all(same): k['kept'][0] += 1
            else: k['detail'].append(('kept_fail', u[:60]))
        else:
            k['translated'][1] += 1
            if not any(same): k['translated'][0] += 1
            else: k['detail'].append(('translated_fail', u[:60]))
            for sub in inline:
                k['inline'][1] += 1
                if not any(same) and all(norm(sub) in norm(t) for _, t in done): k['inline'][0] += 1
                else: k['detail'].append(('inline_fail', sub[:60]))
    return k

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
            kp = keep_score(f, name)
            detail.write(f'{name} {p} {r["correct"]}/{r["units"]}\n' + ''.join(f'    {k}: {t}\n' for k, t in r['detail'])
                         + (''.join(f'    {k}: {t}\n' for k, t in kp['detail']) if kp else ''))
            idx = int(re.search(r'\d+', name.split('-')[0]).group())
            for h in ('all', 'odd' if idx % 2 else 'even'):
                t = tot.setdefault((uc, p, h), dict(n=0, units=0, correct=0, split=0, merged=0, misread=0, missing=0))
                t['n'] += 1
                for k in ('units', 'correct', 'split', 'merged', 'misread', 'missing'): t[k] += r[k]
                if kp:
                    for k in ('kept', 'translated', 'inline'):
                        a = t.setdefault('keep_' + k, [0, 0]); a[0] += kp[k][0]; a[1] += kp[k][1]
    def keep_cols(ts):
        """The keep columns of a group, appended only when some picture of it carries notes."""
        if not any('keep_kept' in t for t in ts): return ''
        g = lambda k: [sum(t.get('keep_' + k, [0, 0])[i] for t in ts) for i in (0, 1)]
        return ' | ' + ' '.join(f'{c} {g(k)[0]}/{g(k)[1]}' for c, k in (('kept_ok', 'kept'), ('translated_ok', 'translated'), ('inline_ok', 'inline')))
    for (uc, p, h), t in sorted(tot.items()):
        print(f'{uc:10s} {p:6s} {h:4s} n={t["n"]:2d} correct {t["correct"]:3d}/{t["units"]:3d} split {t["split"]} merged {t["merged"]} misread {t["misread"]} missing {t["missing"]}' + keep_cols([t]))
    # the totals over every use case
    for p in paths:
        for h in ('all', 'odd', 'even'):
            ts = [t for (uc, q, k), t in tot.items() if q == p and k == h]
            if ts: print(f'{"TOTAL":10s} {p:6s} {h:4s} n={sum(t["n"] for t in ts):2d} correct {sum(t["correct"] for t in ts):3d}/{sum(t["units"] for t in ts):3d}' + keep_cols(ts))

if __name__ == '__main__': main()
