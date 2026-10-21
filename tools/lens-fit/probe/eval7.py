"""fit117: how much do the constants matter? body columns found (of 26 cells; 24 is the ceiling: p13 has none), spurious columns (those matching no true column or wide box), uc-bench scenes with a claimed column (of 52; 6 expected)."""
import sys, glob, os; sys.path.insert(0, '/tmp/r117/fit117/probe')
from common import *
from columns import columns
WIDE = (72.09, 744.93)
def run(**kw):
    found = spur = 0
    for n in range(1, 14):
        cols = columns(blocks(f'/tmp/r117/fit117/data/paper-d14/p{n}.out'), **kw)
        for tl, tr in COLS:
            m = min(cols, key=lambda c: abs(c['left'] - tl) + abs(c['right'] - tr), default=None)
            found += bool(m and abs(m['left'] - tl) <= 4 and abs(m['right'] - tr) <= 4)
        spur += sum(1 for c in cols if not any(abs(c['left'] - l) <= 4 and abs(c['right'] - r) <= 4 for l, r in COLS + [WIDE]))
    uc = sum(1 for f in glob.glob('/tmp/r117/fit117/data/uc-d14/*-auto.out') if columns(blocks(f), **kw))
    return found, spur, uc
print('%-34s %6s %9s %6s' % ('setting', 'found', 'spurious', 'uc>0'))
print('%-34s %6d %9d %6d' % ('default (tol 6, split 24, support 4)', *run()))
for k, vs in (('tol', (3, 10)), ('split', (16, 40)), ('min_support', (3, 6)), ('min_lines', (1, 3))):
    for v in vs: print('%-34s %6d %9d %6d' % ('%s=%s' % (k, v), *run(**{k: v})))
