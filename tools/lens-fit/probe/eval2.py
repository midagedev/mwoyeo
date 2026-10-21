"""fit117 measurement 3: real lens-cut captures (cut-pages/*.png made by mkcrops.py, rendered by the app's own pipeline, build dd-d14main).
For each scenario: blocks of the cropped render (+ the capture origin) -> columns -> the column under the lens; against the page-level estimate and the PDF's true columns."""
import sys; sys.path.insert(0, '/tmp/r117/fit117/probe')
from common import *
from columns import columns, under
from sim1 import clip, PAGE
D = '/tmp/r117/fit117'
for line in open(f'{D}/cut-pages/scenarios.tsv'):
    f = line.split('\t'); name, page = f[0], int(f[1]); lens = tuple(float(v) for v in f[2:6]); cap = tuple(float(v) for v in f[6:10])
    try: bl = [(a + cap[0], b + cap[1], c + cap[0], d + cap[1], l, ch) for a, b, c, d, l, ch in blocks(f'{D}/cut-out/{name}.out')]
    except FileNotFoundError: print(name, 'not rendered'); continue
    page_cols = columns(blocks(f'{D}/data/paper-d14/p{page}.out'))
    ref = under(lens, page_cols)
    real = columns(bl); e = under(lens, real)
    sim = under(lens, columns(clip(blocks(f'{D}/data/paper-d14/p{page}.out'), cap)))
    fmt = lambda c: 'none' if c is None else '%.1f..%.1f (w %.1f, %d lines)' % (c['left'], c['right'], c['right'] - c['left'], c['lines'])
    unk = lambda c: '' if c is None else (' [left=capture edge]' if abs(c['left'] - cap[0]) <= 2.5 and cap[0] > 1 else '') + (' [right=capture edge]' if abs(c['right'] - (cap[0] + cap[2])) <= 2.5 and cap[0] + cap[2] < 816 else '')
    print('%-5s lens x %.0f..%.0f cap x %.0f..%.0f\n   page-level %s\n   real crop  %s%s\n   sim crop   %s%s' % (name, lens[0], lens[0] + lens[2], cap[0], cap[0] + cap[2], fmt(ref), fmt(e), unk(e), fmt(sim), unk(sim)))
