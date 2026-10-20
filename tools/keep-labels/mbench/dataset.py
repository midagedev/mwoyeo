#!/usr/bin/env python3
"""The arrays every judge trains and is scored on, built once from data.py + features.py and cached (MB_SCRATCH/cache/ds-<set>.pkl).

Per set: `blocks`, `Xb` (layout features of each block), `y3` (the block task's class: 0 keep, 1 translate, 2 mixed, -1 = not scored: no letter, or no keep / translate
word), and the word table `tok` (one row per OCR word of every block with a letter): block index, word index, text, previous / next word text, label (1 keep, 0 translate,
-1 not scored), layout features `X`, and `rt` = the block is one the rules OR CodeRegion translate (needs true) -> the inline task's population."""
import os, pickle, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np
import data, features as F, score
from truth import KEEP, TRANSLATE

CLS = {'keep': 0, 'translate': 1, 'mixed': 2}


def build(setname, blocks):
    Xb, own = F.block_matrix(blocks)
    y3 = np.full(len(blocks), -1, dtype=np.int8)
    for i, b in enumerate(blocks):
        if b['noletter']: continue
        c = score.truth_class(b)
        if c is not None: y3[i] = CLS[c]
    bi, wi, txt, prv, nxt, y, rt, rows = [], [], [], [], [], [], [], []
    for i, b in enumerate(blocks):
        if b['noletter']: continue
        W = F.word_matrix(b, own[i])
        rec = b.get('rules')
        translated = bool(rec) and score.rule_rec(b, True)['needs']
        ws = b['words']
        for k, w in enumerate(ws):
            bi.append(i); wi.append(k); txt.append(w[5])
            prv.append(ws[k - 1][5] if k > 0 else ''); nxt.append(ws[k + 1][5] if k + 1 < len(ws) else '')
            y.append(1 if w[2] == KEEP else 0 if w[2] == TRANSLATE else -1); rt.append(translated)
        rows.append(W)
    X = np.vstack(rows) if rows else np.zeros((0, len(F.WORD_NAMES)), dtype=np.float32)
    tok = dict(bi=np.array(bi, dtype=np.int32), wi=np.array(wi, dtype=np.int32), text=txt, prev=prv, next=nxt, y=np.array(y, dtype=np.int8), rt=np.array(rt, dtype=bool), X=X)
    return dict(set=setname, blocks=blocks, Xb=Xb, y3=y3, tok=tok, scene=[b['scene'] for b in blocks], lang=[b['lang'] for b in blocks], read=[b['read'] for b in blocks])


def load(sets=None, rebuild=False):
    out = {}
    for s in sets or (data.TRAIN_SETS + data.TEST_SETS):
        p = f'{data.SCRATCH}/cache/ds-{s}.pkl'
        if os.path.exists(p) and not rebuild:
            out[s] = pickle.load(open(p, 'rb')); continue
        out[s] = build(s, data.load_all([s])[s])
        pickle.dump(out[s], open(p, 'wb'))
    return out


if __name__ == '__main__':
    d = load(rebuild='--rebuild' in sys.argv)
    for s, v in d.items():
        t = v['tok']
        print(f'{s}: blocks {len(v["blocks"])} scored {int((v["y3"] >= 0).sum())} (keep {int((v["y3"] == 0).sum())} translate {int((v["y3"] == 1).sum())} mixed {int((v["y3"] == 2).sum())}); '
              f'words {len(t["y"])} scored {int((t["y"] >= 0).sum())} keep {int((t["y"] == 1).sum())}; inline population (rule-translate blocks) words {int(t["rt"].sum())} scored {int(((t["y"] >= 0) & t["rt"]).sum())} keep {int(((t["y"] == 1) & t["rt"]).sum())}')
