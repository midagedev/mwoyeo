#!/usr/bin/env python3
"""One scorer for every judge: rules_report.py's accumulate() (the code behind RESULTS-h2 / RESULTS-code-region) fed with a rule-shaped record per block,
{"needs": bool, "spans": [[start, end] ...]}: needs=false keeps the block whole, spans protect words inside a translated block. A learned judge is turned into
those records (a block judge: needs = not keep, no spans; an inline judge: needs=true on the blocks the rules translate, spans = runs of predicted keep words),
so the P / R of every judge are counted by the same lines as the rules'.

usage: score.py repro        the scorer on today's rules (rules OR CodeRegion) on H2: must print the RESULTS-h2 headline (doc P 0.98 / R 0.78)"""
import collections, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
KL = os.path.dirname(HERE)
sys.path.insert(0, KL)
sys.path.insert(0, HERE)
import rules_report as RR
from truth import KEEP, TRANSLATE, EITHER, SCORED


def rule_rec(b, with_region=True):
    """The keeprules record of a block, with `needs` false where CodeRegion keeps it (rules OR region, what the app does today) when with_region."""
    r = b['rules']
    if with_region and r.get('region') and r['region'] != 'nofeed' and r['needs']:
        r = dict(r); r['needs'] = False
    return r


def synth(keep_whole, spans=()):
    return {'needs': not keep_whole, 'spans': [list(s) for s in spans]}


def spans_of_words(b, flags):
    """Character spans [start, end) of the runs of consecutive predicted-keep words of a block (one span per run, as InlineMath spans cover a run)."""
    out, cur = [], None
    for k, w in enumerate(b['words']):
        if flags[k]:
            cur = [w[0], w[1]] if cur is None else [cur[0], w[1]]
        elif cur is not None:
            out.append(cur); cur = None
    if cur is not None: out.append(cur)
    return out


def accumulate(blocks, recfn, read, lang=None):
    """RR.Acc over the blocks of one read (and one language) that carry a letter, as RR.rule_tables counts them."""
    acc = RR.Acc()
    for b in blocks:
        if b['read'] != read or b['noletter']: continue
        if lang is not None and b['lang'] != lang: continue
        rec = recfn(b)
        if rec is None: continue
        RR.accumulate(acc, b, rec)
    return acc


def truth_class(b):
    st = b['stats']
    if st['keep'] + st['translate'] == 0: return None
    if st['translate'] == 0: return 'keep'
    return 'translate' if st['keep'] == 0 else 'mixed'


def prf(tp, fp, fn):
    p = tp / (tp + fp) if tp + fp else float('nan')
    r = tp / (tp + fn) if tp + fn else float('nan')
    f = 2 * tp / (2 * tp + fp + fn) if 2 * tp + fp + fn else float('nan')
    return p, r, f


def summary(acc):
    """The numbers of one Acc as a flat dict (word P/R, block keep P/R/F1, the two costly errors, span exact F1, recall by reason, mixed blocks kept whole)."""
    wp, wr, wf = prf(acc.tp, acc.fp, acc.fn)
    bp, br, bf = prf(acc.bk_tp, acc.bk_fp, acc.bk_fn)
    spf = 2 * acc.sp_exact / (acc.sp_truth + acc.sp_pred) if acc.sp_truth + acc.sp_pred else float('nan')
    return dict(w_tp=acc.tp, w_fp=acc.fp, w_fn=acc.fn, w_P=wp, w_R=wr, w_F1=wf, keep_words=acc.tp + acc.fn, translate_words=acc.tw,
                b_tp=acc.bk_tp, b_fp=acc.bk_fp, b_fn=acc.bk_fn, b_P=bp, b_R=br, b_F1=bf,
                fp_blocks=dict(acc.fp_blocks), sp_truth=acc.sp_truth, sp_pred=acc.sp_pred, sp_exact=acc.sp_exact, sp_F1=spf,
                rec={k: (v[0], v[1]) for k, v in acc.rec.items()})


def confusion(blocks, keep_whole_fn, read):
    """truth class (keep / translate / mixed) x predicted (kept whole / translated) over the blocks with a letter and a scored word."""
    c = collections.Counter()
    for b in blocks:
        if b['read'] != read or b['noletter']: continue
        t = truth_class(b)
        if t is None: continue
        kw = keep_whole_fn(b)
        if kw is None: continue
        c[(t, 'kept' if kw else 'translated')] += 1
    return c


def fmt(s):
    return (f'word P {s["w_P"]:.2f} R {s["w_R"]:.2f} (tp {s["w_tp"]} fp {s["w_fp"]} fn {s["w_fn"]}); '
            f'block keep P {s["b_P"]:.2f} R {s["b_R"]:.2f} F1 {s["b_F1"]:.2f} (tp {s["b_tp"]} fp {s["b_fp"]} fn {s["b_fn"]})')


def repro():
    import data
    h2 = data.load_set('h2') if not os.path.exists(f'{data.SCRATCH}/cache/h2.pkl') else data.load_all(['h2'])['h2']
    out = []
    for read in ('doc', 'vn'):
        for name, wr in (('rules only', False), ('rules OR CodeRegion', True)):
            s = summary(accumulate(h2, lambda b, wr=wr: rule_rec(b, wr), read))
            out.append(f'H2 {name:20s} read {read}: ' + fmt(s))
    print('\n'.join(out))
    s = summary(accumulate(h2, lambda b: rule_rec(b, True), 'doc'))
    want = (3281, 65, 945)
    got = (s['w_tp'], s['w_fp'], s['w_fn'])
    print(f'REPRODUCTION (RESULTS-h2-2026-10-20.txt: rules OR CodeRegion, doc read, tp 3281 fp 65 fn 945, P 0.98 R 0.78): got tp {got[0]} fp {got[1]} fn {got[2]} -> '
          + ('MATCH' if got == want else 'DIFFERENT'))
    return got == want


if __name__ == '__main__':
    if sys.argv[1:] == ['repro']:
        sys.exit(0 if repro() else 1)
    print(__doc__)
