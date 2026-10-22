"""first117: do the lines+grouper blocks (the path a picker read takes) give the columns the design measured on the auto path (fit117, D14 bench)?"""
import sys
sys.path.insert(0, '/tmp/r117/first117/probe'); sys.path.insert(0, '/tmp/r117/fit117/probe')
import common, columns as cmod, hover
A = '/tmp/r117/fit117/data/paper-d14'; V = '/tmp/r117/first117/data/vn-pages'
import re
def blocks_err(path, ppp=2.0):
    out = []
    for l in open(path, errors='replace'):
        m = re.match(r"\[trace\] ocr-block \d+ lines: (.*) \d+ ms$", l.rstrip('\n'))
        if not m: continue
        rs = []
        for part in m[1].split(' ; '):
            q = re.match(r"(-?\d+),(-?\d+),(\d+),(\d+) ", part)
            if q: rs.append(tuple(int(v) for v in q.groups()))
        if not rs: continue
        x0 = min(r[0] for r in rs); y0 = min(r[1] for r in rs); x1 = max(r[0] + r[2] for r in rs); y1 = max(r[1] + r[3] for r in rs)
        out.append((x0 / ppp, y0 / ppp, x1 / ppp, y1 / ppp, len(rs), 0))
    return out
print('%-5s %-28s %-28s %s' % ('page', 'columns, auto path', 'columns, lines+grouper', 'max |edge diff| pt'))
worst = 0.0; tot = dict(pos=0, t=0)
for n in (2, 4, 6, 7, 8, 10, 11, 12):
    a = cmod.columns(common.blocks(f'{A}/p{n}.out')); vb = blocks_err(f'{V}/p{n}.err'); v = cmod.columns(vb)
    fmt = lambda cs: ' '.join('%d..%d' % (round(c['left']), round(c['right'])) for c in cs)
    d = []
    for c in a:
        m = min(v, key=lambda x: abs(x['left'] - c['left']), default=None)
        if m and abs(m['left'] - c['left']) < 12: d.append(max(abs(m['left'] - c['left']), abs(m['right'] - c['right'])))
    w = max(d) if d else float('nan')
    if d: worst = max(worst, w)
    print('p%-4d %-28s %-28s %s  (matched %d of %d)' % (n, fmt(a), fmt(v), '%.1f' % w, len(d), len(a)))
print('worst edge difference over matched columns: %.1f pt' % worst)
print()
print('hover target on the lines+grouper blocks (same rule):')
import os
tot = dict(pos=0, t=0, gc=0, tc=0)
hover.common.blocks = lambda p, ppp=2.0: blocks_err(p.replace('.out', '.err'))
for r in hover.run([f'{V}/p{n}.out' for n in (2, 4, 6, 7, 8, 10, 11, 12)], 'vn'):
    tot['pos'] += r['positions']; tot['t'] += r['with_target']; tot['gc'] += r['ghost_cut'] * r['positions']; tot['tc'] += r['tgt_cut'] * r['with_target']
print('positions %d, target %.0f%%, default ghost cuts a block at an edge %.0f%%, target cuts %.1f%%' % (tot['pos'], 100 * tot['t'] / tot['pos'], 100 * tot['gc'] / tot['pos'], 100 * tot['tc'] / max(1, tot['t'])))
