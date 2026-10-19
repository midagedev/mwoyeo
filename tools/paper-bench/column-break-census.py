#!/usr/bin/env python3
"""Which blocks of a bench run `ColumnBreak` cuts, read from the traces alone (no build, no render).
Usage: column-break-census.py <out dir> [<out dir> ...]      (python3 -I; reads <name>.err of run.sh / usecase-bench/bench.sh outputs)

The traces list every block the recognizer returned as `ocr-block <i> lines: x,y,w,h 'text' ; ...` (before the pipeline's own cuts).
A block fires when one of its lines climbs (the line's middle is above the top of the line before it) and the union of its lines
holds half of another block's union: the rule of Core/Sources/MwoyeoCore/ColumnBreak.swift (`climbs`, `holds`), restated. Prints one
FIRES line per cut with the line it climbs at, and the number of firings and files. Compare with the `ocr.column_break` counter and
the `column break:` trace lines of a build that has the rule (score.py prints `colbreak`). Before the rule, run it on a main run to
predict the firings (D1, 2026-10-19: own paper 5 of 41 renders, 1706.03762 0 of 46, use-case bench 1 of 40)."""
import glob
import os
import re
import sys

CROSS = 0.5


def parse(path):
    """[(block index, [(x, y, w, h, text)])] from the `ocr-block` trace lines."""
    out = []
    for ln in open(path, errors='replace'):
        m = re.match(r'\[trace\] ocr-block (\d+) lines: (.*) \d+ ms$', ln.rstrip('\n'))
        if not m:
            continue
        lines = []
        for part in m.group(2).split(' ; '):
            mm = re.match(r"(-?\d+),(-?\d+),(\d+),(\d+) '(.*)'$", part)
            if mm:
                lines.append(tuple(int(mm.group(i)) for i in range(1, 5)) + (mm.group(5),))
        out.append((int(m.group(1)), lines))
    return out


def union(ls):
    x0, y0 = min(l[0] for l in ls), min(l[1] for l in ls)
    x1, y1 = max(l[0] + l[2] for l in ls), max(l[1] + l[3] for l in ls)
    return x0, y0, x1 - x0, y1 - y0


def climbs(ls):
    return [k for k, (a, b) in enumerate(zip(ls, ls[1:])) if b[1] + b[3] / 2 < a[1]]


def holds(u, v):
    w = min(u[0] + u[2], v[0] + v[2]) - max(u[0], v[0])
    h = min(u[1] + u[3], v[1] + v[3]) - max(u[1], v[1])
    return w > 0 and h > 0 and w * h >= CROSS * min(u[2] * u[3], v[2] * v[3])


def main():
    firings, files = 0, 0
    for d in sys.argv[1:]:
        for f in sorted(glob.glob(os.path.join(d, '*.err'))):
            blocks = parse(f)
            if not blocks:
                continue
            files += 1
            unions = {i: union(ls) for i, ls in blocks if ls}
            for i, ls in blocks:
                cuts = climbs(ls)
                if not cuts:
                    continue
                held = [j for j, v in unions.items() if j != i and holds(unions[i], v)]
                if held:
                    firings += 1
                    k = cuts[0]
                    print('FIRES', os.path.basename(d.rstrip('/')) + '/' + os.path.basename(f)[:-4], 'block', i, 'lines', len(ls),
                          'climbs at', cuts, 'holds', len(held), 'blocks |', ls[k][4][-24:], '->', ls[k + 1][4][:24])
    print('files', files, 'firings', firings)


if __name__ == '__main__':
    main()
