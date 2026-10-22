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
ALLOWANCE = 0.10

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

def main(argv):
    if '--selftest' in argv:
        rows = [(1.0, 20, 20, 10, False, 4, 4), (0.5, 20, 20, 10, False, 5, 4), (0.4, 10, 20, 10, True, 6, 4), (0.3, 10, 20, 10, True, 8, 4)]
        blocks = [rows] * 10
        over = table(blocks, 'selftest')
        assert over == 0.5, over
        print('selftest ok')
        return 0
    paragraphs = int(argv[argv.index('--paragraphs') + 1]) if '--paragraphs' in argv else 3
    files = sorted(glob.glob(argv[0].rstrip('/') + '/*.err'))
    blocks = []
    for f in files:
        blocks += parse(open(f, errors='replace').read())
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
