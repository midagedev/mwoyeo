"""fit117: the column estimator the design proposes (ColumnFit.columns), prototyped in Python on the benches' block rects.

Input: blocks (x0, y0, x1, y1, lines) in screen pt. Output: columns (left, right, top, bottom, blocks, lines).
 1. paragraph evidence: a block of >= MIN_LINES lines (a heading, a caption line, a table cell is one line and says nothing about the column).
 2. blocks whose left edges lie within TOL of each other are one stack (single link on sorted left edges).
 3. inside a stack the right edges are split where they jump by more than SPLIT (a full-width element sharing the left edge of a half-width column).
 4. a column = left: median of the lefts, right: max of the rights of its sub-stack; support = lines of its blocks >= MIN_SUPPORT.
"""
from statistics import median
TOL = 6.0
SPLIT = 24.0
MIN_LINES = 2
MIN_SUPPORT = 4          # total lines of a column's blocks

def columns(blocks, min_lines=MIN_LINES, tol=TOL, split=SPLIT, min_support=MIN_SUPPORT):
    p = sorted((b for b in blocks if b[4] >= min_lines), key=lambda b: b[0])
    stacks, cur = [], []
    for b in p:
        if cur and b[0] - cur[-1][0] > tol:
            stacks.append(cur); cur = []
        cur.append(b)
    if cur: stacks.append(cur)
    out = []
    for s in stacks:
        s = sorted(s, key=lambda b: b[2])
        subs, cur = [], []
        for b in s:
            if cur and b[2] - cur[-1][2] > split:
                subs.append(cur); cur = []
            cur.append(b)
        if cur: subs.append(cur)
        for sub in subs:
            lines = sum(b[4] for b in sub)
            if lines < min_support: continue
            out.append(dict(left=median(b[0] for b in sub), right=max(b[2] for b in sub), top=min(b[1] for b in sub),
                            bottom=max(b[3] for b in sub), blocks=len(sub), lines=lines))
    return sorted(out, key=lambda c: (c['left'], c['right']))

def overlap(lens_x0, lens_x1, c):
    """the share of the lens's width that lies in the column (the lens's, not the column's: a column cut by the capture is narrower than it is)"""
    return max(0.0, min(lens_x1, c['right']) - max(lens_x0, c['left'])) / (lens_x1 - lens_x0)

def under(lens, cols, need=0.4, rival=0.5):
    """the column under lens (x, y, w, h): the best share of the lens's width in it >= need, vertically touching the lens, and no other column above rival x best; else None"""
    x, y, w, h = lens
    cand = [(overlap(x, x + w, c), c) for c in cols if c['bottom'] >= y and c['top'] <= y + h]
    cand = sorted(((o, c) for o, c in cand if o > 0), key=lambda t: -t[0])
    if not cand or cand[0][0] < need: return None
    if len(cand) > 1 and cand[1][0] > rival * cand[0][0]: return None
    return cand[0][1]
