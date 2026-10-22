#!/usr/bin/env python3
"""A8 scoring of one rendered window (screen.sh output): the numbers the lead asked for.
usage: python3 -I a8-score.py <name>... (run in the render dir of a8-screen.sh)     prints one row per window
FAIL-first: on build 786db0a window G (p5 left, eq 7) scores eq_drawn 1 and window D (p6 left, eq 10) scores 0; a build that keeps equation (7) must change G to 0.
  eq_kept    runs of >= 12 px (4.5 pt) of ink rows that the render left byte-identical, taller than text-line fragments: display equations (and rules/figures) kept
  eq_drawn   drawn blocks whose source holds a sign of mathematics and < 6 prose words (score.py's formula_translated) and whose pixels the render changed
  debris     drawn prose blocks whose translation holds 3+ one-letter tokens or a stray symbol (score.py's debris rule)
  frag       drawn prose blocks (>= 6 prose words) that start with a lowercase letter or end without sentence punctuation, not counting the first and last block of the window (cuts at inline math)
  blocks     drawn blocks"""
import importlib.util, json, re, subprocess, sys
spec = importlib.util.spec_from_file_location("score", "/Users/hckim/repo/mwoyeo-wt-film3/tools/paper-bench/score.py"); sc = importlib.util.module_from_spec(spec); spec.loader.exec_module(sc)
def gray(path):
    info = json.loads(subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", path], capture_output=True, text=True).stdout)["streams"][0]
    return info["width"], info["height"], subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True).stdout
def row(name):
    w, h, a = gray(name + ".png"); _, _, b = gray(name + "-out.png")
    r = sc.parse(name + ".out")
    pairs = r["pairs"]
    def changed(x0, y0, x1, y1):
        nn = d = 0
        for y in range(max(0, y0), min(h, y1)):
            ra = a[y * w + max(0, x0): y * w + min(w, x1)]; rb = b[y * w + max(0, x0): y * w + min(w, x1)]
            nn += len(ra); d += sum(1 for p, q in zip(ra, rb) if abs(p - q) > 2)
        return d / max(nn, 1)
    kept = []; run = None
    for y in range(h + 1):
        if y < h:
            ra = a[y * w:(y + 1) * w]; rb = b[y * w:(y + 1) * w]
            keep = sum(1 for p in ra if p < 128) > 3 and not any(abs(p - q) > 2 for p, q in zip(ra, rb))
        else: keep = False
        if keep and run is None: run = y
        if not keep and run is not None:
            if y - run >= 12: kept.append((run, y))
            run = None
    allow = sc.read_allow()
    drawn = r["blocks"]; eq_drawn = deb = frag = 0
    for i, bl in enumerate(drawn):
        s = bl["source"]; x, y, bw, bh = bl["core"]
        t = next((tt for ss, tt in pairs if ss.startswith(s[:30]) or s.startswith(ss[:30])), "")
        if sc.MATH.search(s) and sc.prose_words(s) < 6 and changed(x, y, x + bw, y + bh) > 0.1: eq_drawn += 1
        elif sc.prose_words(s) >= 6:
            one = len(re.findall(r'(?<![\w])[A-Za-zΑ-Ωα-ω](?![\w])', t))
            if one >= 3 or re.search('[€∈°×]', t): deb += 1
            if 0 < i < len(drawn) - 1 and (s[:1].islower() or not re.search(r'[.:;?!)"”]$', s.strip())): frag += 1
    return name, len(kept), eq_drawn, deb, frag, len(drawn)
print("%-4s %8s %8s %6s %5s %6s" % ("win", "eq_kept", "eq_drawn", "debris", "frag", "blocks"))
for n in sys.argv[1:]:
    print("%-4s %8d %8d %6d %5d %6d" % row(n))
