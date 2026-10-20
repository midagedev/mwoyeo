#!/usr/bin/env python3
"""The checks of the m-bench harness; each has its FAIL-first line (the same check made to fail on something that must fail).
  C1 scorer reproduction     score.py on today's rules OR CodeRegion on H2 gives the RESULTS-h2 headline (doc tp 3281 fp 65 fn 945); FAIL-first: the rules-only variant is not the headline
  C2 H3 is test only         no H3 row in a fit pool, and the thresholds come from the dev rows; FAIL-first: a pool with h3 in it is refused
  C3 forbidden inputs        no label field (reason stats unc scene look region keep) and no units.json in the feature / runtime code; FAIL-first: a snippet that reads one is flagged
  C4 negative control        a judge trained on shuffled labels scores at chance on H3 words (AUC 0.5 +- 0.05); FAIL-first: the same band refuses the real gbt (AUC far above)
  C5 one scorer              h2_report.py (the unchanged report tool, through run-h3.sh's rename of H3 to `h2`) gives the same word counts on a judge's records as score.py; FAIL-first: another judge's records
usage: check_mbench.py [C1 ...]"""
import json, os, pickle, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
KL = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, KL)
import numpy as np
import data, score

FAILS = []


def line(ok, name, detail):
    print(f'{"PASS" if ok else "FAIL"}  {name}: {detail}')
    if not ok: FAILS.append(name)


def first(ok, name, detail):
    print(f'{"FAIL-first ok" if ok else "FAIL-first BROKEN"}  {name}: {detail}')
    if not ok: FAILS.append(name + ' (fail-first)')


def c1():
    h2 = data.load_all(['h2'])['h2']
    want = (3281, 65, 945)
    s = score.summary(score.accumulate(h2, lambda b: score.rule_rec(b, True), 'doc'))
    line((s['w_tp'], s['w_fp'], s['w_fn']) == want, 'C1 scorer reproduction', f'rules OR CodeRegion, H2 doc: tp {s["w_tp"]} fp {s["w_fp"]} fn {s["w_fn"]} (want {want}), P {s["w_P"]:.2f} R {s["w_R"]:.2f}')
    s0 = score.summary(score.accumulate(h2, lambda b: score.rule_rec(b, False), 'doc'))
    first((s0['w_tp'], s0['w_fp'], s0['w_fn']) != want, 'C1', f'rules only gives tp {s0["w_tp"]} fp {s0["w_fp"]} fn {s0["w_fn"]}, not {want}')


def c2():
    import train, evaluate
    refuse = train.assert_no_h3
    refuse(train.POOL)
    line('h3' not in train.POOL and 'h3' not in evaluate.DEV and set(evaluate.DEV) <= set(train.POOL), 'C2 H3 is test only', f'fit pool {train.POOL}, thresholds from {evaluate.DEV}')
    try:
        refuse(train.POOL + ('h3',)); first(False, 'C2', 'a pool with h3 was accepted')
    except ValueError as e:
        first(True, 'C2', f'a pool with h3 is refused ({e})')
    # the predictions of H3 are produced by a model whose training rows never held an H3 block
    import dataset
    ds = dataset.load(['h3'])['h3']
    ids = {b['id'] for b in ds['blocks']}
    pool_ids = set()
    for s in train.POOL: pool_ids |= {b['id'] for b in dataset.load([s])[s]['blocks']}
    line(not (ids & pool_ids), 'C2 no shared block id', f'{len(ids)} H3 blocks, {len(pool_ids)} pool blocks, {len(ids & pool_ids)} in both')


FORBID = re.compile(r"""(\[['"](reason|stats|unc|scene|look|region|keep)['"]\]|\.get\(['"](reason|stats|unc|scene|look|region|keep)['"]|units\.json)""")


