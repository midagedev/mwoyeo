#!/usr/bin/env python3
"""Translate / keep / either labels of the OCR words of the code use cases (set/k*.html), from their expected.txt notes.
usage: code_labels.py <ocr dir> <out.jsonl>        <ocr dir>/<case>.ocr.jsonl is ocrdump's output of the case's picture

The expected units come from score.rows(). A unit marked `(keep)` stays as written (`(keep:cmd)`, `(keep:path)`, `(keep:log)`,
`(keep:math)` ... name the reason; without one it is guessed from the shape, truth.reason_of); an unmarked one is translated; an
`(optional)` one is not judged (either); the substrings of `(inline: a ; b)` are kept inside the translated unit. Consecutive keep
units (optional ones do not break the run, a translated one does) form a region: a code block, a terminal session, an algorithm body.

Every OCR block, of both reads, is aligned with the whole text of the expected units (difflib: runs of >= 3 characters in order, gaps
between two characters of one unit belong to it), so a block that holds code and prose together (the document read often joins them) is
labelled word by word (a block of nothing but line numbers and diff marks is the gutter the case draws: keep, reason lineno / diffmark); a word needs half of its characters aligned to take the unit's truth, else it has none (a gutter number, a stray
glyph), and half of its characters inside an inline substring to be kept as inline code. Prose words get the truth of truth.prose_truth; a pure-ASCII token that the notes did not keep, inside prose of a CJK language,
is either. Output: same record kinds as label.py (paper header with `cases` and `regions`, block / span / near)."""
import collections, difflib, json, os, re, sys, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', 'usecase-bench'))
import score                                   # rows(): the expected units with their notes
from label import emit_block, fmt, WORD_FIELDS
from truth import near_tag, prose_truth, reason_of, KEEP, TRANSLATE, EITHER, NONE

SET = os.path.join(HERE, '..', 'usecase-bench', 'set')
GUTTER = re.compile(r'\d{1,3}[:：.]?|[+\-−]')


def norm_map(text):
    """Normalized text (NFKC, no spaces, lower case) and, per original character, its [start, end) in the normalized text."""
    out, spans = [], []
    for ch in text:
        n = re.sub(r'\s+', '', unicodedata.normalize('NFKC', ch)).lower()
        spans.append((len(out), len(out) + len(n))); out.extend(n)
    return ''.join(out), spans


def units_of(name, R):
    """Units with their reason and region."""
    U, region, nreg = [], '', 0
    for i, (text, opt, keep, cls, inline) in enumerate(R):
        u = {'i': i, 'text': text, 'opt': opt, 'keep': keep, 'inline': inline, 'reason': '', 'region': ''}
        if keep:
            u['reason'] = 'math' if cls == 'math' else (cls if cls != 'code' else reason_of(text))
            if not region: nreg += 1; region = f'{name}-r{nreg}'
            u['region'] = region
        elif not opt:
            region = ''
        U.append(u)
    return U


def align(btext, bn, units, owners, cat):
    """Per normalized character of the block: the index of the unit it belongs to, or -1."""
    assign = [-1] * len(bn)
    sm = difflib.SequenceMatcher(None, bn, cat, autojunk=False)
    for i, j, n in sm.get_matching_blocks():
        if n >= 3:
            for t in range(n): assign[i + t] = owners[j + t]
    for u in units:
        nu = norm_map(u['text'])[0]
        if 0 < len(nu) < 3 and nu == bn: assign = [u['i']] * len(bn)         # a short unit that is the whole block
    i = 0
    while i < len(assign):
        if assign[i] >= 0: i += 1; continue
        j = i
        while j < len(assign) and assign[j] < 0: j += 1
        if i > 0 and j < len(assign) and assign[i - 1] == assign[j]:
            for t in range(i, j): assign[t] = assign[j]
        i = j
    return assign


def find_all(hay, needle):
    out, i = [], hay.find(needle)
    while i >= 0:
        out.append((i, i + len(needle))); i = hay.find(needle, i + len(needle))
    return out


def find_fuzzy(hay, needle):
    best, span = 0.75, None
    for n in (len(needle) - 1, len(needle), len(needle) + 1, len(needle) + 2):
        for i in range(0, max(0, len(hay) - n) + 1):
            r = difflib.SequenceMatcher(None, hay[i:i + n], needle, autojunk=False).ratio()
            if r > best: best, span = r, (i, i + n)
    return [span] if span else []


