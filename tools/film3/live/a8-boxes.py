#!/usr/bin/env python3
"""A8: the kept (byte-identical) ink runs of a rendered window as boxes, in crop px and in page pt. usage: python3 -I a8-boxes.py <name> <x_pt> <y_pt> (run in the render dir; x/y = the window box origin given to a8-screen.sh)"""
import json, subprocess, sys
name, X, Y = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]); S = 2.6667
def gray(path):
    info = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", path], capture_output=True, text=True).stdout)["streams"][0]
    return info["width"], info["height"], subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True).stdout
w, h, a = gray(name + ".png"); _, _, b = gray(name + "-out.png")
runs = []; run = None
for y in range(h + 1):
    keep = False
    if y < h:
        ra = a[y * w:(y + 1) * w]; rb = b[y * w:(y + 1) * w]
        keep = sum(1 for p in ra if p < 128) > 3 and not any(abs(p - q) > 2 for p, q in zip(ra, rb))
    if keep and run is None: run = y
    if not keep and run is not None:
        if y - run >= 12: runs.append((run, y))
        run = None
for y0, y1 in runs:
    xs = [x for y in range(y0, y1) for x in range(w) if a[y * w + x] < 128]
    x0, x1 = min(xs), max(xs) + 1
    same = all(a[y * w + x] == b[y * w + x] for y in range(y0, y1) for x in range(x0, x1))
    print("%s kept run: crop px x=%d..%d y=%d..%d  page pt x=%.0f..%.0f y=%.0f..%.0f  pixel-identical=%s" % (name, x0, x1, y0, y1, X + x0 / S, X + x1 / S, Y + y0 / S, Y + y1 / S, same))
