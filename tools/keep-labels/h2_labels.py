#!/usr/bin/env python3
"""Translate / keep / either labels of the OCR words of the H2 screens, from the units h2.py wrote (round k3a, 2026-10-20).
usage: h2_labels.py <dir with <name>.units.json and <name>.ocr.jsonl> <out.jsonl> [--set h3]       (index.tsv of h2.py names the screens)
--set names the set in the header (`id`, and `set` of every case); the default is `h2`, so H2's files do not change. H3 (h3.py) runs this file with --set h3.

The OCR words of both Vision reads are aligned with the whole text of the screen's units (code_labels.align: difflib, runs of >= 3
characters in order), as the labels of the code cases are, and a word takes the class the CONSTRUCTION gave the unit it falls in
(addendum A1.1; truth.py's shape rules prose_truth / near_tag / reason_of are not called here):
  unit keep            -> keep, the unit's reason and region
  unit opt             -> either (a name, a time, program output in CJK)
  unit translate       -> translate for every token, but a token of an inline piece of its markup (keep with the author's reason, or either for a name /
                          a number) and a token without any letter (a number, a bracket, a dot: either, reason punct)
  no unit under a word -> no label (a stray glyph, the chrome the construction does not list)
A word needs half of its characters aligned to take a unit's class, and half of its characters inside an inline piece to take its reason.
Two things the construction knows without a text to align: on a screen with a gutter (the IDE look) a block of nothing but integers 1..n that nothing
aligned is the gutter (keep, lineno); on a screen that shows a diff a block of nothing but `+` / `-` is a diff mark (keep, diffmark). The document read
cuts these out as one-token blocks that are too short to align (the code cases' labeller does the same with a shape test).
Words of an `uncertain` unit or inline piece carry that flag (block field `unc`, the word indices): the disagreement sheet reads it.
Output: the record kinds of label.py (paper header with `cases` and `regions`, block / span)."""
import collections, json, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'usecase-bench'))
from code_labels import align, find_all, find_fuzzy, norm_map
from label import emit_block, fmt, WORD_FIELDS
from truth import KEEP, TRANSLATE, EITHER, NONE

NOT_KEPT = ('name', 'number')                         # inline reasons that are either, not keep


def label_block(b, units, cat, owners, gutter_n=0, diff=False):
    """The words of one OCR block -> [start, end, keep, reason, tag, text, region, x, y, w, h, unit, idx, core, uncertain]."""
    text = b['t']
    bn, bspan = norm_map(text)
    assign = align(text, bn, units, owners, cat)
    words = []
    for s, e, x, y, w, h, t in b['w']:
        idx = [q for o in range(s, min(e, len(text))) for q in range(*bspan[o])]
        got = [assign[q] for q in idx if assign[q] >= 0]
        u = collections.Counter(got).most_common(1)[0][0] if idx and len(got) >= 0.5 * len(idx) else -1
        core = [q for q in idx if bn[q].isalnum()] or idx
        words.append([s, e, '', '', '', t, '', x, y, w, h, u, idx, core, False])
    inline = collections.defaultdict(dict)            # unit -> word index -> (reason, uncertain)
    for ui in sorted(set(wd[11] for wd in words if wd[11] >= 0)):
        u = units[ui]
        if u['keep'] or u['opt'] or not u['inline']: continue
        pos = [q for q in range(len(bn)) if assign[q] == ui]
        hay = ''.join(bn[q] for q in pos)
        for sub in u['inline']:
            ns = norm_map(sub)[0]
            hits = find_all(hay, ns) or find_fuzzy(hay, ns)
            for lo, hi in hits:
                touched = set(pos[lo:hi])
                for k, wd in enumerate(words):
                    if wd[11] == ui and wd[13] and len(touched.intersection(wd[13])) > 0.5 * len(wd[13]):
                        inline[ui][k] = (u['inline_reasons'][sub], sub in u['inline_unc'])
    for k, wd in enumerate(words):
        t, ui = wd[5], wd[11]
        if ui < 0: wd[2], wd[3] = NONE, ''; continue
        u = units[ui]
        wd[14] = bool(u['uncertain'])
        if u['opt']: wd[2], wd[3] = EITHER, u['reason']
        elif u['keep']: wd[2], wd[3], wd[6] = KEEP, u['reason'], u['region']
        elif k in inline[ui]:
            r, unc = inline[ui][k]
            wd[2], wd[3] = (EITHER, r) if r in NOT_KEPT else (KEEP, r)
            wd[14] = wd[14] or unc
        elif not any(ch.isalpha() for ch in t): wd[2], wd[3] = EITHER, 'punct'
        else: wd[2], wd[3] = TRANSLATE, 'prose'
    if words and all(wd[11] < 0 for wd in words):
        if gutter_n and all(re.fullmatch(r'\d{1,3}', wd[5]) and 1 <= int(wd[5]) <= gutter_n for wd in words):
            for wd in words: wd[2], wd[3] = KEEP, 'lineno'
        elif diff and all(wd[5] in ('+', '-', '−') for wd in words):
            for wd in words: wd[2], wd[3] = KEEP, 'diffmark'
    return words


def main():
    d, out_path = sys.argv[1:3]
    sname = sys.argv[sys.argv.index('--set') + 1] if '--set' in sys.argv else 'h2'
    rows = [l.rstrip('\n').split('\t') for l in open(f'{d}/index.tsv')][1:]
    recs, header, regions = [], [], []
    for name, look, lang, *_ in rows:
        path = f'{d}/{name}.ocr.jsonl'
        if not os.path.exists(path): print(f'  {name}: no OCR read', file=sys.stderr); continue
        o = json.loads(open(path).read())
        meta = json.load(open(f'{d}/{name}.units.json'))
        U = meta['units']
        owners, parts = [], []
        for u in U:
            n = norm_map(u['text'])[0]; parts.append(n); owners += [u['i']] * len(n)
        cat = ''.join(parts)
        gutter_n = max([len(u['text'].split()) for u in U if u['kind'] == 'gutter'] or [0])
        diff = any(u['reason'] == 'diffmark' for u in U)
        header.append({'case': name, 'lang': lang, 'set': sname, 'look': meta['look'], 'scene': meta['scene'], 'regions': meta['regions']})
        regions += meta['regions']
        for read in ('vn', 'doc'):
            seen = set()
            for bi, b in enumerate(o[read]):
                words = label_block(b, U, cat, owners, gutter_n, diff)
                seen.update(w[11] for w in words)
                emit_block(recs, f'{name}-{read}-{bi}', name, 1, read, b, [w[:11] for w in words],
                           {'lang': lang, 'look': meta['look'], 'scene': meta['scene'], 'unc': [k for k, w in enumerate(words) if w[14]]})
            unread = [u['text'][:30] for u in U if u['i'] not in seen and not u['opt'] and len(norm_map(u['text'])[0]) >= 3]
            if unread: print(f'  {name} {read}: units with no aligned word: {len(unread)} {unread[:3]}', file=sys.stderr)
    with open(out_path, 'w') as f:
        f.write(fmt({'kind': 'paper', 'schema': 2, 'word_fields': WORD_FIELDS, 'id': sname, 'cases': header, 'regions': regions}) + '\n')
        for r in recs: f.write(fmt(r) + '\n')
    c = collections.Counter((r['read'], r['keep']) for r in recs if r['kind'] == 'block')
    s = collections.Counter((r['read'], r['reason']) for r in recs if r['kind'] == 'span')
    print(sname, 'blocks', dict(sorted(c.items())))
    print(sname, 'keep spans', dict(sorted(s.items())), 'regions', len(regions))


if __name__ == '__main__':
    main()
