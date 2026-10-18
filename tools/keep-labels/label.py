#!/usr/bin/env python3
"""Math / prose labels of OCR words, blocks and spans of one paper, from the glyphs of its PDF.
usage: label.py <id> <glyphs.jsonl> <ocr.jsonl> <latex counts.json> <out.jsonl> [--report]

Truth. pdfglyphs gives every glyph of the PDF with its font. A glyph is math when it is set in a math font (CMMI, CMSY, CMEX,
MSAM, MSBM, txfonts' rtxmi / txsy / txex, ...), or in a roman face the paper uses only for math (CMR in a paper whose text is
Times, rtxr, the script sizes of CMR), or when it is a digit, bracket, operator or function name attached to such glyphs with the
spacing TeX puts between them (a thick space beside an operator, none between ordinary symbols, never a word space). Glyphs
that touch each other that way form a group; punctuation and unmatched brackets at its edges are cut off. A group is one
formula of the page (display or inline); an inline one stands within twelve points of a text letter on its line.
Where the text face is also the math roman (CM text; digits and brackets of txfonts) a lone number set in math cannot be told
from text by any means, pixels included: those words are `u` (unsure) and count as `either`: no harm is done whichever way the engine goes.

Each OCR word (both reads of ocrdump: `vn`, the line grouper, and `doc`, the document model) takes the label of the glyphs whose
centres lie in its box: `m` math, `c` set in a typewriter face (code, URLs, e-mail addresses), `p` prose, `u` unsure, `-` no glyph under
it (a raster figure), `f` text of a drawn figure. Then the translate / keep / either truth of the word (truth.py): `m` and `c` are keep
(reason math; url, path, id or code by shape), a prose word is translate unless it is a number, version, name or bare punctuation
(either) or a URL, path or identifier (keep); `u` and `f` are either; `-` has no truth. A block is `keep` when it holds keep words and
no translate word, `translate` when the other way round, `mixed` when it holds both, `either` when nothing in it is scored, `none` when
nothing has a truth. A keep span is a maximal run of keep words in the sequence of scored words (either words are skipped); a `near`
record is a word of the shapes that are mistaken for mathematics or code, with its truth. A display formula (no text letter close
beside it on its line) is a region: its words carry the region id, so the report can ask whether OCR kept it whole.

Output (JSONL, stable order and formatting): one `paper` line (counts, the check against the LaTeX source, the regions), then per page
and read the `block` lines (id, page, read, rect, text, keep class, stats, words [start, end, keep, reason, tag, text, region] with the
range in Characters of `text`; `keep` is keep | translate | either | '' and `reason` rides along, as on every block, span and near line), the `span` lines (a keep span: block, range, rect, text, reason, words [first, last]) and the `near`
lines (word, tag, keep, reason)."""
import collections, json, math, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from truth import near_tag, prose_truth, reason_of, keep_runs, block_class, KEEP, TRANSLATE, EITHER, NONE, SCORED

SCALE = 2.67

ANCHOR_FONT = re.compile(r'^(CM(MI|SY|EX|BSY|MIB)\d*|MS[AB]M\d*|r?tx(mi|sy|sya|syb|ex)\w*|TX\w+|LM(MI|SY|EX)\w*|\w*Math\w*|'
                         r'EU[FSR]M\d*|rsfs\d*|stmary\w*|wasy\w*|MnSymbol\w*|NewTX\w*|STIX(Math|Size)\w*|Symbol|StandardSymL\w*)$')
CM_ROMAN = re.compile(r'^CMR(\d+)$')
MATH_ONLY_ROMAN = re.compile(r'^rtxr$')
OPERATOR_NAMES = {'sin', 'cos', 'tan', 'cot', 'sec', 'csc', 'sinh', 'cosh', 'tanh', 'coth', 'exp', 'log', 'ln', 'lg', 'max', 'min', 'sup', 'inf', 'lim',
                  'det', 'dim', 'ker', 'deg', 'arg', 'gcd', 'mod', 'Pr', 'Tr', 'tr', 'rank', 'diag', 'sgn', 'softmax', 'argmax', 'argmin'}
