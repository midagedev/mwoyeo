#!/usr/bin/env python3
"""The H2 measurement: today's rules and CodeRegion on the screens of h2.py (round k3a, 2026-10-20).
usage: h2_report.py <labels dir with h2.jsonl> <rules.jsonl> [--sheet <dir> --pics <KEEP_WORK/h2>]
  rules.jsonl = keeprules on h2.jsonl with KEEP_FEED set (regionfeed on the H2 pictures): run-rules.sh does both and also prints rules_report.py's
  report; this script adds what H2 needs: the size of the set, the two variants (today's rules; rules OR CodeRegion, the app's behaviour today),
  the verdict per reason slice against the stage-1 stop rule, the cuts by look and language, the clusters of the misses, and the disagreement sheet.

Slices (truth.py's reason taxonomy): recall of a slice = its keep words the variant keeps. Precision of a slice = of the words the variant keeps
that are `truth keep of this reason` (true) or `truth translate` (false keep) the true ones over all of them, where a false keep is charged to the
slice of the keep reason that dominates its block (a translate word kept inside a code block is a false keep of `code`); false keeps in blocks without
any keep word are charged to `prose block`. Stop rule of keep-boundary.md section 7: P and R >= 0.95; a slice with fewer than 40 keep words reads
"thin - no verdict" (addendum A1.5). Every number counts the words of the doc read and the vn read separately."""
import collections, json, os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import rules_report as RR
from truth import KEEP, TRANSLATE, EITHER, SCORED, keep_runs

REASONS = ('code', 'cmd', 'log', 'config', 'path', 'id', 'flag', 'url', 'hash', 'hotkey', 'lineno', 'diffmark', 'math')
THIN = 40


def variant_rules(rules, with_region):
    """Per block id: the rule record, with `needs` false where CodeRegion keeps the block (rules OR region) when with_region."""
    if not with_region: return rules
    out = {}
    for k, r in rules.items():
        r1 = dict(r)
        if r.get('region') and r['region'] != 'nofeed' and r['needs']: r1['needs'] = False
        out[k] = r1
    return out


def slice_table(blocks, rules, read):
    """-> {reason: dict(n, kept, tp, fp)} for the words of one read, with the false keeps charged to the dominant keep reason of their block."""
    S = collections.defaultdict(lambda: dict(n=0, kept=0, fp=0))
    for b in blocks:
        if b['read'] != read or b['noletter']: continue
        pred, _ = RR.predict(b, rules[b['id']])
        dom = b['reason'] or 'prose block'
        for k, w in enumerate(b['words']):
            if w[2] == KEEP:
                S[w[3]]['n'] += 1
                if pred[k]: S[w[3]]['kept'] += 1
            elif w[2] == TRANSLATE and pred[k]:
                S[dom]['fp'] += 1
    return S


def fmt_pct(a, n):
    return f'{a / n:.2f}' if n else ' n/a'


def verdict_rows(blocks, rules, read, out, title):
    S = slice_table(blocks, rules, read)
    out.append(f'  {title}, read {read}: slice  n keep words   R (kept/n)       false keeps charged   P            verdict')
    allr = sorted(set(S) | set(REASONS), key=lambda r: (r not in REASONS, REASONS.index(r) if r in REASONS else 0, r))
    tot_tp = tot_fp = 0
    for r in allr:
        v = S.get(r)
        if v is None: continue
        n, kept, fp = v['n'], v['kept'], v['fp']
        tot_tp += kept; tot_fp += fp
        if n == 0 and fp == 0: continue
        R = kept / n if n else float('nan')
        P = kept / (kept + fp) if kept + fp else float('nan')
        if n < THIN: ver = 'thin - no verdict'
        elif R >= 0.95 and P >= 0.95: ver = 'rules enough'
        else: ver = 'MISS' + (' (R)' if R < 0.95 else '') + (' (P)' if P < 0.95 else '')
        lo, hi = RR.wilson(kept, n)
        out.append(f'    {r:12s} {n:5d}   R {R:.2f} [{lo:.2f},{hi:.2f}] ({kept}/{n})   fp {fp:4d}   P {fmt_pct(kept, kept + fp)}   {ver}')
    out.append(f'    all words: kept keep words {tot_tp}, false keeps {tot_fp}')
    return S


