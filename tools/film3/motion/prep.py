#!/usr/bin/env python3
"""film3-motion prep: film.json -> <work>/data.js (everything the page needs) + the takes' frames. Run isolated: `python3 -I prep.py [film.json]`.
Needs ffmpeg, swiftc, node, numpy and PIL. What it measures instead of typing (FAILURE MODES IT BLOCKS):
- a mark placed by eye: every mark is Vision's box of the marked word inside its span on a frame of the take (locate.swift); a span not read stops prep;
- a callout word that is not the log's: each marked word must be a wrong form (count-terms.py TERMS) found in the before log, and its term an
  established form found in the after log; the 0/5 -> 5/5 counter is count-terms.py's own "wrong raw" count of the two logs;
- a connector to a term the script does not change: pair -> mark links are made by running the pairs in the script's order on the marked spans;
- a callout away from its word: each margin note sits on the row of its word (rows = the ink lines read on the frame); the page reports overlap;
- an equation box drawn by eye: the take's boxes come from film3; the placeholder's are the ink rows that the translation left byte-identical."""
import ast
import json
import os
import re
import shutil
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8", **kw)
    if r.returncode:
        sys.exit("prep: %s failed:\n%s" % (cmd[0], (r.stderr or r.stdout)[-1500:]))
    return r.stdout


def path(p):
    return p if os.path.isabs(p) else os.path.join(ROOT, p)


def crop_vf(crop):
    """A take's optional crop [x, y, w, h] in take px (a whole-screen take -> the part the frame shows), as an ffmpeg filter prefix."""
    return ("crop=%d:%d:%d:%d," % (crop[2], crop[3], crop[0], crop[1])) if crop else ""


def frame_at(take, t, out, crop=None):
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "%.3f" % t, "-i", take, "-vf", crop_vf(crop) + "null", "-frames:v", "1", out])
    return out


def extract(take, t0, t1, fps, out_dir, crop=None):
    """Frames of `take` from second t0 to t1 at the film's rate: <out_dir>/00000.jpg is the take at t0."""
    if os.path.isdir(out_dir):
        shutil.rmtree(out_dir)
    os.makedirs(out_dir)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "%.3f" % t0, "-i", take, "-t", "%.3f" % (t1 - t0), "-vf", crop_vf(crop) + "fps=%d" % fps,
         "-q:v", "2", "-start_number", "0", os.path.join(out_dir, "%05d.jpg")])
    n = len([f for f in os.listdir(out_dir) if f.endswith(".jpg")])
    w, h = Image.open(os.path.join(out_dir, "00000.jpg")).size
    return {"dir": out_dir, "t0": t0, "n": n, "w": w, "h": h}


def lens_box(png):
    """The lens frame: the saturated (rainbow) border's rows and columns."""
    a = np.asarray(Image.open(png).convert("RGB")).astype(int)
    sat = (a.max(2) - a.min(2)) > 60
    rows = np.nonzero(sat.sum(1) > 200)[0]
    cols = np.nonzero(sat.sum(0) > 200)[0]
    if not len(rows) or not len(cols):
        sys.exit("prep: no lens border on %s" % png)
    return [int(cols.min()), int(rows.min()), int(cols.max() - cols.min() + 1), int(rows.max() - rows.min() + 1)]


def ink_lines(png, box, inset=14):
    """Ink lines inside the lens: [y0, y1, x0, x1] per run of rows that hold dark glyph pixels."""
    x, y, w, h = box
    a = np.asarray(Image.open(png).convert("L")).astype(int)[y + inset:y + h - inset, x + inset:x + w - inset]
    ink = a < 120
    rows = ink.sum(1) > 2
    out, i = [], 0
    while i < len(rows):
        if rows[i]:
            s = i
            while i < len(rows) and rows[i]:
                i += 1
            if i - s >= 8:
                cols = np.nonzero(ink[s:i].any(0))[0]
                out.append([y + inset + s, y + inset + i, x + inset + int(cols.min()), x + inset + int(cols.max())])
        i += 1
    return out


def locate(tool, png, spans):
    rows = [json.loads(l) for l in run([tool, png] + ["%s::%s" % (s[0], s[1]) for s in spans]).strip().splitlines()]
    for r, s in zip(rows, spans):
        if not r["found"]:
            sys.exit("prep: %r (in %r) is not read on %s: refusing to place a mark by eye" % (s[1], s[0], png))
    return rows


