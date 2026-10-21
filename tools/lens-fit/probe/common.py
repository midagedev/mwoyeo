"""fit117 probes: shared parsing. Units: bench px -> screen pt is /2 (the bench renders at --scale 2); PDF pt -> screen pt is x 2.67/2."""
import re
S = 2.67 / 2          # PDF pt -> screen pt (page image 2.67 px per PDF pt, 2 px per screen pt)
BLK = re.compile(r'^block: core=(-?\d+),(-?\d+),(-?\d+),(-?\d+) text=(-?\d+),(-?\d+),(-?\d+),(-?\d+) size=([\d.]+) lines=(\d+) chars=(\d+)')
def blocks(path, px_per_pt=2.0):
    """[(x0,y0,x1,y1,lines,chars)] in screen pt of one render's block: lines"""
    out = []
    for l in open(path, errors='replace'):
        m = BLK.match(l)
        if m:
            x, y, w, h = (int(m[i]) / px_per_pt for i in range(1, 5))
            out.append((x, y, x + w, y + h, int(m[10]), int(m[11])))
    return out
def pdf_lines(layout_html):
    """per page: [(x0,y0,x1,y1)] of pdftotext -bbox-layout lines, in screen pt"""
    t = open(layout_html).read()
    pages = []
    for p in re.split(r'<page ', t)[1:]:
        pages.append([tuple(float(v) * S for v in m) for m in re.findall(r'<line xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)"', p)])
    return pages
# the paper's true text columns (PDF pt 54..297 and 315..558, read from the PDF's justified lines), in screen pt
COLS = [(54 * S, 297 * S), (315 * S, 558 * S)]

def pdf_blocks(layout_html):
    """per page: [(x0,y0,x1,y1,lines)] of pdftotext -bbox-layout blocks, in screen pt (the oracle's input)"""
    t = open(layout_html).read()
    pages = []
    for p in re.split(r'<page ', t)[1:]:
        bl = []
        for b in re.split(r'<block ', p)[1:]:
            m = re.match(r'xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)"', b)
            n = len(re.findall(r'<line ', b))
            bl.append(tuple(float(v) * S for v in m.groups()) + (n,))
        pages.append(bl)
    return pages