def size_section(blocks, hdr, out):
    out.append(f'screens {len(hdr["cases"])} (scenes {len(set(c["scene"] for c in hdr["cases"]))}, looks {len(set(c["look"] for c in hdr["cases"]))}, '
               f'languages {dict(collections.Counter(c["lang"] for c in hdr["cases"]))}), code regions {len(hdr["regions"])}')
    out.append('looks: ' + ', '.join(f'{k} {v}' for k, v in sorted(collections.Counter(c['look'] for c in hdr['cases']).items())))
    for read in RR.READS:
        B = [b for b in blocks if b['read'] == read]
        wk = collections.Counter(); reasons = collections.Counter(); either = collections.Counter(); unc = 0
        for b in B:
            for k, w in enumerate(b['words']):
                wk[w[2] or 'none'] += 1
                if w[2] == KEEP: reasons[w[3]] += 1
                if w[2] == EITHER: either[w[3]] += 1
            unc += len(b.get('unc', []))
        cls = collections.Counter(b['keep'] for b in B)
        out.append(f'  read {read}: blocks {len(B)} {dict(sorted(cls.items()))}; words {dict(wk)}; uncertain words {unc}')
        out.append(f'    keep words by reason {dict(reasons.most_common())}')
        out.append(f'    either words by reason {dict(either.most_common())}')


def look_lang_cut(blocks, rules, read, out):
    out.append(f'  by look and by language, rules OR CodeRegion, read {read}: word P / R (keep words), block-keep P / R, keep words n')
    for key in ('look', 'lang'):
        for val in sorted(set(b[key] for b in blocks)):
            acc = RR.Acc()
            for b in blocks:
                if b[key] == val and b['read'] == read and not b['noletter']: RR.accumulate(acc, b, rules[b['id']])
            out.append(f'    {key:4s} {val:16s} P {fmt_pct(acc.tp, acc.tp + acc.fp)} R {fmt_pct(acc.tp, acc.tp + acc.fn)} (n {acc.tp + acc.fn})   '
                       f'block P {fmt_pct(acc.bk_tp, acc.bk_tp + acc.bk_fp)} R {fmt_pct(acc.bk_tp, acc.bk_tp + acc.bk_fn)}   fp words {acc.fp}')


COMMENT_START = re.compile(r'\s*(?:#|//|/{3})')


def block_kind(b, pure):
    """The cluster of a missed block: what the block is, from its labels and its text (never from the rules' view of it)."""
    if not pure: return 'inline piece in a prose block'
    if COMMENT_START.match(b['text']): return 'comment-only line of a code region'
    return {'log': 'log / tool-output line', 'config': 'config line', 'code': 'code line', 'cmd': 'command line', 'path': 'path / window chrome'}.get(b['reason'], 'other keep line')


