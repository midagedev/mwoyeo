#!/usr/bin/env python3
"""Turns the predictions of a judge (train.py) into keeprules-format records and scores them with score.py (rules_report.accumulate), for H2 / code / papers (out-of-fold)
and H3 (test), both reads, every language.

usage: evaluate.py <judge key> ...      (judge key `rules` = today's Core rules, keeprules + CodeRegion; needs MB_SCRATCH/rules-*.jsonl from run.sh)
writes MB_SCRATCH/records/<key>.<task>.<op>.<set>.jsonl   one record per block {"id","needs","spans"} (+ the keeprules fields, so h2_report.py reads them too)
       MB_SCRATCH/cache/metrics-<key>.json                the scored numbers

Variants of a judge:
  block   the block task: needs = block judge says not keep, spans = []                     (binary: keep the whole block)
  inline  the inline task: needs = true everywhere, spans = runs of words the word judge keeps   (the universe is every scored word, for every judge)
  both    needs from the block judge; the word judge's spans in the blocks it translates
Operating points (thresholds from the out-of-fold predictions of the dev-screen rows, h2 + code, never from H3):
  F1    the threshold with the best F1 (block F1 for the block judge, word F1 for the word judge)
  P98   the lowest threshold whose precision is at least 0.98 (block precision / word precision); the best precision if none reaches it"""
import collections, json, os, pickle, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np
import data, dataset, score
from truth import KEEP, TRANSLATE

DEV = ('h2', 'code')
READS = ('doc', 'vn')
LANGS = ('ko', 'ja', 'en', 'zh-Hans')


def op_points(p, y, grid=None):
    """-> {'F1': thr, 'P98': thr} for scores p, labels y in {0, 1}."""
    order = np.argsort(-p)
    ps, ys = p[order], y[order]
    tp = np.cumsum(ys); fp = np.cumsum(1 - ys)
    P = tp / np.maximum(1, tp + fp); R = tp / max(1, ys.sum()); F = 2 * P * R / np.maximum(1e-9, P + R)
    # only cut between distinct scores
    last = np.r_[ps[1:] != ps[:-1], True]
    idx = np.where(last)[0]
    best = idx[np.argmax(F[idx])]
    ok = idx[P[idx] >= 0.98]
    p98 = ok[-1] if len(ok) else idx[np.argmax(P[idx])]          # the most keeping cut that is still precise enough
    thr = lambda i: float(ps[i] - 1e-9) if i == idx[-1] else float((ps[i] + ps[i + 1]) / 2)
    return {'F1': thr(best), 'P98': thr(p98)}


def thresholds(ds, pred):
    out = {}
    pb = np.concatenate([pred['block']['oof'][s][ds[s]['y3'] >= 0] for s in DEV])
    yb = np.concatenate([(ds[s]['y3'][ds[s]['y3'] >= 0] == 0).astype(int) for s in DEV])
    out['block'] = op_points(pb, yb)
    pw = np.concatenate([pred['word']['oof'][s][ds[s]['tok']['y'] >= 0] for s in DEV])
    yw = np.concatenate([ds[s]['tok']['y'][ds[s]['tok']['y'] >= 0].astype(int) for s in DEV])
    out['word'] = op_points(pw, yw)
    return out


def rules_rec_full(r):
    """A keeprules-format record from needs / spans (the other fields as keeprules writes them for a judge that sets none of them)."""
    return r


def make_records(d, pb, pw, task, tb, tw):
    """-> {block id: record} for one set `d` (dataset dict), block scores pb (per block) and word scores pw (per row of d['tok'])."""
    t = d['tok']
    starts = collections.defaultdict(dict)
    for r, (i, k) in enumerate(zip(t['bi'], t['wi'])): starts[int(i)][int(k)] = r
    recs = {}
    for i, b in enumerate(d['blocks']):
        keep_whole = pb is not None and pb[i] >= tb
        if task == 'hyb': keep_whole = not score.rule_rec(b, True)['needs']          # the rules (OR CodeRegion) decide the block, the word judge protects spans in the rest
        flags = None
        if pw is not None and b['words']:
            m = starts.get(i, {})
            flags = [bool(pw[m[k]] >= tw) if k in m else False for k in range(len(b['words']))]
        if task == 'block': rec = score.synth(keep_whole, [])
        elif task == 'inline': rec = score.synth(False, score.spans_of_words(b, flags) if flags else [])
        elif task == 'hyb': rec = score.synth(keep_whole, [] if keep_whole or not flags else score.spans_of_words(b, flags))
        else: rec = score.synth(keep_whole, [] if keep_whole or not flags else score.spans_of_words(b, flags))
        recs[b['id']] = rec
    return recs


def write_records(path, d, recs):
    with open(path, 'w') as f:
        for b in d['blocks']:
            r = recs[b['id']]
            f.write(json.dumps({'id': b['id'], 'spans': r['spans'], 'formula': False, 'mathHeavy': False, 'identifier': False, 'literal': False, 'needs': r['needs'],
                                'share': 0.0, 'signs': 0, 'region': None}) + '\n')


