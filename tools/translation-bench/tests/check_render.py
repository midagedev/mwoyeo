#!/usr/bin/env python3
"""The runner and the scorer render the user memory with two implementations of one rule; this compares them on every
memory of the corpus (and on the window-only and no-speech variants): `python3 -I tests/check_render.py <bench-run>`.
Exit 0 when every rendering is identical."""
import importlib.util
import json
import os
import subprocess
import sys

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("score", os.path.join(BENCH, "score.py"))
S = importlib.util.module_from_spec(spec)
spec.loader.exec_module(S)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    binary = sys.argv[1]
    seqs, mems = S.load_corpus(BENCH)
    bad = n = 0
    for sid in seqs:
        path = os.path.join(BENCH, "memory", sid + ".json")
        for extra, kwargs in (([], {}), (["--sections", "window"], {"sections": ("window",)}), (["--no-speech"], {"speech": False})):
            out = subprocess.run([binary, "render-memory", path] + extra, capture_output=True, text=True, check=True).stdout.rstrip("\n")
            want = S.render_memory(mems[sid], **kwargs)
            n += 1
            if out != want:
                bad += 1
                print("MISMATCH %s %s\n--- swift\n%s\n--- python\n%s" % (sid, extra, out, want))
    print("render parity: %d renderings compared, %d mismatches" % (n, bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
