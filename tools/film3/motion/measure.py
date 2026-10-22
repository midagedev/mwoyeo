#!/usr/bin/env python3
"""film3-motion self-check: the motion read in playback terms, from the 720p30 proxy and the page's own per-frame report (probe.json).
Run isolated: `python3 -I measure.py [film.json]`, or `python3 -I measure.py --self-test` (FAIL-first: every check fails on a bad input).
FAILURE MODES IT BLOCKS: a whip that reads as a cut or as nothing (changed pixels per proxy frame), typing outside 18-30 chars/s, a caption
on screen < 2.5 s, a term mark gone < 0.8 s after it is drawn, Korean smaller than 26 px during a hold, anything important within 48 px of
the screen edge, footage on screen < 60 % of the runtime, a runtime outside 34 +- 3 s (addendum M1), and (addendum M2) a replaced word
above its new word that is held < 1.5 s with all five together, touches the line above it or its own word, or is off the word's centre;
(addendum M3) a marker bar drawn over glyph pixels of the footage (the final takes set lines 7-13 px apart), the lens or the Script card
within 48 px of the edge while they rest, and the tally over a caption; (addendum M4) a typed card showing a take frame with fewer characters
than typed (or the empty editor) or a typed count going back, and a term mark covered by the lens menu < 0.8 s after it is drawn;
(addendum M5) the equation's outline drawn only after the prose has turned Korean (or long before), and the English fragment the take
kept (D3, `paper.hide`) on screen outside the caption pill while the paper beat holds."""
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
EDGE, MIN_KO, MIN_CAP, MIN_MARK = 48, 26.0, 2.5, 0.8


def verdict(ok, text):
    print(("PASS " if ok else "FAIL ") + text)
    return ok


# ---- checks (pure: data in, (ok, line) out), so --self-test can feed them bad input
def check_whip(name, pcts, lo=3, hi=6, thr=40.0):
    n = sum(1 for p in pcts if p >= thr)
    return n >= lo and n <= hi, "whip %s: %d proxy frames >= %.0f %% changed (want %d-%d); per frame %s" % (name, n, thr, lo, hi, " ".join("%.0f" % p for p in pcts))


def check_typing(times, lo=18.0, hi=30.0):
    mean = (len(times) - 1) / (times[-1] - times[0])
    win = [sum(1 for x in times if a <= x < a + 1) for a in np.arange(times[0], times[-1] - 1, 0.25)]
    return lo <= mean <= hi and lo <= min(win) and max(win) <= hi, "typing: %d chars, %.2f chars/s mean, every 1 s window %d-%d chars (want all %.0f-%.0f)" % (
        len(times), mean, min(win), max(win), lo, hi)


def check_caption(name, secs):
    return secs >= MIN_CAP, "caption %s on screen %.2f s (want >= %.1f)" % (name, secs, MIN_CAP)


def typing_frames(frames):
    """M4: per probe frame while the card is typed, the take frame it shows (n characters typed in the take) against the characters the film
    has typed: [(f, typed, shown frame's n, why)] for a frame that shows fewer characters than typed, or a typed count that goes back."""
    bad, last = [], 0
    for r in frames:
        n, k = r.get("typed"), r.get("typFrame")
        if n is None:
            continue
        if n < last:
            bad.append((r["f"], n, k, "typed count went back from %d" % last))
        if k is not None and k >= 0 and k < n and k != 0:
            bad.append((r["f"], n, k, "the take frame holds fewer characters"))
        if k == 0 and n > 0:
            bad.append((r["f"], n, k, "the empty editor while typing"))
        last = n
    return bad


def check_typing_frames(bad):
    return not bad, "typing frames: %d film frames show a take frame short of the typed characters or a count going back%s" % (
        len(bad), " (first: frame %d, typed %d, take frame %s: %s)" % bad[0] if bad else "")


def check_mark(name, secs):
    return secs >= MIN_MARK, "mark %s held %.2f s before the next beat (want >= %.1f)" % (name, secs, MIN_MARK)


def check_korean(name, px_min, px_at):
    return px_min >= MIN_KO, "Korean glyph height during %s: %.1f px at 1080p (min, at %.2f s; want >= %.0f)" % (name, px_min, px_at, MIN_KO)