def block_confusion(d, recs, read):
    c = collections.Counter()
    for b in d['blocks']:
        if b['read'] != read or b['noletter']: continue
        t = score.truth_class(b)
        if t is None: continue
        c[(t, 'kept' if not recs[b['id']]['needs'] else 'translated')] += 1
    return {f'{a}->{b}': v for (a, b), v in sorted(c.items())}


def slice_summary(d, recs, read, pred_blocks):
    """Words of the blocks with at least one translate word (the inline pieces of prose / mixed blocks), scored like the rest."""
    acc = score.accumulate([b for b in d['blocks'] if b['stats']['translate'] > 0], lambda b: recs[b['id']], read)
    return score.summary(acc)


def url_block_recall(d, recs, read):
    """Block-weighted url recall: for each block with url keep words, the share of them the record keeps; averaged over blocks (ja / zh-Hans doc reads cut a url into one word
    per character, so the word-weighted recall of the url slice is dominated by those two languages)."""
    per = collections.defaultdict(list)
    for b in d['blocks']:
        if b['read'] != read or b['noletter']: continue
        idx = [k for k, w in enumerate(b['words']) if w[2] == KEEP and w[3] == 'url']
        if not idx: continue
        rec = recs[b['id']]
        pred, _ = score.RR.predict(b, rec)
        per[b['lang']].append(sum(1 for k in idx if pred[k]) / len(idx))
        per['all'].append(per[b['lang']][-1])
    return {l: dict(blocks=len(v), recall=float(np.mean(v))) for l, v in per.items()}


def metrics_for(d, recs):
    out = {}
    for read in READS:
        out[read] = {'all': score.summary(score.accumulate(d['blocks'], lambda b: recs[b['id']], read)),
                     'confusion': block_confusion(d, recs, read),
                     'inline_slice': slice_summary(d, recs, read, None),
                     'url_block_recall': url_block_recall(d, recs, read)}
        for lang in LANGS:
            if any(b['lang'] == lang for b in d['blocks']):
                out[read][lang] = score.summary(score.accumulate(d['blocks'], lambda b: recs[b['id']], read, lang))
    return out


def evaluate_judge(key):
    ds = dataset.load()
    pred = pickle.load(open(f'{data.SCRATCH}/cache/pred-{key}.pkl', 'rb'))
    thr = thresholds(ds, pred)
    os.makedirs(f'{data.SCRATCH}/records', exist_ok=True)
    have_rules = os.path.exists(f'{data.SCRATCH}/rules-h3.jsonl')
    if have_rules: fresh_rules(ds)
    res = {'thr': thr, 'setting': {t: pred[t]['setting'] for t in ('block', 'word')}, 'cv': {t: pred[t]['cv'] for t in ('block', 'word')}, 'rows': {}}
    for opname in ('F1', 'P98'):
        tb, tw = thr['block'][opname], thr['word'][opname]
        for task in ('block', 'inline', 'both') + (('hyb',) if have_rules else ()):
            for s in data.TRAIN_SETS + data.TEST_SETS:
                src = 'test' if s == 'h3' else 'oof'
                pb = pred['block'][src].get(s) if s in pred['block'][src] else None
                pw = pred['word'][src].get(s)
                recs = make_records(ds[s], pb, pw, task, tb, tw)
                write_records(f'{data.SCRATCH}/records/{key}.{task}.{opname}.{s}.jsonl', ds[s], recs)
                res['rows'][f'{task}|{opname}|{s}'] = metrics_for(ds[s], recs)
    json.dump(res, open(f'{data.SCRATCH}/cache/metrics-{key}.json', 'w'))
    return res


def fresh_rules(ds):
    """The keeprules records of the current tree (MB_SCRATCH/rules-<feed>.jsonl), not the ones cached with the blocks."""
    for s in ds:
        feed = data.SETS[s][2]
        recs = {}
        for l in open(f'{data.SCRATCH}/rules-{feed}.jsonl'):
            r = json.loads(l); recs[r['id']] = r
        for b in ds[s]['blocks']: b['rules'] = recs[b['id']]


def evaluate_rules():
    ds = dataset.load()
    fresh_rules(ds)
    res = {'rows': {}}
    for variant, wr in (('rules', False), ('rules+region', True)):
        for task in ('block', 'inline', 'both'):
            for s in data.TRAIN_SETS + data.TEST_SETS:
                recs = {}
                for b in ds[s]['blocks']:
                    r = score.rule_rec(b, wr)
                    if task == 'block': recs[b['id']] = {'needs': r['needs'], 'spans': []}
                    elif task == 'inline': recs[b['id']] = {'needs': True, 'spans': r['spans']}
                    else: recs[b['id']] = {'needs': r['needs'], 'spans': r['spans']}
                os.makedirs(f'{data.SCRATCH}/records', exist_ok=True)
                write_records(f'{data.SCRATCH}/records/{variant}.{task}.-.{s}.jsonl', ds[s], recs)
                res['rows'][f'{variant}|{task}|{s}'] = metrics_for(ds[s], recs)
    json.dump(res, open(f'{data.SCRATCH}/cache/metrics-rules.json', 'w'))
    return res


if __name__ == '__main__':
    for k in sys.argv[1:]:
        r = evaluate_rules() if k == 'rules' else evaluate_judge(k)
        print(k, 'evaluated;', 'thresholds', r.get('thr'))
