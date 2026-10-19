#!/usr/bin/env python3
"""How many screens of two label files (two legs of make-h2.sh with fresh Vision reads of the same pictures) differ.
usage: h2_legs.py <A.jsonl> <B.jsonl>        prints `<differing screens> <screens>`
The document read of Vision is not byte-stable on the same picture (round k3a, 2026-10-20: one screen of 46 per pair of legs, a block cut in two once
and joined once; the vn read never differed), so a byte compare of two legs is the wrong gate; this counts the screens whose blocks differ."""
import collections, sys


def screens(path):
    d = collections.defaultdict(list)
    for line in open(path):
        if '"kind":"block"' in line[:20]:
            d[line.split('"paper":"', 1)[1].split('"', 1)[0]].append(line)
    return d


a, b = screens(sys.argv[1]), screens(sys.argv[2])
names = sorted(set(a) | set(b))
print(sum(1 for n in names if a.get(n) != b.get(n)), len(names))