def check_edges(bad):
    return not bad, "edges: %d frame(s) with an important box within %d px of the screen edge%s" % (
        len(bad), EDGE, (": first " + ", ".join("%.2f s %s %s" % b for b in bad[:4])) if bad else "")


def check_ruby_hold(secs, at, need=1.5):
    return secs >= need, "rubies (M2): all five readable together for %.2f s from %.2f s (opacity >= 0.9, on-screen font >= 20 px; want >= %.1f s)" % (secs, at, need)


def check_ruby_clear(bad):
    return not bad, "rubies (M2): %d frame(s) where a ruby touches the previous line's text box (or its marker bar / the lens chrome) or its own new word%s" % (
        len(bad), (": first " + ", ".join("%.2f s ruby %d %s" % b for b in bad[:3])) if bad else "")


def check_ruby_centre(dx):
    return dx <= 2.0, "rubies (M2): centred on the new word's measured box within %.1f px (want <= 2)" % dx


def bars_on_ink(gray, marks, pad=5):
    """Marker bars whose rows (+- 1) hold glyph pixels of the reference frame in the bar's columns: [(word, top, height, ink rows)]."""
    bad = []
    for m in marks:
        top, h = m["bar"]
        x0, x1 = max(0, int(m["x"]) - pad), int(m["x"] + m["w"]) + pad + 1
        rows = [r for r in range(top - 1, top + h + 1) if (gray[r, x0:x1] < 120).any()]
        if rows:
            bad.append((m["part"], top, h, rows))
    return bad


def check_bars(name, bad):
    return not bad, "marker bars on the %s take: %d over glyph pixels%s" % (name, len(bad), (": " + ", ".join("%s rows %d+%d (ink %s)" % (w, t, h, r) for w, t, h, r in bad)) if bad else "")


def ruby_frames(frames, fps):
    """(hold seconds, hold start, clearance failures, max centring error) from the page's per-frame ruby boxes."""
    run = best = 0
    start = best_at = 0.0
    bad, dx = [], 0.0
    hit = lambda a, b: a[0] < b[0] + b[2] and b[0] < a[0] + a[2] and a[1] < b[1] + b[3] and b[1] < a[1] + a[3]
    for r in frames:
        rb = r.get("rubies") or []
        o = r["poses"]["B"]["o"] if r.get("poses") else 1
        font = r.get("rubyFontPx", 0) * (on_screen(r, "B") if r.get("poses") else 1)
        if rb and all(x["o"] >= 0.9 for x in rb) and o >= 0.9 and font >= 20:
            if not run:
                start = r["f"] / fps
            run += 1
            if run > best:
                best, best_at = run, start
        else:
            run = 0
        for i, x in enumerate(rb):
            if x["o"] > 0.05 and o > 0.05:
                for name in ("above", "word"):
                    if hit(x["box"], x[name]):
                        bad.append((r["f"] / fps, i + 1, name))
            if x["o"] > 0.5:
                dx = max(dx, abs((x["box"][0] + x["box"][2] / 2) - (x["word"][0] + x["word"][2] / 2)))
    return best / fps, best_at, bad, dx


def tally_on_caption(frames, fps):
    """Frames where the tally's box and a caption's box intersect (both on screen)."""
    out = []
    for r in frames:
        tb = r.get("tallyBox")
        for name, (x, y, w, h) in r.get("caps", []) if tb else []:
            if x < tb[0] + tb[2] and tb[0] < x + w and y < tb[1] + tb[3] and tb[1] < y + h:
                out.append((r["f"] / fps, name))
    return out


def check_tally(bad):
    return not bad, "tally over a caption: %d frame(s)%s" % (len(bad), (": first %.2f s (%s)" % bad[0]) if bad else "")


def check_outline(eq_at, fade_a, fade_b, lead=0.4, early=1.0):
    """M5: the stroke (0.7 s, expo out: >= 98 % drawn 0.4 s in) is on while the take's lens cross-fades the prose to Korean."""
    ok = fade_a - early <= eq_at <= fade_b - lead
    return ok, ("equation outline drawn while the prose turns Korean: stroke from %.2f s (>= 98 %% drawn by %.2f s), the take's cross-fade %.2f-%.2f s "
                "(want the stroke to start %.1f s before the cross-fade at most, and to be drawn by its end)" % (eq_at, eq_at + lead, fade_a, fade_b, early))


