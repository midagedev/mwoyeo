"""first117: the hover target of the one-click picker, prototyped on the benches' block rects (fit117's data), and what it does to the
default 560 x 320 ghost's edges. Units: screen pt (bench px / 2).

TARGET (the rule the design proposes; the Swift port is `LensTarget.choose`):
  1. column   = the ColumnFit column whose x range [left - pad - slack, right + pad + slack] holds the pointer (nearest one when two do).
  2. anchor   = the column's member block holding the pointer's y; in a gap, the nearer block within GAP; none farther = no target (ghost).
                Hysteresis: the previous anchor stays while the pointer is within HYST of its box (no flicker at the midpoint of a gap).
  3. extent   = from the anchor's top, down over the following members while the gap to the previous member is <= BREAK, until the height
                reaches H = clamp(A0 / width, HMIN, HMAX); a block that crosses H stays in when at least half of it is inside, else it is out;
                a lens is never shorter than its anchor. Short of room below (display / window bottom) it grows upward by whole members.
  4. width    = column.left - pad .. column.right + pad (fit117's `fitted`).
members = every block (one-line headings and captions too) whose x range lies inside [left - TOLX, right + TOLX].
"""
import sys, os, math, random, statistics
sys.path.insert(0, '/tmp/r117/fit117/probe')
import common, columns as cmod

PAD = 6.0
SLACK = 12.0       # pointer reach beyond the column's padded edge
GAP = 40.0         # farthest a block may be from the pointer's y and still anchor
HYST = 6.0
BREAK = 44.0       # a vertical gap between members that ends the chain (a figure, a full-width element)
TOLX = 8.0
A0 = 560.0 * 320.0  # the default lens's area: a read costs about what the default lens costs
HMIN, HMAX = 160.0, 560.0
MINLINES = 2      # a target holds at least two lines of text, as a column's evidence does
MINW = 160.0      # a column narrower than this (a table's cell column, a sidebar item) is not a reading column: the ghost stays
MINH = 40.0       # the lens's resize floor (RegionFrameWindow)
LINE = 14.0

def members(col, blocks):
    return sorted((b for b in blocks if b[0] >= col['left'] - TOLX and b[2] <= col['right'] + TOLX), key=lambda b: b[1])

def column_at(x, cols):
    best = None
    for c in cols:
        lo, hi = c['left'] - PAD - SLACK, c['right'] + PAD + SLACK
        if lo <= x <= hi:
            d = 0 if c['left'] - PAD <= x <= c['right'] + PAD else min(abs(x - (c['left'] - PAD)), abs(x - (c['right'] + PAD)))
            if best is None or d < best[0]:
                best = (d, c)
    return best[1] if best else None

def score(y, b):
    """signed distance: depth inside the block, minus the distance outside it"""
    if b[1] <= y <= b[3]:
        return min(y - b[1], b[3] - y)
    return -min(abs(y - b[1]), abs(y - b[3]))

SWITCH = 8.0   # a new anchor must beat the held one by this much (pt of signed distance)

def anchor_of(y, mem, prev=None):
    if not mem:
        return None
    best = max(mem, key=lambda b: score(y, b))
    if prev is not None and prev in mem and best is not prev and score(y, prev) >= -GAP and score(y, best) - score(y, prev) < SWITCH:
        return prev
    return best if score(y, best) >= -GAP else None