def label_block(b, units, cat, owners, lang):
    text = b['t']
    bn, bspan = norm_map(text)
    assign = align(text, bn, units, owners, cat)
    cjk = lang in ('ja', 'ko') or lang.startswith('zh')
    words = []
    for s, e, x, y, w, h, t in b['w']:
        idx = [q for o in range(s, min(e, len(text))) for q in range(*bspan[o])]
        got = [assign[q] for q in idx if assign[q] >= 0]
        u = collections.Counter(got).most_common(1)[0][0] if idx and len(got) >= 0.5 * len(idx) else -1
        core = [q for q in idx if bn[q].isalnum()] or idx
        words.append([s, e, '', '', '', t, '', x, y, w, h, u, idx, core])
    # inline code of the prose units the block holds: found among the characters aligned to the unit
    inline = collections.defaultdict(dict)                 # unit -> word index -> reason
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
                    if wd[11] == ui and wd[13] and len(touched.intersection(wd[13])) > 0.5 * len(wd[13]): inline[ui][k] = reason_of(sub)
    # the gutter of a listing (line numbers, diff marks) is drawn by the case, not written in the notes: a block of nothing but such tokens
    gutter = bool(words) and all(wd[11] < 0 and GUTTER.fullmatch(wd[5]) for wd in words)
    prev = ''
    for k, wd in enumerate(words):
        t = wd[5]; ui = wd[11]
        if gutter:
            wd[2], wd[3] = KEEP, 'lineno' if t[:1].isdigit() else 'diffmark'
        elif ui < 0:
            wd[2], wd[3] = NONE, ''
        else:
            u = units[ui]
            if u['opt']: wd[2], wd[3] = EITHER, 'optional'
            elif u['keep']: wd[2], wd[3], wd[6] = KEEP, u['reason'], u['region']
            elif k in inline[ui]: wd[2], wd[3] = KEEP, inline[ui][k]
            else:
                wd[4] = near_tag(t)
                wd[2], wd[3] = prose_truth(t, wd[4], k == 0, prev, cjk)
        prev = t
    return words


def main():
    ocr_dir, out_path = sys.argv[1:3]
    rows = [l.rstrip('\n').split('\t') for l in open(f'{SET}/index.tsv')][1:]
    recs, header, regions = [], [], []
    for name, uc, lang, *_ in rows:
        if uc != 'code': continue
        path = f'{ocr_dir}/{name}.ocr.jsonl'
        if not os.path.exists(path): continue
        o = json.loads(open(path).read())
        U = units_of(name, score.rows(f'{SET}/{name}.expected.txt'))
        owners, parts = [], []
        for u in U:
            n = norm_map(u['text'])[0]; parts.append(n); owners += [u['i']] * len(n)
        cat = ''.join(parts)
        idx = int(re.search(r'\d+', name.split('-')[0]).group())
        header.append({'case': name, 'lang': lang, 'set': 'dev' if idx % 2 else 'hold',
                       'regions': sorted(set(u['region'] for u in U if u['region']))})
        regions += header[-1]['regions']
        for read in ('vn', 'doc'):
            seen = set()
            for bi, b in enumerate(o[read]):
                words = label_block(b, U, cat, owners, lang)
                seen.update(w[11] for w in words)
                emit_block(recs, f'{name}-{read}-{bi}', name, 1, read, b, [w[:11] for w in words], {'lang': lang})
            unread = [u['text'][:30] for u in U if u['i'] not in seen and not u['opt'] and len(norm_map(u['text'])[0]) >= 3]
            if unread: print(f'  {name} {read}: units with no aligned word: {unread}', file=sys.stderr)
    with open(out_path, 'w') as f:
        f.write(fmt({'kind': 'paper', 'schema': 2, 'word_fields': WORD_FIELDS, 'id': 'code', 'cases': header, 'regions': regions}) + '\n')
        for r in recs: f.write(fmt(r) + '\n')
    c = collections.Counter((r['read'], r['keep']) for r in recs if r['kind'] == 'block')
    s = collections.Counter((r['read'], r['reason']) for r in recs if r['kind'] == 'span')
    n = collections.Counter((r['read'], r['keep']) for r in recs if r['kind'] == 'near')
    print('code blocks', dict(sorted(c.items())))
    print('code keep spans', dict(sorted(s.items())))
    print('code near', dict(sorted(n.items())), 'regions', len(regions))


if __name__ == '__main__':
    main()