def fragment_frames(frames, fps, a, b, need=0.9):
    """M5: frames in [a, b) where a fragment the take kept in English (paper.hide, the report's screen boxes) is on screen and not inside the
    paper caption's pill at >= `need` opacity. Returns (bad, frames checked)."""
    bad, n = [], 0
    for r in frames:
        t, h = r["f"] / fps, r.get("hide")
        if not (a <= t < b) or not h:
            continue
        n += 1
        pill, o = h.get("pill"), h.get("o", 0.0)
        for x, y, w, hh in h["boxes"]:
            if x + w <= 0 or y + hh <= 0 or x >= 1920 or y >= 1080:
                continue
            if not (pill and o >= need and pill[0] <= x and pill[1] <= y and x + w <= pill[0] + pill[2] and y + hh <= pill[1] + pill[3]):
                bad.append((t, [x, y, w, hh], pill, o))
                break
    return bad, n


def check_fragment(res, a, b):
    bad, n = res
    first = (": first %.2f s box %s, pill %s at %.2f" % bad[0]) if bad else ""
    return n > 0 and not bad, ("English fragment kept by the take (D3) during the paper hold %.2f-%.2f s: %d of %d frame(s) outside the caption pill%s"
                               % (a, b, len(bad), n, first))


def check_footage(share):
    return share >= 0.60, "footage on screen (a take covering >= 20 %% of the frame) %.0f %% of the runtime (want >= 60 %%)" % (share * 100)


def check_runtime(d):
    return 31.0 <= d <= 37.0, "runtime %.2f s (want 34 +- 3)" % d


# ---- instruments
def proxy_change(path):
    """% of pixels whose luma moves > 10 levels from the previous proxy frame."""
    w, h = 1280, 720
    raw = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", path, "-vf", "scale=%d:%d,format=gray" % (w, h), "-f", "rawvideo", "-"],
                         capture_output=True).stdout
    a = np.frombuffer(raw, np.uint8).reshape(-1, h, w).astype(np.int16)
    return [0.0] + [float((np.abs(a[i] - a[i - 1]) > 10).mean() * 100) for i in range(1, len(a))]


def boxes(r):
    out = [("caption " + n, b) for n, b in r.get("caps", [])] + [("chip", b) for b in r.get("chips", [])] + [("tag", b) for b in r.get("tags", [])]
    out += [("mark", b) for b in r.get("marks", [])]
    if r.get("tallyBox"):
        out.append(("tally", r["tallyBox"]))
    if r.get("lensBox"):
        out.append(("lens", r["lensBox"]))
    if r.get("cardBox"):
        out.append(("card", r["cardBox"]))
    return out


def edge_bad(frames, fps, holds=()):
    """Captions, tally, chips and tags on every frame; a mark (glued to a word of the footage) and the Script card are checked while they rest
    (the probe's largest move < 3 px per frame, the renderer's own motion threshold): a word leaving with its page is an exit, not a placement.
    The lens (the paragraph, header pill to bottom) is checked during the tight holds (`holds`: [(from s, to s)]); elsewhere it moves on purpose."""
    bad = []
    for r in frames:
        for name, (x, y, w, h) in boxes(r):
            if name in ("mark", "card") and r.get("disp", 0) >= 3:
                continue
            if name == "lens" and (r.get("disp", 0) >= 3 or not any(a <= r["f"] / fps <= b for a, b in holds)):
                continue
            if w and h and (x < EDGE or y < EDGE or x + w > 1920 - EDGE or y + h > 1080 - EDGE) and x + w > 0 and x < 1920 and y + h > 0 and y < 1080:
                bad.append((r["f"] / fps, name, [x, y, w, h]))
                break
    return bad


