#!/usr/bin/env python3
"""How well today's Core rules draw the translate / keep boundary on the labelled words, and how pure the OCR blocks are.
usage: rules_report.py <labels dir> <rules.jsonl> [--json out.json]
  <labels dir> holds <paper id>.jsonl (label.py) and code.jsonl (code_labels.py); papers.tsv names the dev / hold-out split of the papers,
  the code cases are split by their number (odd: dev, even: hold-out, as the use-case bench splits its pictures).
  rules.jsonl is keeprules' output on those files.

What the rules decide, as the app runs them on a block: `needs` false (TranslationFilter.needsTranslation) keeps the whole block as
written; otherwise InlineMath.spans protects the words it covers (half of a word's characters inside a span) and every other word is
translated. So a word is predicted keep when its block is kept or a span covers it. Truth: the word's `keep` label (translate / keep /
either); `either` and unlabelled words are not scored. Blocks without a letter are left out of the rule scores (every rule treats them
alike) but not out of the purity tables.

Metrics (design note addendum 2, keep-boundary.md section 2), per source (papers dev / hold-out, cases dev / hold-out) and read (doc, vn):
  (a) word-level keep precision and recall, recall sliced by the reason of the keep word, false keeps by what kept them;
  (b) keep spans (runs of keep words in the sequence of scored words): exact-boundary F1 and the edge error in scored words;
  (c) whole-block keep: truth = the block holds keep words and no translate word;
  (d) the two costly errors apart: keep->translated (words, spans) and translate->kept (words, blocks), sliced by reason / mechanism.
Then block purity, the keep-mass split and the region fit (the lead's addition), the clusters of the misses, and the decision per
slice: precision and recall both >= 0.95 on the hold-out -> the model is deferred for that slice (design section 7), else train for the band."""
import collections, json, math, os, re, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from truth import keep_runs, SCORED, KEEP, TRANSLATE, EITHER

SOURCES = ('papers dev', 'papers hold', 'cases dev', 'cases hold', 'h2')      # h2: the own screens of h2.py, a labels dir of its own (labels-h2/)
READS = ('doc', 'vn')


def wilson(k, n, z=1.96):
    if n == 0: return (0.0, 1.0)
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    r = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - r) / d, (c + r) / d)


def ratio(k, n):
    return k / n if n else float('nan')


def rci(k, n):
    """'0.91 [0.85,0.95]' for k of n."""
    lo, hi = wilson(k, n)
    return f'{ratio(k, n):.2f} [{lo:.2f},{hi:.2f}]'


def load(labels_dir):
    papers = {}
    for ln in open(os.path.join(HERE, 'papers.tsv')).read().splitlines()[1:]:
        f = ln.split('\t'); papers[f[0]] = f[2]
    blocks, regions = [], collections.defaultdict(set)
    for fn in sorted(os.listdir(labels_dir)):
        if not fn.endswith('.jsonl'): continue
        pid = fn[:-6]
        lines = [json.loads(l) for l in open(os.path.join(labels_dir, fn))]
        head = lines[0]
        if pid in ('code', 'h2'):
            pre = 'cases ' if pid == 'code' else ''
            sets = {c['case']: c['set'] for c in head['cases']}
            for r in lines[1:]:
                if r['kind'] == 'block': r['src'] = pre + sets[r['paper']]; blocks.append(r)
            for c in head['cases']: regions[pre + c['set']].update(c['regions'])
        else:
            for r in lines[1:]:
                if r['kind'] == 'block': r['src'] = 'papers ' + papers[pid]; blocks.append(r)
            regions['papers ' + papers[pid]].update(head['regions'])
    return blocks, regions


# ------------------------------------------------------------------------------------------------------------------ rule predictions

def covered_words(b, spans):
    """Per word: True when half of its characters lie in a predicted span."""
    cov = []
    for w in b['words']:
        s, e = w[0], w[1]
        n = max(1, e - s)
        hit = sum(max(0, min(e, se) - max(s, ss)) for ss, se in spans)
        cov.append(hit >= 0.5 * n)
    return cov


