#!/usr/bin/env python3
"""Speed of every judge on the same H3 blocks, CPU only, single thread, one loop per repetition with all judges interleaved and `uptime` recorded for each.

usage: bench_time.py [--reps 3] [--pages 6] [--judges gbt,ngram,...] [--out FILE]        the interleaved timing -> MB_SCRATCH/cache/timing.json
       bench_time.py child <key>                                                         (internal) one judge in a fresh process: load time and RSS

What is timed (everything from the raw inputs: OCR block with its word boxes, the picture's pixels, the read's other blocks; PNG decode excluded, the app has the image):
  block, batch=1   one block of a read, in reading order, with the earlier blocks of the page already seen (the live lens): block features incl. the tint read from the
                   pixels + the embedding of its text + the classifier
  block, batched   all blocks of a page (one picture's doc read) in one call; ms per block = page time / blocks
  words, batch=1   all words of one block in one call; ms per word = block time / words
  words, batched   all words of a page in one call
  judge 1          TranslationFilter.needsTranslation + InlineMath.spans per block alone (batch=1, in process, rulestime), CodeRegion.keep per read (ms per block), and the
                   regionfeed run over the H3 pictures (ms per block; it includes the PNG decode and the OCR json parse, so it is an upper bound)
Python timings are an upper bound for a Swift port. No GPU / MPS / ANE; torch threads = 1."""
import os, sys
for v in ('OMP_NUM_THREADS', 'VECLIB_MAXIMUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
    os.environ[v] = '1'
import json, pickle, random, resource, subprocess, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np
from PIL import Image
import data, features as F


def uptime():
    return subprocess.run(['uptime'], capture_output=True, text=True).stdout.strip()


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] if v else float('nan')


def summ(v):
    return dict(n=len(v), median=pct(v, 0.5), p95=pct(v, 0.95), mean=float(np.mean(v)) if v else float('nan'))


def child(key):
    import torch
    torch.set_num_threads(1)
    t0 = time.perf_counter()
    import runtime
    rt = runtime.Runtime(key) if key != 'baseline' else None
    load_s = time.perf_counter() - t0
    if rt:
        blocks = data.load_all(['h3'])['h3']
        grp = [b for b in blocks if b['read'] == 'doc' and b['paper'] == blocks[0]['paper']]
        grp.sort(key=lambda b: int(b['id'].rsplit('-', 1)[1]))
        pix = np.asarray(Image.open(grp[0]['png']).convert('RGB'))
        ctx = rt.context(grp, pix)
        rt.block_prob(ctx, [min(2, len(grp) - 1)])
        rt.word_prob(ctx, [min(2, len(grp) - 1)])
    print(json.dumps(dict(key=key, load_s=load_s, rss_mb=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1e6)))


def pages(n_pages, seed=5):
    blocks = data.load_all(['h3'])['h3']
    g = F.picture_groups([b for b in blocks if b['read'] == 'doc'])
    keys = sorted(g)
    random.Random(seed).shuffle(keys)
    out = []
    for k in keys:
        grp = [b for b in g[k]]
        if 25 <= len(grp) <= 90 and any(not b['noletter'] for b in grp):
            out.append(grp)
        if len(out) == n_pages: break
    return out


