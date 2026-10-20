#!/usr/bin/env python3
"""When the lens drew its translation of each line of a live recording, when it settled, and how long the line then stayed: from the
video's own pixels and the app's log. Run it isolated:
`python3 -I settle.py <part>.mp4 <part>.events.jsonl [--log <part>.jsonl] [--hold 1.5] [--per-line]` (record.sh writes all three).

The lens's inside (its rect from the `lens` event, inset 16 pt so the frame's glow is left out) is decoded at 30 fps, a quarter of its
size, grey. Pass 1: a frame is active when its mean absolute difference from the one before is above --threshold; the first active frame
after the recording started is line 1 appearing (or, better, the video's first frame is at the `rec0` epoch); the other lines are due
by the page's own times of their swaps (`line` events) and shown at the first big change (--swap) near that time.
Pass 2: per line, every frame is compared with the line's first frame (the stage's own text, before the lens did anything): the lens drew
the line once that difference passes --drawn (the Japanese covered by Korean; a plate's name alone, or the lens's glow, stays far below).
A drawn line has settled at its last active frame before the next swap; its hold is the time from then to the next swap.
With --log, a line is translated once the log's entries (their `time`: the line's first usable translation) cover logmatch.COVER of its
text; the lens keeps its last picture over a changed box until it reads again, so a change on screen alone is no proof (it can be the
old picture going). Prints `settle: …` and exits 1 when a line was never drawn (with --log: never translated, or on screen less than
--hold s after its translation), or held less than --hold seconds after the lens's last change.
FAILURE MODE IT BLOCKS: a take whose lines change before the lens translated them, or while it is still rewriting them (the film would
show Japanese only, or the lens mid-work)."""
import argparse
import json
import statistics
import subprocess
import sys

import numpy as np

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import logmatch  # noqa: E402

FPS = 30