def on_screen(r, key, persp=2400.0):
    """screen px per take px: the frame's scale x the camera zoom x the perspective of its z (film.html #world perspective 2400px)."""
    return r["poses"][key]["s"] * r["cam"]["z"] * persp / (persp - r["poses"][key]["z"])


def hangul_height(lines):
    return min(l[1] - l[0] for l in lines)


def paper_glyph(work):
    """The paper beat: the median height of the ink bands the translation changed (Korean prose) in the Korean crop (placeholder: the page vs
    the app's render; take: the take just before its cross-fade vs after it)."""
    a = np.asarray(Image.open(os.path.join(work, "paper-en.png")).convert("L")).astype(int)
    b = np.asarray(Image.open(os.path.join(work, "paper-ko.png")).convert("L")).astype(int)
    ink, changed = (b < 120).sum(1) > 3, (np.abs(a - b) > 24).any(1)
    bands, i = [], 0
    while i < len(ink):
        if ink[i] and changed[i]:
            s = i
            while i < len(ink) and ink[i]:
                i += 1
            if i - s >= 8:
                bands.append(i - s)
        i += 1
    return float(np.median(bands))


def fake_ruby(f, o, box):
    """One probe frame with one ruby (above box ends at y 100, the new word starts at y 150), frame B flat at scale 1, camera 1, font 24."""
    return {"f": f, "poses": {"B": {"s": 1.0, "z": 0, "o": 1}}, "cam": {"z": 1.0}, "rubyFontPx": 24,
            "rubies": [{"o": o, "box": box, "above": [50, 60, 400, 40], "word": [100, 150, 60, 40]}]}


def fake_page():
    """Two ink lines (rows 10-39 and 52-79) 12 blank rows apart, as the final takes set them."""
    g = np.full((100, 100), 255)
    g[10:40, 20:60] = 0
    g[52:80, 10:90] = 0
    return g


