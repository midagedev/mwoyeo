"""fit117: true column edges of a screenshot of a PDF by ink projection (px), for the Preview shots. usage: inkcols.py <png> <w> <h> <y0> <y1> <x0> <x1>"""
import subprocess, sys
import numpy as np
png, w, h, y0, y1, x0, x1 = sys.argv[1], *map(int, sys.argv[2:])
raw = subprocess.run(['magick', png, '-colorspace', 'Gray', '-depth', '8', 'gray:-'], capture_output=True, check=True).stdout
a = np.frombuffer(raw, np.uint8).reshape(h, w)[y0:y1, x0:x1]
ink = a < 110
cols = ink.sum(0)
xs = np.nonzero(cols > 0)[0] + x0
# gaps wider than 40 px split the ink into columns
groups = np.split(xs, np.nonzero(np.diff(xs) > 40)[0] + 1)
for g in groups:
    print('ink x px %d..%d  pt %.1f..%.1f  width %.1f pt' % (g[0], g[-1], g[0] / 2, g[-1] / 2, (g[-1] - g[0]) / 2))
