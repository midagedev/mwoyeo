"""fit117: width and edge error of the estimated body columns against the PDF's true ones (the 24 (page, column) cells eval1 found) and the 4 Preview cells (ink)."""
import sys; sys.path.insert(0, '/tmp/r117/fit117/probe')
from common import *
from columns import columns
import statistics as st
W, L, R = [], [], []
for n in range(1, 14):
    cols = columns(blocks(f'/tmp/r117/fit117/data/paper-d14/p{n}.out'))
    for tl, tr in COLS:
        m = min(cols, key=lambda c: abs(c['left'] - tl) + abs(c['right'] - tr), default=None)
        if m and abs(m['left'] - tl) <= 4 and abs(m['right'] - tr) <= 4:
            L.append(m['left'] - tl); R.append(m['right'] - tr); W.append((m['right'] - m['left']) - (tr - tl))
srt = lambda v: sorted(abs(x) for x in v)
q = lambda v, p: srt(v)[min(len(v) - 1, int(p * len(v)))]
print('paper, %d cells: width err mean %+.2f  median |.| %.2f  p90 |.| %.2f  max |.| %.2f ; share within 2 pt: %d%%, within 3 pt: %d%%' % (len(W), st.mean(W), q(W, .5), q(W, .9), max(map(abs, W)), 100 * sum(abs(w) <= 2 for w in W) / len(W), 100 * sum(abs(w) <= 3 for w in W) / len(W)))
print('       left err mean %+.2f max|.| %.2f ; right err mean %+.2f max|.| %.2f' % (st.mean(L), max(map(abs, L)), st.mean(R), max(map(abs, R))))