def self_test():
    """FAIL-first: each check on an input that must fail, then on one that must pass."""
    cases = [
        (check_whip("x", [3, 12, 30, 35, 20, 5]), False), (check_whip("x", [5, 45, 62, 70, 48, 10]), True),
        (check_whip("x", [50] * 9), False),
        (check_typing([i / 35 for i in range(200)]), False), (check_typing([i / 26 for i in range(200)]), True),
        (check_typing([i / 40 + (2.5 if i >= 100 else 0) for i in range(200)]), False),
        (check_caption("x", 2.0), False), (check_caption("x", 3.1), True),
        (check_mark("x", 0.5), False), (check_mark("x", 1.2), True),
        # M4: the typed card never shows a take frame with fewer characters than typed, and the count never goes back
        (check_typing_frames(typing_frames([{"f": 1, "typed": 8, "typFrame": 8}, {"f": 2, "typed": 9, "typFrame": 8}])), False),
        (check_typing_frames(typing_frames([{"f": 1, "typed": 8, "typFrame": 8}, {"f": 2, "typed": 7, "typFrame": 8}])), False),
        (check_typing_frames(typing_frames([{"f": 1, "typed": 3, "typFrame": 0}])), False),
        (check_typing_frames(typing_frames([{"f": 1, "typed": 0, "typFrame": 0}, {"f": 2, "typed": 9, "typFrame": 12}, {"f": 3, "typed": 12, "typFrame": -1}])), True),
        (check_korean("x", 22.0, 1.0), False), (check_korean("x", 30.0, 1.0), True),
        (check_edges([(1.0, "chip", [20, 300, 200, 40])]), False), (check_edges([]), True),
        (check_edges(edge_bad([{"f": 60, "disp": 0.5, "marks": [[30, 500, 120, 6]]}], 60)), False),
        (check_edges(edge_bad([{"f": 60, "disp": 40.0, "marks": [[30, 500, 120, 6]]}], 60)), True),
        (check_edges(edge_bad([{"f": 60, "disp": 40.0, "tags": [[900, 20, 200, 40]]}], 60)), False),
        (check_edges(edge_bad([{"f": 60, "disp": 0.5, "lensBox": [430, 60, 1500, 800]}], 60, [(0.5, 2.0)])), False),
        (check_edges(edge_bad([{"f": 60, "disp": 0.5, "lensBox": [430, 60, 1500, 800]}], 60, [(1.5, 2.0)])), True),
        (check_edges(edge_bad([{"f": 60, "disp": 0.5, "cardBox": [760, 300, 1128, 500]}], 60)), False),
        (check_edges(edge_bad([{"f": 60, "disp": 9.0, "cardBox": [760, 300, 1128, 500]}], 60)), True),
        (check_footage(0.45), False), (check_footage(0.8), True),
        (check_ruby_hold(1.2, 1.0), False), (check_ruby_hold(1.6, 1.0), True),
        (check_ruby_clear([(1.0, 2, "above")]), False), (check_ruby_clear([]), True),
        (check_ruby_centre(3.5), False), (check_ruby_centre(0.5), True),
        # the instrument itself: a ruby box over the previous line is found, one clear of it is not; a short hold is measured short
        (check_ruby_clear(ruby_frames([fake_ruby(0, 1, [100, 95, 60, 20])], 60)[2]), False),
        (check_ruby_clear(ruby_frames([fake_ruby(0, 1, [100, 120, 60, 20])], 60)[2]), True),
        (check_ruby_hold(*ruby_frames([fake_ruby(f, 1 if f < 60 else 0.3, [100, 120, 60, 20]) for f in range(120)], 60)[:2]), False),
        # M5: an outline that starts after the Korean has landed (the M1 rule) fails, one drawn through the cross-fade passes
        (check_outline(3.30, 2.75, 2.98), False), (check_outline(2.50, 2.75, 2.98), True), (check_outline(1.2, 2.75, 2.98), False),
        (check_fragment(fragment_frames([{"f": 400, "hide": {"boxes": [[530, 850, 222, 46]], "pill": [96, 859, 649, 137], "o": 1.0}}], 60, 6.4, 9.12), 6.4, 9.12), False),
        (check_fragment(fragment_frames([{"f": 400, "hide": {"boxes": [[520, 866, 210, 46]], "pill": [96, 859, 649, 137], "o": 0.6}}], 60, 6.4, 9.12), 6.4, 9.12), False),
        (check_fragment(fragment_frames([{"f": 400}], 60, 6.4, 9.12), 6.4, 9.12), False),
        (check_fragment(fragment_frames([{"f": 400, "hide": {"boxes": [[520, 866, 210, 46]], "pill": [96, 859, 649, 137], "o": 1.0}},
                                         {"f": 410, "hide": {"boxes": [[520, 1100, 210, 46]], "pill": None, "o": 0.0}}], 60, 6.4, 9.12), 6.4, 9.12), True),
        (check_runtime(29.0), False), (check_runtime(34.5), True),
        (check_tally(tally_on_caption([{"f": 60, "tallyBox": [600, 896, 140, 64], "caps": [["resolve", [96, 859, 509, 137]]]}], 60)), False),
        (check_tally(tally_on_caption([{"f": 60, "tallyBox": [621, 896, 140, 64], "caps": [["resolve", [96, 859, 509, 137]]]}], 60)), True),
        # M3: a bar on the next line's glyph tops is found, one in the blank rows is not
        (check_bars("x", bars_on_ink(fake_page(), [{"part": "w", "x": 20, "w": 40, "bar": [52, 6]}])), False),
        (check_bars("x", bars_on_ink(fake_page(), [{"part": "w", "x": 20, "w": 40, "bar": [43, 4]}])), True),
    ]
    ok = True
    for (res, line), want in cases:
        print("self-test %s (expected %s): %s" % ("PASS" if res else "FAIL", "PASS" if want else "FAIL", line))
        ok &= res == want
    print("self-test: %s" % ("all checks fail on bad input and pass on good input" if ok else "A CHECK DID NOT BEHAVE"))
    return ok


