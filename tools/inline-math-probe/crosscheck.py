#!/usr/bin/env python3 -I
"""An independent path for the probe's measures (numpy + PIL, no code shared with the Swift side).
usage: crosscheck.py <spans-base.tsv> <pages dir> <dir of read's json> [threshold 170] [window in line heights, 4]
(a) is exact (the probe's own-line cuts plus the neighbours' cuts): a component is cut by the crop exactly when an ink pixel inside it has an 8-neighbour ink pixel outside it, so
    "a > 0 (tol 1)" must equal "some ink pixel pair crosses the border".
(c) is approximate: components are labelled again in a window of four line heights around the crop (BFS), and an intrusion is a
    component with >= 4 pixels in the crop that the span's line does not own: the nearest line (by the centroid's distance to the
    line's middle) among those that share the component's columns owns it; a component longer than 3 or taller than 2.5 line heights
    is no glyph and is nobody's.
(b) is the strict-connectivity share (the dilated one has no second implementation here).
Prints the number of disagreements per measure."""
import sys
import numpy as np
from PIL import Image
from collections import deque

import json
tsv, pages, ocr = sys.argv[1], sys.argv[2], sys.argv[3]
thr = int(sys.argv[4]) if len(sys.argv) > 4 else 170
rows = [l.rstrip("\n").split("\t") for l in open(tsv)]
head, rows = rows[0], rows[1:]
col = {n: i for i, n in enumerate(head)}
cache = {}
WINDOW = float(sys.argv[5]) if len(sys.argv) > 5 else 4.0
lines_of = {}

def page(name):
    if name not in cache:
        cache[name] = np.asarray(Image.open(f"{pages}/{name}.png").convert("L")) < thr
    return cache[name]

def lines(path, name):
    if (path, name) not in lines_of:
        d = json.load(open(f"{ocr}/{path}-{name}.json"))
        lines_of[(path, name)] = [l for para in d["paragraphs"] for l in para]
    return lines_of[(path, name)]

def crosses(ink, x0, y0, x1, y1):
    inside = np.zeros_like(ink); inside[y0:y1, x0:x1] = True
    ink_in = ink & inside
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dx == 0 and dy == 0:
                continue
            # the neighbour of (y, x) at (y-dy, x-dx): ink, and outside the crop
            n_ink = np.roll(np.roll(ink, dy, axis=0), dx, axis=1)
            n_inside = np.roll(np.roll(inside, dy, axis=0), dx, axis=1)
            if (ink_in & n_ink & ~n_inside).any():
                return True
    return False

def label_window(win):
    h, w = win.shape
    lab = np.zeros((h, w), dtype=np.int32)
    n = 0
    for y in range(h):
        for x in range(w):
            if win[y, x] and lab[y, x] == 0:
                n += 1
                lab[y, x] = n
                q = deque([(y, x)])
                while q:
                    cy, cx = q.popleft()
                    for ny in range(max(0, cy - 1), min(h, cy + 2)):
                        for nx in range(max(0, cx - 1), min(w, cx + 2)):
                            if win[ny, nx] and lab[ny, nx] == 0:
                                lab[ny, nx] = n
                                q.append((ny, nx))
    return lab, n

bad_a = bad_c = n_c = bad_b = n_b = 0
for r in rows:
    ink = page(r[col["page"]])
    x0, y0, x1, y1 = map(int, r[col["crop"]].split(","))
    a_swift = r[col["a_cut"]] != "" or r[col["a_cut_foreign"]] != ""
    a_py = crosses(ink, x0, y0, x1, y1)
    if a_swift != a_py:
        bad_a += 1
        print("a differs:", r[col["path"]], r[col["page"]], r[col["text"]], "swift", a_swift, "python", a_py)
    lx, ly, lw, lhh = map(float, r[col["line"]].split(","))
    m = int(WINDOW * lhh)
    wx0, wy0, wx1, wy1 = max(0, x0 - m), max(0, y0 - m), min(ink.shape[1], x1 + m), min(ink.shape[0], y1 + m)
    lab, n = label_window(ink[wy0:wy1, wx0:wx1])
    ys = np.arange(wy0, wy1)[:, None] * np.ones((1, wx1 - wx0))
    all_lines = lines(r[col["path"]], r[col["page"]])
    others = [l for l in all_lines if not (abs(l["x"] - lx) < 0.01 and abs(l["y"] - ly) < 0.01)]
    my_mid = ly + lhh / 2
    foreign = 0
    own = np.zeros(n + 1, dtype=bool)
    for k in range(1, n + 1):
        mask = lab == k
        cy = ys[mask].mean()
        inside = mask[y0 - wy0:y1 - wy0, x0 - wx0:x1 - wx0].sum()
        bw = np.where(mask.any(axis=0))[0]; bh = np.where(mask.any(axis=1))[0]
        glyph = (bw[-1] - bw[0] + 1) <= 3 * lhh and (bh[-1] - bh[0] + 1) <= 2.5 * lhh
        cols = (bw[0] + wx0, bw[-1] + wx0)
        near = [abs(cy - (l["y"] + l["h"] / 2)) for l in others if l["x"] < cols[1] + 1 and l["x"] + l["w"] > cols[0]]
        own[k] = glyph and not (near and min(near) < abs(cy - my_mid))
        if inside >= 4 and not own[k]:
            foreign += 1
    # (b) strict: own components with ink in the crop; their ink inside the crop's rows vs. outside within 0.6 line heights
    rowmask = np.zeros(lab.shape, dtype=np.int8)
    mh = int(round(0.6 * lhh))
    members = set(np.unique(lab[y0 - wy0:y1 - wy0, x0 - wx0:x1 - wx0]).tolist()) - {0}
    members = {k for k in members if own[k]}
    sel = np.isin(lab, list(members)) if members else np.zeros(lab.shape, dtype=bool)
    xs = slice(x0 - wx0, x1 - wx0)
    inn = sel[y0 - wy0:y1 - wy0, xs].sum()
    top = sel[max(0, y0 - mh - wy0):y0 - wy0, xs].sum()
    bot = sel[y1 - wy0:min(lab.shape[0], y1 + mh - wy0), xs].sum()
    b_py = (top + bot) / (inn + top + bot) if inn + top + bot else 0.0
    b_sw = float(r[col["b_strict"]])
    n_b += 1
    if abs(b_py - b_sw) > 0.02:
        bad_b += 1
        print("b differs:", r[col["path"]], r[col["page"]], r[col["text"]], "swift", b_sw, "python", round(b_py, 3))
    c_swift = len([v for v in r[col["c_foreign"]].split(",") if v and int(v) >= 4])
    n_c += 1
    if (c_swift > 0) != (foreign > 0):
        bad_c += 1
        print("c differs:", r[col["path"]], r[col["page"]], r[col["text"]], "swift", c_swift, "python", foreign)
print(f"crosscheck {tsv}: spans={len(rows)} a-disagreements={bad_a} c-disagreements={bad_c}/{n_c} b_strict-disagreements(>0.02)={bad_b}/{n_b}")
