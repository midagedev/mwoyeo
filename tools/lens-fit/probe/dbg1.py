import sys; sys.path.insert(0, '/tmp/r117/fit117/probe')
from sim1 import *
import collections
W = 320; why = collections.Counter(); shown = collections.Counter()
for n in PAGES:
    bl = blocks(f'{D}/paper-d14/p{n}.out')
    for y in range(60, 800, 150):
        for x in range(0, 817 - W + 1, 20):
            lens = (x, y, W, 250); t = under(lens, TRUE)
            if t is None: continue
            cap = capture_rect(lens, False, PAGE)
            cb = clip(bl, cap); ec = columns(cb); e = under(lens, ec)
            c = classify(lens, cap, bl, t)
            if c in ('none', 'wrong'):
                # what is in the lens band
                inband = [b for b in cb if b[3] >= y and b[1] <= y + 250]
                key = (c, 'no multi-line block in band' if not any(b[4] >= 2 for b in inband) else 'multi-line blocks in band')
                why[key] += 1
                if shown[key] < 3:
                    shown[key] += 1
                    print(key, 'p%d' % n, 'lens', lens, 'cap', cap, 'true', round(t['left']), round(t['right']), 'est', None if not e else (round(e['left']), round(e['right']), e['lines']),
                          'cols', [(round(c_['left']), round(c_['right']), c_['lines']) for c_ in ec])
print(why)
