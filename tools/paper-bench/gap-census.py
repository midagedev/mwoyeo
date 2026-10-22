#!/usr/bin/env python3
"""The gap between a line and the line below it in its column (in line heights), split by whether the two belong together
(round read117, `ParagraphGrouper.maxGap`). Measurement, exit 0 (python3 -I).
Usage: gap-census.py blocks <err glob>          truth = the document reader's own blocks: both lines in one block, or in two
       gap-census.py units <err glob>           truth = the use-case bench's expected units (`set/<scene>.expected.txt`): both lines
                                                inside one expected paragraph, or inside two (a line whose text is found in no unit or in
                                                several is skipped; the trace holds 24 characters of a line)
The `<err glob>` is the renders' traces (`ocr-block N lines: x,y,w,h 'text'`). The nearest line below is picked as the grouper's own
test does: heights within 1.5, gap from -0.4 to 1.5 heights, left edges within 1.25 heights or centres within 0.5.
Reading: a limit separates the two kinds when every `same` gap is below it and every `diff` gap above; the table shows how many of each lie
in the bins around the grouper's limit (0.6)."""
import glob
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "usecase-bench"))
EDGES = [-0.4, 0, 0.2, 0.4, 0.5, 0.55, 0.6, 0.65, 0.7, 0.8, 1.0, 1.5]


def lines_of(path):
    out = []
    for line in open(path, errors="replace"):
        m = re.search(r"ocr-block (\d+) lines: (.*?) \d+ ms$", line.rstrip("\n"))
        if m:
            out += [(int(a), int(b), int(c), int(d), t, int(m.group(1))) for a, b, c, d, t in re.findall(r"(\d+),(\d+),(\d+),(\d+) '([^']*)'", m.group(2))]
    return out


def below(lines):
    """(gap, i, j): for every line i, the nearest line j below it in its column."""
    out = []
    for i, a in enumerate(lines):
        best = None
        for j, b in enumerate(lines):
            if i == j:
                continue
            tall, short = max(a[3], b[3]), min(a[3], b[3])
            if short <= 0 or tall / short > 1.5:
                continue
            gap = (b[1] - (a[1] + a[3])) / tall
            if gap < -0.4 or gap > 1.5:
                continue
            if not (abs(b[0] - a[0]) <= 1.25 * tall or abs((b[0] + b[2] / 2) - (a[0] + a[2] / 2)) <= 0.5 * tall):
                continue
            if best is None or gap < best[0]:
                best = (gap, i, j)
        if best:
            out.append(best)
    return out


def units_of(scene):
    import score
    path = f"{score.S}/{scene}.expected.txt"
    return [score.norm(t) for t, *_ in score.rows(path)] if os.path.exists(path) else None


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ("blocks", "units"):
        sys.exit(__doc__)
    mode, pattern = sys.argv[1:]
    same, diff = [], []
    for f in sorted(glob.glob(pattern)):
        if mode == "blocks" and re.match(r"p\d+-", os.path.basename(f)):
            continue    # a crop of the paper bench is a part of a page that is read as a page
        lines = lines_of(f)
        if mode == "blocks":
            for gap, i, j in below(lines):
                (same if lines[i][5] == lines[j][5] else diff).append(gap)
        else:
            import score
            units = units_of(os.path.basename(f).rsplit("-", 1)[0])
            if units is None:
                continue
            def unit(text):
                n = score.norm(text)
                hits = [k for k, u in enumerate(units) if len(n) >= 3 and n in u]
                return hits[0] if len(hits) == 1 else None
            for gap, i, j in below(lines):
                ua, ub = unit(lines[i][4]), unit(lines[j][4])
                if ua is not None and ub is not None:
                    (same if ua == ub else diff).append(gap)
    print(f"same pairs n={len(same)}, different pairs n={len(diff)}")
    for a, b in zip(EDGES, EDGES[1:]):
        print("  [%.2f,%.2f) same=%4d diff=%4d" % (a, b, sum(1 for x in same if a <= x < b), sum(1 for x in diff if a <= x < b)))
    print("  max same gap %.2f; min diff gap %.2f" % (max(same, default=0), min(diff, default=0)))


if __name__ == "__main__":
    main()
