#!/usr/bin/env python3
"""The number behind LensWindow.minShare (docs/design/recognition.md section 16.2): how a translation fits when the lens covers only part of its block.

usage: python3 -I sweep.py <dir of render .err files> [--paragraphs N]

A render with MWOYEO_LENS_SWEEP=1 (tools/paper-bench/run.sh sets nothing; export it before the run) writes, for every block it draws, one `sweep` line per
share of the block's source text width (100 % down to 10 %, from the text's left edge): the size the fitter returned beside the size at the full width and its
floor, whether the translation was cut ("..."), the lines it came to. A block "reads" at a share when the fitter stayed above its floor and the translation
was not cut. This prints, per share, how many blocks do not, for all blocks and for the paragraphs (at least N source lines, default 3), and the median size
as a share of the full-width size. Blocks that do not read even at the full width (a long translation in a one-line label) are left out: the lens did not
make them worse. minShare's candidate is the narrowest share down to which at most 10 % of the paragraphs that read at the full width stop reading.

FAILURE MODE IT BLOCKS: a floor taken from the first number that looked right. Exit 2 when the directory holds no sweep line: a run without the variable is
not a measurement. FAIL-first: `sweep.py --selftest` feeds it lines of a block that stops reading at 0.4 and must say so."""
import re, sys, glob, statistics

LINE = re.compile(r"sweep share (?P<share>[\d.]+) size (?P<size>[\d.]+) full (?P<full>[\d.]+) floor (?P<floor>[\d.]+) clipped (?P<clipped>\d) ellipsis (?P<ellipsis>\d) "
                  r"lines (?P<lines>\d+) wrapped (?P<wrapped>\d+) core (?P<cw>[\d.]+)x(?P<ch>[\d.]+) chars (?P<chars>\d+)")
INK = re.compile(r"ink line (?P<i>\d+) of (?P<n>\d+) height (?P<h>[\d.]+) size (?P<size>[\d.]+) top (?P<t>[\d. -]+) bottom (?P<b>[\d. -]+) src")
ALLOWANCE = 0.10
INK_SHARE = 10   # the share of a line's ink (percent) that an edge may cut and the line still count as whole (the column of `top`/`bottom` that holds it; --ink-share 2|5|10)

def parse(text):
    """Blocks as lists of (share, size, full, floor, cut, lines, wrapped) in the order of the lines: a block starts at share 1.0."""
    blocks = []
    for m in LINE.finditer(text):
        share = float(m['share'])
        row = (share, float(m['size']), float(m['full']), float(m['floor']), m['ellipsis'] == '1', int(m['lines']), int(m['wrapped']))
        if share >= 0.999 or not blocks:
            blocks.append([])
        blocks[-1].append(row)
    return blocks

def reads(row):
    share, size, full, floor, cut, lines, wrapped = row
    return size > floor + 0.5 and not cut

def table(blocks, label):
    total = len(blocks)
    blocks = [b for b in blocks if reads(b[0])]
    shares = sorted({r[0] for b in blocks for r in b}, reverse=True)
    print(f'{label}: {total} blocks, {len(blocks)} read at the full width')
    print('  share  not reading  of blocks   median size / full-width size')
    candidate = prev = None
    for s in shares:
        rows = [r for b in blocks for r in b if abs(r[0] - s) < 1e-6]
        bad = sum(1 for r in rows if not reads(r))
        ratio = statistics.median(r[1] / r[2] for r in rows if r[2] > 0) if rows else 0
        share_bad = bad / len(rows) if rows else 0
        mark = ''
        if candidate is None and share_bad > ALLOWANCE: mark = '  <- over the allowance'; candidate = prev
        if candidate is None: prev = s
        print(f'  {s:5.2f}  {bad:5d}  {len(rows):5d}  {share_bad:6.1%}   {ratio:5.2f}{mark}')
    return candidate if candidate is not None else prev

def ink_lines(text):
    """(height, size, top, bottom) per `ink` line: top and bottom are the depths (shares of the box's height) at which an edge has cut 0, 2, 5 and 10 % of the ink."""
    return [(float(m['h']), float(m['size']), [float(v) for v in m['t'].split()], [float(v) for v in m['b'].split()]) for m in INK.finditer(text)]

def percentile(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, max(0, int(q * len(values))))]