def snap_left(png, m, line):
    """Vision's box of a word inside a line can start a few px early (on the space or the period before it): move the mark's left edge to the
    first glyph column after a white gap (a word start) within 30 px of Vision's edge."""
    a = np.asarray(Image.open(png).convert("L")).astype(int)[line[0]:line[1]]
    ink = (a < 120).any(0)
    x0, right = int(round(m["x"])), m["x"] + m["w"]
    best = None
    for c in range(max(line[2], x0 - 30), x0 + 31):
        if ink[c] and not ink[max(0, c - 5):c].any() and (best is None or abs(c - x0) < abs(best - x0)):
            best = c
    if best is not None:
        m["x"], m["w"] = float(best), right - best
    return m


def bar_under(png, m, line, style, keep=(2, 3), pad=5):
    """The marker bar under a marked word, [top row, height] in take px. It sits style["bar_gap"] px under the word's own ink, style["bar_h"]
    px tall, when the rows below are free; where the next line comes closer (the final takes set lines 7-13 px apart), it thins (>= 3 px) and
    centres in the blank rows, >= keep[0] px under the word and >= keep[1] px over the next ink. The columns are the bar's own (word +- pad)."""
    a = np.asarray(Image.open(png).convert("L")).astype(int)
    ink = (a[:, max(0, int(m["x"]) - pad):int(m["x"] + m["w"]) + pad + 1] < 120).any(1)
    wb = max(r for r in range(line[0], line[1]) if ink[r]) + 1            # the first blank row under the word
    nt = next((r for r in range(wb, min(len(ink), wb + 60)) if ink[r]), wb + 60)
    gap, g, h = nt - wb, style["bar_gap"], style["bar_h"]
    if gap - g - h >= keep[1]:
        return [wb + g, h]
    h = min(h, max(3, gap - keep[0] - keep[1]))
    top = wb + max(keep[0], (gap - h) // 2)
    if top + h >= nt:
        sys.exit("prep: no room for the marker bar under %r (%d blank rows before the next line)" % (m["part"], gap))
    return [top, h]


def band_over(m, ref, pad=5):
    """The soft band behind a marked word, [top row, bottom row) in take px: from `pad` px over its line (never over the line above, nor
    over a marker bar under that line's words) down to its own marker bar."""
    k, x0, x1 = m["lineIndex"], m["x"] - pad, m["x"] + m["w"] + pad
    limit = ref["lines"][k - 1][1] if k > 0 else 0
    for o in ref["marks"]:
        if o["lineIndex"] == k - 1 and o["x"] - pad < x1 and o["x"] + o["w"] + pad > x0:
            limit = max(limit, o["bar"][0] + o["bar"][1])
    return [max(ref["lines"][k][0] - pad, limit + 2), m["bar"][0]]


def terms_table(count_terms):
    src = open(count_terms, encoding="utf-8").read()
    node = next(n for n in ast.parse(src).body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "TERMS")
    return ast.literal_eval(node.value)


def log_text(log):
    return " ".join(json.loads(l)["translation"] for l in open(log, encoding="utf-8") if l.strip())


def wrong_raw(count_terms, script, log):
    out = run(["python3", "-I", count_terms, script, "/tmp", "--log", log])
    row = next(l for l in out.splitlines() if l.startswith("all "))
    n, raw = (int(v) for v in row.split()[1:3])
    return n, raw, out


def equations_by_diff(en, ko, min_h=14):
    """Placeholder only: per page column, the runs of ink rows (white gaps < 9 px: a sum's limits stay with it) whose pixels the translation left
    unchanged = display equations the reader kept. A changed row (prose) ends a run."""
    a = np.asarray(en.convert("L")).astype(int)
    b = np.asarray(ko.convert("L")).astype(int)
    inkcols = (a < 140).sum(0)
    mid = slice(a.shape[1] // 3, 2 * a.shape[1] // 3)
    white = np.nonzero(inkcols[mid] == 0)[0] + a.shape[1] // 3
    split = int(np.median(white)) if len(white) else a.shape[1]
    out = []
    for c0, c1 in ((0, split), (split, a.shape[1])):
        ca, cb = a[:, c0:c1], b[:, c0:c1]
        ink = (ca < 140).any(1)
        same = (np.abs(ca - cb) < 24).all(1)
        # runs of rows that are white or unchanged ink, white gaps < 9 px; a changed ink row ends a run
        i = 0
        while i < len(ink):
            if not (ink[i] and same[i]):
                i += 1
                continue
            s, j, last = i, i, i
            while j < len(ink) and j - last < 9 and (same[j] or not ink[j]):
                if ink[j]:
                    last = j
                j += 1
            e, i = last + 1, j
            if e - s >= min_h:
                cols = np.nonzero((ca[s:e] < 140).any(0))[0]
                if cols[-1] - cols[0] > 120:
                    out.append([int(c0 + cols[0]), int(s), int(cols[-1] - cols[0] + 1), int(e - s)])
    return out


def ruby_room(png, ref, font_px, margin, inset=14):
    """M2: room for the replaced word written small above its new word (ruby) in the after take's lens. Per marked line: the band of rows above it
    that is blank across the whole lens interior (a row with > 2 pixels off the row's own background colour by > 40 ends it), the box of what
    ends the band (the previous ink line; for the first line, the lens's own chrome above it), the cut (the band's middle row: the lens is split
    there into strips) and the opening the strip below needs so that the ruby (font_px x 1.15 tall) has `margin` px above and below it. When the
    previous line carries a mark, its marker bar (prep's bar_under, drawn by film.html) is part of what is above."""
    x, y, w, h = ref["lens"]
    a = np.asarray(Image.open(png).convert("RGB")).astype(int)
    inner = a[:, x + inset:x + w - inset]
    bg = np.median(inner, axis=1, keepdims=True)
    busy = (np.abs(inner - bg).max(2) > 40).sum(1) > 2
    need = int(round(font_px * 1.15)) + 2 * margin
    cuts = []
    for k in sorted({m["lineIndex"] for m in ref["marks"]}):
        top = ref["lines"][k][0]
        r = top - 1
        while r > 0 and not busy[r]:
            r -= 1
        band = top - 1 - r                                 # blank rows between what ends the band (row r) and the line
        if k > 0 and ref["lines"][k - 1][0] <= r <= ref["lines"][k - 1][1] + 3:
            l = ref["lines"][k - 1]                        # the previous line's text box, down to its last anti-aliased row (and its marker bar)
            bottom = max(l[1], r + 1)
            bottom = max([bottom] + [m["bar"][0] + m["bar"][1] for m in ref["marks"] if m["lineIndex"] == k - 1])
            above = [l[2], l[0], l[3] - l[2] + 1, bottom - l[0]]
        else:                                              # the lens chrome (border, header pill) above the first line
            rows = np.nonzero(busy[max(0, r - 60):r + 1])[0] + max(0, r - 60)
            cols = np.nonzero((np.abs(a[rows.min():r + 1, x:x + w] - np.median(a[rows.min():r + 1, x:x + w], axis=1, keepdims=True)).max(2) > 40).any(0))[0] + x
            above = [int(cols.min()), int(rows.min()), int(cols.max() - cols.min() + 1), int(r + 1 - rows.min())]
        # the cut: the band's middle row, kept clear of the lens's rounded top corners (radius ~22 px) and of anti-aliased glyph tops
        row = min(max(r + 1 + band // 2, y + 20), top - 3)
        clear = top - (above[1] + above[3])               # rows between what is above and the line (negative: a marker bar reaches into it)
        cuts.append({"line": k, "band": [int(r + 1), int(top)], "row": int(row), "open": max(0, need - clear), "above": above,
                     "aboveLine": k - 1 if k > 0 and above[1] == ref["lines"][k - 1][0] else -1})
    # the lens grows by the openings over the page below it: its bottom border must land in a gap between the page's lines, never across one
    # (a line half under the border reads as a glitch). The extra is shared out over the openings (more air above each ruby, even spacing).
    page = a[:, x:x + w]
    blank = (np.abs(page - np.median(page, axis=1, keepdims=True)).max(2) > 40).sum(1) <= 2
    grow = sum(c["open"] for c in cuts)
    snap = next(d for d in range(grow, grow + 160) if blank[y + h + d - 4:y + h + d + 15].all())
    for i, c in enumerate(cuts):
        c["open"] += (snap - grow) // len(cuts) + (1 if i < (snap - grow) % len(cuts) else 0)
    return {"font_px": font_px, "margin": margin, "need": need, "x0": x - 10, "x1": x + w + 10, "bottom": y + h + 10, "cuts": cuts, "grow": int(snap)}


def equation_room(ko, boxes, cap=40):
    """Per equation box, the white rows above and below it in the Korean image (within the box's columns, up to `cap`): the outline's padding
    and the tag's side are chosen from them, so neither ever crosses the prose around the equation."""
    b = np.asarray(ko.convert("L")).astype(int)
    out = []
    for x, y, w, h in boxes:
        ink = (b[:, x:x + w] < 140).any(1)
        up = next((k for k in range(1, cap + 1) if y - k < 0 or ink[y - k]), cap + 1) - 1
        down = next((k for k in range(cap) if y + h + k >= len(ink) or ink[y + h + k]), cap)
        out.append([int(up), int(down)])
    return out


def is_hangul(c):
    return 0xAC00 <= ord(c) <= 0xD7A3


def editor_layout(gray, script, box, x0, adv, ink_at=140):
    """The editor's layout on the final typed frame: its ink lines, the Hangul advance (Latin is `adv`, the editor is monospace; the Hangul
    fallback font is not) and every character's cell [line, x0, x1] (None for a newline). Each visual line runs from x0 to the character whose
    cell holds the line's right ink end; a space at a soft wrap is hidden at the line's end. The Hangul advance is the one, among those that
    lay out every line, whose cell boundaries cross the least ink."""
    bx, by, bw, bh = box
    ink = gray > ink_at
    reg = ink[by:by + bh, bx:bx + bw]
    rows = reg.sum(1) > 0
    lines, i = [], 0
    while i < len(rows):
        if rows[i]:
            s = i
            while i < len(rows) and rows[i]:
                i += 1
            cols = np.nonzero(reg[s:i].any(0))[0]
            lines.append([by + s, by + i, bx + int(cols.min()), bx + int(cols.max()) + 1])
        i += 1

    def solve(h):
        cells, p = [None] * len(script), 0
        for li, (_, _, _, ix1) in enumerate(lines):
            x, q, best = x0, p, None
            while q < len(script) and script[q] != "\n":
                a = h if is_hangul(script[q]) else adv
                cells[q] = [li, x, x + a]
                if script[q] != " " and x + 2 <= ix1 <= x + a + 2:
                    best = q
                x, q = x + a, q + 1
            if best is None:
                return None
            for k in range(best + 1, len(script)):
                cells[k] = None
            nxt = best + 1
            if nxt < len(script) and script[nxt] == " ":
                cells[nxt] = [li, cells[best][2], cells[best][2] + adv]
            p = nxt + 1 if nxt < len(script) and script[nxt] in " \n" else nxt
        return cells if p >= len(script) else None

    best = None
    for h in np.arange(20.0, 25.0, 0.01):
        cells = solve(float(h))
        if cells is None:
            continue
        cost = sum(int(ink[lines[c[0]][0]:lines[c[0]][1], int(round(c[2])) - 1:int(round(c[2])) + 1].sum()) for c in cells if c)
        if best is None or cost < best[0]:
            best = (cost, float(h), cells)
    if best is None:
        sys.exit("prep: the editor's lines on the final typed frame are not the script laid out at %d px per character" % adv)
    empty = [i for i, c in enumerate(best[2]) if c and script[i] != " " and
             not ink[lines[c[0]][0]:lines[c[0]][1], int(round(c[1])) + 1:int(round(c[2])) - 1].any()]
    if empty:
        sys.exit("prep: %d characters of the script have no ink in their cell on the final typed frame (first %r)" % (len(empty), script[empty[0]]))
    return lines, round(best[1], 2), [[c[0], round(c[1], 1), round(c[2], 1)] if c else None for c in best[2]]


def typed_count(gray, final, script, cells, lines, ink_at=140):
    """How many characters a typing frame shows (its prefix in the final layout), and how many pixels of the editor differ from the final frame
    with the rest hidden (0 when the frame is exactly that prefix; a frame the editor re-wrapped differs by hundreds)."""
    n = 0
    for i, c in enumerate(script):
        if cells[i] is None or c == " ":
            n = i + 1
            continue
        li, a, b = cells[i]
        y0, y1 = lines[li][:2]
        f = final[y0:y1, int(round(a)):int(round(b))] > ink_at
        if f.sum() and ((gray[y0:y1, int(round(a)):int(round(b))] > ink_at) & f).sum() >= 0.6 * f.sum():
            n = i + 1
        else:
            break
    while n > 0 and script[n - 1] in " \n":
        n -= 1
    return n


def hide_after(final, cells, lines, n, bg):
    e = final.copy()
    for c in cells[n:]:
        if c:
            e[lines[c[0]][0] - 3:lines[c[0]][1] + 3, int(np.floor(c[1])):int(np.ceil(c[2]))] = bg
    return e


def ui_take(U, frame_crop, script, tool, work, fps):
    """M4: the UI take. The lens menu (a patch over frame B), the settings window's states, the editor while the script is typed, the Run switch.
    FAILURE MODES IT BLOCKS: a typed frame whose text sits elsewhere than in the final layout (the editor re-wraps while typing: such frames are
    dropped, never masked), a character shown before it is typed (a film frame shows a take frame with n >= the typed count and hides the rest
    by the final layout's cells, so the take must hold a valid frame at every n it needs), a click ring placed by eye (Vision's box of the
    control's label), a menu patch placed by eye (the menu is where the take with the menu open differs from it closed)."""
    take, out = U["take"], os.path.join(work, "ui")
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(os.path.join(out, "typ"))
    jpg = lambda png, name: Image.open(png).convert("RGB").save(os.path.join(out, name), quality=93)

    # the menu: the take with it open vs closed, in frame B's crop
    M = U["menu"]
    m_png = frame_at(take, M["at"], os.path.join(out, "menu.png"), frame_crop)
    c_png = frame_at(take, M["closed_at"], os.path.join(out, "menu-closed.png"), frame_crop)
    d = np.abs(np.asarray(Image.open(m_png).convert("RGB")).astype(int) - np.asarray(Image.open(c_png).convert("RGB")).astype(int)).max(2) > 20
    rows, cols = np.nonzero(d.sum(1) > 30)[0], np.nonzero(d.sum(0) > 30)[0]
    menu_rect = [int(cols.min()), int(rows.min()), int(cols.max() - cols.min() + 1), int(rows.max() - rows.min() + 1)]
    item = locate(tool, m_png, [[M["click"][1], M["click"][1]]])[0]
    jpg(m_png, "menu.jpg")

    # the window's states
    W = U["window"]
    states = []
    for name, at in U["states"]:
        png = frame_at(take, at, os.path.join(out, name + ".png"), W)
        jpg(png, name + ".jpg")
        states.append(name)
    clicks = []
    for at, state, label in U["clicks"]:
        b = locate(tool, os.path.join(out, state + ".png"), [[label, label]])[0]
        clicks.append([at, states.index(state), round(b["x"] + b["w"] / 2, 1), round(b["y"] + b["h"] / 2, 1)])
    sheet = np.asarray(Image.open(os.path.join(out, U["states"][0][0] + ".png")).convert("RGB")).astype(int)
    vx, vy, vw, vh = U["viewport"]
    vbg = np.median(sheet[vy + 4:vy + vh - 4, vx + 4:vx + 10].reshape(-1, 3), axis=0).astype(int)

    # the editor: the card's frames while the script is typed, one per typed count the take shows
    cx, cy, cw, ch = U["card"]
    card_crop = [W[0] + cx, W[1] + cy, cw, ch]
    raw = os.path.join(out, "raw")
    os.makedirs(raw)
    t0, t1 = U["typing"]
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "%.3f" % t0, "-i", take, "-t", "%.3f" % (t1 - t0), "-vf",
         crop_vf(card_crop) + "fps=%d" % fps, "-start_number", "0", os.path.join(raw, "%05d.png")])
    files = sorted(f for f in os.listdir(raw) if f.endswith(".png"))
    final = np.asarray(Image.open(os.path.join(raw, files[-1])).convert("L")).astype(int)
    lines, hadv, cells = editor_layout(final, script, U["editor"], U["editor_x0"], U["latin_adv"])
    card_rgb = np.asarray(Image.open(os.path.join(raw, files[-1])).convert("RGB")).astype(int)
    ex, ey, ew, eh = U["editor"]
    bg_rgb = np.median(card_rgb[ey:ey + eh, ex + ew - 30:ex + ew].reshape(-1, 3), axis=0).astype(int)
    bg = int(np.median(final[ey:ey + eh, ex + ew - 30:ex + ew]))
    exp, chosen, dropped = {}, {}, []
    for k, f in enumerate(files):
        g = np.asarray(Image.open(os.path.join(raw, f)).convert("L")).astype(int)
        n = typed_count(g, final, script, cells, lines)
        if n == 0:
            chosen.setdefault(0, f)                      # the empty editor (its placeholder): the first frame
            continue
        if n not in exp:
            exp[n] = hide_after(final, cells, lines, n, bg)
        diff = int((np.abs(g[ey:ey + eh, ex:ex + ew] - exp[n][ey:ey + eh, ex:ex + ew]) > 40).sum())
        if diff <= 30:
            chosen[n] = f                                # the last frame at n: settled
        else:
            dropped.append((round(t0 + k / fps, 3), n, diff))
    if len(script) not in chosen:
        sys.exit("prep: no typing frame shows the whole script (%d chars) in the final layout" % len(script))
    # the editor grows by a line as the script's last line lands: the Run row below it moves down. Per kept frame, how far its row sits
    # above the final frame's (the editor/Run separator: the first row under the code that differs from the card's colour)
    def separator(g):
        rows = [y for y in range(lines[-1][0], g.shape[0]) if abs(int(np.median(g[y, ex + 20:ex + ew - 20])) - bg) >= 6]
        if not rows:
            sys.exit("prep: no separator under the editor's code")
        return rows[0]
    sep_final, dy = separator(final), {}
    for n, f in chosen.items():
        jpg(os.path.join(raw, f), "typ/%d.jpg" % n)
        dy[n] = separator(np.asarray(Image.open(os.path.join(raw, f)).convert("L")).astype(int)) - sep_final

    # the Run switch: where the typed frame (off) and the switch-on frame differ; the lower region is the switch, the upper the status word
    on_png = frame_at(take, U["on_at"], os.path.join(out, "on.png"), card_crop)
    jpg(on_png, "on.jpg")
    on = np.asarray(Image.open(on_png).convert("RGB")).astype(int)
    d = np.abs(on - card_rgb).max(2) > 30
    lower = d.copy()
    lower[:ch // 2] = False
    ys, xs = np.nonzero(lower)
    sw = on[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    blue = (sw[..., 2] - sw[..., 0]) > 80
    by_, bx_ = np.nonzero(blue)
    track = [int(xs.min() + bx_.min()), int(ys.min() + by_.min()), int(bx_.max() - bx_.min() + 1), int(by_.max() - by_.min() + 1)]
    tx, ty, tw, th = track
    lum = lambda a: a.mean(2)
    k_on = np.nonzero(lum(on[ty:ty + th, tx:tx + tw]) > 200)
    k_off = np.nonzero(lum(card_rgb[ty:ty + th, tx:tx + tw]) > 200)
    knob_on = [int(tx + k_on[1].min()), int(ty + k_on[0].min()), int(k_on[1].max() - k_on[1].min() + 1), int(k_on[0].max() - k_on[0].min() + 1)]
    knob_off = [int(tx + k_off[1].min()), int(ty + k_off[0].min()), int(k_off[1].max() - k_off[1].min() + 1), int(k_off[0].max() - k_off[0].min() + 1)]
    hexc = lambda v: "#%02x%02x%02x" % tuple(int(x) for x in v)
    toggle = {"track": track, "knob_off": knob_off, "knob_on": knob_on,
              "off": hexc(card_rgb[ty + th // 2, tx + tw - th // 2]), "on": hexc(np.median(sw[blue], axis=0)),
              "knob_off_rgb": hexc(card_rgb[knob_off[1] + knob_off[3] // 2, knob_off[0] + knob_off[2] // 2]),
              "knob_on_rgb": hexc(on[knob_on[1] + knob_on[3] // 2, knob_on[0] + knob_on[2] // 2])}
    # the character count right of the switch: hidden on every typed frame and drawn live (a take frame shows its own n, up to 44 ahead)
    row = final[ty - 10:ty + th + 10, tx + tw + 6:cw - 4]
    ys, xs = np.nonzero(row > 80)
    counter = [int(tx + tw + 6 + xs.min()), int(ty - 10 + ys.min()), int(xs.max() - xs.min() + 1), int(ys.max() - ys.min() + 1)]
    ink = card_rgb[counter[1]:counter[1] + counter[3], counter[0]:counter[0] + counter[2]]
    counter_rgb = np.percentile(ink[ink.mean(2) > 80], 90, axis=0)
    tail = final[counter[1]:counter[1] + counter[3], counter[0] + counter[2] - 10:counter[0] + counter[2]] > 80   # the last "0": no descender
    baseline = int(counter[1] + np.nonzero(tail.any(1))[0].max() + 1)
    shutil.rmtree(raw)

    ns = sorted(chosen)
    info = {"menu": {"rect": menu_rect, "click": [round(item["x"] + item["w"] / 2, 1), round(item["y"] + item["h"] / 2, 1)]},
            "win": {"w": W[2], "h": W[3], "states": states}, "viewport_bg": hexc(vbg), "clicks": clicks,
            "typing": {"ns": ns, "lines": [l[:2] for l in lines], "cells": cells, "hangul_adv": hadv, "bg": hexc(bg_rgb),
                       "font_px": int(np.median([l[1] - l[0] for l in lines])), "dropped": dropped,
                       "counter": counter, "counter_rgb": hexc(counter_rgb), "counter_baseline": baseline, "counter_text": "%d / 8,000" % len(script),
                       "dy": {str(n): int(v) for n, v in dy.items()}},
            "toggle": toggle}
    gaps = max(b - a for a, b in zip(ns, ns[1:]))
    print("prep: UI take: menu %s, item %r at %s; states %s; clicks %s; editor %d lines, Hangul advance %.2f px, typed frames at %d counts "
          "(largest gap %d chars), %d re-wrapped frames dropped (%s); the Run row %s px above its final place until n %d; Run switch track %s, knob %s -> %s, %s -> %s" % (
              menu_rect, M["click"][1], info["menu"]["click"], states, clicks, len(lines), hadv, len(ns), gaps, len(dropped),
              ", ".join("%.2f s n %d diff %d" % x for x in dropped[:1] + dropped[-1:]),
              sorted(set(-v for v in dy.values() if v)), max([n for n, v in dy.items() if v] or [0]), track, knob_off, knob_on, toggle["off"], toggle["on"]))
    return info


def main():
    cfg_path = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "film.json"))
    cfg = json.load(open(cfg_path, encoding="utf-8"))
    work = cfg["work"]
    os.makedirs(work, exist_ok=True)
    fps, tl = cfg["fps"], cfg["timeline"]
    tool = os.path.join(work, "locate")
    if not os.path.exists(tool) or os.path.getmtime(tool) < os.path.getmtime(os.path.join(HERE, "locate.swift")):
        run(["swiftc", "-O", os.path.join(HERE, "locate.swift"), "-o", tool])
    script = path(cfg["script"])
    script_text = open(script, encoding="utf-8").read().rstrip("\n")
    count_terms = path(cfg["count_terms"])

    # the typing's length decides where the whip falls; everything after it is relative to the whip
    type_end = tl["type_start"] + len(script_text) / tl["type_cps"]
    whip = type_end + tl["whip_after_type"]
    end = whip + tl["end_start"] + tl["end_dur"]

    data = {"cfg": cfg, "script": script_text, "whip": round(whip, 4), "duration": round(end, 4)}

    # takes of the paragraph: before (from the transition into the defect beat to the whip) and after (from the whip to the end card)
    B, A = cfg["before"], cfg["after"]
    b_off = B["korean_at"] - tl["defect_xfade"]
    a_off = A["korean_at"] - (whip + tl["after_xfade"])
    data["before"] = extract(B["take"], round(tl["paper_end"] - 0.5 + b_off, 3), round(whip + tl["whip_dur"] + 0.5 + b_off, 3), fps, os.path.join(work, "before"), B.get("crop"))
    data["before"]["off"] = b_off
    data["after"] = extract(A["take"], round(whip - 0.5 + a_off, 3), round(whip + tl["end_start"] + 1.5 + a_off, 3), fps, os.path.join(work, "after"), A.get("crop"))
    data["after"]["off"] = a_off

    refs = {}
    for name, part in (("before", B), ("after", A)):
        png = frame_at(part["take"], part["ref_at"], os.path.join(work, "ref-%s.png" % name), part.get("crop"))
        lens = lens_box(png)
        refs[name] = {"lens": lens, "lines": ink_lines(png, lens), "marks": locate(tool, png, part["spans"])}
        for m in refs[name]["marks"]:
            m["lineIndex"] = next((i for i, l in enumerate(refs[name]["lines"]) if l[0] - 6 <= m["y"] + m["h"] / 2 <= l[1] + 6), -1)
            if m["lineIndex"] < 0:
                sys.exit("prep: the mark %r sits on no ink line of the lens" % m["part"])
            snap_left(png, m, refs[name]["lines"][m["lineIndex"]])
            m["bar"] = bar_under(png, m, refs[name]["lines"][m["lineIndex"]], cfg["marks"])
        for m in refs[name]["marks"]:
            m["hl"] = band_over(m, refs[name])
    data["refs"] = refs

    # callouts: the log's words. The marked word must be a wrong form found in the before log; its established form must be in the after log.
    terms = terms_table(count_terms)
    before_text, after_text = log_text(B["log"]), log_text(A["log"])
    callouts = []
    for mb, ma in zip(refs["before"]["marks"], refs["after"]["marks"]):
        word = mb["part"]
        row = next((t for t in terms if word in t[3]), None)
        if row is None or word not in before_text:
            sys.exit("prep: the marked word %r is not a wrong form of count-terms.py found in the before log" % word)
        right = next((ok for ok in row[2] if ok in after_text and ok == ma["part"]), None)
        if right is None:
            sys.exit("prep: the after mark %r is not an established form of %r found in the after log" % (ma["part"], row[0]))
        callouts.append({"term": row[0], "shown": word, "right": right})
    n_b, raw_b, out_b = wrong_raw(count_terms, script, B["log"])
    n_a, raw_a, out_a = wrong_raw(count_terms, script, A["log"])
    if raw_b != len(callouts) or raw_a != 0:
        sys.exit("prep: count-terms says %d wrong before and %d after; the film marks %d and resolves to 0" % (raw_b, raw_a, len(callouts)))
    data["callouts"] = callouts
    data["counter"] = {"n": n_b, "before_wrong": raw_b, "after_wrong": raw_a}

    # pairs of the script, run in its order on each marked span: the first pair that changes the span is the one the connector links
    pairs = re.findall(r'\["([^"]+)", "([^"]+)"\]', script_text)
    links = []
    for i, (wrong, right) in enumerate(pairs):
        links.append([k for k, m in enumerate(refs["before"]["marks"]) if wrong in m["span"] and
                      next(j for j, (w, _) in enumerate(pairs) if w in m["span"]) == i])
    data["pairs"] = [{"wrong": w, "right": r, "marks": l} for (w, r), l in zip(pairs, links)]
    if sorted(k for l in links for k in l) != list(range(len(callouts))):
        sys.exit("prep: the script's pairs do not reach every mark once: %s" % links)

    # the paper beat (M1)
    P = cfg["paper"]
    if P["placeholder"]:
        x, y, w, h = P["crop"]                             # the page region (a take's crop is its region of the take instead)
        en = Image.open(P["en"]).convert("RGB").crop((x, y, x + w, y + h))
        ko = Image.open(P["ko"]).convert("RGB").crop((x, y, x + w, y + h))
        en.save(os.path.join(work, "paper-en.png"))
        ko.save(os.path.join(work, "paper-ko.png"))
        data["paper"] = {"placeholder": True, "w": w, "h": h, "equations": P["equations"] or equations_by_diff(en, ko)}
        data["paper"]["room"] = equation_room(ko, data["paper"]["equations"])
    else:
        p_off = P["korean_at"] - tl["paper_xfade"]
        data["paper"] = extract(P["take"], round(p_off, 3), round(tl["defect_start"] + 0.5 + p_off, 3), fps, os.path.join(work, "paper"), P.get("crop"))
        data["paper"].update({"placeholder": False, "off": p_off, "equations": P["equations"]})
        if not P["equations"]:
            sys.exit("prep: the paper take needs film3's equation boxes (paper.equations)")
        ko = Image.open(frame_at(P["take"], P["korean_at"] + 1.0, os.path.join(work, "paper-ko.png"), P.get("crop")))
        # film3's boxes are whole pt: a box edge can cut the equation's last ink row (the bracket); grow it over ink it touches (<= 6 px)
        g = np.asarray(ko.convert("L")).astype(int)
        boxes = []
        for x, y, w, h in P["equations"]:
            grow = 0
            while grow < 6 and y + h + grow < g.shape[0] and (g[y + h + grow, x:x + w] < 140).any():
                grow += 1
            boxes.append([x, y, w, h + grow])
        data["paper"]["equations"] = boxes
        data["paper"]["room"] = equation_room(ko, boxes)
        frame_at(P["take"], P["korean_at"] - 0.25, os.path.join(work, "paper-en.png"), P.get("crop"))   # the English under the lens: measure's Korean bands

    # M2: the replaced words above the new ones (ruby), from the after take's reference frame
    data["ruby"] = ruby_room(os.path.join(work, "ref-after.png"), refs["after"], cfg["ruby"]["font_px"], cfg["ruby"]["margin"])

    # M4: the UI take (menu, window, editor, switch); the app icon
    data["ui"] = ui_take(cfg["ui"], B.get("crop"), script_text, tool, work, fps)
    shutil.copyfile(path(cfg["icon"]), os.path.join(work, "icon.png"))

    open(os.path.join(work, "data.js"), "w", encoding="utf-8").write("window.FILM = " + json.dumps(data, ensure_ascii=False, indent=1) + ";\n")
    open(os.path.join(work, "counts.txt"), "w", encoding="utf-8").write("before log\n" + out_b + "after log\n" + out_a)
    print("prep: %d before frames (take %.2f s on), %d after frames (take %.2f s on); script %d chars, typing %.2f-%.2f s at %.1f c/s, whip %.2f s, film %.2f s" % (
        data["before"]["n"], data["before"]["t0"], data["after"]["n"], data["after"]["t0"], len(script_text), tl["type_start"], type_end, tl["type_cps"], whip, end))
    print("prep: lens %s; %d ink lines; marks %s" % (refs["before"]["lens"], len(refs["before"]["lines"]), ", ".join("%s@L%d" % (m["part"], m["lineIndex"]) for m in refs["before"]["marks"])))
    print("prep: callouts %s; count-terms wrong %d -> %d of %d; links %s; paper %s, %d equation boxes" % (
        ", ".join("%s→%s" % (c["shown"], c["right"]) for c in callouts), raw_b, raw_a, n_b, links,
        "PLACEHOLDER" if P["placeholder"] else "take", len(data["paper"]["equations"])))
    print("prep: equation boxes %s, white rows above/below %s" % (data["paper"]["equations"], data["paper"]["room"]))
    print("prep: ruby (M2) font %d px, need %d px; per line [band, cut row, opening]: %s; lens grows %d px (its bottom snapped to a page gap)" % (data["ruby"]["font_px"], data["ruby"]["need"],
          ", ".join("L%d %s %d +%d" % (c["line"], c["band"], c["row"], c["open"]) for c in data["ruby"]["cuts"]), data["ruby"]["grow"]))


main()
