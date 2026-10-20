#!/usr/bin/env python3
"""Trains one learned judge on H2 + the code cases + the two CC BY papers by grouped cross-validation, and predicts H3 once (H3 is test only).

usage: train.py <judge key> ...        keys: gbt ngram potion potion+layout e5 e5+layout eg2 eg2+layout eg2-256 eg2-128   (judges.py)
writes MB_SCRATCH/cache/pred-<key>.pkl:  {task: {'oof': {set: p per row}, 'test': {'h3': p per row}, 'C': chosen setting, 'cv': {setting: logloss}}}  for task in block, word.

Split (binding): the pool is h2 + code + p2401 + p2310; H3 never enters a fit, a feature choice, a hyper-parameter choice or a threshold. Folds = GroupKFold(6) over the pool,
the group being the SCENE for H2, the CASE for the code cases and the PAPER for the papers (addendum A1.5); the out-of-fold predictions of every pool row are what the
cross-validation numbers and the thresholds (thresholds.py) are made from. The hyper-parameter (C, or the tree grid) is the setting with the lowest out-of-fold log loss.
The layout columns are standardised by statistics of the pool rows only (no labels)."""
import os, pickle, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np
import scipy.sparse as sp
import data, dataset, judges

POOL = ('h2', 'code', 'p2401', 'p2310')
FOLDS = 6
TRIES = {'dense': [0.0003, 0.001, 0.003, 0.01, 0.03], 'sparse': [0.3, 3.0, 30.0, 300.0], 'gbt': [dict(n=150, leaves=7), dict(n=400, leaves=15), dict(n=400, leaves=31)]}


def assert_no_h3(pool):
    """H3 is test only (binding split): it never enters a fit, a hyper-parameter choice or a threshold."""
    if 'h3' in pool: raise ValueError('h3 is in the fit pool')


def group_of(set_name, b):
    return f'h2:{b["scene"]}' if set_name == 'h2' else f'code:{b["paper"]}' if set_name == 'code' else set_name


def stack(parts):
    if sp.issparse(parts[0]): return sp.vstack(parts, format='csr')
    return np.vstack(parts)


def pool_arrays(J, ds, task):
    """-> X (all pool rows), y (1 / 0 / -1), group (str per row), set (str per row), offsets per set."""
    Xs, ys, gs, ss, off = [], [], [], [], {}
    n = 0
    for s in POOL:
        d = ds[s]
        if task == 'block':
            X = J.block_X(d); y = np.where(d['y3'] == 0, 1, np.where(d['y3'] > 0, 0, -1)).astype(np.int8)
            g = [group_of(s, b) for b in d['blocks']]
        else:
            X = J.word_X(d); y = d['tok']['y']
            g = [group_of(s, d['blocks'][i]) for i in d['tok']['bi']]
        Xs.append(X); ys.append(y); gs += g; ss += [s] * len(y); off[s] = (n, n + len(y)); n += len(y)
    return stack(Xs), np.concatenate(ys), np.array(gs), np.array(ss), off


def make_clf(J, task, setting):
    if J.kind == 'trees':
        import lightgbm as lgb
        return lgb.LGBMClassifier(objective='binary', n_estimators=setting['n'], num_leaves=setting['leaves'], learning_rate=0.05, min_child_samples=10, subsample=0.8, subsample_freq=1,
                                  colsample_bytree=0.8, reg_lambda=1.0, n_jobs=4, random_state=7, deterministic=True, force_row_wise=True, verbose=-1)
    from sklearn.linear_model import LogisticRegression
    if J.kind == 'sparse':
        return LogisticRegression(C=setting, solver='liblinear', max_iter=200)
    return LogisticRegression(C=setting, solver='lbfgs', max_iter=300)


def scaler_for(J, task, X_pool, y):
    """Dense judges: standardise every column with the pool's statistics (median-imputing the layout columns first); returns f(X) -> float32."""
    if J.kind != 'dense': return lambda X: X
    d_emb = J.n_emb_cols(task)
    prep = None
    if J.layout:
        prep = judges.Prep().fit(X_pool[:, d_emb:])
    mu = X_pool[:, :d_emb].mean(axis=0); sd = X_pool[:, :d_emb].std(axis=0); sd = np.where(sd < 1e-6, 1.0, sd)
    def f(X):
        parts = [(X[:, :d_emb] - mu) / sd]
        if prep is not None: parts.append(prep.transform(X[:, d_emb:]))
        return np.hstack(parts).astype(np.float32)
    return f


def logloss(y, p):
    p = np.clip(p, 1e-6, 1 - 1e-6)
    return float(-np.mean(y * np.log(p) + (1 - y) * np.log(1 - p)))


def fit_predict(J, task, setting, f, Xtr, ytr, Xte_list):
    if J.key.endswith('shuffled'):                                  # the negative control: the same pipeline on labels with no relation to the rows
        ytr = np.random.RandomState(11).permutation(ytr)
    clf = make_clf(J, task, setting)
    clf.fit(f(Xtr), ytr)
    return [clf.predict_proba(f(X))[:, 1] for X in Xte_list]


def run(key):
    t0 = time.time()
    assert_no_h3(POOL)
    J = judges.Judge(key)
    ds = dataset.load()
    out = {}
    for task in ('block', 'word'):
        X, y, grp, sets, off = pool_arrays(J, ds, task)
        scored = y >= 0
        f = scaler_for(J, task, X[scored], y)
        from sklearn.model_selection import GroupKFold
        folds = list(GroupKFold(n_splits=FOLDS).split(np.zeros(len(y)), y, grp))
        grid = TRIES['gbt'] if J.kind == 'trees' else TRIES[J.kind]
        if key.endswith('shuffled'): grid = grid[1:2]                # the negative control needs one setting, not a search
        cv, oofs = {}, {}
        for gi, setting in enumerate(grid):
            oof = np.zeros(len(y), dtype=np.float32)
            for tr, te in folds:
                tr = tr[scored[tr]]
                oof[te] = fit_predict(J, task, setting, f, X[tr], y[tr], [X[te]])[0]
            cv[gi] = logloss(y[scored], oof[scored]); oofs[gi] = oof
            print(f'  [{key}] {task} setting {setting}: out-of-fold log loss {cv[gi]:.4f} ({time.time() - t0:.0f} s)', flush=True)
        best = min(cv, key=cv.get)
        # the final model on every scored pool row, applied to H3 once
        Xt = J.block_X(ds['h3']) if task == 'block' else J.word_X(ds['h3'])
        pt = fit_predict(J, task, grid[best], f, X[scored], y[scored], [Xt])[0]
        out[task] = dict(oof={s: oofs[best][a:b] for s, (a, b) in off.items()}, test={'h3': pt}, setting=grid[best], cv={str(grid[g]): v for g, v in cv.items()})
    out['seconds'] = time.time() - t0
    pickle.dump(out, open(f'{data.SCRATCH}/cache/pred-{key}.pkl', 'wb'))
    print(f'[{key}] done in {out["seconds"]:.0f} s; settings {out["block"]["setting"]} / {out["word"]["setting"]}', flush=True)


if __name__ == '__main__':
    for k in sys.argv[1:]: run(k)
