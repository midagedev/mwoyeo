#!/usr/bin/env python3
"""Can the layout tree judge ship as a Core ML model? The block judge's features (111) and an XGBoost classifier of the same size as the LightGBM one (coremltools converts XGBoost,
scikit-learn trees and Core ML pipelines, not LightGBM); converts it, runs it on the H3 blocks through Core ML and compares with XGBoost's own probabilities.
usage: coreml_check.py        (needs coremltools + xgboost in the venv; writes MB_SCRATCH/models/block-xgb.mlmodel, never into the repo)"""
import os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np
import data, dataset, judges, train


def main():
    import xgboost as xgb, coremltools as ct
    print('xgboost', xgb.__version__, 'coremltools', ct.__version__)
    ds = dataset.load()
    J = judges.Judge('gbt')
    X, y, grp, sets, off = train.pool_arrays(J, ds, 'block')
    m = y >= 0
    clf = xgb.XGBClassifier(n_estimators=400, max_depth=5, learning_rate=0.05, subsample=0.8, colsample_bytree=0.8, random_state=7, n_jobs=4, tree_method='hist')
    clf.fit(X[m], y[m])
    Xt = ds['h3']['Xb']
    p_x = clf.predict_proba(Xt)[:, 1]
    names = [f'f{i}' for i in range(X.shape[1])]
    booster = clf.get_booster(); booster.feature_names = names
    t = time.time()
    ml = ct.converters.xgboost.convert(booster, feature_names=names, mode='classifier', class_labels=[0, 1], n_classes=2)
    out = f'{data.SCRATCH}/models/block-xgb.mlmodel'
    os.makedirs(os.path.dirname(out), exist_ok=True)
    ml.save(out)
    size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(out) for f in fs) if os.path.isdir(out) else os.path.getsize(out)
    print(f'converted in {time.time() - t:.1f} s; {out}: {size / 1e6:.2f} MB')
    ml2 = ct.models.MLModel(out)
    n = len(Xt)
    sel = np.linspace(0, n - 1, 400).astype(int)
    p_c = []
    t = time.time()
    for i in sel:
        r = ml2.predict({nm: float(v) if v == v else float('nan') for nm, v in zip(names, Xt[i])})
        pr = r.get('classProbability') or r
        p_c.append(float(pr[1]) if 1 in pr else float(pr.get('1', np.nan)))
    dt = (time.time() - t) / len(sel) * 1e3
    p_c = np.array(p_c)
    d = np.abs(p_c - p_x[sel])
    print(f'Core ML vs XGBoost on {len(sel)} H3 blocks: max |dp| {np.nanmax(d):.2e}, mean {np.nanmean(d):.2e}, decisions equal at 0.5: {int(((p_c >= 0.5) == (p_x[sel] >= 0.5)).sum())}/{len(sel)}; Core ML predict {dt:.2f} ms/block (python call, one block)')


if __name__ == '__main__':
    main()