def target(p, cols, blocks, bounds, prev=None):
    """-> (rect x0,y0,x1,y1, anchor block) or None"""
    c = column_at(p[0], cols)
    if not c:
        return None
    if c['right'] - c['left'] < MINW:
        return None
    mem = members(c, blocks)
    a = anchor_of(p[1], mem, prev)
    if a is None:
        return None
    width = c['right'] - c['left'] + 2 * PAD
    H = max(HMIN, min(HMAX, A0 / width))
    i = mem.index(a)
    top, bottom = a[1], a[3]
    j = i
    while j + 1 < len(mem):
        n = mem[j + 1]
        if n[1] - bottom > BREAK:
            break
        h_with = n[3] - top
        if bottom - top >= H:
            break
        if h_with > H and (H - (bottom - top)) < (n[3] - n[1]) / 2:   # crosses H and less than half of it fits
            break
        bottom = n[3]
        j += 1
    # short of room below: grow upward by whole members
    room = bounds[3]
    if bottom > room:
        bottom = room
    k = i
    while bottom - top < H * 0.6 and k - 1 >= 0 and top - mem[k - 1][3] <= BREAK:
        k -= 1
        top = mem[k][1]
    lines = sum(b[4] for b in mem if top - 1 <= b[1] and b[3] <= bottom + 1)
    if lines < MINLINES or bottom - top < MINH:
        return None
    return (c['left'] - PAD, top, c['right'] + PAD, bottom, a)

def ghost(p, bounds):
    w, h = min(560.0, bounds[2] - bounds[0]), min(320.0, bounds[3] - bounds[1])
    x = min(max(p[0] - w / 2, bounds[0]), bounds[2] - w)
    y = min(max(p[1] - h / 2, bounds[1]), bounds[3] - h)
    return (x, y, x + w, y + h)

def cuts(y, blocks, x0, x1):
    """does a horizontal lens edge at y cut through a block (more than 2 pt inside it) among the blocks the lens's x range touches"""
    for b in blocks:
        if b[2] <= x0 or b[0] >= x1:
            continue
        if b[1] + 2 < y < b[3] - 2:
            return True
    return False

def run(page_paths, label, step=10.0):
    rows = []
    for path in page_paths:
        blocks = common.blocks(path)
        if not blocks:
            continue
        cols = cmod.columns(blocks)
        W = max(b[2] for b in blocks) + 40
        Hh = max(b[3] for b in blocks) + 40
        bounds = (0, 0, W, Hh)
        n_in = n_t = 0
        hs, widths = [], []
        ghost_cut = ghost_top_cut = ghost_bottom_cut = 0
        tgt_cut = 0
        n_g = 0
        x = step
        while x < W:
            y = step
            while y < Hh:
                p = (x, y)
                c = column_at(x, cols)
                if c and c['top'] - GAP <= y <= c['bottom'] + GAP:
                    n_in += 1
                    t = target(p, cols, blocks, bounds)
                    if t:
                        n_t += 1
                        hs.append(t[3] - t[1]); widths.append(t[2] - t[0])
                        if cuts(t[1], blocks, t[0], t[2]) or cuts(t[3], blocks, t[0], t[2]):
                            tgt_cut += 1
                    g = ghost(p, bounds)
                    n_g += 1
                    tc = cuts(g[1], blocks, g[0], g[2]); bc = cuts(g[3], blocks, g[0], g[2])
                    ghost_top_cut += tc; ghost_bottom_cut += bc; ghost_cut += (tc or bc)
                y += step
            x += step
        rows.append(dict(page=os.path.basename(path), cols=len(cols), positions=n_in, with_target=n_t,
                         h_med=statistics.median(hs) if hs else 0, h_min=min(hs) if hs else 0, h_max=max(hs) if hs else 0,
                         w_med=statistics.median(widths) if widths else 0,
                         ghost_cut=ghost_cut / n_g if n_g else 0, ghost_top=ghost_top_cut / n_g if n_g else 0,
                         ghost_bottom=ghost_bottom_cut / n_g if n_g else 0, tgt_cut=tgt_cut / n_t if n_t else 0))
    return rows