def frames(video, crop, size):
    w, h, x, y = crop
    cmd = ["ffmpeg", "-v", "error", "-i", video, "-vf", "crop=%d:%d:%d:%d,scale=%d:%d,fps=%d,format=gray" % (w, h, x, y, size[0], size[1], FPS),
           "-f", "rawvideo", "-"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    n = size[0] * size[1]
    try:
        while True:
            buf = proc.stdout.read(n)
            if len(buf) < n:
                break
            yield np.frombuffer(buf, dtype=np.uint8).astype(np.int16)
    finally:                                    # a reader that stops early ends the decoder quietly (no broken-pipe noise)
        if proc.poll() is None:
            proc.kill()
        proc.wait()


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("video")
    ap.add_argument("events")
    ap.add_argument("--hold", type=float, default=1.5, help="the least seconds a line must stay after the lens settled")
    ap.add_argument("--threshold", type=float, default=0.8, help="mean grey-level change of an active frame")
    ap.add_argument("--drawn", type=float, default=3.0, help="mean grey-level difference from the line's first frame once drawn")
    ap.add_argument("--swap", type=float, default=3.0, help="mean grey-level change of the frame where a new line shows")
    ap.add_argument("--log", help="the app's jsonl log of the take: check each line's translation by it")
    ap.add_argument("--per-line", action="store_true")
    args = ap.parse_args(argv)
    ev = [json.loads(l) for l in open(args.events, encoding="utf-8")]
    lens = [float(v) for v in next(e for e in ev if e.get("k") == "lens")["v"].split(",")]
    cw, ch, cx, cy = (int(v) for v in next(e for e in ev if e.get("k") == "rec")["v"].split(":"))
    lines = [(int(e["id"]), int(e["ms"]) / 1000.0) for e in ev if e.get("k") == "line"]
    inset = 16
    x0, y0 = max(0, int(lens[0] * 2 - cx + inset * 2)), max(0, int(lens[1] * 2 - cy + inset * 2))
    w = min(int(lens[2] * 2 - inset * 4), cw - x0) // 8 * 8
    h = min(int(lens[3] * 2 - inset * 4), ch - y0) // 8 * 8
    crop, size = (w, h, x0, y0), (w // 4, h // 4)

    diffs, prev = [], None
    for cur in frames(args.video, crop, size):
        diffs.append(0.0 if prev is None else float(np.abs(cur - prev).mean()))
        prev = cur
    act = [i for i, d in enumerate(diffs) if d > args.threshold]
    if not act or not lines:
        print("settle: no activity in the lens (%d frames) or no line events" % len(diffs))
        return 1
    # Where the page's clock sits in the video: from the first frame's epoch (record.sh's `rec0`), else line 1 appearing (the first
    # active frame; early when the lens drew something over the empty scene first).
    rec0 = next((float(e["v"]) for e in ev if e.get("k") == "rec0" and e.get("v")), None)
    t1 = lines[0][1] - rec0 if rec0 is not None else act[0] / FPS
    # Where each swap should be by the page's clock, and where it shows: the first big change from 0.3 s before that to 2.5 s after it
    # (the lens keeps its last picture over the box until it reads again, so a new line can show up to a second after the page drew it).
    starts = []
    for lid, t in lines:
        due = t1 + (t - lines[0][1])
        seen = [i / FPS for i, d in enumerate(diffs) if d > args.swap and due - 0.3 <= i / FPS <= due + 2.5]
        starts.append((lid, seen[0] if seen else due))
    late = [round(s - (t1 + (t - lines[0][1])), 2) for (_, s), (_, t) in zip(starts, lines)]
    # A line's window starts 0.25 s after its swap shows and ends 0.15 s before the next one does, or before the page drew the next
    # one when the video's clock is known (`rec0`): a stage that changes under the lens at once (stage2's portraits) starts leaving then.
    dues = [t1 + (t - lines[0][1]) for _, t in lines]
    spans = [(lid, a, min(b, dues[k + 1]) if rec0 is not None else b)
             for k, ((lid, a), (_, b)) in enumerate(zip(starts, starts[1:])) if lid]

    first, peak, drawn_at = {}, {}, {}
    k = 0
    for i, cur in enumerate(frames(args.video, crop, size)):
        t = i / FPS
        while k < len(spans) and t >= spans[k][2] - 0.15:
            k += 1
        if k == len(spans):
            break
        lid, a, b = spans[k]
        if t < a + 0.1:
            continue
        if lid not in first:
            first[lid] = cur
            continue
        d = float(np.abs(cur - first[lid]).mean())
        peak[lid] = max(peak.get(lid, 0.0), d)
        if d > args.drawn and lid not in drawn_at:
            drawn_at[lid] = t - a

    shown = {lid: t for lid, t in lines}
    after = {lid: nxt for (lid, _), (_, nxt) in zip(lines, lines[1:])}
    translated = {}
    if args.log:
        texts, speakers = logmatch.load()
        log = sorted(((logmatch.epoch(e["time"]), e["original"]) for e in map(json.loads, open(args.log, encoding="utf-8")) if e.get("time")))
        for lid, _, _ in spans:
            got = []
            for t, original in log:
                if shown[lid] - 0.5 <= t < after[lid] and logmatch.read_of(original, texts[lid]):
                    got.append(original)
                    if logmatch.coverage(got, texts[lid], speakers) >= logmatch.COVER:
                        translated[lid] = t - shown[lid]
                        break
    rows = []
    for lid, a, b in spans:
        inside = [i / FPS for i in act if a + 0.25 <= i / FPS < b - 0.15]
        last = inside[-1] - a if inside else 0.0
        rows.append({"id": lid, "drawn": drawn_at.get(lid), "settled": last, "held": (b - a) - last, "span": b - a,
                     "peak": peak.get(lid, 0.0), "translated": translated.get(lid),
                     "after": None if lid not in translated else after[lid] - shown[lid] - translated[lid]})
    if args.per_line:
        for r in rows:
            print("L%-3d %s settled %5.2f s  held %5.2f s  of %5.2f s  (peak difference %.1f)%s" % (
                r["id"], "drawn %5.2f s" % r["drawn"] if r["drawn"] is not None else "NOT DRAWN   ", r["settled"], r["held"],
                r["span"], r["peak"], "" if not args.log else "  translated %s" % (
                    "NEVER" if r["translated"] is None else "%.2f s, on screen %.2f s after" % (r["translated"], r["after"]))))
    drawn = [r for r in rows if r["drawn"] is not None]
    blank = ["L%d" % r["id"] for r in rows if r["drawn"] is None]
    short = ["L%d %.2f" % (r["id"], r["held"]) for r in drawn if r["held"] < args.hold]
    if drawn:
        slow = max(drawn, key=lambda r: r["settled"])
        worst = min(drawn, key=lambda r: r["held"])
        print("settle: %d lines, %d drawn (median %.2f s after the swap, max %.2f s); settled max %.2f s (L%d); held after it min %.2f s "
              "(L%d); under %.1f s: %s; never drawn: %s" % (
                  len(rows), len(drawn), statistics.median(r["drawn"] for r in drawn), max(r["drawn"] for r in drawn), slow["settled"],
                  slow["id"], worst["held"], worst["id"], args.hold, ", ".join(short) or "none", ", ".join(blank) or "none"))
    else:
        print("settle: %d lines, none drawn by the lens" % len(rows))
    print("swaps shown after the page drew them (s): median %.2f, max %.2f" % (statistics.median(late), max(late)))
    if not args.log:
        return 1 if short or blank else 0
    never = ["L%d" % r["id"] for r in rows if r["translated"] is None]
    brief = ["L%d %.2f" % (r["id"], r["after"]) for r in rows if r["after"] is not None and r["after"] < args.hold]
    done = [r for r in rows if r["after"] is not None]
    print("log: %d of %d lines translated (median %.2f s after the swap, max %.2f s); on screen after it min %.2f s; under %.1f s: %s; "
          "never translated: %s" % (len(done), len(rows), statistics.median(r["translated"] for r in done) if done else 0,
                                    max((r["translated"] for r in done), default=0), min((r["after"] for r in done), default=0),
                                    args.hold, ", ".join(brief) or "none", ", ".join(never) or "none"))
    return 1 if short or never or brief else 0


if __name__ == "__main__":
    sys.exit(main())