def clusters(blocks, rules, read, pics, out, limit=8):
    """The keep words the rules OR region translate, clustered by what their block is (block_kind) and the look family: blocks, words, the scenes,
    two examples, and for the pure-keep blocks how many each cheap feature of code_features.py catches (thresholds of the code cases: held out here;
    the false-fire rates of the features on H2's pure-translate blocks are printed after the table)."""
    if pics is None:
        out.append(f'  clusters, read {read}: skipped (give --pics <KEEP_WORK>/h2)'); return
    import code_features as CF
    from PIL import Image
    os.environ['FRAME'] = 'dominant'
    names = ('indent', 'mono', 'lineend', 'keyword', 'tint')
    cache = {}

    def feats(b):
        case = b['paper']
        if case not in cache:
            o = json.loads(open(os.path.join(pics, case + '.ocr.jsonl')).read())
            img = Image.open(os.path.join(pics, case + '.png')).convert('RGB')
            cache[case] = (o, img, CF.frame_colour(img), {rd: min(x['r'][0] for x in o[rd] if len(x['w']) >= 2) for rd in ('doc', 'vn')})
        o, img, corner, margins = cache[case]
        return CF.features(o[read][int(b['id'].rsplit('-', 1)[1])], margins[read], img, corner)[0]
    cl = collections.defaultdict(lambda: dict(words=0, blocks=0, scenes=collections.Counter(), looks=collections.Counter(), ex=[], caught=collections.Counter()))
    fires = collections.Counter(); npt = 0
    for b in blocks:
        if b['read'] != read or b['noletter']: continue
        st = b['stats']
        if st['keep'] + st['translate'] == 0: continue
        pure = st['translate'] == 0 and st['keep'] > 0
        if st['keep'] == 0:
            npt += 1
            for n, v in feats(b).items(): fires[n] += v
        pred, mech = RR.predict(b, rules[b['id']])
        miss = [k for k, w in enumerate(b['words']) if w[2] == KEEP and not pred[k]]
        if not miss: continue
        c = cl[block_kind(b, pure)]
        c['words'] += len(miss); c['blocks'] += 1; c['scenes'][b['scene']] += 1; c['looks'][b['look']] += 1
        if len(c['ex']) < 2: c['ex'].append(re.sub(r'\s+', ' ', b['text'] if pure else ' '.join(b['words'][k][5] for k in miss))[:70])
        if pure:
            for n, v in feats(b).items(): c['caught'][n] += v
    rows = sorted(cl.items(), key=lambda kv: (-kv[1]['words'], kv[0]))
    out.append(f'  clusters of the missed keep words, read {read}: {len(rows)} (block kind), top {min(limit, len(rows))}')
    for kind, c in rows[:limit]:
        cat = ' '.join(f'{n} {c["caught"][n]}' for n in names) if kind != 'inline piece in a prose block' else 'no block feature applies'
        out.append(f'    {c["words"]:4d} words in {c["blocks"]:3d} blocks  {kind:34s} scenes {dict(c["scenes"].most_common(4))}  looks {dict(c["looks"].most_common(4))}')
        out.append(f'         caught by (of {c["blocks"]}): {cat}   e.g. ' + ' | '.join(c['ex']))
    rest = rows[limit:]
    if rest: out.append(f'    (other {len(rest)} clusters: {sum(c["words"] for _, c in rest)} words in {sum(c["blocks"] for _, c in rest)} blocks)')
    out.append(f'  false fires of each feature on the {npt} pure-translate blocks of H2, read {read}: ' + ', '.join(f'{n} {fires[n]}' for n in names) + '   (tint against the dominant colour)')


def crop(png, rect, out_png, pad=14):
    x, y, w, h = rect
    x0, y0 = max(0, int(x) - pad), max(0, int(y) - pad)
    subprocess.run(['sips', '--cropToHeightWidth', str(int(h) + 2 * pad), str(int(w) + 2 * pad), '--cropOffset', str(y0), str(x0), png, '--out', out_png],
                   capture_output=True, check=True)


def sheet(blocks, rules, sheet_dir, pics, out, limit=40):
    """The blocks where the variant (rules OR region) and the construction labels disagree on a word the construction is not certain of
    (the `unc` words of the block record): at most `limit` rows, doc read, spread over the scenes in turn; one crop each."""
    cand = []
    for b in blocks:
        if b['read'] != 'doc' or b['noletter']: continue
        pred, mech = RR.predict(b, rules[b['id']])
        bad = [k for k in b.get('unc', []) if b['words'][k][2] in SCORED and pred[k] != (b['words'][k][2] == KEEP)]
        if bad: cand.append((b, bad, mech))
    by_scene = collections.defaultdict(list)
    for item in sorted(cand, key=lambda t: t[0]['id']): by_scene[item[0]['scene']].append(item)
    chosen = []
    while len(chosen) < limit and any(by_scene.values()):
        for s in sorted(by_scene):
            if by_scene[s] and len(chosen) < limit: chosen.append(by_scene[s].pop(0))
    os.makedirs(sheet_dir, exist_ok=True)
    rows = ['crop\tblock\tocr text\trules say\tlabels say\tuncertain words']
    for i, (b, bad, mech) in enumerate(chosen, 1):
        name = f'{i:02d}-{b["id"]}.png'
        crop(os.path.join(pics, b['paper'] + '.png'), b['rect'], os.path.join(sheet_dir, name))
        r = rules[b['id']]
        if not r['needs']: says = "keep (today's rules keep the block)"
        elif r.get('region') and r['region'] != 'nofeed': says = 'keep (CodeRegion: ' + r['region'] + ')'
        else: says = 'translate (inline spans protect ' + str(len(r['spans'])) + ')'
        st = b['stats']
        labels = f'{"keep" if st["translate"] == 0 else "translate" if st["keep"] == 0 else "mixed"} ' + json.dumps(st['reasons'], ensure_ascii=False)
        txt = re.sub(r'\s+', ' ', b['text'])[:160]
        unc = ' '.join(b['words'][k][5] + '=' + b['words'][k][2] for k in bad)[:120]
        rows.append('\t'.join([name, b['id'], txt, says, labels, unc]))
    with open(os.path.join(os.path.dirname(sheet_dir.rstrip('/')), os.path.basename(sheet_dir.rstrip('/')) + '.tsv'), 'w') as f: f.write('\n'.join(rows) + '\n')
    out.append(f'DISAGREEMENT SHEET: {len(cand)} doc-read blocks disagree on an uncertain word; {len(chosen)} rows written to {sheet_dir}.tsv with the crops in {sheet_dir}/')


