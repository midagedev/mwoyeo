#!/usr/bin/env python3
"""Is the page under the lens unchanged in a box (an equation)? Compares the box in a frame before the lens exists and in a frame after its Korean settled, allowing a shift of up to
+-3 px (the lens redraws its capture). usage: python3 -I take-compare.py <take.mp4> <t_before> <t_after> <x,y,w,h pt of the box>
prints the mean absolute gray difference at the best shift, the shift, and the share of ink pixels (< 128) that are ink in both."""
import json, subprocess, sys
mp4, t0, t1, box = sys.argv[1], sys.argv[2], sys.argv[3], [float(v) for v in sys.argv[4].split(",")]
info = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", mp4], capture_output=True, text=True).stdout)["streams"][0]
S = info["width"] / 1512.0
x, y, w, h = (int(round(v * S)) for v in box)
pad = 4
def gray(t):
    return subprocess.run(["ffmpeg", "-v", "error", "-ss", t, "-i", mp4, "-frames:v", "1", "-vf", "crop=%d:%d:%d:%d" % (w + 2 * pad, h + 2 * pad, x - pad, y - pad), "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True).stdout
a, b = gray(t0), gray(t1)
W = w + 2 * pad
best = None
for dy in range(-3, 4):
    for dx in range(-3, 4):
        tot = n = 0
        for r in range(pad, pad + h):
            ra = a[r * W + pad: r * W + pad + w]; rb = b[(r + dy) * W + pad + dx: (r + dy) * W + pad + dx + w]
            tot += sum(abs(p - q) for p, q in zip(ra, rb)); n += w
        m = tot / n
        if best is None or m < best[0]: best = (m, dx, dy)
m, dx, dy = best
ink = both = 0
for r in range(pad, pad + h):
    for c in range(pad, pad + w):
        if a[r * W + c] < 128:
            ink += 1; both += b[(r + dy) * W + c + dx] < 160
print("box %s pt: mean gray diff %.2f at shift (%d,%d) px; ink pixels still ink: %.1f %%" % (sys.argv[4], m, dx, dy, 100.0 * both / max(ink, 1)))
