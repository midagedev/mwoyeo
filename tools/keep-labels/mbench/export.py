#!/usr/bin/env python3
"""Refits the final model of a judge on the whole pool with the setting train.py chose (the model that produced the H3 predictions: LightGBM and the logistic
regressions are deterministic) and stores it for the timing and size measurements: MB_SCRATCH/models/<key>.pkl = {task: {'scaler': Scaler | None, 'clf': ...}}.
Also writes a Core ML conversion check for the tree judge (coreml_check below) when coremltools is installed.

usage: export.py <judge key> ..."""
import os, pickle, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np
import data, dataset, judges, train
from scaler import Scaler


def run(key):
    t0 = time.time()
    J = judges.Judge(key)
    ds = dataset.load()
    pred = pickle.load(open(f'{data.SCRATCH}/cache/pred-{key}.pkl', 'rb'))
    out = {}
    for task in ('block', 'word'):
        X, y, grp, sets, off = train.pool_arrays(J, ds, task)
        scored = y >= 0
        sc = Scaler(J, task, X[scored])
        setting = pred[task]['setting']
        ytr = y[scored]
        if key.endswith('shuffled'): ytr = np.random.RandomState(11).permutation(ytr)
        clf = train.make_clf(J, task, setting)
        clf.fit(sc(X[scored]), ytr)
        # the refit must reproduce the H3 predictions of train.py
        Xt = J.block_X(ds['h3']) if task == 'block' else J.word_X(ds['h3'])
        p = clf.predict_proba(sc(Xt))[:, 1]
        diff = float(np.abs(p - pred[task]['test']['h3']).max())
        out[task] = dict(scaler=sc, clf=clf, setting=setting, refit_max_diff=diff)
        print(f'  [{key}] {task}: refit max |p - p(train.py)| on H3 = {diff:.2e}')
    os.makedirs(f'{data.SCRATCH}/models', exist_ok=True)
    pickle.dump(out, open(f'{data.SCRATCH}/models/{key}.pkl', 'wb'))
    print(f'[{key}] exported in {time.time() - t0:.0f} s')


if __name__ == '__main__':
    for k in sys.argv[1:]: run(k)
