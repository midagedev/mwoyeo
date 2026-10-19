#!/usr/bin/env python3
"""Scores the paper bench outputs of run.sh: what is wrong with the translated pages of the paper PDF (from 2026-10-19 our own
paper, tools/paper-own/mwoyeo-method; before that arXiv 1706.03762, whose results are not comparable: another document).
Usage: score.py <out dir> [--detail]      (python3 -I)

Per page (p1..pN, whole pages; N is the number of pages of the PDF) and in total:
  formula_translated  translated sources that hold a sign of mathematics (= ∈ × ∑ √ ^ _ ... or a call with one-letter
                      arguments, "Attention(Q, K, V)") and are not a body sentence: a source with six or more prose words (a run
                      of three letters or more with a vowel), or one that allow.txt lists, is a sentence that holds one formula
                      and is rightly translated.
  math_heavy_kept     blocks left as written because they are mostly inline mathematics (`TranslationFilter.isMathHeavy`, D5): the
                      render's `ocr.kept.math`; the blocks are listed in detail.txt from the trace for review.
  overlaps/spill/cut/clipped  the sums of the render's `layout:` line (clipped: a translation that needs more room than its patch
                      has at the smallest size). ellipsis: of those, the translations cut to fit and ended in "…" (D4).
  big_text            drawn body-like blocks (40 or more characters per source line) whose font size is over 1.3 times the
                      median of the page's body-like blocks (the `block:` lines of the render).
  cross_col           pairs of blocks where one block's source rect holds at least half of the other's: a join of lines across
                      a column gap (the author header of page 1: two columns' emails in one block) reaches over the block of the
                      column between them. Listed in detail.txt. The check is geometric, so it holds for any author block.
  debris              body text with OCR formula debris: translated blocks (paragraphs, not already in formula_translated) whose
                      translation carries three or more one-letter Latin or Greek tokens, or a stray symbol from € ∈ ° × that the
                      OCR made of a typeset sign ("W° € Be xx" on page 5 comes back as "Wo € IR 모델 × dx"). Reported for pages
                      3-6; nothing fixes it yet (the inline-math round owns it). Listed in detail.txt.
Per crop (p<N>-c1, p<N>-c2: top and bottom edge run through a line of text; p<N>-s1: left and right edge cut the words):
  edge_cut            translated blocks whose source lines touch the top or bottom edge of the crop (within 4 px, CaptureEdge.tolerance): a line cut
                      by the edge was read and drawn over.  near: the same within 8 px but not 4 (is 4 px too tight?).
                      side_cut: the same at the left and right edge.
Also prints the translation-flagged sources of every render to <out dir>/detail.txt."""
import os
import re
import statistics
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))
MATH = re.compile(r'[=∈×∑√^_∞≈≠≤≥±∂∇∫∏→←]|[A-Za-z]\w* ?\(\s*[A-Za-z](?:\s*,\s*[A-Za-z])*\s*\)')
VOWELS = set('aeiouyAEIOUY')
BODY_CHARS = 40
BIG = 1.3
EDGE = 4   # CaptureEdge.tolerance
CROSS = 0.5  # share of the smaller core that another core must cover for cross_col
NEAR = 8   # a looser distance: lines cut by an edge whose box ends a few pixels short of it (tells whether EDGE is too tight)


def norm(s):
    return re.sub(r'\s+', ' ', unicodedata.normalize('NFKC', s)).strip().lower()


def prose_words(s):
    return sum(1 for w in re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)?", s) if len(w) >= 3 and any(c in VOWELS for c in w))


def allowed(source, entries):
    n = norm(source)
    return prose_words(source) >= 6 or any(e in n for e in entries)


def read_allow():
    path = os.path.join(HERE, 'allow.txt')
    if not os.path.exists(path):
        return []
    return [norm(l) for l in open(path, encoding='utf-8') if l.strip() and not l.startswith('#')]


