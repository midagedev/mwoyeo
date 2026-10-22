#!/usr/bin/env python3
"""Lines whose box reaches the left or right edge of the picture they were read from (round read117, A5: `CaptureEdge.cutAtSides`).
Usage: side-census.py <paper bench out dir> [<use-case bench out dir>] [--list]      (python3 -I; measurement, exit 0)

The line boxes are the renders' own trace (`ocr-block N lines: x,y,w,h 'text'` in `<name>.err`, the document reader's lines before any
rule), the frame size is the size of the picture that was rendered. A line reaches an edge within `CaptureEdge.tolerance` (4 px). Per
render: lines read, lines that reach a side, and the lines `cutAtSides` would cut (three or more on one side, at least one line that
reaches neither). A bench change of the rule is attributable to the renders this lists and to no other.
  env: PAGES=<the paper bench's pictures> (default /tmp/paper-quality/pages-own)
       PNGS=<the use-case bench's pictures> (default ~/.cache/mwoyeo-gates/usecases/set)"""
import glob
import os
import re
import struct
import sys

TOLERANCE = 4
SIDE_COLUMN = 3


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    return struct.unpack(">II", head[16:24])


def lines_of(err):
    out = []
    for line in open(err, errors="replace"):
        m = re.search(r"ocr-block (\d+) lines: (.*?) \d+ ms$", line.rstrip("\n"))
        if m:
            out += [(int(a), int(b), int(c), int(d), t) for a, b, c, d, t in re.findall(r"(\d+),(\d+),(\d+),(\d+) '([^']*)'", m.group(2))]
    return out


def sides(lines, width):
    """(left, right) indices of the lines that reach a side edge."""
    return ([i for i, x in enumerate(lines) if x[0] <= TOLERANCE], [i for i, x in enumerate(lines) if x[0] + x[2] >= width - TOLERANCE])


def cut(lines, width):
    left, right = sides(lines, width)
    touching = set(left) | set(right)
    if len(touching) == len(lines):
        return set()
    return set().union(*(s for s in (left, right) if len(s) >= SIDE_COLUMN)) if lines else set()


def renders(paper, uc):
    pages = os.environ.get("PAGES", "/tmp/paper-quality/pages-own")
    for f in sorted(glob.glob(os.path.join(paper, "*.err"))):
        name = os.path.basename(f)[:-4]
        if os.path.exists(f"{pages}/{name}.png"):
            yield "paper", name, f, png_size(f"{pages}/{name}.png")[0]
    pngs = os.environ.get("PNGS", os.path.expanduser("~/.cache/mwoyeo-gates/usecases/set"))
    for f in sorted(glob.glob(os.path.join(uc, "*-auto.err"))) if uc else []:
        name = os.path.basename(f)[:-9]
        if os.path.exists(f"{pngs}/{name}.png"):
            yield "uc", name, f, png_size(f"{pngs}/{name}.png")[0]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    total = {"paper": [0, 0, 0, 0], "uc": [0, 0, 0, 0]}
    for kind, name, err, width in renders(args[0], args[1] if len(args) > 1 else None):
        lines = lines_of(err)
        left, right = sides(lines, width)
        c = cut(lines, width)
        t = total[kind]
        t[0] += 1; t[1] += len(lines); t[2] += len(set(left) | set(right)); t[3] += len(c)
        if left or right:
            print(f"{kind} {name} width {width}: {len(lines)} lines, {len(left)} at the left, {len(right)} at the right, cut {len(c)}")
            if "--list" in sys.argv:
                for i in sorted(set(left) | set(right)):
                    x = lines[i]
                    print(f"    {'L' if i in left else ' '}{'R' if i in right else ' '} {x[0]},{x[1]},{x[2]},{x[3]} {x[4]!r}")
    for kind, t in total.items():
        print(f"{kind}: {t[0]} renders, {t[1]} lines, {t[2]} reach a side, {t[3]} cut")


if __name__ == "__main__":
    main()