def sweep(path, jitter=2.0, seed=1):
    """walk the pointer down every column at 1 pt; with and without hysteresis count the target changes; then jitter +-2 pt at each
    block boundary and count reversals (A -> B -> A)."""
    blocks = common.blocks(path)
    cols = cmod.columns(blocks)
    H = max(b[3] for b in blocks) + 40
    W = max(b[2] for b in blocks) + 40
    bounds = (0, 0, W, H)
    out = []
    for c in cols:
        x = (c['left'] + c['right']) / 2
        prev = None
        seq = []
        y = 0.0
        while y < H:
            t = target((x, y), cols, blocks, bounds, prev)
            a = t[4] if t else None
            seq.append(a)
            prev = a
            y += 1.0
        changes = sum(1 for i in range(1, len(seq)) if seq[i] != seq[i - 1] and seq[i] is not None and seq[i - 1] is not None)
        # jitter: wiggle +-jitter around each boundary between two targets, 200 samples, with and without hysteresis
        rnd = random.Random(seed)
        flick_h = flick_n = 0
        mem = members(c, blocks)
        for b0, b1 in zip(mem, mem[1:]):
            mid = (b0[3] + b1[1]) / 2
            for use_h in (True, False):
                prev = None; seq2 = []
                for _ in range(200):
                    yy = mid + rnd.uniform(-jitter, jitter)
                    t = target((x, yy), cols, blocks, bounds, prev if use_h else None)
                    a = t[4] if t else None
                    seq2.append(a); prev = a
                rev = sum(1 for i in range(2, len(seq2)) if seq2[i] == seq2[i - 2] and seq2[i] != seq2[i - 1])
                if use_h: flick_h += rev
                else: flick_n += rev
        out.append((round(c['left']), round(c['right']), len(mem), changes, flick_h, flick_n))
    return out

if __name__ == '__main__':
    base = '/tmp/r117/fit117/data/paper-d14'
    pages = [f'{base}/p{n}.out' for n in (2, 4, 6, 7, 8, 10, 11, 12)]
    print('== target vs default ghost, 8 prose pages, pointer grid 10 pt, positions inside a column (+-GAP vertically)')
    print('%-8s %5s %9s %7s %6s %6s %6s %6s | %9s %9s %9s | %9s' % ('page', 'cols', 'positions', 'target%', 'h med', 'h min', 'h max', 'w med', 'ghost cut', 'top', 'bottom', 'tgt cut'))
    tot = dict(pos=0, t=0, gc=0, gt=0, gb=0, tc=0)
    for r in run(pages, 'paper'):
        print('%-8s %5d %9d %6.0f%% %6.0f %6.0f %6.0f %6.0f | %8.0f%% %8.0f%% %8.0f%% | %8.1f%%' % (
            r['page'], r['cols'], r['positions'], 100 * r['with_target'] / max(1, r['positions']), r['h_med'], r['h_min'], r['h_max'], r['w_med'],
            100 * r['ghost_cut'], 100 * r['ghost_top'], 100 * r['ghost_bottom'], 100 * r['tgt_cut']))
        tot['pos'] += r['positions']; tot['t'] += r['with_target']; tot['gc'] += r['ghost_cut'] * r['positions']
        tot['gt'] += r['ghost_top'] * r['positions']; tot['gb'] += r['ghost_bottom'] * r['positions']; tot['tc'] += r['tgt_cut'] * r['with_target']
    print('ALL      %5s %9d %6.0f%% %6s %6s %6s %6s | %8.0f%% %8.0f%% %8.0f%% | %8.1f%%' % (
        '', tot['pos'], 100 * tot['t'] / tot['pos'], '', '', '', '', 100 * tot['gc'] / tot['pos'], 100 * tot['gt'] / tot['pos'], 100 * tot['gb'] / tot['pos'], 100 * tot['tc'] / max(1, tot['t'])))
    print()
    print('== stability: pointer walks down each column at 1 pt; boundary jitter +-2 pt x 200 samples per boundary')
    print('%-8s %-12s %7s %8s %12s %12s' % ('page', 'column', 'members', 'changes', 'reversals(h)', 'reversals(no h)'))
    for n in (2, 4, 6, 7, 8, 10, 11, 12):
        for l, r, m, ch, fh, fn in sweep(f'{base}/p{n}.out'):
            print('%-8s %-12s %7d %8d %12d %12d' % ('p%d' % n, '%d..%d' % (l, r), m, ch, fh, fn))
