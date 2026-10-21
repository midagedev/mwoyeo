"""fit117 measurement 1: how accurately do column edges come out of the existing blocks? 13 pages of our own paper (paper-d14 bench = main at the D14 landing),
OCR blocks -> columns() vs the oracle = the same estimator on the PDF's own text blocks (pdftotext -bbox-layout), and vs the two true text columns
(PDF pt 54..297 and 315..558, the paper's geometry)."""
import sys; sys.path.insert(0, '/tmp/r117/fit117/probe')
from common import *
from columns import columns
D = '/tmp/r117/fit117/data'
pdf = pdf_blocks(f'{D}/layout.html')
errs_l, errs_r, rows = [], [], []
tot_o = tot_hit = 0
for n in range(1, 14):
    ocr = columns(blocks(f'{D}/paper-d14/p{n}.out'))
    orc = columns(pdf[n - 1])
    hit = 0
    for o in orc:
        m = min(ocr, key=lambda c: abs(c['left'] - o['left']) + abs(c['right'] - o['right']), default=None)
        ok = m and abs(m['left'] - o['left']) <= 4 and abs(m['right'] - o['right']) <= 4
        if ok:
            hit += 1; errs_l.append(m['left'] - o['left']); errs_r.append(m['right'] - o['right'])
    tot_o += len(orc); tot_hit += hit
    # estimated columns that match no oracle column
    spur = [c for c in ocr if not any(abs(c['left'] - o['left']) <= 4 and abs(c['right'] - o['right']) <= 4 for o in orc)]
    # of the two true body columns
    body = []
    for tl, tr in COLS:
        m = min(ocr, key=lambda c: abs(c['left'] - tl) + abs(c['right'] - tr), default=None)
        body.append((m['left'] - tl, m['right'] - tr) if m and abs(m['left'] - tl) <= 4 and abs(m['right'] - tr) <= 4 else None)
    rows.append((n, len(orc), len(ocr), hit, len(spur), body))
    print('p%-2d oracle cols %d  ocr cols %d  recovered %d  spurious %d  body L/R err (pt): %s' % (n, len(orc), len(ocr), hit, len(spur),
          ['%+.1f/%+.1f' % b if b else 'miss' for b in body]))
    for c in spur: print('      spurious: %.0f..%.0f (w %.0f) blocks %d lines %d' % (c['left'], c['right'], c['right'] - c['left'], c['blocks'], c['lines']))
import statistics as st
a = lambda xs: (st.mean(xs), st.pstdev(xs), max(abs(x) for x in xs))
print('matched oracle columns %d of %d' % (tot_hit, tot_o))
print('edge error (pt) left: mean %+.2f sd %.2f max|.| %.2f ; right: mean %+.2f sd %.2f max|.| %.2f ; n=%d' % (*a(errs_l), *a(errs_r), len(errs_l)))
print('within 2 pt: left %d%% right %d%%' % (100 * sum(abs(e) <= 2 for e in errs_l) / len(errs_l), 100 * sum(abs(e) <= 2 for e in errs_r) / len(errs_r)))
bodyhit = [b for r in rows for b in r[5] if b]; bodyall = [b for r in rows for b in r[5]]
print('true body columns found on %d of %d (page,column) cells' % (len(bodyhit), len(bodyall)))
