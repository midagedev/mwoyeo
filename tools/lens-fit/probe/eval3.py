"""fit117 measurement 4: the two real Preview screens of film3 (3024 x 1964 px = 1512 x 982 pt). Blocks from the app's headless render (dd-d14main) -> columns,
against the ink of the screenshot (inkcols.py: left 148.5..149 / 737..737.5, right 777..778 / 1365), and the film3 take's lens (770,382,600,270) with its overscan."""
import sys; sys.path.insert(0, '/tmp/r117/fit117/probe')
from common import *
from columns import columns, under
from overscan import capture_rect
from sim1 import clip
D = '/tmp/r117/fit117/data/pv-out'
INK = {'shotA': [(149.0, 737.5), (778.0, 1365.0)], 'shotB': [(148.5, 737.0), (777.0, 1365.0)]}
DISPLAY = (0, 0, 1512, 982)
for s in ('shotA', 'shotB'):
    bl = blocks(f'{D}/{s}.out'); cols = columns(bl)
    print(s, 'blocks', len(bl), 'columns found', [(round(c['left'], 1), round(c['right'], 1), c['blocks'], c['lines']) for c in cols])
    for tl, tr in INK[s]:
        m = min(cols, key=lambda c: abs(c['left'] - tl) + abs(c['right'] - tr))
        print('   true %.1f..%.1f  est %.1f..%.1f  err L %+.1f R %+.1f  width err %+.1f' % (tl, tr, m['left'], m['right'], m['left'] - tl, m['right'] - tr, (m['right'] - m['left']) - (tr - tl)))
# the take: lens over the right column (film3 after-manifest: lens_region_pt 770,382,600,270)
lens = (770, 382, 600, 270)
for wide in (False, True):
    cap = capture_rect(lens, wide, DISPLAY)
    bl = clip(blocks(f'{D}/shotB.out'), cap)
    e = under(lens, columns(bl))
    print('take lens', lens, 'wide' if wide else 'rest', 'capture x %.0f..%.0f y %.0f..%.0f' % (cap[0], cap[0] + cap[2], cap[1], cap[1] + cap[3]), '-> column',
          None if not e else '%.1f..%.1f (true 777..1365): the lens would move %+.1f / %+.1f pt' % (e['left'], e['right'], e['left'] - lens[0], e['right'] - (lens[0] + lens[2])))
# the same lens width over the left column
lens = (140, 382, 600, 270)
cap = capture_rect(lens, False, DISPLAY); e = under(lens, columns(clip(blocks(f'{D}/shotB.out'), cap)))
print('lens over the left column', lens, '->', None if not e else '%.1f..%.1f' % (e['left'], e['right']))
