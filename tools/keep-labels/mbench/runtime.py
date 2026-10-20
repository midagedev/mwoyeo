#!/usr/bin/env python3
"""The judges as they would run on a live block: raw inputs in (the OCR block with its word boxes, the picture's pixels, the neighbouring blocks of the read), a
keep probability out. Every call includes its feature extraction, the tint read off the pixels (the block background and the frame colour, as regionfeed computes them)
and the background behind each word (inline-code chips); nothing is precomputed from labels or from the regionfeed output. Used by bench_time.py.

A Python timing is an upper bound for a Swift port (the tint and chip reads are numpy here; Swift reads the same pixels in the region pipeline anyway)."""
import os, pickle, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np
import data, features as F, judges, embed, scaler


def pixel_mode(pix, x, y, w, h):
    """Most common colour of a box of the picture (5 bits a channel), the way data.word_backgrounds reads a word's background."""
    return data.word_backgrounds(pix, [[0, 0, x, y, w, h, '']])[0]


def frame_colour(pix):
    """The picture's dominant colour (every third pixel), regionfeed's frameBackground."""
    q = pix[::3, ::3].reshape(-1, 3) >> 3
    code = (q[:, 0].astype(np.int32) << 10) | (q[:, 1].astype(np.int32) << 5) | q[:, 2].astype(np.int32)
    k = int(np.bincount(code).argmax())
    return [((k >> 10) << 3) | 4, (((k >> 5) & 31) << 3) | 4, ((k & 31) << 3) | 4]


def block_tint(b, pix):
    """The block background: the per-channel median over its lines of the colour behind each line."""
    lines = F.group_lines(b['ocr']['w'])
    boxes = [[0, 0, min(w[2] for w in ln), min(w[3] for w in ln), max(w[2] + w[4] for w in ln) - min(w[2] for w in ln), max(w[3] + w[5] for w in ln) - min(w[3] for w in ln), ''] for ln in lines]
    bgs = data.word_backgrounds(pix, boxes) if boxes else np.zeros((1, 3), dtype=np.float32)
    return [float(v) for v in np.median(bgs, axis=0)]


