#!/usr/bin/env python3
"""Edge profile of a lens capture (UICapture.lensShot: 880 x 680 px at 2x, region's left edge at x = 80 px).

Blocks the failure mode where the glow renders as an opaque hard band of the stroke's width (no blur falloff, the same
value on any backdrop, deaf to the glow opacity) and hides the ring under it.

  profile.py profile <png> [--y ROW] [--x0 X --x1 X]   the profile across the left edge and its metrics
  profile.py compare <a.png> <b.png> [--y --x0 --x1]   two captures of the same lens: dark vs light proves translucency
                                                       (band values differ), resting vs reading the glow's brightness
  profile.py ring <png>                                peak contrast of each crossing around the ring (left, right and
                                                       bottom sides); prints the minimum

Values are the mean of R, G and B per pixel. Background is the median of the first 8 pixels (outside the glow).
Metrics: peak delta (largest |value - background|), band (pixels with delta >= 50 % of the peak: the ring core when the
glow is soft), falloff (pixels from the outermost band pixel outward until delta <= 5); compare adds the halo sum (|delta| summed
over the pixels outside A's band, toward x0: the glow's light).
Run with python3 -I.
"""
import argparse
import sys

import numpy as np
from PIL import Image

X0, X1, Y = 40, 120, 320


def load(path):
    a = np.asarray(Image.open(path).convert("RGB")).astype(float)
    return a.mean(axis=2)


def row(img, y, x0, x1):
    return img[y, x0:x1]


def metrics(v):
    bg = float(np.median(v[:8]))
    d = np.abs(v - bg)
    peak = float(d.max())
    p = int(d.argmax())
    band = np.where(d >= 0.5 * peak)[0] if peak > 0 else np.array([], int)
    first = int(band[0]) if band.size else p
    i = first
    while i > 0 and d[i - 1] > 5:
        i -= 1
    falloff = first - i
    return {"bg": bg, "peak": peak, "peak_at": p, "band": int(band.size), "band_from": first,
            "falloff": falloff, "band_values": v[band] if band.size else np.array([])}


def verdict(m):
    words = []
    if m["falloff"] < 2:
        words.append("no falloff")
    else:
        words.append(f"falloff {m['falloff']} px")
    return ", ".join(words)


def show(name, v, m, x0):
    print(f"{name}: x{x0}..{x0 + len(v)} " + " ".join(f"{int(round(x))}" for x in v))
    print(f"  bg {m['bg']:.0f}  peak delta {m['peak']:.0f} at x{x0 + m['peak_at']}  band(>=50%) {m['band']} px"
          f" from x{x0 + m['band_from']}  falloff {m['falloff']} px  [{verdict(m)}]")


def cmd_profile(a):
    img = load(a.png)
    v = row(img, a.y, a.x0, a.x1)
    m = metrics(v)
    show(a.png.split("/")[-1], v, m, a.x0)
    flat = m["band"] >= 4 and np.ptp(m["band_values"]) <= 3
    print(f"  SUMMARY band {m['band']} falloff {m['falloff']} peak {m['peak']:.0f}"
          f"{'  FLAT (one value across the band: opaque-looking)' if flat else ''}"
          f"{'  NO-FALLOFF' if m['falloff'] < 2 else ''}")


def cmd_compare(a):
    va, vb = row(load(a.a), a.y, a.x0, a.x1), row(load(a.b), a.y, a.x0, a.x1)
    ma, mb = metrics(va), metrics(vb)
    show("A " + a.a.split("/")[-1], va, ma, a.x0)
    show("B " + b_name(a.b), vb, mb, a.x0)
    # Translucency: inside A's band, how far the two captures' values sit apart. An opaque layer has the same value on
    # any backdrop; a translucent one carries the backdrop through.
    lo, hi = ma["band_from"], ma["band_from"] + ma["band"]
    diff = float(np.abs(va[lo:hi] - vb[lo:hi]).max()) if hi > lo else 0.0
    # Halo: the glow's light outside the band (toward x0), as the sum of |value - background| over those pixels.
    ha, hb = (float(np.abs(v[:lo] - m["bg"]).sum()) for v, m in ((va, ma), (vb, mb)))
    print(f"  SUMMARY band-value diff {diff:.0f} ({'opaque' if diff < 3 else 'translucent'})  halo sum A {ha:.0f} B {hb:.0f}"
          f"  peak delta A {ma['peak']:.0f} B {mb['peak']:.0f} (diff {abs(ma['peak'] - mb['peak']):.0f})"
          f"  falloff A {ma['falloff']} B {mb['falloff']}")


def b_name(p):
    return p.split("/")[-1]


def cmd_ring(a):
    img = load(a.png)
    h, w = img.shape
    bg = float(np.median(np.concatenate([img[:8, :8].ravel(), img[-8:, -8:].ravel()])))
    # Region in the capture: x 80..800, y (top-down) 120..520; crossings 12 px either side of the outline.
    peaks = []
    # The corners style draws only brackets: sample its bottom arms (straight, 24..60 px from each bottom corner).
    arms = a.arms or "corners" in a.png.split("/")[-1]
    for y in (range(466, 494, 2) if arms else range(160, 500, 4)):  # sides, clear of the name tag and the corners
        for x in (78, 802):
            peaks.append(np.abs(img[y, x - 12:x + 12] - bg).max())
    for x in (list(range(106, 134, 2)) + list(range(746, 774, 2)) if arms else range(120, 760, 4)):  # bottom
        peaks.append(np.abs(img[522 - 12:522 + 12, x] - bg).max())
    peaks = np.array(peaks)
    print(f"{a.png.split('/')[-1]}: bg {bg:.0f}  crossings {peaks.size}  min contrast {peaks.min():.0f}"
          f"  median {np.median(peaks):.0f}  max {peaks.max():.0f}")
    print(f"  SUMMARY min-contrast {peaks.min():.0f}")


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    for name, args in (("profile", ["png"]), ("compare", ["a", "b"]), ("ring", ["png"])):
        s = sub.add_parser(name)
        for x in args:
            s.add_argument(x)
        s.add_argument("--y", type=int, default=Y)
        s.add_argument("--x0", type=int, default=X0)
        s.add_argument("--x1", type=int, default=X1)
        s.add_argument("--arms", action="store_true", help="ring: sample the corners style's bottom arms")
    a = p.parse_args()
    {"profile": cmd_profile, "compare": cmd_compare, "ring": cmd_ring}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
