"""fit117 measurement 6: how sticky is a snap? The share of one axis of a drag within the snap reach (8 pt) of a target, so the share where the lens is held back or pulled.
x: the lens's left edge near a column's left edge, or its right edge near a column's right edge (lens width W). y: the lens's top near a paragraph's top or bottom
(a block of >= 2 lines), or its bottom likewise. Paper pages 2 4 6 7 8 10 11 12, the film3 Preview shot B, page-level columns/blocks."""
import sys; sys.path.insert(0, '/tmp/r117/fit117/probe')
from common import *
from columns import columns
R = 8
def covered(vals, targets, lo, hi):
    return sum(any(abs(v - t) <= R for t in targets) for v in vals) / len(vals)
print('x axis, columns as targets (reach %d pt):' % R)
for name, files, width in (('paper pages', [f'/tmp/r117/fit117/data/paper-d14/p{n}.out' for n in (2, 4, 6, 7, 8, 10, 11, 12)], 817), ('Preview shot B', ['/tmp/r117/fit117/data/pv-out/shotB.out'], 1512)):
    for W in (200, 320, 600):
        cs = []
        for f in files:
            cols = columns(blocks(f))
            lefts, rights = [c['left'] for c in cols], [c['right'] for c in cols]
            xs = [x / 2 for x in range(0, int((width - W) * 2))]
            cs.append(sum(any(abs(x - l) <= R for l in lefts) or any(abs(x + W - r) <= R for r in rights) for x in xs) / len(xs))
        print('   %-15s lens W=%3d: %4.1f%% of left-edge positions are held by a column target (mean over %d page(s), %d column(s) a page)' % (name, W, 100 * sum(cs) / len(cs), len(files), round(sum(len(columns(blocks(f))) for f in files) / len(files))))
print('y axis, paragraph edges as targets (a block of >= 2 lines):')
cs = []
for n in (2, 4, 6, 7, 8, 10, 11, 12):
    bl = [b for b in blocks(f'/tmp/r117/fit117/data/paper-d14/p{n}.out') if b[4] >= 2]
    ys = [y / 2 for y in range(0, 2114)]
    t = [b[1] for b in bl] + [b[3] for b in bl]
    cs.append(sum(any(abs(y - v) <= R for v in t) for y in ys) / len(ys))
print('   paper prose pages: %.1f%% of y positions held by a paragraph edge (mean; min %.1f max %.1f)' % (100 * sum(cs) / len(cs), 100 * min(cs), 100 * max(cs)))