def parse(path):
    r = dict(layout=None, image=None, blocks=[], pairs=[])
    src = None
    for ln in open(path, encoding='utf-8', errors='replace'):
        ln = ln.rstrip('\n')
        m = re.match(r'layout: blocks=(\d+) overlaps=(\d+) spill=(\d+) cut=(\d+)(?: clipped=(\d+))?', ln)
        if m:
            r['layout'] = dict(zip(('blocks', 'overlaps', 'spill', 'cut', 'clipped'), (int(g or 0) for g in m.groups())))
            continue
        m = re.match(r'image: (\d+)×(\d+)', ln)
        if m:
            r['image'] = (int(m.group(1)), int(m.group(2)))
            continue
        m = re.match(r'block: core=(\d+),(\d+),(\d+),(\d+) text=(\d+),(\d+),(\d+),(\d+) size=([\d.]+) lines=(\d+) chars=(\d+) clipped=(\d)(?: ellipsis=(\d))? "(.*)"$', ln)
        if m:
            g = m.groups()
            r['blocks'].append(dict(core=tuple(map(int, g[0:4])), text=tuple(map(int, g[4:8])), size=float(g[8]), lines=int(g[9]),
                                    chars=int(g[10]), clipped=int(g[11]), ellipsis=int(g[12] or 0), source=g[13]))
            continue
        if re.match(r'^  \S', ln) and not ln.startswith('  overlap:') and not ln.startswith('  cut:') and not ln.startswith('  spill:'):
            src = ln[2:]
        elif ln.startswith('    → ') and src is not None:
            r['pairs'].append((src, ln[6:]))
            src = None
    return r


def kept_math(out, name):
    """The blocks the render left as written because they are mostly inline mathematics (D5): the `ocr.kept.math` count of the
    render's work line, and the `kept math` lines of its trace (.err) for review."""
    count = 0
    for ln in open(os.path.join(out, name + '.out'), encoding='utf-8', errors='replace'):
        m = re.search(r'ocr\.kept\.math=(\d+)', ln)
        if m:
            count = int(m.group(1))
    lines = []
    err = os.path.join(out, name + '.err')
    if os.path.exists(err):
        lines = [ln.split('[trace] ', 1)[1].rsplit(' ms', 1)[0] for ln in open(err, encoding='utf-8', errors='replace') if '[trace] kept math' in ln]
    return count, lines


def formula_translated(r, allow):
    out = []
    for s, t in r['pairs']:
        if t == '(no translation)' or t == s:
            continue
        if MATH.search(s) and not allowed(s, allow):
            out.append((s, t))
    return out


DEBRIS_SYMBOLS = '€∈°×'
ONE_LETTER = re.compile(r'(?<![\w])[A-Za-zΑ-Ωα-ω](?![\w])')


def debris(r, flagged):
    """Translated pairs whose translation shows OCR formula debris: 3+ one-letter tokens or a stray € ∈ ° ×."""
    out = []
    for s, t in r['pairs']:
        if t == '(no translation)' or t == s or (s, t) in flagged:
            continue
        if len(ONE_LETTER.findall(t)) >= 3 or any(c in t for c in DEBRIS_SYMBOLS):
            out.append((s, t))
    return out


def big_text(r):
    body = [b for b in r['blocks'] if b['chars'] / max(1, b['lines']) >= BODY_CHARS and b['size'] > 0]
    if len(body) < 3:
        return []
    med = statistics.median(b['size'] for b in body)
    return [b for b in body if b['size'] > BIG * med]


def cross_column(r):
    """Pairs of blocks whose source rects (cores) overlap by at least half of the smaller one's area."""
    out = []
    bs = r['blocks']
    for i in range(len(bs)):
        for j in range(i + 1, len(bs)):
            a, b = bs[i]['core'], bs[j]['core']
            w = min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0])
            h = min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1])
            if w > 0 and h > 0 and w * h >= CROSS * min(a[2] * a[3], b[2] * b[3]):
                out.append((bs[i], bs[j]))
    return out


def edge_cut(r):
    if not r['image']:
        return 0, 0, 0
    w, h = r['image']
    top_bottom = sum(1 for b in r['blocks'] if b['core'][1] <= EDGE or b['core'][1] + b['core'][3] >= h - EDGE)
    near = sum(1 for b in r['blocks'] if EDGE < b['core'][1] <= NEAR or h - NEAR <= b['core'][1] + b['core'][3] < h - EDGE)
    sides = sum(1 for b in r['blocks'] if b['core'][0] <= EDGE or b['core'][0] + b['core'][2] >= w - EDGE)
    return top_bottom, sides, near


