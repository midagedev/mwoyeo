#!/usr/bin/env python3
"""How much a preview moves, second by second: the numbers that say whether "live" reads (memory rule: motion is judged in
playback, on a 720p/30 fps proxy, not on stills).

  motion.py <proxy.mp4> [--beats 0,a,b,c,end] [--max-still s1,s2,s3,s4]

Per output second: in the lens' rest rect and in the page outside it (the captions' strip left out), the mean absolute luma
change between consecutive frames (0-255, x100) and how many of the 30 frames changed visibly (mean change > 0.25 in the
rect, or any 1 % of its pixels by > 24 levels). Then each beat's sums, and its longest still: the longest run of frames
in which neither the lens nor the page changed visibly (the pointer alone does not count: it moves under 1 % of the page).
Exits 1 when a beat's longest still is over its --max-still (default 2.0 s for the first three beats, 3.0 s for ⌃⌥O, which
holds the original up to read): an autoplaying, muted preview that stands still reads as a picture. The as4 judge called
out the opening (longest still 3.40 s ko, 3.43 s en: FAIL here) and passed stills of <= 0.83 s in the drag and the
scroll and 2.50 s in the ⌃⌥O beat.
Geometry: take.sh's lens (592,591) 490x250 pt in the recorded rect (552,383) 960x540 pt, at 2 px per pt (the 1920x1080
preview), then scaled to 1280. Beats default to the uncut preview's (0, 6, 12, 20, 27 s); cut.sh passes the cut's."""
import subprocess, sys
import numpy as np

W, H = 1280, 720
K = 1280 / 1920                                    # take px -> proxy px
LENS = [round(v * K) for v in (80, 416, 980, 500)]  # x, y, w, h in the proxy
CAPTION_TOP = round(934 * H / 1080)                # the captions' strip starts here
NAMES = ['new messages', 'drag the lens', 'scroll', 'show original']

args = sys.argv[1:]
opt = lambda name, default: [float(v) for v in (args[args.index(name) + 1] if name in args else default).split(',')]
EDGES = opt('--beats', '0,6,12,20,27')
MAX_STILL = opt('--max-still', '2.0,2.0,2.0,3.0')

raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', args[0], '-vf', f'scale={W}:{H},format=gray', '-f', 'rawvideo', '-'],
                     capture_output=True, check=True).stdout
frames = np.frombuffer(raw, np.uint8).reshape(-1, H, W).astype(np.int16)
x, y, w, h = LENS
inside = np.zeros((H, W), bool)
inside[y:y + h, x:x + w] = True
outside = ~inside
outside[CAPTION_TOP:, :] = False

rows = []
for i in range(1, len(frames)):
    d = np.abs(frames[i] - frames[i - 1])
    rows.append([(d[m].mean(), (d[m] > 24).mean()) for m in (inside, outside)])
rows = np.array(rows)                              # frame pair i (frames i, i+1), (lens, page), (mean, share over 24)
seen = (rows[:, :, 0] > 0.25) | (rows[:, :, 1] > 0.01)   # pair, (lens, page): changed visibly

def per_second(s):
    part = slice(max(0, s * 30 - 1), (s + 1) * 30 - 1)
    return rows[part, 0, 0].mean() * 100, int(seen[part, 0].sum()), rows[part, 1, 0].mean() * 100, int(seen[part, 1].sum())

def longest_still(a, b):
    """Longest run of still frame pairs between output seconds a and b, in seconds."""
    run = best = 0
    for moved in (seen[a:b, 0] | seen[a:b, 1]):
        run = 0 if moved else run + 1
        best = max(best, run)
    return best / 30

print(f'frames {len(frames)}, lens rect {LENS} (proxy px)')
print(' s  lens.change  lens.frames  page.change  page.frames')
for s in range(len(frames) // 30):
    lc, lf, pc, pf = per_second(s)
    print(f'{s:2d}  {lc:11.1f}  {lf:11d}  {pc:11.1f}  {pf:11d}')
failed = []
for k, (name, a, b) in enumerate(zip(NAMES, EDGES, EDGES[1:])):
    fa, fb = round(a * 30), min(round(b * 30) - 1, len(rows))
    still = longest_still(fa, fb)
    over = still > MAX_STILL[k]
    if over: failed.append(name)
    print(f'beat {a:5.2f}-{b:5.2f} s {name:14s} lens frames changed {int(seen[fa:fb, 0].sum()):3d}/{fb - fa}, '
          f'mean lens change {rows[fa:fb, 0, 0].mean() * 100:.1f}, longest still {still:.2f} s '
          f'(max {MAX_STILL[k]}){" FAIL" if over else ""}')
print('motion: ' + (f'FAIL ({", ".join(failed)} stands still too long)' if failed else 'PASS'))
sys.exit(1 if failed else 0)
