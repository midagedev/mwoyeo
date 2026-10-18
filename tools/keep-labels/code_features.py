#!/usr/bin/env python3
"""Which cheap block feature would have caught a keep block that today's rules translate?
usage: code_features.py <ocr dir> <labels/code.jsonl> <rules.jsonl>      (<ocr dir>/<case>.ocr.jsonl and <case>.png from make-code-labels.sh)

The blocks: pure-keep blocks of the code cases (keep words, no translate word, a letter in the text) for which TranslationFilter
.needsTranslation is true, per read. For each, five features that need no model (keep-boundary.md section 5, design note section 8), all
computed from what the app has in memory after makeBlock (text, word boxes, the frame pixels):
  indent    the block starts 1.5 glyph widths or more right of the frame's left margin (the leftmost block of the read with two words or
            more), or its lines start at two margins (a block of several lines).
  mono      the width per character of its ASCII words (3+ characters, 3+ such words) varies by less than 0.06 (coefficient of variation).
  lineend   half of its lines end in one of ; { } ) ]   (a line = the words on one baseline).
  keyword   a fifth of its tokens or more are code keywords (const let var func def return import class else end while print ...).
  tint      the most common colour inside its rectangle differs from the frame's corner colour by 6 levels or more.
A feature that fires on prose is no use: each is also counted on the pure-translate and the mixed blocks of the same read (false fires).
The thresholds were set once on this set (the 6 % is the CV that lets about one pure-translate block in ten fire), so the false-fire
rates are the honest part of the table and the catch rates are an upper bound."""
import collections, json, os, re, statistics, sys
from PIL import Image

KEYWORDS = set('const let var func function return import from class def elif else end while print console async await null none true false self this '
               'struct enum fn lambda then do for if in to'.split())
LINE_END = set(';{})]')


def lines_of(words):
    """Words grouped by baseline: [[word, ...], ...] top to bottom, each left to right. word = [start, end, x, y, w, h, text]."""
    if not words: return []
    h = statistics.median(w[5] for w in words)
    out = []
    for w in sorted(words, key=lambda w: (w[3] + w[5] / 2, w[2])):
        cy = w[3] + w[5] / 2
        if out and abs(cy - out[-1][0]) <= 0.6 * h: out[-1][1].append(w)
        else: out.append([cy, [w]])
    return [sorted(ws, key=lambda w: w[2]) for _, ws in out]


def glyph_width(words):
    n = sum(len(w[6]) for w in words)
    return sum(w[4] for w in words) / n if n else 0


def features(b, margin, img, corner):
    words = b['w']
    ls = lines_of(words)
    gw = glyph_width(words)
    f = {}
    left = min(w[2] for w in words)
    starts = [min(w[2] for w in l) for l in ls]
    f['indent'] = (left - margin >= 1.5 * gw) or (len(ls) > 1 and max(starts) - min(starts) >= 1.5 * gw)
    ascii_words = [w for w in words if re.fullmatch(r'[\x21-\x7e]{3,}', w[6])]
    cv = None
    if len(ascii_words) >= 3:
        u = [w[4] / len(w[6]) for w in ascii_words]
        cv = statistics.pstdev(u) / statistics.mean(u)
    f['mono'] = cv is not None and cv < 0.06
    ends = [l[-1][6].rstrip()[-1:] for l in ls]
    ratio = sum(1 for e in ends if e in LINE_END) / len(ends) if ends else 0
    f['lineend'] = ratio >= 0.5
    toks = [t.lower() for t in re.findall(r'[A-Za-z_]+', b['t'])]
    kw = sum(1 for t in toks if t in KEYWORDS)
    kshare = kw / len(toks) if toks else 0
    f['keyword'] = kw >= 1 and kshare >= 0.2
    x, y, w, h = [int(round(v)) for v in b['r']]
    crop = img.crop((max(0, x), max(0, y), min(img.width, x + w), min(img.height, y + h)))
    pix = crop.tobytes()
    mode = collections.Counter(zip(pix[0::3], pix[1::3], pix[2::3])).most_common(1)[0][0] if crop.width and crop.height else corner
    delta = max(abs(a - c) for a, c in zip(mode[:3], corner[:3]))
    f['tint'] = delta >= 6
    vals = {'indent': round((left - margin) / gw, 1) if gw else 0, 'mono': None if cv is None else round(cv, 3), 'lineend': round(ratio, 2),
            'keyword': round(kshare, 2), 'tint': delta}
    return f, vals


def main():
    ocr_dir, labels_path, rules_path = sys.argv[1:4]
    labels = {}
    for l in open(labels_path):
        r = json.loads(l)
        if r.get('kind') == 'block': labels[r['id']] = r
    rules = {}
    for l in open(rules_path):
        r = json.loads(l); rules[r['id']] = r
    names = ('indent', 'mono', 'lineend', 'keyword', 'tint')
    cache = {}
    for read in ('doc', 'vn'):
        rows = []                                           # (class, features, values, label record)
        for bid, rec in sorted(labels.items()):
            if rec['read'] != read or rec['noletter'] or rec['keep'] not in ('keep', 'translate', 'mixed') or bid not in rules: continue
            case, idx = rec['paper'], int(bid.rsplit('-', 1)[1])
            if case not in cache:
                o = json.loads(open(f'{ocr_dir}/{case}.ocr.jsonl').read())
                img = Image.open(f'{ocr_dir}/{case}.png').convert('RGB')
                margins = {rd: min(b['r'][0] for b in o[rd] if len(b['w']) >= 2) for rd in ('doc', 'vn')}
                cache[case] = (o, img, img.getpixel((3, 3)), margins)
            o, img, corner, margins = cache[case]
            f, v = features(o[read][idx], margins[read], img, corner)
            rows.append((rec['keep'], f, v, rec))
        miss = [r for r in rows if r[0] == 'keep' and rules[r[3]['id']]['needs']]
        print(f'READ {read}: {len(miss)} pure-keep blocks the rules translate (of {sum(1 for r in rows if r[0] == "keep")} pure-keep blocks)')
        for cls, f, v, rec in miss:
            hit = [n for n in names if f[n]]
            dom = max(rec['stats']['reasons'].items(), key=lambda kv: kv[1])[0] if rec['stats']['reasons'] else '-'
            print(f'  {rec["id"]:30s} {dom:7s} caught by: {",".join(hit) or "none":28s} ' +
                  ' '.join(f'{n}={v[n]}' for n in names) + '  | ' + re.sub(r'\s+', ' ', rec['text'])[:46])
        print(f'  feature         caught/{len(miss)}   false fires of the feature on pure-translate blocks / on mixed blocks')
        pt = [r for r in rows if r[0] == 'translate']; mx = [r for r in rows if r[0] == 'mixed']
        for n in names:
            print(f'  {n:10s}  {sum(1 for r in miss if r[1][n]):3d}/{len(miss)}      {sum(1 for r in pt if r[1][n])}/{len(pt)}  {sum(1 for r in mx if r[1][n])}/{len(mx)}')
        anyc = sum(1 for r in miss if any(r[1][n] for n in names))
        print(f'  any of the five: {anyc}/{len(miss)}; none: {len(miss) - anyc}; any feature on pure-translate blocks: {sum(1 for r in pt if any(r[1][n] for n in names))}/{len(pt)}'
              f'; the two cheapest, tint or keyword: {sum(1 for r in miss if r[1]["tint"] or r[1]["keyword"])}/{len(miss)}')


if __name__ == '__main__':
    main()
