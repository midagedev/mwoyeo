#!/usr/bin/env python3
"""Compares the lines two runs of the app read, picture by picture.

  python3 -I tools/ocr-probe/same-lines.py A B [-v] [--tol <px>]

A and B are directories of `<picture>.err` files (what a --render run writes to stderr with MWOYEO_TRACE_READS=1: the
`[read]` records of TextRecognizer), or two single trace files. Per picture it compares, in order, every read (kind, picture
size, region, number of lines) and every line (paragraph, text, rect) and every word (range, rect). Prints

  same: <k>/<n> pictures, max rect delta <px> px

n counts the pictures of both runs; a picture only one run has is not the same. A picture is the same when its text, words
and structure are equal and no rect differs by more than --tol pixels (default 0: equal to the bit). Exit 0 when k == n (and
n > 0), else 1. `-v` names the first difference of each picture that differs.
"""
import os
import sys


def parse(path):
    """The reads of one trace file: [(header, [line records])]; a picture with no [read] record has no reads."""
    reads = []
    with open(path, encoding="utf-8", errors="replace") as f:
        for raw in f:
            if not raw.startswith("[read]\t"):
                continue
            parts = raw.rstrip("\n").split("\t")
            if len(parts) >= 3 and parts[2] == "begin":
                reads.append((tuple(parts[1:]), []))
            elif len(parts) >= 3 and parts[2] == "line" and reads:
                reads[-1][1].append(parts[3:])
    return reads


def pictures(path):
    if os.path.isdir(path):
        return {n[:-4]: os.path.join(path, n) for n in sorted(os.listdir(path)) if n.endswith(".err")}
    return {os.path.basename(path): path}


def num(s):
    try:
        return float(s)
    except ValueError:
        return float("nan")


def words(field):
    out = []
    for w in field.split(";") if field else []:
        rect, _, span = w.partition("@")
        out.append(([num(v) for v in rect.split(",")], span))
    return out


def compare(a, b):
    """(reason or None, max rect delta) for two parsed traces of one picture."""
    delta = 0.0
    if len(a) != len(b):
        return f"{len(a)} reads vs {len(b)}", delta
    for i, ((ha, la), (hb, lb)) in enumerate(zip(a, b)):
        if ha != hb:
            return f"read {i}: header {ha} vs {hb}", delta
        if len(la) != len(lb):
            return f"read {i} ({ha[0]}): {len(la)} lines vs {len(lb)}", delta
        for j, (x, y) in enumerate(zip(la, lb)):
            # x = [paragraph, x, y, w, h, text, words]
            if x[0] != y[0] or x[5] != y[5]:
                return f"read {i} line {j}: paragraph/text {x[0]}:{x[5][:30]!r} vs {y[0]}:{y[5][:30]!r}", delta
            for p, q in zip(x[1:5], y[1:5]):
                delta = max(delta, abs(num(p) - num(q)))
            wx, wy = words(x[6] if len(x) > 6 else ""), words(y[6] if len(y) > 6 else "")
            if len(wx) != len(wy):
                return f"read {i} line {j}: {len(wx)} words vs {len(wy)}", delta
            for (rp, sp), (rq, sq) in zip(wx, wy):
                if sp != sq:
                    return f"read {i} line {j}: word range {sp} vs {sq}", delta
                for p, q in zip(rp, rq):
                    delta = max(delta, abs(p - q))
    return None, delta


def main(argv):
    verbose = "-v" in argv
    tol = 0.0
    args = [a for a in argv if a != "-v"]
    if "--tol" in args:
        i = args.index("--tol")
        tol = float(args[i + 1])
        del args[i:i + 2]
    if len(args) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    pa, pb = pictures(args[0]), pictures(args[1])
    names = sorted(set(pa) | set(pb))
    same, worst = 0, 0.0
    for name in names:
        if name not in pa or name not in pb:
            if verbose:
                print(f"{name}: only in {'A' if name in pa else 'B'}", file=sys.stderr)
            continue
        reason, delta = compare(parse(pa[name]), parse(pb[name]))
        worst = max(worst, delta)
        if reason is None and delta > tol:
            reason = f"a rect moved by {delta:g} px"
        if reason is None:
            same += 1
        elif verbose:
            print(f"{name}: {reason}", file=sys.stderr)
    print(f"same: {same}/{len(names)} pictures, max rect delta {worst:g} px")
    return 0 if names and same == len(names) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
