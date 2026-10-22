#!/usr/bin/env python3
"""usage: luma.py <recording.mov> <page.png> <out.txt>
Per frame of a screen recording of resize-hold-checks: the share of the page's text pixels (inside the part of the lens that every step of the check
keeps: page points 10..340 x 10..230) that are still dark on the screen. ~0.3 when the lens draws its translations over erased text, ~1 when the page's
own text shows (a blank lens). Prints the spans where it is high between the first translation drawn and the last frame."""
import subprocess, sys, json
import numpy as np
from PIL import Image
mov, pagepng, out = sys.argv[1:4]
S = 2                      # pixels per point on this display (a Retina screen)
PX, PY = 100, 120          # the page's top-left on the screen, points (ResizeHoldChecks.pageOrigin)
X0, Y0, W, H = 10, 10, 330, 220   # page points
page = np.asarray(Image.open(pagepng).convert('L'))
mask = page[Y0*S:(Y0+H)*S, X0*S:(X0+W)*S] < 110
cw, ch, cx, cy = W*S, H*S, (PX+X0)*S, (PY+Y0)*S
# timestamps of the frames
pts = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'frame=pts_time', '-of', 'csv=p=0', mov], capture_output=True, text=True).stdout.split()
pts = [float(x.strip(',')) for x in pts if x.strip(',')]
proc = subprocess.Popen(['ffmpeg', '-v', 'error', '-i', mov, '-vf', f'crop={cw}:{ch}:{cx}:{cy}', '-vsync', 'passthrough', '-f', 'rawvideo', '-pix_fmt', 'gray', '-'],
                        stdout=subprocess.PIPE)
series = []
n = 0
while True:
    buf = proc.stdout.read(cw*ch)
    if len(buf) < cw*ch: break
    f = np.frombuffer(buf, dtype=np.uint8).reshape(ch, cw) < 110
    d = f.copy()                      # one pixel of slack for the scaling of the window
    d[1:, :] |= f[:-1, :]; d[:-1, :] |= f[1:, :]; d[:, 1:] |= f[:, :-1]; d[:, :-1] |= f[:, 1:]
    series.append(float((d & mask).sum()) / max(1, mask.sum()))
    n += 1
t = pts[:len(series)]
with open(out, 'w') as o:
    for a, b in zip(t, series): o.write(f'{a:.3f} {b:.3f}\n')
s = np.array(series)
# first drop below 0.6 after the page was shown bare (>= 0.9): the first translation drawn
hi = np.where(s >= 0.9)[0]
if len(hi) == 0: print('no bare page frame found'); sys.exit(1)
first = None
for i in range(hi[0], len(s)):
    if s[i] < 0.6: first = i; break
if first is None: print('no translation found'); sys.exit(1)
# the end of the run: the last frame below 0.6 that is followed only by the page closing (take the last frame below 0.6 before the final stretch of frames >= 0.6 or noise)
last = max(i for i in range(first, len(s)) if s[i] < 0.6)
spans = []
i = first
while i <= last:
    if s[i] >= 0.6:
        j = i
        while j <= last and s[j] >= 0.6: j += 1
        spans.append((t[i], t[j-1], j - i, float(s[i:j].max())))
        i = j
    else: i += 1
print(f'frames {len(s)}, first translation at {t[first]:.2f} s, last translated frame at {t[last]:.2f} s, translated level {float(np.median(s[first:last+1])):.2f}')
# a stretch of more than 2 s is the page bare between two sessions of the check (the first lens stopped, the second not yet translating), not a dip
dips = [x for x in spans if x[1] - x[0] <= 2]
print(f'dips (>= 0.6, up to 2 s): {len(dips)}; longer bare stretches: {len(spans) - len(dips)}')
for a, b, k, m in spans: print(f'  {a:.2f}-{b:.2f} s  {(b-a)*1000:.0f} ms  {k} frame(s)  depth {m:.2f}' + ('' if (b - a) <= 2 else '   (bare page between sessions)'))