def predict(b, rule):
    """Per word: keep (True) or translate; and what decided it: 'block' (kept whole) or 'span'."""
    kept = not rule['needs']
    cov = covered_words(b, rule['spans'])
    return [kept or c for c in cov], ('block' if kept else 'span')


def runs_of(flags):
    out, cur = [], None
    for i, f in enumerate(flags):
        if f and cur is None: cur = i
        if not f and cur is not None: out.append((cur, i - 1)); cur = None
    if cur is not None: out.append((cur, len(flags) - 1))
    return out


def shape(w):
    t = w.strip('.,;:!?')
    if len(t) == 1 and t.isalpha(): return 'single letter'
    if re.fullmatch(r'[\d.,]+', t): return 'bare number'
    if re.fullmatch(r'[A-Za-z]{1,3}[0-9]?', t) and not re.search(r'[aeiouyAEIOUY]', t): return 'bare operand (dk, x1)'
    if re.search(r'[-−–/*]', t) and not re.search(r'[=+×·∈<>≤≥→^_√]', t): return 'weak operator (- / *)'
    if re.search(r'[€®©¡¿§¶°¢£¥ß]|[^\x00-\x7f]', t) and not re.search(r'[=+×·∈<>≤≥→^_√∑∏∫∂∇∞∀∃±÷⋅∘∉⊂⊆⊃⊇∪∩≈≠⇒⇔∝]', t): return 'garbled symbol / CJK text'
    if re.fullmatch(r'[A-Za-z]+\(.*\)?', t): return 'call-like name(...)'
    if re.fullmatch(r'[A-Za-z]{2,}', t): return 'plain word run (IP, softmax)'
    return 'other'


# ----------------------------------------------------------------------------------------------------------------------- the metrics

class Acc:
    """Counts of one (source, read)."""
    def __init__(self):
        self.tp = self.fp = self.fn = self.tw = 0
        self.rec = collections.defaultdict(lambda: [0, 0])          # keep word reason -> [kept, total]
        self.fp_mech = collections.Counter()                         # block / span
        self.tp_mech = collections.Counter()
        self.fp_tag = collections.Counter()
        self.sp_truth = self.sp_pred = self.sp_exact = 0
        self.sp_reason = collections.defaultdict(lambda: [0, 0, 0])  # reason -> [truth, exact, found (overlapped)]
        self.sp_fate = collections.defaultdict(lambda: collections.Counter())   # reason -> kept / partial / lost
        self.edge = []; self.sp_missed = 0
        self.bk_tp = self.bk_fp = self.bk_fn = self.bk_tn = 0
        self.b9_tp = self.b9_fp = self.b9_fn = 0
        self.fp_blocks = collections.Counter()                       # translate / mixed blocks kept whole
        self.miss = collections.defaultdict(collections.Counter); self.miss_ex = collections.defaultdict(list)
        self.fa = collections.Counter(); self.fa_ex = collections.defaultdict(list)


