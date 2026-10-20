#!/usr/bin/env python3
"""WCAG contrast of the dialogue text against the lightest pixel of the panel it stands on, measured in the stage PNGs.
Run it isolated: `python3 -I contrast.py [--min 7] <png>...`   Exit 1 when a shot is below --min.

The panel is translucent over the scene, so the worst case is the lightest panel pixel. The two strips read are the padding of the
box that no glyph touches: CSS y 760..784 (above the first line) and 898..920 (below the second), between x 70 and 890; the text
colour is the page's --ink, #f7f4ec, which is what a glyph's solid pixels are. Scale is read from the image (2160 px = 2.25)."""
import argparse
import sys

from PIL import Image

INK = (0xF7, 0xF4, 0xEC)
STRIPS = ((760, 784), (898, 920))      # CSS px rows of the box padding with no text in them
X = (70, 890)


def lin(c):
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def lum(rgb):
    r, g, b = (lin(v) for v in rgb[:3])
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def worst_panel(path):
    im = Image.open(path).convert("RGB")
    k = im.width / 960.0
    best, at = -1.0, None
    for y0, y1 in STRIPS:
        crop = im.crop((int(X[0] * k), int(y0 * k), int(X[1] * k), int(y1 * k)))
        raw = crop.tobytes()
        for px in {tuple(raw[i:i + 3]) for i in range(0, len(raw), 3)}:
            L = lum(px)
            if L > best:
                best, at = L, px
    return best, at


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--min", type=float, default=7.0)
    ap.add_argument("pngs", nargs="+")
    a = ap.parse_args()
    worst, rc = 1e9, 0
    for p in a.pngs:
        Lp, px = worst_panel(p)
        ratio = (lum(INK) + 0.05) / (Lp + 0.05)
        worst = min(worst, ratio)
        if ratio < a.min:
            print("FAIL %s: contrast %.2f:1 < %.1f (lightest panel pixel %s)" % (p, ratio, a.min, px))
            rc = 1
    print("contrast: worst of %d shots %.2f:1 (min %.1f) ink %s %s" % (len(a.pngs), worst, a.min, "#%02x%02x%02x" % INK, "OK" if rc == 0 else "FAIL"))
    return rc


if __name__ == "__main__":
    sys.exit(main())
