"""first117: where a hover target exists. For every scene of the use-case bench (fit117's block data, `auto` path) and the two real Preview
shots: the share of grid positions (20 pt) that get a target, and of those how many are inside a column the estimator claims. Scenes that
are not pages (chat, games, subtitles, code) are expected to claim nothing: a target there is a false claim (the picker would show a
column outline where today's ghost stood)."""
import sys, os, glob
sys.path.insert(0, '/tmp/r117/first117/probe'); sys.path.insert(0, '/tmp/r117/fit117/probe')
import hover, common, columns as cmod

def scene(path, ppp=2.0):
    blocks = common.blocks(path, ppp)
    if not blocks:
        return None
    cols = cmod.columns(blocks)
    W = max(b[2] for b in blocks) + 40; H = max(b[3] for b in blocks) + 40
    bounds = (0, 0, W, H)
    n = t = 0
    hs = []
    x = 10.0
    while x < W:
        y = 10.0
        while y < H:
            n += 1
            r = hover.target((x, y), cols, blocks, bounds)
            if r:
                t += 1; hs.append(r[3] - r[1])
            y += 20.0
        x += 20.0
    return dict(blocks=len(blocks), cols=len(cols), n=n, t=t, area=W * H, h_med=sorted(hs)[len(hs) // 2] if hs else 0, widths=[round(c['right'] - c['left']) for c in cols])

if __name__ == '__main__':
    base = '/tmp/r117/fit117/data/uc-d14'
    groups = {}
    for f in sorted(glob.glob(f'{base}/*-auto.out')):
        name = os.path.basename(f).replace('-auto.out', '')
        r = scene(f)
        if r: groups.setdefault(name[0], []).append((name, r))
    cat = dict(c='chat', d='docs-web', g='games', p='papers', s='subtitles', k='code')
    print('%-26s %-9s %6s %4s %9s %8s %6s  %s' % ('scene', 'category', 'blocks', 'cols', 'positions', 'target%', 'h med', 'column widths (pt)'))
    for g in 'cdgpsk':
        tot = tt = 0; claim = 0
        for name, r in groups.get(g, []):
            print('%-26s %-9s %6d %4d %9d %7.0f%% %6.0f  %s' % (name, cat[g], r['blocks'], r['cols'], r['n'], 100 * r['t'] / r['n'], r['h_med'], r['widths']))
            tot += 1; claim += 1 if r['cols'] else 0
        print('  -> %s: %d of %d scenes claim a column' % (cat[g], claim, tot))
    print()
    print('real Preview screens (1512 x 982 pt, Retina px / 2):')
    for f in ('shotA', 'shotB'):
        p = f'/tmp/r117/fit117/pv-out/{f}.out'
        r = scene(p)
        if r: print('%-26s %-9s %6d %4d %9d %7.0f%% %6.0f  %s' % (f, 'preview', r['blocks'], r['cols'], r['n'], 100 * r['t'] / r['n'], r['h_med'], r['widths']))
