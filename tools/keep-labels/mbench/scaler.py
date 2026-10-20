#!/usr/bin/env python3
"""The picklable scaler of a dense judge (train.scaler_for's twin): standardise the embedding columns, median-impute / flag / standardise the layout columns."""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import numpy as np
import judges


class Scaler:
    """Picklable twin of train.scaler_for: standardise the embedding columns, prep the layout columns."""
    def __init__(self, J, task, X):
        self.d_emb = J.n_emb_cols(task) if J.kind == 'dense' else None
        self.prep = None
        if self.d_emb is None: return
        if J.layout: self.prep = judges.Prep().fit(X[:, self.d_emb:])
        self.mu = X[:, :self.d_emb].mean(axis=0); self.sd = X[:, :self.d_emb].std(axis=0); self.sd = np.where(self.sd < 1e-6, 1.0, self.sd)

    def __call__(self, X):
        if self.d_emb is None: return X
        parts = [(X[:, :self.d_emb] - self.mu) / self.sd]
        if self.prep is not None: parts.append(self.prep.transform(X[:, self.d_emb:]))
        return np.hstack(parts).astype(np.float32)