LIGATURE = re.compile(r'^(f[fil]+|ff|fi|fl|ffi|ffl|[ﬀ-ﬆ])$')
# binary operators and relations: TeX sets a medium or thick space beside them, so a glyph may stand 0.35 em off one
BINREL = set('=<>+−±×÷·∘∈∉∋⊂⊃⊆⊇⊄≤≥≪≫≈≠≡≃≅∼∝→←↔⇒⇐⇔↦∪∩∧∨⊗⊕⊙⋅∗*/|⟨⟩∣')
OPERATORS = set('=+<>/*|!′\'∣')
WORD_FIELDS = ['start', 'end', 'keep', 'reason', 'tag', 'text', 'region']
MONO_FONT = re.compile(r'(?i)(SFTT|CMTT|CMITT|CMSLTT|LMMono|LMTT|NimbusMon|Courier|Mono|Consol|Menlo|Inconsolata|Typewriter)')
GREEK_CAP = set('ΓΔΘΛΞΠΣΥΦΨΩ∆\u2126')


def load_glyphs(path):
    pages = collections.defaultdict(list)
    for line in open(path):
        g = json.loads(line)
        pages[g['p']].append(g)
    return pages


def profile(pages):
    """The text face: the commonest font that is not a math font, and its commonest size."""
    count = collections.Counter(); sizes = collections.defaultdict(collections.Counter)
    for gl in pages.values():
        for g in gl:
            if g.get('d') or ANCHOR_FONT.match(g['f']) or not g['u'].isalpha(): continue
            count[g['f']] += 1; sizes[g['f']][round(g['s'], 1)] += 1
    body = count.most_common(1)[0][0]
    family = re.sub(r'(Regu|Roman|Rm|-?Regular)$', '', body)
    italic = [f for f in count if f != body and f.startswith(family) and re.search(r'(Ital|Italic|Oblique)$', f)]
    # where no math font holds Latin letters (txfonts: the math italic is the text italic), short runs of italic letters are the variables
    latin_in_math = sum(1 for gl in pages.values() for g in gl if ANCHOR_FONT.match(g['f']) and re.fullmatch(r'[A-Za-z]', g['u']) and not g.get('d'))
    latin_italic = sum(count[f] for f in italic)
    return {'body': body, 'size': sizes[body].most_common(1)[0][0], 'cm_text': bool(CM_ROMAN.match(body)),
            'italic': italic, 'italic_math': bool(italic) and latin_in_math < 0.1 * latin_italic}


def kind_of(g, prof):
    """('A' math for certain | 'W' ambiguous roman | 'T' text, shape class)."""
    f, u = g['f'], g['u']
    if not u or u.isspace(): return 'T', 'S'
    c = u[0]
    if g.get('d'): return 'T', 'F'
    k = 'T'
    if ANCHOR_FONT.match(f): k = 'A'
    elif MATH_ONLY_ROMAN.match(f): k = 'T' if LIGATURE.match(u) else 'A'
    elif CM_ROMAN.match(f):
        if prof['cm_text']: k = 'A' if g['s'] < 0.85 * prof['size'] else 'W'
        else: k = 'A'
    elif f == prof['body']: k = 'W'
    if k == 'T': return 'T', 'T'
    if c in '∗†‡§¶': return 'W', 'X'                                 # footnote marks: beside a formula at most
    if c.isdigit(): cls = 'D'
    elif c in '([{⟨': cls = 'Bo'
    elif c in ')]}⟩': cls = 'Bc'
    elif c in BINREL: cls = 'O'
    elif c in ',;': cls = 'P' if k == 'W' else 'C'
    elif c in '.:-‐‑–—': cls = 'P'
    elif c.isalpha(): cls = 'V' if k == 'W' else 'L'
    else: cls = 'X'
    if k == 'W' and (c in GREEK_CAP or (c in '×·±' or 0x2190 <= ord(c) <= 0x22FF)):
        k = 'A'
    return k, cls


