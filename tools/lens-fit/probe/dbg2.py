import sys; sys.path.insert(0, '/tmp/r117/fit117/probe')
from sim1 import *
from columns import overlap
import collections
W = 320; shown = collections.Counter(); why = collections.Counter()
for n in PAGES:
    bl = blocks(f'{D}/paper-d14/p{n}.out'); pc = columns(bl)
    for y in range(60, 800, 150):
        for x in range(0, 817 - W + 1, 20):
            lens = (x, y, W, 250); t = under(lens, pc)
            if t is None: continue
            cap = capture_rect(lens, False, PAGE)
            if classify(lens, cap, bl, t) != 'none': continue
            ec = columns(clip(bl, cap))
            cand = [(round(overlap(x, x + W, c), 2), round(c['left']), round(c['right']), c['lines']) for c in ec if c['bottom'] >= y and c['top'] <= y + 250]
            k = 'no column touches the band' if not cand else ('rival' if len(cand) > 1 else 'weak overlap')
            why[k] += 1
            if shown[k] < 4:
                shown[k] += 1; print(k, 'p%d' % n, lens, 'cap', cap, 'page-level', (round(t['left']), round(t['right'])), 'cand', cand)
print(why)
