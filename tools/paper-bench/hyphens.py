#!/usr/bin/env python3
"""Words the typesetter broke at the end of a line that are still two pieces in the text that was translated (round read117, item 1).
Usage: hyphens.py <paper bench out dir> [--list]      (python3 -I; exit 1 when one is left)

A source of the render (`<page>.out`, the lines with two spaces in front) holds a token `stem-rest` (two or more letters, then two or more
lowercase letters) whose joined form `stemrest` is an English word of the system's list (/usr/share/dict/words): "con-text", "noth-ing". A
compound ("sequence-aligned", "position-wise", "co-occurrence") is not a word once joined and is not counted. `LineJoin` joins the first
kind before the text goes to the engine; what is left is a word the spell checker (`EnglishWords`) did not know, a stem in capitals, or a
line end that sat inside code. The renders' `hyphen join:` trace marks (`<page>.err`) are counted beside it: the words that were joined."""
import glob
import os
import re
import sys

TOKEN = re.compile(r"(?<![A-Za-z0-9_/.\-])([A-Za-z]{2,})-([a-z]{2,})(?![A-Za-z0-9_\-])")


def words():
    path = "/usr/share/dict/words"
    return {w.strip().lower() for w in open(path, errors="replace")} if os.path.exists(path) else set()


def sources(path):
    for line in open(path, errors="replace"):
        if line.startswith("  ") and not line.startswith("   ") and not line.startswith("  →"):
            yield line[2:].rstrip("\n")


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    if not args:
        sys.exit(__doc__)
    known = words()
    if not known:
        sys.exit("hyphens.py: /usr/share/dict/words is missing")
    left, joined, pages = [], 0, 0
    for out in sorted(glob.glob(os.path.join(args[0], "*.out"))):
        name = os.path.basename(out)[:-4]
        pages += 1
        for src in sources(out):
            for m in TOKEN.finditer(src):
                if (m.group(1) + m.group(2)).lower() in known:
                    left.append((name, m.group(0)))
        err = out[:-4] + ".err"
        if os.path.exists(err):
            for line in open(err, errors="replace"):
                m = re.match(r"\[trace\] hyphen join: (.*?) \d+ ms$", line)
                if m:
                    joined += len(m.group(1).split())
    print(f"hyphens: {pages} renders, broken words left {len(left)}, joined by the reader {joined}")
    if "--list" in sys.argv:
        for name, token in left:
            print(f"  {name}: {token}")
    sys.exit(1 if left else 0)


if __name__ == "__main__":
    main()