def accumulate(acc, b, rule):
    pred, mech = predict(b, rule)
    words = b['words']
    for k, w in enumerate(words):
        if w[2] not in SCORED: continue
        if w[2] == KEEP:
            acc.rec[w[3]][1] += 1
            if pred[k]: acc.tp += 1; acc.rec[w[3]][0] += 1; acc.tp_mech[mech] += 1
            else:
                acc.fn += 1
                sh = shape(w[5]); acc.miss[w[3]][sh] += 1
                if len(acc.miss_ex[(w[3], sh)]) < 6: acc.miss_ex[(w[3], sh)].append(w[5])
        else:
            acc.tw += 1
        if w[2] == TRANSLATE and pred[k]:
            acc.fp += 1; acc.fp_mech[mech] += 1
            tag = w[4] or 'plain prose word'
            acc.fp_tag[tag] += 1; acc.fa[(mech, tag)] += 1
            if len(acc.fa_ex[(mech, tag)]) < 6: acc.fa_ex[(mech, tag)].append(w[5])
    keeps = [w[2] for w in words]
    runs, S = keep_runs(keeps)
    if not S: return
    posS = {k: i for i, k in enumerate(S)}
    truth_runs = [(posS[r[0]], posS[r[-1]], r) for r in runs]
    pred_runs = runs_of([pred[k] for k in S])
    acc.sp_truth += len(truth_runs); acc.sp_pred += len(pred_runs)
    pset = set(pred_runs)
    for a, z, r in truth_runs:
        reason = collections.Counter(words[k][3] for k in r).most_common(1)[0][0]
        acc.sp_reason[reason][0] += 1
        if (a, z) in pset: acc.sp_exact += 1; acc.sp_reason[reason][1] += 1
        ov = [(min(z, pz) - max(a, pa) + 1, pa, pz) for pa, pz in pred_runs if min(z, pz) >= max(a, pa)]
        if ov:
            _, pa, pz = max(ov)
            acc.edge.append(abs(a - pa) + abs(z - pz)); acc.sp_reason[reason][2] += 1
        else: acc.sp_missed += 1
        hit = sum(1 for k in r if pred[k])
        acc.sp_fate[reason]['kept' if hit == len(r) else ('lost' if hit == 0 else 'partial')] += 1
    st = b['stats']
    if st['keep'] + st['translate'] > 0:
        truth_keep = st['translate'] == 0
        pk = mech == 'block'
        if truth_keep and pk: acc.bk_tp += 1
        elif truth_keep: acc.bk_fn += 1
        elif pk: acc.bk_fp += 1; acc.fp_blocks[b['keep']] += 1
        else: acc.bk_tn += 1
        near = st['keep'] / (st['keep'] + st['translate']) >= 0.9
        if near and pk: acc.b9_tp += 1
        elif near: acc.b9_fn += 1
        elif pk: acc.b9_fp += 1


def pr_line(tp, fp, fn):
    return f'P {rci(tp, tp + fp)}  R {rci(tp, tp + fn)}  (tp {tp} fp {fp} fn {fn})'


def rule_tables(blocks, rules, out):
    accs = {}
    for src in SOURCES:
        for read in READS:
            acc = Acc()
            for b in blocks:
                if b['src'] == src and b['read'] == read and not b['noletter']: accumulate(acc, b, rules[b['id']])
            accs[(src, read)] = acc
    for read in READS:
        for src in SOURCES:
            a = accs[(src, read)]
            if a.tp + a.fp + a.fn == 0: continue
            out.append(f'  [{src}, read {read}]')
            out.append(f'    (a) words      {pr_line(a.tp, a.fp, a.fn)}')
            out.append('        precision by decider: ' + ', '.join(f'{m} {rci(a.tp_mech[m], a.tp_mech[m] + a.fp_mech[m])} (tp {a.tp_mech[m]} fp {a.fp_mech[m]})' for m in ('block', 'span')))
            out.append('        recall by reason: ' + ', '.join(f'{r} {rci(v[0], v[1])} n={v[1]}' for r, v in sorted(a.rec.items(), key=lambda kv: -kv[1][1])))
            f1 = 2 * a.sp_exact / (a.sp_truth + a.sp_pred) if a.sp_truth + a.sp_pred else float('nan')
            P = ratio(a.sp_exact, a.sp_pred); R = ratio(a.sp_exact, a.sp_truth)
            e = a.edge
            out.append(f'    (b) spans      exact-boundary F1 {f1:.2f}  (P {P:.2f} R {R:.2f}; truth {a.sp_truth}, predicted {a.sp_pred}, exact {a.sp_exact}, '
                       f'overlapped {len(e)}, missed {a.sp_missed})   edge error over overlapped spans: mean {sum(e) / len(e) if e else float("nan"):.2f} words, '
                       f'exact {sum(1 for x in e if x == 0)}, <=1 {sum(1 for x in e if x <= 1)}, >=3 {sum(1 for x in e if x >= 3)}')
            out.append('        exact by reason: ' + ', '.join(f'{r} {v[1]}/{v[0]}' for r, v in sorted(a.sp_reason.items(), key=lambda kv: -kv[1][0])))
            out.append(f'    (c) block keep {pr_line(a.bk_tp, a.bk_fp, a.bk_fn)}   [truth keep = keep words and no translate word]')
            out.append(f'        near-pure   {pr_line(a.b9_tp, a.b9_fp, a.b9_fn)}   [truth keep = keep share of scored words >= 0.9]')
            fate = collections.Counter(); [fate.update(v) for v in a.sp_fate.values()]
            out.append(f'    (d) keep->translated: {a.fn} of {a.tp + a.fn} keep words; spans fully kept {fate["kept"]}, partly {fate["partial"]}, lost {fate["lost"]}')
            out.append('        spans lost or partly by reason: ' + (', '.join(f'{r} {v["lost"]}+{v["partial"]}/{sum(v.values())}' for r, v in sorted(a.sp_fate.items(), key=lambda kv: -sum(kv[1].values()))) or '-'))
            out.append(f'        translate->kept: {a.fp} of {a.tw} translate words kept by: ' +
                       ', '.join(f'{m} {n}' for m, n in sorted(a.fp_mech.items())) + (f'; translate/mixed blocks kept whole: {dict(a.fp_blocks)}' if a.fp_blocks else '') +
                       '; by shape: ' + ', '.join(f'{t} {n}' for t, n in a.fp_tag.most_common(6)))
    return accs