def allowed(a, b, ka, kb):
    """May glyphs a and b (kind, class pairs, with boxes) belong to one formula?"""
    (a_k, a_c), (b_k, b_c) = ka, kb
    em = max(a['s'], b['s'])
    l, r = (a, b) if a['x'] <= b['x'] else (b, a)
    gap = (r['x'] - (l['x'] + l['w'])) / em
    tall = lambda g: g['u'][:1] in '√∑∏∫' or 'EX' in g['f'] or 'ex' in g['f']
    similar = min(a['s'], b['s']) > 0.85 * em
    dy = abs(a['y'] - b['y']) / em
    if a_c == 'P' or b_c == 'P':
        # a decimal point or a thousands comma between digits is part of the number; punctuation joins nothing else
        p, o = (a, b) if a_c == 'P' else (b, a)
        oc = b_c if p is a else a_c
        return p['u'] in ('.', ',') and oc == 'D' and abs(p['y'] - o['y']) <= 0.12 * em and -0.05 <= gap <= 0.06
    weak = a_k == 'W' or b_k == 'W'
    if weak:
        # an ambiguous glyph stands beside a formula on its baseline or as its script, never under or over it
        if gap < -0.12 and not (tall(a) or tall(b)): return False
        if tall(a) or tall(b): ok = dy <= 1.1
        elif similar: ok = dy <= 0.12
        else:
            big_c = a_c if a['s'] >= b['s'] else b_c       # a script hangs on a bigger glyph, which is not an ambiguous letter
            ok = dy <= 0.55 and not (big_c == 'V' and (a_k if a['s'] >= b['s'] else b_k) == 'W')
    else:
        # a radical or a delimiter built of CMEX pieces reaches below its origin
        ok = dy <= (3.0 if (tall(a) or tall(b)) else (0.45 if similar else 0.65))
    if not ok: return False
    t = 0.10
    if a_k == 'A' and b_k == 'A': t = 0.22
    if (a_c == 'V' and a_k == 'W') or (b_c == 'V' and b_k == 'W'):
        # an ambiguous letter is part of a formula as a script (`d_model`), or in a name that runs into its argument (`sin(`)
        # or its own letters; words of the text stand beside formulas at every other distance
        v, o = (a, b) if (a_c == 'V' and a_k == 'W') else (b, a)
        oc = b_c if v is a else a_c
        ov_k = b_k if v is a else a_k
        script = v['s'] < 0.85 * o['s']
        name = abs(gap) <= 0.04 and (oc == 'V' or (oc == 'Bo' and v['x'] < o['x']))
        return script and gap <= 0.10 or name
    elif a_c == 'O' or b_c == 'O': t = 0.35
    elif a_c in 'C' or b_c in 'C': t = 0.25
    return gap <= t


