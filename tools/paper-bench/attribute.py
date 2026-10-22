#!/usr/bin/env python3
"""Attributes the differences between two bench output dirs (before, after) by the source text of the blocks, not by their order: the
reader's grouping of lines varies with the load of the machine (round read117).
Usage: attribute.py <before dir> <after dir> [--list] [--hyphens]      (python3 -I; measurement, exit 0)
       dirs: the paper bench's out dir, or the use-case bench's `<out>/out`

Each block of the after render (a source line of `<name>.out` with its translation on the line after "→") is
  same       its source is a source of the before render and the translation is equal;
  case       the same source, the translation differs only by letter case (a name given its spelling back, `restoreSourceTokens`);
  other      the same source, any other translation (listed);
  hyphen     its source is a before-source with the hyphens of broken words taken out (the `hyphen join:` words of the after render's
             trace, `LineJoin`); listed with --hyphens;
  regrouped  neither: the reader cut the text another way in the two runs, nothing to compare.
Run it on two renders of the same build to see the noise: that is the regrouped count a change has to be read against."""
import glob
import os
import re
import sys


def pairs(path):
    lines = open(path, errors="replace").read().split("\n")
    return [(l[2:], lines[i + 1][6:]) for i, l in enumerate(lines[:-1])
            if l.startswith("  ") and not l.startswith("   ") and not l.startswith("  →") and lines[i + 1].startswith("    → ")]


def joined_words(err):
    words = []
    if os.path.exists(err):
        for line in open(err, errors="replace"):
            m = re.match(r"\[trace\] hyphen join: (.*?) \d+ ms$", line)
            if m:
                words += m.group(1).split()
    return words


def dehyphen(source, words):
    for w in words:
        for k in range(2, len(w) - 1):
            source = source.replace(w[:k] + "-" + w[k:], w)
    return source


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if len(args) != 2:
        sys.exit(__doc__)
    before, after = args
    total = dict(same=0, hyphen=0, case=0, other=0, regrouped=0)
    rows = []
    for f in sorted(glob.glob(os.path.join(after, "*.out"))):
        name = os.path.basename(f)[:-4]
        b = os.path.join(before, name + ".out")
        if not os.path.exists(b):
            continue
        pb, pa = pairs(b), pairs(f)
        words = joined_words(f[:-4] + ".err")
        by_source = {s: t for s, t in pb}
        by_dehyphened = {dehyphen(s, words): (s, t) for s, t in pb}
        for s, t in pa:
            if s in by_source:
                tb = by_source[s]
                if tb == t:
                    total["same"] += 1
                elif tb.lower() == t.lower():
                    total["case"] += 1; rows.append((name, "case", f"{tb[:70]!r} -> {t[:70]!r}"))
                else:
                    total["other"] += 1; rows.append((name, "other", f"{s[:60]!r}: {tb[:50]!r} -> {t[:50]!r}"))
            elif s in by_dehyphened:
                total["hyphen"] += 1; rows.append((name, "hyphen", f"{by_dehyphened[s][0][-40:]!r} -> {s[-40:]!r}"))
            else:
                total["regrouped"] += 1
    print(" ".join(f"{k} {v}" for k, v in total.items()))
    if "--list" in sys.argv:
        for r in rows:
            if r[1] != "hyphen" or "--hyphens" in sys.argv:
                print("  %s %s: %s" % r)


if __name__ == "__main__":
    main()