def run(reps, n_pages, keys, out_path):
    import torch
    torch.set_num_threads(1)
    import runtime
    pg = pages(n_pages)
    pix = [np.asarray(Image.open(g[0]['png']).convert('RGB')) for g in pg]
    print(f'pages: {len(pg)} H3 doc reads, blocks {[len(g) for g in pg]}; reps {reps}; judges {keys}', flush=True)
    rts = {k: runtime.Runtime(k) for k in keys}
    res = {k: dict(block1=[], blockb=[], word1=[], wordb=[], word1_per_block=[], blockb_page=[], wordb_page=[], uptime=[]) for k in keys}
    rules = dict(filter=[], spans=[], region_per_block=[], regionfeed_ms_per_block=[], uptime=[], nblocks=0)
    labels = os.path.join(os.path.dirname(HERE), 'labels-h3', 'h3.jsonl')
    for rep in range(reps):
        for key in keys:
            rt = rts[key]
            res[key]['uptime'].append(uptime())
            # block, batch=1 and word, batch=1: the page in reading order, a fresh context per page
            for g, px in zip(pg, pix):
                ctx = rt.context(g, px)
                for k in range(len(g)):
                    if g[k]['noletter']:
                        rt._prepare(ctx, k) if (rt.J.kind == 'trees' or rt.J.layout) else None
                        continue
                    t = time.perf_counter(); rt.block_prob(ctx, [k]); res[key]['block1'].append((time.perf_counter() - t) * 1e3)
                ctx = rt.context(g, px)
                for k in range(len(g)):
                    if g[k]['noletter'] or not g[k]['words']:
                        rt._prepare(ctx, k) if (rt.J.kind == 'trees' or rt.J.layout) else None
                        continue
                    t = time.perf_counter(); rt.word_prob(ctx, [k]); dt = (time.perf_counter() - t) * 1e3
                    res[key]['word1'].append(dt / max(1, len(g[k]['words']))); res[key]['word1_per_block'].append(dt)
                # batched: a whole page in one call
                ks = [k for k in range(len(g)) if not g[k]['noletter']]
                ctx = rt.context(g, px)
                t = time.perf_counter(); rt.block_prob(ctx, ks); dt = (time.perf_counter() - t) * 1e3
                res[key]['blockb'].append(dt / len(ks)); res[key]['blockb_page'].append(dt)
                ks = [k for k in ks if g[k]['words']]
                nw = sum(len(g[k]['words']) for k in ks)
                ctx = rt.context(g, px)
                t = time.perf_counter(); rt.word_prob(ctx, ks); dt = (time.perf_counter() - t) * 1e3
                res[key]['wordb'].append(dt / nw); res[key]['wordb_page'].append(dt)
            print(f'  rep {rep + 1}/{reps} {key}: block1 median {pct(res[key]["block1"], .5):.2f} ms, word1 {pct(res[key]["word1"], .5):.3f} ms/word, page block {pct(res[key]["blockb"], .5):.2f} ms/block', flush=True)
        # judge 1 (Swift), once per repetition, in the same loop
        rules['uptime'].append(uptime())
        bd = os.environ.get('KEEP_BUILD', f'{data.SCRATCH}/build') + '/release'
        rtbin = f'{data.SCRATCH}/rt/rulestime'
        if os.path.exists(rtbin):
            o = json.loads(subprocess.run([rtbin, labels, f'{data.SCRATCH}/feed-h3.jsonl', '3'], capture_output=True, text=True).stdout)
            rules['nblocks'] = o['blocks']
            rules['filter'] += [a / 1e6 for a in o['filter_ns']]; rules['spans'] += [a / 1e6 for a in o['spans_ns']]
            rules['region_per_block'] += [a / n / 1e6 for a, n in zip(o['region_ns'], o['region_blocks'])]
        if os.path.exists(bd + '/regionfeed'):
            t = time.perf_counter()
            subprocess.run([bd + '/regionfeed', f'{data.SCRATCH}/work/h3root'], capture_output=True)
            rules['regionfeed_ms_per_block'].append((time.perf_counter() - t) * 1e3 / 5526)
        print(f'  rep {rep + 1}/{reps} rules: filter+spans median {pct([a + b for a, b in zip(rules["filter"], rules["spans"])], .5) * 1e3:.1f} us, region {pct(rules["region_per_block"], .5):.2f} ms/block, regionfeed {rules["regionfeed_ms_per_block"][-1:] } ms/block', flush=True)
    out = dict(reps=reps, pages=len(pg), blocks_per_page=[len(g) for g in pg], uptime_start=uptime(), judges={}, rules={})
    for k, v in res.items():
        out['judges'][k] = dict(block1=summ(v['block1']), blockb=summ(v['blockb']), word1=summ(v['word1']), word1_per_block=summ(v['word1_per_block']), wordb=summ(v['wordb']),
                                blockb_page=summ(v['blockb_page']), wordb_page=summ(v['wordb_page']), uptime=v['uptime'])
    both = [a + b for a, b in zip(rules['filter'], rules['spans'])]
    out['rules'] = dict(filter_spans_ms=summ(both), filter_ms=summ(rules['filter']), spans_ms=summ(rules['spans']), region_ms_per_block=summ(rules['region_per_block']),
                        regionfeed_ms_per_block=summ(rules['regionfeed_ms_per_block']), uptime=rules['uptime'], blocks=rules['nblocks'])
    out['uptime_end'] = uptime()
    # load time and RSS: a fresh process each, after the loop
    out['child'] = {}
    for k in ['baseline'] + keys:
        r = subprocess.run([sys.executable, '-B', '-I', os.path.abspath(__file__), 'child', k], capture_output=True, text=True)
        try: out['child'][k] = json.loads(r.stdout.strip().splitlines()[-1]); out['child'][k]['uptime'] = uptime()
        except Exception: out['child'][k] = dict(error=r.stderr[-300:])
        print('  child', k, out['child'][k], flush=True)
    json.dump(out, open(out_path, 'w'), indent=1)
    print('wrote', out_path)


if __name__ == '__main__':
    a = sys.argv[1:]
    if a and a[0] == 'child':
        child(a[1])
    else:
        opt = lambda n, d: a[a.index(n) + 1] if n in a else d
        run(int(opt('--reps', 3)), int(opt('--pages', 6)), opt('--judges', 'gbt,ngram,potion,potion+layout,e5,e5+layout,eg2,eg2+layout').split(','), opt('--out', f'{data.SCRATCH}/cache/timing.json'))