def groups_of(gl, prof):
    """Formula groups of one page: lists of glyph indices, plus which are math."""
    kinds = [kind_of(g, prof) for g in gl]
    if prof['italic_math']:
        i = 0
        while i < len(gl):
            if gl[i]['f'] not in prof['italic'] or not gl[i]['u'].isalpha(): i += 1; continue
            j = i
            while (j + 1 < len(gl) and gl[j + 1]['f'] in prof['italic'] and gl[j + 1]['u'].isalpha() and abs(gl[j + 1]['y'] - gl[j]['y']) <= 0.5 * gl[j]['s']
                   and gl[j + 1]['x'] - (gl[j]['x'] + gl[j]['w']) <= 0.12 * gl[j]['s']): j += 1
            if j - i + 1 <= 3:
                for k in range(i, j + 1): kinds[k] = ('A', 'L')
            i = j + 1
    # upright operator names (sin, max, ...) are mathematics when a formula stands beside them
    i = 0
    while i < len(gl):
        if kinds[i] != ('W', 'V'): i += 1; continue
        j = i
        while j + 1 < len(gl) and kinds[j + 1] == ('W', 'V') and abs(gl[j + 1]['y'] - gl[j]['y']) < 0.05 * gl[j]['s'] and gl[j + 1]['x'] - (gl[j]['x'] + gl[j]['w']) <= 0.04 * gl[j]['s']: j += 1
        if ''.join(gl[k]['u'] for k in range(i, j + 1)) in OPERATOR_NAMES and any(
                kinds[k][0] == 'A' and abs(gl[k]['y'] - gl[i]['y']) < 0.6 * gl[i]['s'] and
                (-0.2 <= (gl[k]['x'] - (gl[j]['x'] + gl[j]['w'])) / gl[i]['s'] <= 0.35 or -0.2 <= (gl[i]['x'] - (gl[k]['x'] + gl[k]['w'])) / gl[i]['s'] <= 0.35)
                for k in range(max(0, i - 6), min(len(gl), j + 7)) if k < i or k > j):
            for k in range(i, j + 1): kinds[k] = ('A', 'V')
        i = j + 1
    cand = [i for i, (k, c) in enumerate(kinds) if k in 'AW' and (c != 'P' or gl[i]['u'] in ('.', ','))]
    cell = 24.0
    grid = collections.defaultdict(list)
    for i in cand: grid[(int(gl[i]['x'] // cell), int(gl[i]['y'] // cell))].append(i)

    def near(i):
        cx, cy = int(gl[i]['x'] // cell), int(gl[i]['y'] // cell)
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for j in grid.get((cx + dx, cy + dy), ()): yield j
    seen, out = set(), []
    for s in cand:
        if kinds[s][0] != 'A' or s in seen: continue
        comp, stack = [s], [s]; seen.add(s)
        while stack:
            i = stack.pop()
            for j in near(i):
                if j in seen: continue
                if not (kinds[i][0] == 'A' or kinds[j][0] == 'A' or True): continue
                # an ambiguous glyph joins only through a member, which i is
                if allowed(gl[i], gl[j], kinds[i], kinds[j]):
                    seen.add(j); comp.append(j); stack.append(j)
        comp = trim(sorted(comp, key=lambda i: (gl[i]['x'], -gl[i]['y'])), gl, kinds)
        if any(kinds[i][0] == 'A' for i in comp): out.append(comp)
    return out, kinds


def trim(comp, gl, kinds):
    """Cut punctuation and unmatched brackets off both edges."""
    def weak(i): return kinds[i][0] == 'W'
    depth, unmatched_close = 0, set()
    for i in comp:
        c = kinds[i][1]
        if c == 'Bo': depth += 1
        elif c == 'Bc':
            if depth: depth -= 1
            else: unmatched_close.add(i)
    changed = True
    while comp and changed:
        changed = False
        i = comp[-1]
        if weak(i) and (kinds[i][1] in ('Bo', 'P') or i in unmatched_close):
            comp = comp[:-1]; changed = True
        i = comp[0] if comp else None
        if i is not None and weak(i) and (kinds[i][1] in ('Bc', 'P') or i in unmatched_close):
            comp = comp[1:]; changed = True
        # an opener with nothing after it inside the group
        if comp:
            opens = [j for j in comp if kinds[j][1] == 'Bo' and weak(j)]
            for j in opens:
                if all(kinds[k][1] != 'Bc' or gl[k]['x'] < gl[j]['x'] for k in comp) and gl[j]['x'] >= gl[comp[-1]]['x'] - 1e-6:
                    comp = [k for k in comp if k != j]; changed = True
    return comp


def classify_groups(gl, groups, kinds):
    """inline | display for every group, by whether a text letter stands close beside it on its line."""
    letters = [g for i, g in enumerate(gl) if kinds[i][0] != 'A' and g['u'][:1].isalpha() and not g.get('d')]
    res = []
    for comp in groups:
        x0 = min(gl[i]['x'] for i in comp); x1 = max(gl[i]['x'] + gl[i]['w'] for i in comp)
        ys = sorted(gl[i]['y'] for i in comp); em = max(gl[i]['s'] for i in comp)
        yc = ys[len(ys) // 2] + 0.3 * em
        inline = any(abs(g['y'] + 0.3 * g['s'] - yc) <= 0.8 * em and (0 <= g['x'] - x1 <= 12 or 0 <= x0 - (g['x'] + g['w']) <= 12) for g in letters)
        res.append('inline' if inline else 'display')
    return res


def display_regions(gl, groups, classes, pid, page):
    """Region id of every group: display groups whose boxes lie within an em of each other (the parts of one displayed line: numerator
    and denominator, scripts, the two sides of a relation across a quad) form one region of at least six glyphs; inline groups and
    smaller clusters have none ('')."""
    boxes = {}
    for gi, comp in enumerate(groups):
        if classes[gi] != 'display': continue
        em = max(gl[i]['s'] for i in comp)
        boxes[gi] = (min(gl[i]['x'] for i in comp) - em, min(gl[i]['y'] for i in comp) - 0.8 * em,
                     max(gl[i]['x'] + gl[i]['w'] for i in comp) + em, max(gl[i]['y'] for i in comp) + 1.3 * em)
    parent = {gi: gi for gi in boxes}

    def find(a):
        while parent[a] != a: parent[a] = parent[parent[a]]; a = parent[a]
        return a
    ids = sorted(boxes)
    for ai, a in enumerate(ids):
        for b in ids[ai + 1:]:
            A, B = boxes[a], boxes[b]
            if A[0] <= B[2] and B[0] <= A[2] and A[1] <= B[3] and B[1] <= A[3]:
                ra, rb = find(a), find(b)
                if ra != rb: parent[max(ra, rb)] = min(ra, rb)
    size = collections.Counter()
    for gi in boxes: size[find(gi)] += len(groups[gi])
    # a displayed line has at least six glyphs; smaller clusters are inline formulas that stand apart from the text letters of their line
    return [f'{pid}-p{page}-d{find(gi)}' if gi in boxes and size[find(gi)] >= 6 else '' for gi in range(len(groups))]


# ---------------------------------------------------------------------------------------------------------------------- labelling

def to_px(g, H):
    return (g['x'] + g['w'] / 2) * SCALE, H - (g['y'] + 0.3 * g['s']) * SCALE


def label_page(gl, groups, regions, kinds, size, ambiguous_numbers):
    """Cell grid of glyph centres with their label ('m' in a formula, 'c' typewriter, 't' text, 'f' figure) and the display formula they
    belong to. -> word_label(rect, text) = (label, region id of the display formula or '')."""
    W, H = size
    group_of = {}
    for gi, comp in enumerate(groups):
        for i in comp: group_of[i] = regions[gi]
    cell = 32
    grid = collections.defaultdict(list)
    for i, g in enumerate(gl):
        if not g['u'] or g['u'].isspace(): continue
        cx, cy = to_px(g, H)
        if g.get('d'): lab = 'f'
        elif i in group_of: lab = 'm'
        elif MONO_FONT.search(g['f']): lab = 'c'
        else: lab = 't'
        grid[(int(cx // cell), int(cy // cell))].append((cx, cy, lab, g['u'][:1].isalnum(), group_of.get(i, '')))

    def word_label(rect, text):
        x, y, w, h = rect
        x0, x1, y0, y1 = x - 2, x + w + 2, y - 0.2 * h, y + h + 0.2 * h
        c = collections.Counter(); regions = collections.Counter()
        for gx in range(int(x0 // cell), int(x1 // cell) + 1):
            for gy in range(int(y0 // cell), int(y1 // cell) + 1):
                for cx, cy, lab, an, gid in grid.get((gx, gy), ()):
                    if x0 <= cx <= x1 and y0 <= cy <= y1:
                        c[lab] += 1
                        if an: c[lab + 'a'] += 1
                        if lab == 'm': regions[gid] += 1
        total = c['m'] + c['t'] + c['f'] + c['c']
        if total == 0: return '-', ''
        if c['f'] >= 0.5 * total: return 'f', ''
        region = lambda: sorted(regions.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]
        # letters and digits decide ("(a)", "x," are math with their punctuation); a word of both ("p-admissible") is unsure
        alnum = c['ma'] + c['ta'] + c['ca']
        if alnum:
            if c['ca'] >= 0.5 * alnum: return 'c', ''
            if c['ma'] and c['ma'] < 0.5 * alnum: return 'u', ''
            if c['ma'] >= 0.5 * alnum: return 'm', region()
        elif c['c'] >= 0.5 * total: return 'c', ''
        elif c['m'] >= 0.5 * total: return 'm', region()
        if ambiguous_numbers and re.fullmatch(r'[\d.,]+', text.strip('.,;:!?()[]')): return 'u', ''
        return 'p', ''
    return word_label


def word_truth(lab, text, tag, first, prev):
    """(keep, reason) of a word from its glyph label."""
    if lab == 'm': return KEEP, 'math'
    if lab == 'c': return KEEP, reason_of(core_text(text))
    if lab == 'u': return EITHER, 'unsure'
    if lab == 'f': return EITHER, 'figure'
    if lab == '-': return NONE, ''
    return prose_truth(text, tag, first, prev, False)


def core_text(t):
    return t.strip('.,;:!?()[]{}"\'')


def build_blocks(paper, read, page, blocks, word_label):
    recs = []
    for bi, b in enumerate(blocks):
        words, prev = [], ''
        for k, (s, e, x, y, w, h, t) in enumerate(b['w']):
            lab, region = word_label((x, y, w, h), t)
            tag = near_tag(t) if lab == 'p' else ''
            keep, reason = word_truth(lab, t, tag, k == 0, prev)
            words.append([s, e, keep, reason, tag, t, region, x, y, w, h])
            prev = t
        emit_block(recs, f'{paper}-p{page}-{read}-{bi}', paper, page, read, b, words)
    return recs


def emit_block(recs, bid, paper, page, read, b, words, extra=None):
    """Appends the block record, its keep spans and its near records. words: [start, end, keep, reason, tag, text, region, x, y, w, h]."""
    cls = block_class([w[2] for w in words])
    n = collections.Counter(w[2] for w in words)
    reasons = collections.Counter(w[3] for w in words if w[2] == KEEP)
    stats = {'keep': n[KEEP], 'translate': n[TRANSLATE], 'either': n[EITHER], 'none': n[NONE], 'reasons': dict(sorted(reasons.items()))}
    letters = sum(ch.isalpha() for ch in b['t'])
    rec = {'kind': 'block', 'id': bid, 'paper': paper, 'page': page, 'read': read, 'rect': b['r'],
           'text': b['t'], 'keep': cls, 'reason': reasons.most_common(1)[0][0] if reasons else '', 'noletter': letters == 0, 'stats': stats,
           'words': [w[:7] for w in words]}
    if extra: rec.update(extra)
    recs.append(rec)
    runs, _ = keep_runs([w[2] for w in words])
    for run in runs:
        ws = [words[k] for k in range(run[0], run[-1] + 1)]
        reason = collections.Counter(words[k][3] for k in run).most_common(1)[0][0]
        recs.append({'kind': 'span', 'block': bid, 'paper': paper, 'page': page, 'read': read,
                     'rect': union([(w[7], w[8], w[9], w[10]) for w in ws]), 'keep': KEEP, 'reason': reason,
                     'start': ws[0][0], 'end': ws[-1][1], 'text': b['t'][ws[0][0]:ws[-1][1]], 'words': [run[0], run[-1]], 'n': len(run)})
    for k, w in enumerate(words):
        if w[4]:
            recs.append({'kind': 'near', 'block': bid, 'paper': paper, 'page': page, 'read': read, 'rect': [w[7], w[8], w[9], w[10]],
                         'tag': w[4], 'keep': w[2], 'reason': w[3], 'start': w[0], 'end': w[1], 'text': w[5], 'words': [k, k]})


def union(rects):
    x0 = min(r[0] for r in rects); y0 = min(r[1] for r in rects)
    x1 = max(r[0] + r[2] for r in rects); y1 = max(r[1] + r[3] for r in rects)
    return [round(x0, 1), round(y0, 1), round(x1 - x0, 1), round(y1 - y0, 1)]


def fmt(rec):
    return json.dumps(rec, ensure_ascii=False, separators=(',', ':'))


def main():
    pid, glyph_path, ocr_path, latex_path, out_path = sys.argv[1:6]
    pages = load_glyphs(glyph_path)
    prof = profile(pages)
    latex = json.load(open(latex_path))
    spans_tex = latex.get('spans', [])
    # the text face is also the math roman where CM text is used, or where txfonts take digits and brackets from it
    math_digits_in_body = not any(g['f'].startswith('CMR') and g['u'].isdigit() for gl in pages.values() for g in gl)
    has_numeric_math = any(k == 'inline' and re.fullmatch(r'[\d.,\s]+', t) for k, t in spans_tex)
    ambiguous_numbers = (prof['cm_text'] or math_digits_in_body) and has_numeric_math
    recs, regions, per_page = [], [], {}
    ocr = [json.loads(l) for l in open(ocr_path)]
    for o in ocr:
        page = int(re.sub(r'\D', '', o['image']))
        gl = pages.get(page, [])
        groups, kinds = groups_of(gl, prof)
        cls = classify_groups(gl, groups, kinds)
        per_page[page] = (cls.count('inline'), cls.count('display'))
        rid = display_regions(gl, groups, cls, pid, page)
        regions += sorted(set(r for r in rid if r))
        wl = label_page(gl, groups, rid, kinds, o['size'], ambiguous_numbers)
        for read in ('vn', 'doc'):
            recs += build_blocks(pid, read, page, o[read], wl)
    # check against the LaTeX source, all pages of the PDF (the glyph file holds every page)
    all_inline = all_display = 0
    for page, gl in sorted(pages.items()):
        groups, kinds = groups_of(gl, prof)
        cls = classify_groups(gl, groups, kinds)
        all_inline += cls.count('inline'); all_display += cls.count('display')
    header = {'kind': 'paper', 'schema': 2, 'word_fields': WORD_FIELDS, 'id': pid, 'text_face': prof['body'], 'text_size': prof['size'], 'cm_text': prof['cm_text'],
              'ambiguous_numbers': ambiguous_numbers, 'tex_inline': latex['inline'], 'tex_display': latex['display'],
              'pdf_groups_inline': all_inline, 'pdf_groups_display': all_display, 'pages': sorted(per_page), 'regions': regions}
    with open(out_path, 'w') as f:
        f.write(fmt(header) + '\n')
        for r in recs: f.write(fmt(r) + '\n')
    if '--report' in sys.argv:
        b = collections.Counter((r['read'], r['keep']) for r in recs if r['kind'] == 'block')
        sp = collections.Counter((r['read'], r['reason']) for r in recs if r['kind'] == 'span')
        nr = collections.Counter((r['read'], r['keep']) for r in recs if r['kind'] == 'near')
        print(pid, {k: v for k, v in header.items() if k != 'regions'}, 'regions', len(regions))
        print('  blocks', dict(sorted(b.items()))); print('  keep spans', dict(sorted(sp.items()))); print('  near', dict(sorted(nr.items())))


if __name__ == '__main__':
    main()