class Runtime:
    def __init__(self, key):
        self.key = key
        self.J = judges.Judge(key)
        t = time.perf_counter()
        self.models = pickle.load(open(f'{data.SCRATCH}/models/{key}.pkl', 'rb')) if os.path.exists(f'{data.SCRATCH}/models/{key}.pkl') else None
        if self.models and self.J.kind == 'trees':
            for m in self.models.values(): m['clf'].set_params(n_jobs=1)
        self.emb = embed.Embedder(self.J.emb, threads=1) if self.J.emb else None
        self.load_s = time.perf_counter() - t

    # ------------------------------------------------------------------------------------------------------------- raw context of a picture's read
    def context(self, grp, pix):
        """What the live lens knows when a block of the read arrives: the picture, the frame colour and the blocks seen so far (their features are made when they arrive)."""
        return dict(grp=grp, pix=pix, frame=None, margin=F.margin_of(grp), own={})

    def _prepare(self, ctx, k):
        """Own features of block k (tint read from the pixels, the word backgrounds), cached in ctx['own']."""
        if k in ctx['own']: return ctx['own'][k]
        b = dict(ctx['grp'][k])
        pix = ctx['pix']
        if ctx['frame'] is None: ctx['frame'] = frame_colour(pix)
        b['feed'] = {'bg': block_tint(b, pix), 'frame': ctx['frame']}
        b['wbg'] = data.word_backgrounds(pix, b['ocr']['w']) if self.J.key.startswith('gbt') or self.J.layout else None
        o = F.own_features(b, ctx['margin'])
        ctx['own'][k] = (b, o)
        return ctx['own'][k]

    def _row(self, ctx, k):
        """The block feature row of block k: needs the own features of k-2..k+2 (the neighbours' were made when they arrived; the following two are made now)."""
        grp = ctx['grp']
        lo, hi = max(0, k - 2), min(len(grp), k + 3)
        pairs = {j: self._prepare(ctx, j) for j in range(lo, hi)}
        sub = [pairs[j][0] for j in range(lo, hi)]
        own = [pairs[j][1] for j in range(lo, hi)]
        row = np.full(len(F.BLOCK_NAMES), np.nan, dtype=np.float32)
        F.assemble_row(row, sub, own, k - lo)
        return row

    # -------------------------------------------------------------------------------------------------------------------------- block task
    def _emb(self, strings):
        E = self.emb.encode(list(strings))
        return judges.cut(E, self.J.dim) if self.J.dim else E

    def block_prob(self, ctx, ks):
        """Keep probabilities for blocks `ks` of the read (one block = batch=1; a page = all)."""
        J, m = self.J, self.models['block']
        grp = ctx['grp']
        if J.kind == 'sparse':
            X = judges.ngram_vec([grp[k]['text'] for k in ks], (1, 4))
        elif J.kind == 'trees':
            X = np.vstack([self._row(ctx, k) for k in ks])
            if J.key == 'gbt-nopix': X = X[:, judges.cols_without(F.BLOCK_NAMES, judges.PIX_BLOCK)]
        else:
            E = self._emb([grp[k]['text'] for k in ks])
            X = np.hstack([E, np.vstack([self._row(ctx, k) for k in ks])]) if J.layout else E
        return m['clf'].predict_proba(m['scaler'](X))[:, 1]

    # --------------------------------------------------------------------------------------------------------------------------- word task
    def word_prob(self, ctx, ks):
        """-> list of arrays, the keep probability of every word of blocks `ks` (all of them classified in one call; one block = batch=1, a page = all blocks)."""
        import scipy.sparse as sp
        J, m = self.J, self.models['word']
        grp = ctx['grp']
        uses_layout = J.kind == 'trees' or J.layout
        items = []
        for k in ks:
            if uses_layout:
                b, o = self._prepare(ctx, k)
                if b['wbg'] is None: b['wbg'] = data.word_backgrounds(ctx['pix'], b['ocr']['w'])
                items.append((b, F.word_matrix(b, o), self._row(ctx, k)))
            else:
                items.append((grp[k], None, None))
        if J.kind == 'dense':
            strings = sorted({w[6] for b, _, _ in items for w in b['ocr']['w']} | {b['text'] for b, _, _ in items})
            E = self._emb(strings)
            ix = {s_: i for i, s_ in enumerate(strings)}
            zero = np.zeros((1, E.shape[1]), dtype=np.float32)
        parts = []
        for b, W, row in items:
            ws = b['ocr']['w']
            txt = [w[6] for w in ws]
            if J.kind == 'trees':
                if J.key == 'gbt-nopix':
                    X = np.hstack([W[:, judges.cols_without(F.WORD_NAMES, judges.PIX_WORD)], np.repeat(row[None, judges.cols_without(F.BLOCK_NAMES, judges.PIX_BLOCK)], len(ws), 0)])
                else:
                    X = np.hstack([W, np.repeat(row[None, :], len(ws), 0)])
            elif J.kind == 'sparse':
                prv = [''] + txt[:-1]; nxt = txt[1:] + ['']
                X = sp.hstack([judges.ngram_vec(['<' + s_ + '>' for s_ in txt], (1, 5)), 0.5 * judges.ngram_vec(['<' + s_ + '>' for s_ in prv], (1, 3)),
                               0.5 * judges.ngram_vec(['<' + s_ + '>' for s_ in nxt], (1, 3))], format='csr')
            else:
                et = E[[ix[s_] for s_ in txt]]
                ep = np.vstack([zero] + [E[ix[s_]][None] for s_ in txt[:-1]])
                en = np.vstack([E[ix[s_]][None] for s_ in txt[1:]] + [zero])
                eb = np.repeat(E[ix[b['text']]][None], len(txt), 0)
                X = np.hstack([et, ep, en, eb] + ([W, np.repeat(row[None, :], len(ws), 0)] if J.layout else []))
            parts.append(X)
        big = sp.vstack(parts, format='csr') if J.kind == 'sparse' else np.vstack(parts)
        p = m['clf'].predict_proba(m['scaler'](big))[:, 1]
        out, a = [], 0
        for X in parts:
            out.append(p[a:a + X.shape[0]]); a += X.shape[0]
        return out