def main():
    if "--self-test" in sys.argv:
        sys.exit(0 if self_test() else 1)
    cfg = json.load(open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "film.json"), encoding="utf-8"))
    work, out = cfg["work"], cfg["out"]
    p = json.load(open(os.path.join(work, "probe.json"), encoding="utf-8"))
    s = open(os.path.join(work, "data.js"), encoding="utf-8").read()
    data = json.loads(s[s.index("=") + 1:s.rindex(";")])
    fps, frames, T = p["fps"], p["frames"], p["times"]
    at = lambda t: frames[min(len(frames) - 1, max(0, int(round(t * fps))))]
    ok = True

    print("== motion (the page's own pose per frame)")
    for name, ts, key in (
        ("open: frame A rotateY / rotateX / scale / z", [0.1, 0.4, 0.8, 1.2, 1.6, 2.25, 2.75], "A"),
        ("defect: frame B rotateY", [T["defect"], T["defect"] + 0.35, T["marks"] - 0.5, T["marks"] + 0.1, T["fix"]], "B"),
        ("fix: frame B rotateY (aside)", [T["fix"], T["fix"] + 0.5, T["fix"] + 1.1, T["line1End"] + 1.25], "B"),
        ("fix: Script card rotateY", [T["fix"] + 0.3, T["fix"] + 0.8, T["fix"] + 1.35, T["type"], T["line1End"] + 1.25, T["whip"]], "P"),
        ("whip: frame B rotateY (spring release)", [T["whip"] + k / 30 for k in range(0, 31, 3)], "B")):
        print("  %s: %s" % (name, "  ".join("%.2fs %s" % (t, "/".join(str(at(t)["poses"][key][k]) for k in (("ry", "rx", "s", "z") if key == "A" else ("ry",)))) for t in ts)))
    print("  camera zoom (push-in and dives): %s" % "  ".join("%.2fs %.2f" % (t, at(t)["cam"]["z"]) for t in
          [T["paper"], T["paper"] + 1.75, T["paperEnd"], T["defect"], T["defect"] + 0.6, T["marks"] - 0.4, T["marks"] + 0.1, T["fix"], T["fix"] + 1.0, T["type"],
           T["line1End"] + 1.25, T["whip"], T["whipEnd"], T["easeOut"], T["easeOut"] + 1.5]))

    print("== the proxy (720p, 30 fps): changed pixels per frame")
    proxy = os.path.join(out, "proxy-720p30.mp4")
    ch = proxy_change(proxy)
    np.save(os.path.join(work, "proxy-change.npy"), np.array(ch))
    for name, a, b in (("paper->paragraph", T["paperEnd"], T["defect"]), ("script->paragraph", T["whip"], T["whipEnd"] + 0.05)):
        pcts = ch[int(a * 30):int(b * 30) + 2]
        res, line = check_whip(name, pcts)
        ok &= verdict(res, line)
    for name, a, b in (("paper glide", T["paper"] + 1.8, T["paperEnd"]), ("defect hold", T["marks"] + 0.8, T["fix"]), ("typing", T["type"], T["typeEnd"]),
                       ("resolve hold", T["resolve"] + 1.3, T["easeOut"]), ("final hold", T["easeOut"] + 1.6, T["end"]), ("end card", T["end"] + 1.8, T["stop"] - 0.5)):
        seg = ch[int(a * 30):int(b * 30)]
        print("  hold %-14s %.2f-%.2f s = %.2f s, changed px per frame mean %.2f %%, max %.2f %%" % (name, a, b, b - a, float(np.mean(seg)), float(np.max(seg))))

    print("== typing, captions, marks")
    typed = [r["typed"] for r in frames if r.get("typed") is not None]
    times = []
    last = 0
    for r in frames:
        n = r.get("typed")
        if n is not None and n > last:
            times += [r["f"] / fps] * (n - last)
            last = n
    res, line = check_typing(times)
    ok &= verdict(res, line)
    res, line = check_typing_frames(typing_frames(frames))
    ok &= verdict(res, line)
    for name in ("paper", "defect", "fix", "resolve"):
        secs = sum(1 for r in frames if any(c[0] == name for c in r.get("caps", []))) / fps
        res, line = check_caption(name, secs)
        ok &= verdict(res, line)
    for i in range(len(data["callouts"])):
        drawn = T["marks"] + T["st"] * i + 0.32
        res, line = check_mark("%d %s (before, until the lens menu covers it)" % (i + 1, data["callouts"][i]["shown"]), min(T["fix"], T.get("menu", T["fix"])) - drawn)
        ok &= verdict(res, line)
        flipped = T["resolve"] + T["st"] * i + 0.6 + 0.34
        res, line = check_mark("%d %s (resolved)" % (i + 1, data["callouts"][i]["right"]), T["easeOut"] - flipped)
        ok &= verdict(res, line)
    res = p["frames"][-1].get("tally")
    ok &= verdict(res == data["counter"]["n"], "tally ends at %s/%d (count-terms: %d wrong before, %d after)" % (res, data["counter"]["n"], data["counter"]["before_wrong"], data["counter"]["after_wrong"]))
    ok &= verdict(not p["overlaps"], "margin notes over the paragraph's glyphs: %d" % len(p["overlaps"]))
    for name in ("before", "after"):
        gray = np.asarray(Image.open(os.path.join(work, "ref-%s.png" % name)).convert("L")).astype(int)
        res, line = check_bars(name, bars_on_ink(gray, data["refs"][name]["marks"]))
        ok &= verdict(res, line + " [bars %s]" % " ".join("%d+%d" % tuple(m["bar"]) for m in data["refs"][name]["marks"]))

    print("== legibility")
    hk = hangul_height(data["refs"]["before"]["lines"])
    for name, a, b in (("defect hold", T["marks"], T["fix"]), ("resolve hold", T["resolve"], T["easeOut"]), ("final hold", T["easeOut"] + 1.5, T["end"])):
        seg = [(hk * on_screen(r, "B"), r["f"] / fps) for r in frames[int(a * fps):int(b * fps)]]
        m = min(seg)
        res, line = check_korean(name, m[0], m[1])
        ok &= verdict(res, line + " [Hangul %d take px x frame scale x camera]" % hk)
    hp = paper_glyph(work)
    seg = [(hp * on_screen(r, "A"), r["f"] / fps) for r in frames[int((T["paper"] + 1.75) * fps):int(T["paperEnd"] * fps)]]
    m = min(seg)
    res, line = check_korean("paper glide (%s)" % ("placeholder" if data["paper"]["placeholder"] else "take"), m[0], m[1])
    ok &= verdict(res, line + " [Korean band %.0f px x scale]" % hp)
    if not data["paper"]["placeholder"]:
        xa = T["paper"]
        res, line = check_outline(T["eqAt"][0], xa, xa + cfg["paper"]["xfade_s"])
        ok &= verdict(res, line)
        ha = cfg["paper"]["camera"][-2][0]
        res, line = check_fragment(fragment_frames(frames, fps, ha, T["paperEnd"]), ha, T["paperEnd"])
        ok &= verdict(res, line)
    res, line = check_edges(edge_bad(frames, fps, [(T["marks"] + 0.6, T["fix"]), (T["resolve"], T["easeOut"])]))
    ok &= verdict(res, line)
    res, line = check_tally(tally_on_caption(frames, fps))
    ok &= verdict(res, line)
    ef = [r["editorFont"] for r in frames[int(T["type"] * fps):int(T["typeEnd"] * fps)] if r.get("editorFont")]
    print("  editor font on screen while typing: %.1f-%.1f px" % (min(ef), max(ef)))

    print("== the replaced words above the new ones (M2)")
    hold, hold_at, bad, dx = ruby_frames(frames, fps)
    for res, line in (check_ruby_hold(hold, hold_at), check_ruby_clear(bad), check_ruby_centre(dx)):
        ok &= verdict(res, line)
    rf = [r["rubyFontPx"] * on_screen(r, "B") for r in frames if r.get("rubies") and all(x["o"] >= 0.9 for x in r["rubies"])]
    print("  ruby font on screen while all five show: %.1f-%.1f px; the lens opened by %s take px" % (min(rf), max(rf), data["ruby"]["grow"]))

    print("== runtime and footage")
    share = sum(1 for r in frames if max(r["footage"]["A"], r["footage"]["B"]) >= 0.2) / len(frames)
    res, line = check_footage(share)
    ok &= verdict(res, line)
    res, line = check_runtime(p["duration"])
    ok &= verdict(res, line)
    print("measure: %s" % ("all PASS" if ok else "FAIL above"))
    sys.exit(0 if ok else 1)


main()