def main():
    out = sys.argv[1]
    allow = read_allow()
    names = sorted((f[:-4] for f in os.listdir(out) if f.endswith('.out')),
                   key=lambda n: (0 if re.fullmatch(r'p\d+', n) else 1, [int(x) if x.isdigit() else x for x in re.split(r'(\d+)', n)]))
    detail = []
    pages, crops = [], []
    for n in names:
        r = parse(os.path.join(out, n + '.out'))
        if r['layout'] is None:
            (pages if re.fullmatch(r'p\d+', n) else crops).append((n, None))
            continue
        ft = formula_translated(r, allow)
        bt = big_text(r)
        et, es, nr = edge_cut(r)
        km, kml = kept_math(out, n)
        cx = cross_column(r)
        db = debris(r, set(ft))
        row = dict(r['layout'], formula=len(ft), math_kept=km, big=len(bt), cross=len(cx), debris=len(db), edge=et, side=es, near=nr, ellipsis=sum(b['ellipsis'] for b in r['blocks']))
        (pages if re.fullmatch(r'p\d+', n) else crops).append((n, row))
        for line in kml:
            detail.append(f'{n} math_heavy_kept: {line[:150]}')
        for s, t in ft:
            detail.append(f'{n} formula_translated: {s[:90]!r} -> {t[:60]!r}')
        for b in bt:
            detail.append(f'{n} big_text: size={b["size"]} {b["source"][:60]!r}')
        for s, t in db:
            detail.append(f'{n} debris: {s[:80]!r} -> {t[:80]!r}')
        for a, b in cx:
            detail.append(f'{n} cross_col: {a["source"][:40]!r} core={a["core"]} holds {b["source"][:40]!r} core={b["core"]}')
        for b in r['blocks']:
            if b['clipped']:
                detail.append(f'{n} clipped{" ellipsis" if b["ellipsis"] else ""}: size={b["size"]} {b["source"][:60]!r}')
            if r['image'] and (b['core'][1] <= EDGE or b['core'][1] + b['core'][3] >= r['image'][1] - EDGE) and not re.fullmatch(r'p\d+', n):
                detail.append(f'{n} edge_cut: core={b["core"]} {b["source"][:60]!r}')
    cols = ['blocks', 'formula', 'math_kept', 'overlaps', 'spill', 'cut', 'clipped', 'ellipsis', 'big', 'cross']
    print('page   ' + ' '.join(f'{c:>8}' for c in cols))
    total = dict.fromkeys(cols, 0)
    for n, row in pages:
        if row is None:
            print(f'{n:<6} no layout line (render failed?)')
            continue
        print(f'{n:<6} ' + ' '.join(f'{row[c]:>8}' for c in cols))
        for c in cols:
            total[c] += row[c]
    print(f'{"TOTAL":<6} ' + ' '.join(f'{total[c]:>8}' for c in cols))
    p36 = sum(row['formula'] for n, row in pages if row and n in ('p3', 'p4', 'p5', 'p6'))
    d36 = sum(row['debris'] for n, row in pages if row and n in ('p3', 'p4', 'p5', 'p6'))
    print(f'formula_translated pages 3-6: {p36}   debris pages 3-6: {d36}')
    cc = ['blocks', 'formula', 'math_kept', 'edge', 'near', 'side', 'overlaps', 'spill', 'cut', 'clipped', 'ellipsis', 'big', 'cross']
    print('crop   ' + ' '.join(f'{c:>8}' for c in cc))
    ctotal = dict.fromkeys(cc, 0)
    for n, row in crops:
        if row is None:
            print(f'{n:<6} no layout line (render failed?)')
            continue
        print(f'{n:<6} ' + ' '.join(f'{row[c]:>8}' for c in cc))
        for c in cc:
            ctotal[c] += row[c]
    print(f'{"TOTAL":<6} ' + ' '.join(f'{ctotal[c]:>8}' for c in cc))
    print(f'edge_cut (top/bottom crops c1,c2): {sum(row["edge"] for n, row in crops if row and "-c" in n)}  '
          f'side_cut (crops s1): {sum(row["side"] for n, row in crops if row and "-s" in n)}')
    with open(os.path.join(out, 'detail.txt'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(detail) + '\n')


if __name__ == '__main__':
    main()
