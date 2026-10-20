#!/usr/bin/env python3
"""The stage2 page's numeric checks, on what shoot.mjs captured. Run isolated: python3 -I check.py <check> ...; exit 1 on a failure.
  lines     <game.html> <sequence.json>    the LINES copy in the page is the sequence's (id, speaker, text)
  wrap      <still dir>                    every line was revealed and needs at most two lines in the box (still.json)
  contrast  <still dir> <hide dir> [min]   WCAG contrast of the ink against the lightest panel pixel behind the text and the name (the
                                           hide=text capture of the same lines), and the text's own lightest pixels are the ink itself
                                           (solid glyphs: no glow, no gradient, no tint over the strokes); min 7
  still     <frames dir> [settle]          inside every line, once `settle` s have passed (default 0.45: the reveal is <= 0.39 s), the
                                           pixels of the text block and of the name tag never change from frame to frame
FAILURE MODES IT BLOCKS: a page whose words drifted from the sequence the bench measured; a line that wraps to three and is cut by the
box; a panel too light for the OCR; a glyph drawn with glow or gradient; a background that moves behind the text, so the app sees the
text's pixels change and translates it again."""
import json
import re
import sys

import numpy as np
from PIL import Image

INK = (0xF6, 0xF2, 0xEA)


def lum(rgb):
    def lin(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(float(v)) for v in rgb[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def box(rect, k, im):
    x0, y0 = int(rect["x"] * k), int(rect["y"] * k)
    x1, y1 = int((rect["x"] + rect["w"]) * k + 0.999), int((rect["y"] + rect["h"]) * k + 0.999)
    return np.asarray(im.convert("RGB"), dtype=np.int16)[max(0, y0):y1, max(0, x0):x1]


def lines(html_path, seq_path):
    html = open(html_path, encoding="utf-8").read()
    got = json.loads(re.search(r'<script type="application/json" id="lines">(.*?)</script>', html, re.S).group(1))
    want = [{"id": l["id"], "speaker": l.get("speaker"), "text": l["text"]} for l in json.load(open(seq_path, encoding="utf-8"))["lines"]]
    if got != want:
        bad = [w["id"] for g, w in zip(got, want) if g != w] or ["count %d vs %d" % (len(got), len(want))]
        print("FAIL lines: the page's LINES differ from the sequence at %s" % bad)
        return 1
    print("lines: LINES equal the sequence (%d lines)" % len(want))
    return 0


def wrap(d):
    rows = json.load(open(d + "/still.json"))["rows"]
    bad = [(r["id"], r["lines"]) for r in rows if r["lines"] > 2 or not r["revealed"]]
    for i, n in bad:
        print("FAIL wrap: L%s needs %d lines (the box holds two) or was not revealed" % (i, n))
    print("wrap: %d lines shot, most lines a text needs %d, over two: %d" % (len(rows), max(r["lines"] for r in rows), len(bad)))
    return 1 if bad else 0


def contrast(d, hide, minimum=7.0):
    meta = json.load(open(hide + "/still.json"))   # the lines shot bare; their rects are the same in the full shot
    k = meta["scale"]
    rc, worst, ink_l = 0, 1e9, lum(INK)
    for r in meta["rows"]:
        bare = Image.open("%s/L%s.png" % (hide, r["id"]))
        full = Image.open("%s/L%s.png" % (d, r["id"]))
        for part in ("text", "tag"):
            if part == "tag" and not r["speaker"]:
                continue
            rect = r[part]
            if part == "tag":   # inside the pill's gold edge and round ends: the glass the name stands on
                h = rect["h"]
                rect = {"x": rect["x"] + 0.4 * h, "y": rect["y"] + 0.15 * h, "w": rect["w"] - 0.8 * h, "h": 0.7 * h}
            panel = box(rect, k, bare).reshape(-1, 3)
            lightest = max(map(tuple, np.unique(panel, axis=0)), key=lum)
            ratio = (ink_l + 0.05) / (lum(lightest) + 0.05)
            # the text's lightest pixels: the solid cores of the strokes, which must be the ink and nothing lighter or tinted
            px = box(rect, k, full).reshape(-1, 3)
            core = px[np.argsort([lum(p) for p in px])[-20:]]
            off = int(np.abs(core - np.array(INK)).max())
            worst = min(worst, ratio)
            line = "L%s %-4s contrast %.2f:1 (lightest panel pixel #%02x%02x%02x), stroke cores off the ink by %d" % (
                r["id"], part, ratio, lightest[0], lightest[1], lightest[2], off)
            if ratio < minimum or off > 3:
                print("FAIL contrast: " + line)
                rc = 1
            else:
                print("contrast: " + line)
    print("contrast: worst %.2f:1 (min %.1f) ink #%02x%02x%02x %s" % (worst, minimum, INK[0], INK[1], INK[2], "OK" if rc == 0 else "FAIL"))
    return rc


def still(d, settle=0.45):
    meta = json.load(open(d + "/frames.json"))
    k = meta["scale"]
    groups = {}
    for i, r in enumerate(meta["rows"]):
        if r["local"] >= settle:
            groups.setdefault((r["id"], round(r["t"] - r["local"], 3)), []).append((i, r))
    rc, compared = 0, 0
    for (lid, _), frames in sorted(groups.items()):
        for part in ("text", "tag"):
            if part == "tag" and not frames[0][1]["speaker"]:
                continue
            ref = box(frames[0][1][part], k, Image.open("%s/f%05d.png" % (d, frames[0][0])))
            worst = 0
            for i, r in frames[1:]:
                cur = box(r[part], k, Image.open("%s/f%05d.png" % (d, i)))
                worst = max(worst, int(np.abs(cur - ref).max()) if cur.shape == ref.shape else 255)
                compared += 1
            line = "L%s %-4s %d settled frames, largest pixel change %d" % (lid, part, len(frames), worst)
            if worst:
                print("FAIL still: " + line)
                rc = 1
            else:
                print("still: " + line)
    print("still: %d frame pairs compared, text and name pixels %s" % (compared, "never change" if rc == 0 else "CHANGE"))
    return rc


if __name__ == "__main__":
    c, args = sys.argv[1], sys.argv[2:]
    if c == "lines":
        sys.exit(lines(*args))
    if c == "wrap":
        sys.exit(wrap(*args))
    if c == "contrast":
        sys.exit(contrast(args[0], args[1], *map(float, args[2:])))
    if c == "still":
        sys.exit(still(args[0], *map(float, args[1:])))
    sys.exit("usage: check.py lines|wrap|contrast|still ...")
