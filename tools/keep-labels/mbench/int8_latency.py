#!/usr/bin/env python3
"""Embedding latency of the fp32 model and its torch dynamic-int8 twin on the same H3 block texts, single thread, interleaved per text (EmbeddingGemma 2 text-only, e5-small).
Why a separate script: the int8 EG2 judge itself was not trained (its embeddings of the 12.6k strings ran at ~3 strings/s, about 25 times slower than fp32; stopped), so
bench_time.py has no model for it; the embedding forward pass is what int8 changes.
usage: int8_latency.py [n_texts=60]        prints one line per model: batch=1 median / p95 ms per text, batched (all texts, batch 32) ms per text"""
import os, sys
for v in ('OMP_NUM_THREADS', 'VECLIB_MAXIMUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
    os.environ[v] = '1'
import json, random, subprocess, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np
import data, embed


def pct(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))]


def main(n):
    blocks = [b for b in data.load_all(['h3'])['h3'] if b['read'] == 'doc' and not b['noletter']]
    random.Random(3).shuffle(blocks)
    texts = [b['text'] for b in blocks[:n]]
    import torch
    torch.set_num_threads(1)
    names = [('e5', 'e5-int8'), ('eg2', 'eg2-int8')]
    for fp, q in names:
        ms = {fp: embed.Embedder(fp, threads=1), q: embed.Embedder(q, threads=1)}
        for e in ms.values(): e.encode(texts[:2])                                  # warm
        one = {fp: [], q: []}
        for t in texts:
            for k, e in ms.items():
                a = time.perf_counter(); e.encode([t]); one[k].append((time.perf_counter() - a) * 1e3)
        batched = {}
        for k, e in ms.items():
            a = time.perf_counter(); e.encode(texts, batch_size=32); batched[k] = (time.perf_counter() - a) * 1e3 / len(texts)
        up = subprocess.run(['uptime'], capture_output=True, text=True).stdout.strip()
        for k in (fp, q):
            print(json.dumps(dict(model=k, texts=len(texts), batch1_median_ms=pct(one[k], .5), batch1_p95_ms=pct(one[k], .95), batched_ms_per_text=batched[k], uptime=up)))


if __name__ == '__main__':
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 60)
