"""fit117: lens-cut captures of bench pages. For each scenario, the lens (screen pt, page = 817 x 1057 pt = 1634 x 2114 px at 2 px/pt) and the
capture the app would hold at rest around it (Overscan.rect, Core/Sources/MwoyeoCore/Overscan.swift:36, display = the page), cropped to a PNG
for the paper bench's headless render. Writes <out>/<name>.png and scenarios.tsv (name page lens x y w h, capture x y w h in pt)."""
import sys
from PIL import Image
sys.path.insert(0, '/tmp/r117/fit117/probe')
from overscan import capture_rect
SRC = '/tmp/paper-quality/pages-own'
OUT = '/tmp/r117/fit117/cut-pages'
PAGE = (0, 0, 817, 1057)
# name, page, lens (x, y, w, h) in screen pt
SC = [
    ('p10A', 10, (100, 300, 300, 250)),    # inside the left column, 28 pt off its left edge
    ('p10B', 10, (170, 300, 200, 250)),    # narrow lens in the middle of the left column
    ('p10C', 10, (300, 300, 200, 250)),    # across the gutter, more of the left column
    ('p10D', 10, (150, 300, 500, 250)),    # across both columns
    ('p10E', 10, (200, 300, 150, 250)),    # a very narrow lens
    ('p10F', 10, (500, 300, 250, 250)),    # the right column, 80 pt off its left edge
    ('p3T', 3, (100, 330, 300, 160)),      # over a full-width table
    ('p3F', 3, (80, 90, 400, 120)),        # over the diagram at the top
    ('p5A', 5, (100, 300, 300, 250)),
    ('p9A', 9, (100, 300, 300, 250)),
]
import os
os.makedirs(OUT, exist_ok=True)
rows = []
for name, page, lens in SC:
    cap = capture_rect(lens, False, PAGE)
    im = Image.open(f'{SRC}/p{page}.png').crop(tuple(int(v * 2) for v in (cap[0], cap[1], cap[0] + cap[2], cap[1] + cap[3])))
    im.save(f'{OUT}/{name}.png')
    rows.append('\t'.join([name, str(page)] + [str(v) for v in lens] + [str(v) for v in cap]))
open(f'{OUT}/scenarios.tsv', 'w').write('\n'.join(rows) + '\n')
print('\n'.join(rows))
