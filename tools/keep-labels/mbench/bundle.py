#!/usr/bin/env python3
"""Size of what each judge would ship: the embedding model's weights (as the runtime holds them: float32, and the int8 dynamic-quantised state dict where measured), the
classifier (pickle of the fitted sklearn / LightGBM object; for LightGBM the text model too), per task. -> MB_SCRATCH/cache/bundle.json
usage: bundle.py [key ...]        (needs MB_SCRATCH/models/<key>.pkl from export.py)"""
import os, sys
for v in ('OMP_NUM_THREADS', 'VECLIB_MAXIMUM_THREADS', 'OPENBLAS_NUM_THREADS', 'MKL_NUM_THREADS'):
    os.environ[v] = '1'                                    # torch and LightGBM each bring a libomp: one thread each, or the process hangs on macOS
import io, json, pickle

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np
import data, embed, judges, scaler

MB = 1e6


def torch_size(emb, dtype_bytes=None):
    import torch
    buf = io.BytesIO()
    torch.save(emb.m.state_dict(), buf)
    return buf.tell() / MB


def emb_sizes(name):
    """-> {'params_M', 'fp32_MB', 'bf16_MB', 'int8_MB' (measured on the dynamic-quantised state dict when name has an int8 twin)}"""
    if name == 'potion':
        e = embed.Embedder('potion')
        n = int(np.prod(e.m.embedding.shape))
        return dict(params_M=n / MB, fp32_MB=n * 4 / MB, bf16_MB=n * 2 / MB, int8_MB=n / MB, note='static table (vocab x dim); model2vec can store it int8')
    out = {}
    e = embed.Embedder(name)
    n = sum(p.numel() for p in e.m.parameters())
    out.update(params_M=n / MB, fp32_MB=n * 4 / MB, bf16_MB=n * 2 / MB)
    q = embed.Embedder(name + '-int8')
    out['int8_MB'] = torch_size(q)                              # Linear weights int8, the token-embedding table stays float32 under dynamic quantisation
    out['note'] = 'int8 = torch dynamic quantisation of the Linear layers (embedding table float32)'
    return out


def clf_size(m):
    return len(pickle.dumps(m['clf'])) / MB + (len(pickle.dumps(m['scaler'])) / MB if m['scaler'] is not None else 0)


def main(keys):
    out = {}
    p = f'{data.SCRATCH}/cache/bundle.json'
    if os.path.exists(p): out = json.load(open(p))
    cache = {}
    for k in keys:
        mp = f'{data.SCRATCH}/models/{k}.pkl'
        if not os.path.exists(mp): print('skip', k); continue
        models = pickle.load(open(mp, 'rb'))
        J = judges.Judge(k)
        row = dict(block_clf_MB=clf_size(models['block']), word_clf_MB=clf_size(models['word']))
        if J.kind == 'trees':
            row['block_clf_MB'] = len(models['block']['clf'].booster_.model_to_string()) / MB
            row['word_clf_MB'] = len(models['word']['clf'].booster_.model_to_string()) / MB
            row['trees'] = [models[t]['clf'].booster_.num_trees() for t in ('block', 'word')]
        if J.emb:
            base = J.emb.replace('-int8', '')
            if base not in cache: cache[base] = emb_sizes(base)
            row['embedding'] = dict(cache[base], used='int8_MB' if J.emb.endswith('-int8') else 'fp32_MB')
        out[k] = row
        print(k, json.dumps(row))
    json.dump(out, open(p, 'w'), indent=1)


if __name__ == '__main__':
    main(sys.argv[1:] or ['gbt', 'gbt-nopix', 'ngram', 'potion', 'potion+layout', 'e5', 'e5+layout', 'e5-int8', 'eg2', 'eg2+layout', 'eg2-int8', 'eg2-256', 'eg2-128'])
