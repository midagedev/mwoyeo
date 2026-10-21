"""fit117 measurement 2: a lens over a column of our paper, what the capture holds and what the estimator makes of it.
Per page (the 10 pages with prose in two columns), lens widths W and x positions every 20 pt, heights 250 and y positions every 150 pt:
  truth    = the true column under the lens (PDF columns 72..396.5 / 420.5..745, the same `under` rule)
  capture  = Overscan.rect(around: lens, wide: false|true, display: the page)
  blocks   = the page's OCR blocks cut to the capture (a block cut by the capture keeps its lines in proportion to its height; its x edge becomes the capture's)
  estimate = columns(blocks) -> under(lens); an edge within 2.5 pt of a capture edge that is not the page's edge is `unknown` (the capture, not the column, ends there)
Reports per W: lens positions with a true column; capture holds the whole column (%); estimate exact (both edges <= 3 pt), partly unknown, wrong, none."""
import sys; sys.path.insert(0, '/tmp/r117/fit117/probe')
from common import *
from columns import columns, under
from overscan import capture_rect
D = '/tmp/r117/fit117/data'
PAGE = (0, 0, 817, 1057)
TRUE = [dict(left=l, right=r, top=0, bottom=1057) for l, r in COLS]
PAGES = [2, 4, 6, 7, 8, 10, 11, 12]     # prose pages; p1 (title, abstract) and p3, p5, p9, p13 (tables, listings) are reported apart

def clip(blocks, cap):
    cx0, cy0, cx1, cy1 = cap[0], cap[1], cap[0] + cap[2], cap[1] + cap[3]
    out = []
    for x0, y0, x1, y1, ln, ch in blocks:
        a, b, c, d = max(x0, cx0), max(y0, cy0), min(x1, cx1), min(y1, cy1)
        if c - a < 8 or d - b < 4: continue
        h = y1 - y0
        out.append((a, b, c, d, max(1, round(ln * (d - b) / h)) if h > 0 else ln, ch))
    return out

def classify(lens, cap, blocks, truth):
    est_cols = columns(clip(blocks, cap))
    e = under(lens, est_cols)
    if e is None: return 'none'
    unk_l = abs(e['left'] - cap[0]) <= 2.5 and cap[0] > PAGE[0] + 1
    unk_r = abs(e['right'] - (cap[0] + cap[2])) <= 2.5 and cap[0] + cap[2] < PAGE[0] + PAGE[2] - 1
    okl, okr = abs(e['left'] - truth['left']) <= 3, abs(e['right'] - truth['right']) <= 3
    if (okl or unk_l) and (okr or unk_r):
        return 'exact' if okl and okr else 'partly-unknown'
    return 'wrong'

def run(wide, pages=None):
    res = {}
    pages = pages or PAGES
    for W in (160, 240, 320, 400, 560):
        cnt = dict(lenses=0, contained=0, exact=0, partial=0, wrong=0, none=0, amb=0)
        for n in pages:
            bl = blocks(f'{D}/paper-d14/p{n}.out')
            for H in (250,):
                for y in range(60, 800, 150):
                    for x in range(0, 817 - W + 1, 20):
                        lens = (x, y, W, H)
                        t = under(lens, columns(bl))
                        if t is None: cnt['amb'] += 1; continue
                        cap = capture_rect(lens, wide, PAGE)
                        cnt['lenses'] += 1
                        if cap[0] <= t['left'] + 1 and cap[0] + cap[2] >= t['right'] - 1: cnt['contained'] += 1
                        c = classify(lens, cap, bl, t)
                        cnt[{'exact': 'exact', 'partly-unknown': 'partial', 'wrong': 'wrong', 'none': 'none'}[c]] += 1
        res[W] = cnt
    return res

def main(pages=None, tag=''):
  for wide in (False, True):
      print('--- capture margins: %s' % ('wide (lens moving / content moving)' if wide else 'at rest'))
      print('%5s %7s %10s %7s %9s %6s %5s   (lens positions with an unambiguous true column; %% of them)' % ('W pt', 'lenses', 'col in cap', 'exact', 'part-unk', 'wrong', 'none'))
      for W, c in run(wide, pages).items():
          n = c['lenses']
          print('%5d %7d %9.0f%% %6.0f%% %8.0f%% %5.0f%% %4.0f%%   ambiguous lens positions (gutter / across): %d' % (W, n, 100 * c['contained'] / n, 100 * c['exact'] / n, 100 * c['partial'] / n, 100 * c['wrong'] / n, 100 * c['none'] / n, c['amb']))


if __name__ == '__main__':
    print('prose pages', PAGES); main()
    print('p1 (title + abstract + two columns)'); main([1])
    print('table / listing pages 3 5 9 13'); main([3, 5, 9, 13])
