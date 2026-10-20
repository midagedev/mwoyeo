#!/usr/bin/env python3
"""The learned judges: how each turns a dataset (dataset.py) into feature matrices and which classifier it trains.

Two tasks, one classifier each, trained on the same labels the scorer uses (either / none words and no-letter blocks dropped, `unc` words kept with their class):
  block   one row per block: y = 1 when the whole block is keep (the labels hold keep words and no translate word), else 0 (translate and mixed blocks alike)
  word    one row per OCR word of every block with a letter: y = 1 keep, 0 translate (the inline task's universe: every scored word, for every judge)

judge key          block features                         word features                                            classifier
  gbt              layout (111)                           word layout (60) + its block's layout                    LightGBM
  ngram            hashed char 1-4-grams of the text      hashed char 1-5-grams of the word + 1-3-grams of both    logistic regression (sparse)
                                                          neighbours
  potion|e5|eg2    embedding of the block text            [emb(word), emb(prev), emb(next), emb(block)]            logistic regression (dense)
  <emb>+layout     embedding + standardised layout        + standardised word and block layout                     logistic regression (dense)
  eg2-256|eg2-128  eg2 cut to 256 / 128 dims (Matryoshka, re-normalised)"""
import os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np
import scipy.sparse as sp
import embed

DIMS = {'potion': 256, 'e5': 384, 'eg2': 768, 'e5-int8': 384, 'eg2-int8': 768}


class Prep:
    """Median-impute, add an is-missing flag for columns that are often missing, standardise and clip: the layout block fed to a logistic regression."""
    def fit(self, X):
        self.med = np.nanmedian(X, axis=0); self.med = np.where(np.isnan(self.med), 0.0, self.med)
        self.flag = np.where(np.isnan(X).mean(axis=0) > 0.05)[0]
        Z = self._fill(X)
        self.mu = Z.mean(axis=0); self.sd = Z.std(axis=0); self.sd = np.where(self.sd < 1e-6, 1.0, self.sd)
        return self

    def _fill(self, X):
        Z = np.where(np.isnan(X), self.med, X)
        return Z

    def transform(self, X):
        Z = (self._fill(X) - self.mu) / self.sd
        F = np.isnan(X[:, self.flag]).astype(np.float32)
        return np.clip(np.hstack([Z, F]), -6, 6).astype(np.float32)


def cut(E, d):
    """Matryoshka: keep the leading d dimensions and re-normalise."""
    E = E[:, :d]
    n = np.linalg.norm(E, axis=1, keepdims=True)
    return E / np.where(n == 0, 1, n)


class Judge:
    key = ''
    kind = 'dense'          # dense | sparse | trees
    emb = None              # embedder name
    dim = None              # Matryoshka cut
    layout = False

    def __init__(self, key):
        self.key = key
        base = key.split('+')[0]
        self.layout = key.endswith('+layout')
        if base in ('potion', 'e5', 'eg2', 'e5-int8', 'eg2-int8'): self.emb = base
        elif base in ('eg2-256', 'eg2-128'): self.emb, self.dim = 'eg2', int(base.split('-')[1])
        self.kind = 'trees' if key.startswith('gbt') else 'sparse' if key == 'ngram' else 'dense'

    # ------------------------------------------------------------------------------------------------------ features of one dataset
    def _E(self, strings):
        E = embed.lookup(self.emb, strings)
        return cut(E, self.dim) if self.dim else E

    def block_X(self, ds):
        if self.kind == 'trees':
            if self.key == 'gbt-nopix':
                from features import BLOCK_NAMES
                return ds['Xb'][:, cols_without(BLOCK_NAMES, PIX_BLOCK)]
            return ds['Xb']
        texts = [b['text'] for b in ds['blocks']]
        if self.kind == 'sparse':
            return ngram_vec(texts, (1, 4))
        E = self._E(texts)
        return np.hstack([E, ds['Xb']]) if self.layout else E            # the layout part is standardised by the caller (Prep over the layout columns)

    def word_X(self, ds):
        t = ds['tok']
        bi = t['bi']
        if self.kind == 'trees':
            if self.key == 'gbt-nopix':
                from features import BLOCK_NAMES, WORD_NAMES
                return np.hstack([t['X'][:, cols_without(WORD_NAMES, PIX_WORD)], ds['Xb'][bi][:, cols_without(BLOCK_NAMES, PIX_BLOCK)]])
            return np.hstack([t['X'], ds['Xb'][bi]])
        if self.kind == 'sparse':
            return sp.hstack([ngram_vec(['<' + s + '>' for s in t['text']], (1, 5)),
                              0.5 * ngram_vec(['<' + s + '>' for s in t['prev']], (1, 3)),
                              0.5 * ngram_vec(['<' + s + '>' for s in t['next']], (1, 3))], format='csr')
        uniq = sorted(set(t['text']) | set(t['prev']) | set(t['next']))
        E = self._E(uniq)
        ix = {s: i for i, s in enumerate(uniq)}
        zero = np.zeros(E.shape[1], dtype=np.float32)
        get = lambda s: E[ix[s]] if s else zero
        et = E[[ix[s] for s in t['text']]]
        ep = np.stack([get(s) for s in t['prev']]); en = np.stack([get(s) for s in t['next']])
        eb = self._E([b['text'] for b in ds['blocks']])[bi]
        parts = [et, ep, en, eb]
        if self.layout: parts += [t['X'], ds['Xb'][bi]]
        return np.hstack(parts)

    def n_layout_cols(self, task):
        from features import BLOCK_NAMES, WORD_NAMES
        return len(BLOCK_NAMES) if task == 'block' else len(WORD_NAMES) + len(BLOCK_NAMES)

    def n_emb_cols(self, task):
        d = self.dim or DIMS[self.emb]
        return d if task == 'block' else 4 * d


def ngram_vec(texts, rng):
    from sklearn.feature_extraction.text import HashingVectorizer
    hv = HashingVectorizer(analyzer='char', ngram_range=rng, n_features=2 ** 19, alternate_sign=False, norm='l2', lowercase=False, dtype=np.float32)
    return hv.transform(texts)


# pixel-derived features: the block's tint against the frame, and the background behind each word (inline-code chips). `gbt-nopix` leaves them out: OCR text and word boxes only.
PIX_BLOCK = ['c_dist', 'c_lum', 'c_flum', 'c_dlum', 'prev_c_dist', 'next_c_dist', 'prev_same_bg', 'next_same_bg', 'win2_same_bg']
PIX_WORD = ['tk_bg_dist', 'tk_chip', 'tk_prev_chip', 'tk_next_chip', 'b_chips']


def cols_without(names, drop):
    return [i for i, n in enumerate(names) if n not in drop]


JUDGES = ['gbt', 'gbt-nopix', 'gbt-shuffled', 'ngram', 'potion', 'potion+layout', 'e5', 'e5+layout', 'eg2', 'eg2+layout', 'eg2-256', 'eg2-128', 'e5-int8', 'eg2-int8']