def main():
    args = sys.argv[1:]
    labels_dir, rules_path = args[0], args[1]
    blocks, _ = RR.load(labels_dir)
    hdr = json.loads(open(os.path.join(labels_dir, 'h2.jsonl')).readline())
    rules = {}
    for l in open(rules_path):
        r = json.loads(l); rules[r['id']] = r
    rr = variant_rules(rules, True)
    out = []
    out.append('H2 SIZE')
    size_section(blocks, hdr, out)
    nofeed = [b['id'] for b in blocks if rules[b['id']].get('region') == 'nofeed']
    if nofeed: out.append(f'WARNING: {len(nofeed)} labelled blocks have no picture in the feed; CodeRegion did not run on them')
    out.append('')
    for name, rl in (('TODAY\'S RULES (InlineMath + TranslationFilter) ON H2', rules), ('RULES OR CodeRegion ON H2 (what the app does today)', rr)):
        out.append(name)
        RR.rule_tables(blocks, rl, out)
        out.append('')
    out.append('VERDICT PER REASON SLICE (stop rule: P and R >= 0.95; fewer than 40 keep words: thin)')
    for title, rl in (('rules only', rules), ('rules OR CodeRegion', rr)):
        for read in RR.READS: verdict_rows(blocks, rl, read, out, title)
    out.append('')
    out.append('CUTS')
    for read in RR.READS: look_lang_cut(blocks, rr, read, out)
    out.append('')
    out.append('CLUSTERS (rules OR CodeRegion)')
    pics = args[args.index('--pics') + 1] if '--pics' in args else None
    for read in RR.READS: clusters(blocks, rr, read, pics, out)
    out.append('')
    # false keeps: translate words the variant keeps, by block kind
    for read in RR.READS:
        fp = collections.Counter(); ex = collections.OrderedDict()
        for b in blocks:
            if b['read'] != read or b['noletter']: continue
            pred, mech = RR.predict(b, rr[b['id']])
            n = sum(1 for k, w in enumerate(b['words']) if w[2] == TRANSLATE and pred[k])
            if n:
                fp[(b['scene'], b['look'])] += n
                ex[b['id']] = (n, len(b['words']), mech, re.sub(r"\s+", " ", b["text"])[:84])
        out.append(f'  translate words kept (rules OR CodeRegion), read {read}: {sum(fp.values())}; by screen: {dict(fp.most_common(8))}')
        for bid, (n, tot, mech, txt) in list(ex.items())[:8]: out.append(f'    {bid}: {n} of {tot} words kept ({mech}): {txt}')
    if '--sheet' in args:
        sd = args[args.index('--sheet') + 1]; pics = args[args.index('--pics') + 1]
        out.append('')
        sheet(blocks, rr, sd, pics, out)
    print('\n'.join(out))


if __name__ == '__main__':
    main()