# -------------------------------------------------------------------------------------------------------- purity, keep mass, region fit

def purity_tables(blocks, regions, out):
    for read in READS:
        out.append(f'  read {read}')
        out.append(f'    {"source":12s} {"blocks":>6s} {"pure keep":>9s} {"pure transl":>11s} {"mixed":>6s} {"purity":>7s}   keep words: in pure-keep blocks / in mixed blocks'
                   f' (of which near-pure >= 0.9)   region fit (whole / split / merged)')
        for src in SOURCES:
            B = [b for b in blocks if b['src'] == src and b['read'] == read]
            cls = collections.Counter(b['keep'] for b in B)
            n = cls['keep'] + cls['translate'] + cls['mixed']
            if not n: continue
            kw_pure = sum(b['stats']['keep'] for b in B if b['keep'] == 'keep')
            kw_mixed = sum(b['stats']['keep'] for b in B if b['keep'] == 'mixed')
            kw_near = sum(b['stats']['keep'] for b in B if b['keep'] == 'mixed' and b['stats']['keep'] / (b['stats']['keep'] + b['stats']['translate']) >= 0.9)
            tot = kw_pure + kw_mixed
            fit = region_fit(B, regions[src])
            out.append(f'    {src:12s} {n:6d} {cls["keep"]:9d} {cls["translate"]:11d} {cls["mixed"]:6d} {(cls["keep"] + cls["translate"]) / n:7.2f}   '
                       f'{kw_pure} ({kw_pure / max(1, tot):.2f}) / {kw_mixed} ({kw_mixed / max(1, tot):.2f}) ({kw_near})   '
                       f'{fit["whole"]} / {fit["split"]} / {fit["merged"]}  of {sum(fit.values()) - fit["lost"]} read regions ({fit["lost"]} not read at all)')
        out.append('    keep words by reason, share in pure-keep blocks vs inside mixed blocks (inline spans among translated text):')
        for src in SOURCES:
            B = [b for b in blocks if b['src'] == src and b['read'] == read]
            pure, mixed = collections.Counter(), collections.Counter()
            for b in B:
                for r, v in b['stats']['reasons'].items():
                    if b['keep'] == 'keep': pure[r] += v
                    elif b['keep'] == 'mixed': mixed[r] += v
            if not pure and not mixed: continue
            rows = sorted(set(pure) | set(mixed), key=lambda r: (-(pure[r] + mixed[r]), r))              # ties by name: set order changes with the hash seed
            out.append(f'      {src:12s} ' + ', '.join(f'{r} {pure[r]}/{mixed[r]}' for r in rows))
        for src in SOURCES:
            mixed = sorted((b for b in blocks if b['src'] == src and b['read'] == read and b['keep'] == 'mixed'), key=lambda b: b['id'])
            if not mixed: continue
            picks = sorted(set([0, len(mixed) // 3, 2 * len(mixed) // 3]))
            for i in picks:
                b = mixed[i]; st = b['stats']
                out.append(f'      mixed example, {src}: {b["id"]} keep {st["keep"]} translate {st["translate"]} ({",".join(sorted(st["reasons"]))}): ' + re.sub(r'\s+', ' ', b['text'])[:90])


def region_fit(B, region_ids):
    """Per truth region: does it map to one whole OCR block (whole), to several blocks that hold nothing but keep words (split),
    does some block holding a part of it also hold translate words (merged), or did OCR read none of it (lost)."""
    holders = collections.defaultdict(set)
    byid = {}
    for b in B:
        byid[b['id']] = b
        for w in b['words']:
            if w[6]: holders[w[6]].add(b['id'])
    fit = collections.Counter()
    for r in region_ids:
        hs = holders.get(r)
        if not hs: fit['lost'] += 1
        elif any(byid[h]['keep'] == 'mixed' for h in hs): fit['merged'] += 1
        elif len(hs) == 1: fit['whole'] += 1
        else: fit['split'] += 1
    return fit


# --------------------------------------------------------------------------------------------------------------------- label counts

def count_tables(blocks, out):
    for read in READS:
        for src in SOURCES:
            B = [b for b in blocks if b['src'] == src and b['read'] == read]
            if not B: continue
            cls = collections.Counter(b['keep'] for b in B)
            wk = collections.Counter(); reasons = collections.Counter(); nspan = collections.Counter(); near = collections.Counter()
            for b in B:
                for w in b['words']:
                    wk[w[2] or 'none'] += 1
                    if w[2] == KEEP: reasons[w[3]] += 1
                    if w[4]: near[(w[4], w[2])] += 1
                runs, _ = keep_runs([w[2] for w in b['words']])
                for r in runs: nspan[collections.Counter(b['words'][k][3] for k in r).most_common(1)[0][0]] += 1
            nn = sum(near.values())
            out.append(f'  {src:12s} {read:3s} blocks {len(B)} ({dict(sorted(cls.items()))}), noletter {sum(1 for b in B if b["noletter"])}')
            out.append(f'               words {dict(wk)}; keep words by reason {dict(reasons.most_common())}')
            out.append(f'               keep spans {sum(nspan.values())} by reason {dict(nspan.most_common())}; near-negative words {nn}: '
                       f'translate {sum(v for (t, k), v in near.items() if k == TRANSLATE)}, either {sum(v for (t, k), v in near.items() if k == EITHER)}, keep {sum(v for (t, k), v in near.items() if k == KEEP)}')


# ------------------------------------------------------------------------------------------------------------ where the misses cluster

def cluster_tables(accs, out):
    for src in SOURCES:
        a = accs[(src, 'doc')]
        if a.tp + a.fn == 0: continue
        out.append(f'  [{src}, read doc] keep words the rules translate, by reason and shape:')
        for r, c in sorted(a.miss.items(), key=lambda kv: -sum(kv[1].values())):
            out.append(f'    {r:9s} {sum(c.values()):4d}: ' + '; '.join(f'{sh} {n} (' + ' '.join(a.miss_ex[(r, sh)][:4]) + ')' for sh, n in c.most_common(4)))
        if a.fa:
            out.append(f'  [{src}, read doc] translate words the rules keep, by mechanism and shape:')
            for (m, tag), n in a.fa.most_common(6): out.append(f'    {m:6s} {tag:18s} {n:4d}  e.g. ' + ' '.join(a.fa_ex[(m, tag)][:6]))


def share_table(blocks, rules, out):
    """The line of today's rules: how often a block is kept whole by its keep share (keep / (keep + translate) words)."""
    bins = [(0, 0.01), (0.01, 0.15), (0.15, 0.30), (0.30, 0.50), (0.50, 0.70), (0.70, 0.90), (0.90, 1.01)]
    out.append('  whole-block keep by the keep share of the block, read doc, papers (all) and cases (all)')
    for lo, hi in bins:
        sel = [b for b in blocks if b['read'] == 'doc' and not b['noletter'] and b['stats']['keep'] + b['stats']['translate'] > 0
               and lo <= b['stats']['keep'] / (b['stats']['keep'] + b['stats']['translate']) < hi]
        kept = sum(1 for b in sel if not rules[b['id']]['needs'])
        out.append(f'    keep share [{lo:.2f},{min(hi, 1):.2f}): {len(sel):4d} blocks, kept whole {kept:4d} ({ratio(kept, len(sel)):.2f})')


def group_table(blocks, rules, out):
    out.append('  per paper / case, read doc: keep words found (recall), translate words kept by mistake, exact keep spans')
    for key in sorted(set(b['paper'] for b in blocks)):
        acc = Acc()
        for b in blocks:
            if b['paper'] == key and b['read'] == 'doc' and not b['noletter']: accumulate(acc, b, rules[b['id']])
        src = next(b['src'] for b in blocks if b['paper'] == key)
        out.append(f'    {key:22s} {src:12s} keep words {acc.tp + acc.fn:4d} found {ratio(acc.tp, acc.tp + acc.fn):.2f} | translate words {acc.tw:4d} kept {acc.fp:3d} | '
                   f'keep spans {acc.sp_truth:3d} exact {acc.sp_exact:3d}')


def decision(accs, out):
    out.append('DECISION (precision and recall both >= 0.95 on the hold-out -> defer the model for the slice; else train for the band; n < 20: thin)')
    for src in ('papers hold', 'cases hold', 'h2'):
        a = accs[(src, 'doc')]
        if src == 'h2' and a.tp + a.fn == 0: continue                          # no H2 labels in this run
        P = ratio(a.tp, a.tp + a.fp)
        out.append(f'  [{src}, read doc] word precision {P:.2f}; recall by reason (precision is of all kept words, one number for every slice):')
        for r, v in sorted(a.rec.items(), key=lambda kv: -kv[1][1]):
            R = ratio(v[0], v[1])
            out.append(f'    {r:9s} R {R:.2f} (n={v[1]}{", thin" if v[1] < 20 else ""})  -> ' + ('defer' if R >= 0.95 and P >= 0.95 else 'train for the band'))
        f1 = 2 * a.sp_exact / (a.sp_truth + a.sp_pred) if a.sp_truth + a.sp_pred else float('nan')
        out.append(f'    spans: exact-boundary F1 {f1:.2f} -> ' + ('defer' if f1 >= 0.95 else 'train for the band') + f'   (keep-boundary.md section 5 asks F1 >= 0.90 for a model)')
        Pb, Rb = ratio(a.bk_tp, a.bk_tp + a.bk_fp), ratio(a.bk_tp, a.bk_tp + a.bk_fn)
        out.append(f'    whole-block keep: P {Pb:.2f} R {Rb:.2f} -> ' + ('defer' if Pb >= 0.95 and Rb >= 0.95 else 'train for the band'))


def region_tables(blocks, rules, out):
    """CodeRegion (keeprules with KEEP_FEED): the rules alone, and the rules OR the region verdict, per source and read. A block the region
    keeps and today's rules translate is `flipped`; a flipped block whose truth is not pure keep is a false fire and is listed by name."""
    out.append('CODE REGIONS (Core CodeRegion, tools/keep-labels/Sources/keeprules; kept = today\'s rules OR a region verdict)')
    nofeed = sum(1 for b in blocks if rules[b['id']].get('region') == 'nofeed')
    if nofeed: out.append(f'  WARNING: {nofeed} labelled blocks have no picture in the feed (KEEP_WORK lacks their pictures): CodeRegion is not run on them')
    only = os.environ.get('KEEP_SETS')                       # e.g. "cases dev,papers dev": fit on these, leave the hold-outs unread
    if only: out.append(f'  (only the sets {only})')
    for read in READS:
        for src in SOURCES:
            if only and src not in only.split(','): continue
            B = [b for b in blocks if b['src'] == src and b['read'] == read and not b['noletter']]
            if not B: continue
            a0, a1 = Acc(), Acc()
            fired, false_fires = collections.Counter(), []
            for b in B:
                r = rules[b['id']]
                accumulate(a0, b, r)
                r1 = dict(r)
                if r.get('region') and r['region'] != 'nofeed' and r['needs']:
                    r1['needs'] = False
                    fired[r['region']] += 1
                    st = b['stats']
                    if st['keep'] + st['translate'] > 0 and st['translate'] > 0: false_fires.append(b)
                accumulate(a1, b, r1)
            tw = a0.tw
            out.append(f'  [{src}, read {read}]')
            out.append(f'    block keep   before {pr_line(a0.bk_tp, a0.bk_fp, a0.bk_fn)}')
            out.append(f'                 after  {pr_line(a1.bk_tp, a1.bk_fp, a1.bk_fn)}')
            out.append(f'    keep->translated words  {a0.fn} -> {a1.fn} of {a0.tp + a0.fn};  translate->kept words {a0.fp} -> {a1.fp} of {tw} '
                       f'(+{a1.fp - a0.fp} = {100 * (a1.fp - a0.fp) / max(1, tw):.2f} % of translate words)')
            out.append(f'    blocks flipped to keep by region: {sum(fired.values())} {dict(fired)}; of them with translate words in the truth: {len(false_fires)}')
            for b in false_fires:
                out.append(f'      FALSE FIRE {b["id"]} truth {b["keep"]} {rules[b["id"]]["region"]}: ' + re.sub(r'\s+', ' ', b['text'])[:70])
    pt = [b for b in blocks if b['read'] == 'doc' and b['src'].startswith('cases') and b['keep'] == 'translate' and not b['noletter']
          and (not only or b['src'] in only.split(','))]
    ff = [b for b in pt if rules[b['id']].get('region') and rules[b['id']]['needs']]
    out.append(f'  pure-translate case blocks (read doc, dev + hold-out): {len(pt)}; fired by the region (and translated today): {len(ff)}  ' + ', '.join(b['id'] for b in ff))


def main():
    labels_dir, rules_path = sys.argv[1:3]
    blocks, regions = load(labels_dir)
    rules = {}
    for l in open(rules_path):
        r = json.loads(l); rules[r['id']] = r
    out = []
    out.append(f'labels: {len(blocks)} blocks of {len(set(b["paper"] for b in blocks))} papers / cases')
    out.append('')
    out.append('LABEL COUNTS')
    count_tables(blocks, out)
    out.append('')
    out.append('TODAY\'S RULES ON THE KEEP BOUNDARY: (a) words (b) spans (c) blocks (d) the two costly errors')
    accs = rule_tables(blocks, rules, out)
    out.append('')
    out.append('BLOCK PURITY, KEEP-MASS SPLIT, REGION FIT (all blocks, noletter included)')
    purity_tables(blocks, regions, out)
    out.append('')
    out.append('WHERE THE MISSES CLUSTER')
    cluster_tables(accs, out)
    share_table(blocks, rules, out)
    out.append('')
    out.append('PER PAPER / CASE')
    group_table(blocks, rules, out)
    out.append('')
    decision(accs, out)
    if any('region' in r for r in rules.values()):
        out.append('')
        region_tables(blocks, rules, out)
    print('\n'.join(out))
    if '--json' in sys.argv:
        json.dump({'text': out}, open(sys.argv[sys.argv.index('--json') + 1], 'w'), ensure_ascii=False, indent=1)


if __name__ == '__main__':
    main()