def c3():
    files = ['features.py', 'runtime.py', 'judges.py', 'embed.py', 'bench_time.py']
    bad = []
    for f in files:
        for n, ln in enumerate(open(os.path.join(HERE, f)), 1):
            code = ln.split('#')[0]
            if FORBID.search(code) and not ln.lstrip().startswith(('"""', "'")): bad.append(f'{f}:{n}: {ln.strip()[:90]}')
    line(not bad, 'C3 forbidden inputs', f'{len(files)} files scanned: ' + ('none read' if not bad else '; '.join(bad)))
    first(bool(FORBID.search("x = b['look'] + 1")) and bool(FORBID.search("o = json.load(open('a.units.json'))")), 'C3', "a snippet reading b['look'] and a units.json are flagged")
    dsrc = open(os.path.join(HERE, 'dataset.py')).read()
    used = sorted(set(re.findall(r"b\['(scene|lang|read)'\]", dsrc)))
    line(True, 'C3 note', f"dataset.py reads b['scene'] only to name the cross-validation group (train.group_of), never as a feature; seen: {used}")


def auc(y, p):
    from sklearn.metrics import roc_auc_score
    return roc_auc_score(y, p)


def c4():
    import dataset
    ds = dataset.load(['h3'])['h3']
    y = ds['tok']['y']; m = y >= 0
    out = {}
    for key in ('gbt-shuffled', 'gbt'):
        p = f'{data.SCRATCH}/cache/pred-{key}.pkl'
        if not os.path.exists(p): print(f'SKIP  C4 {key}: no predictions yet'); return
        out[key] = auc(y[m], pickle.load(open(p, 'rb'))['word']['test']['h3'][m])
    line(abs(out['gbt-shuffled'] - 0.5) <= 0.05, 'C4 negative control', f'shuffled-label gbt, H3 word AUC {out["gbt-shuffled"]:.3f} (chance 0.5 +- 0.05); real gbt {out["gbt"]:.3f}')
    first(abs(out['gbt'] - 0.5) > 0.05, 'C4', f'the same band refuses the real gbt (AUC {out["gbt"]:.3f})')


def count_line(text, which=0):
    """(tp, fp, fn) of the nth '(a) words' line of the doc read in an h2_report.py output."""
    hits = re.findall(r'\[h2, read doc\]\s*\n\s*\(a\) words .*\(tp (\d+) fp (\d+) fn (\d+)\)', text)
    return tuple(int(x) for x in hits[which])


def h2_report_counts(records, scratch):
    labels = os.path.join(scratch, 'labels'); os.makedirs(labels, exist_ok=True)
    src = open(os.path.join(KL, 'labels-h3', 'h3.jsonl')).read().replace('"id":"h3"', '"id":"h2"').replace('"set":"h3"', '"set":"h2"')
    open(os.path.join(labels, 'h2.jsonl'), 'w').write(src)
    r = subprocess.run([sys.executable, '-B', '-I', os.path.join(KL, 'h2_report.py'), labels, records], capture_output=True, text=True)
    if r.returncode: raise SystemExit(r.stderr[-400:])
    return count_line(r.stdout)


def c5():
    rec = f'{data.SCRATCH}/records/gbt.both.P98.h3.jsonl'
    other = f'{data.SCRATCH}/records/gbt.block.P98.h3.jsonl'
    if not os.path.exists(rec): print('SKIP  C5: no records yet'); return
    import dataset
    h3 = dataset.load(['h3'])['h3']['blocks']
    recs = {json.loads(l)['id']: json.loads(l) for l in open(rec)}
    mine = score.summary(score.accumulate(h3, lambda b: recs[b['id']], 'doc'))
    with tempfile.TemporaryDirectory() as tmp:
        theirs = h2_report_counts(rec, tmp)
        wrong = h2_report_counts(other, tmp)
    line(theirs == (mine['w_tp'], mine['w_fp'], mine['w_fn']), 'C5 one scorer', f'h2_report.py (unchanged) tp/fp/fn {theirs} = score.py {(mine["w_tp"], mine["w_fp"], mine["w_fn"])} on gbt both@P98, H3 doc (headings of that tool read "H2")')
    first(wrong != theirs, 'C5', f'the block-only records of the same judge give {wrong}, not {theirs}')


if __name__ == '__main__':
    todo = sys.argv[1:] or ['C1', 'C2', 'C3', 'C4', 'C5']
    for c in todo: {'C1': c1, 'C2': c2, 'C3': c3, 'C4': c4, 'C5': c5}[c]()
    print('ALL PASS' if not FAILS else 'FAILED: ' + ', '.join(FAILS))
    sys.exit(1 if FAILS else 0)