def ink_table(lines):
    """LensWindow.wholeInset: the depth that at most ALLOWANCE of the lines have cut more than INK_SHARE % of their ink by (the 10th percentile of the depth at which the edge has cut 5 %),
    for the top and for the bottom edge. Prints the distribution by size class and returns (top, bottom)."""
    col = {0: 0, 2: 1, 5: 2, 10: 3}[INK_SHARE]
    out = []
    for name, group in (('all lines', lines), ('size < 30 px', [l for l in lines if l[1] < 30]), ('30 to 44 px', [l for l in lines if 30 <= l[1] < 44]), ('44 px and more', [l for l in lines if l[1] >= 44])):
        if not group: continue
        print(f'{name}: {len(group)} lines; depth into the box (share of its height) at which an edge has cut {INK_SHARE} % of the ink; ink starts at')
        for edge, k in (('top   ', 2), ('bottom', 3)):
            v = [l[k][col] for l in group]; start = [l[k][0] for l in group]
            print(f'  {edge} p10 {percentile(v, ALLOWANCE):.3f}  p25 {percentile(v, .25):.3f}  median {percentile(v, .5):.3f}  p90 {percentile(v, .9):.3f}   (ink starts: p10 {percentile(start, ALLOWANCE):.3f} median {percentile(start, .5):.3f})')
        if name == 'all lines': out = [percentile([l[2][col] for l in group], ALLOWANCE), percentile([l[3][col] for l in group], ALLOWANCE)]
    return tuple(out)

def main(argv):
    global INK_SHARE
    if '--ink-share' in argv:
        INK_SHARE = int(argv[argv.index('--ink-share') + 1])
    if '--selftest' in argv:
        # A line whose ink starts at 0.12 of its box and whose first INK_SHARE % (10) is cut at 0.20 (bottom 0.21): the table must say so.
        fake = [(36.0, 30.0, [0.12, 0.14, 0.17, 0.20], [0.13, 0.15, 0.18, 0.21])] * 20
        assert ink_table(fake) == (0.20, 0.21), ink_table(fake)
        rows = [(1.0, 20, 20, 10, False, 4, 4), (0.5, 20, 20, 10, False, 5, 4), (0.4, 10, 20, 10, True, 6, 4), (0.3, 10, 20, 10, True, 8, 4)]
        blocks = [rows] * 10
        over = table(blocks, 'selftest')
        assert over == 0.5, over
        print('selftest ok')
        return 0
    paragraphs = int(argv[argv.index('--paragraphs') + 1]) if '--paragraphs' in argv else 3
    files = sorted(glob.glob(argv[0].rstrip('/') + '/*.err'))
    blocks, inks = [], []
    for f in files:
        text = open(f, errors='replace').read()
        blocks += parse(text)
        inks += ink_lines(text)
    if inks and '--ink' in argv:
        top, bottom = ink_table(inks)
        print(f'wholeInset candidate: top {top:.3f}, bottom {bottom:.3f} ({len(inks)} lines)')
        return 0
    if not blocks:
        print(f'sweep.py: no sweep line in {argv[0]} (render with MWOYEO_LENS_SWEEP=1)', file=sys.stderr)
        return 2
    table(blocks, 'all blocks')
    over = table([b for b in blocks if b[0][6] >= paragraphs], f'paragraphs (>= {paragraphs} source lines)')
    print(f'minShare candidate: the narrowest share down to which at most {ALLOWANCE:.0%} of the paragraphs stop reading = {over}')
    print('by source lines (the same allowance):')
    for lo, hi in ((1, 1), (2, 2), (3, 5), (6, 10 ** 6)):
        group = [b for b in blocks if lo <= b[0][6] <= hi and reads(b[0])]
        if not group: continue
        shares = sorted({r[0] for b in group for r in b}, reverse=True)
        cand = None
        for s in shares:
            rows = [r for b in group for r in b if abs(r[0] - s) < 1e-6]
            if sum(1 for r in rows if not reads(r)) / len(rows) > ALLOWANCE: break
            cand = s
        print(f'  {lo}{"+" if hi > 100 else "" if lo == hi else "-" + str(hi)} lines: {len(group)} blocks read at the full width, narrowest share within the allowance {cand}')
    return 0

sys.exit(main(sys.argv[1:]))
