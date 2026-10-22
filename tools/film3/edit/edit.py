#!/usr/bin/env python3
"""Film 3's edit: takes + a plan -> the 1920x1080 / 30 fps film and its 720p proxy. Run isolated: `python3 -I edit.py plan.json` (needs ffmpeg and swiftc).
FAILURE MODES IT BLOCKS: a mark placed by eye (every mark is placed from the box Vision reads for its span on a frame of the take; a span that is not read
stops the edit: `--self-test --missing` shows it); speeded or retimed footage (a clip has no speed, only a start and a length; waits are CUT, joined by a
dissolve); a dissolve over 300 ms; a caption or card text that is not in the plan (the words are the lead's, none is written here).

plan.json:
  {"out": "/tmp/film3/out/mwoyeo-1.1.5-script-26s", "fps": 30,
   "clips": [{"src": "take.mp4", "ss": 4.1, "dur": 1.0, "crop": "1718:966:0:752", "dissolve": 0.25},   # crop = w:h:x:y of the source in pixels; dissolve into this
             {"card": "card.png", "dur": 2.0, "dissolve": 0.25}],                                          # clip from the previous one (s, <= 0.3; 0 = a hard cut)
   "marks": [{"t": 0.3, "dur": 1.8, "src": "take.mp4", "at": 4.4, "crop": "1718:966:0:752", "span": "(츠쿠모)"}],   # t = output seconds; `at` = the source second of a frame
   "captions": [{"t": 0.4, "dur": 5.2, "png": "pill1.png", "x": 96, "y": 72}]}                                    # PNGs from caption.swift"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
W, H = 1920, 1080
MARK = "0xe8c88c"         # the accent of the stage's name plate hairline (film2/stage2/game.html --accent)
MAX_DISSOLVE = 0.3


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8", **kw)
    if r.returncode:
        sys.exit("edit: %s failed:\n%s" % (cmd[0], r.stderr[-1500:]))
    return r.stdout


def build_tool(name, scratch):
    out = os.path.join(scratch, name)
    run(["swiftc", "-O", os.path.join(HERE, name + ".swift"), "-o", out])
    return out


def locate(tool, src, at, crop, span, scratch):
    """The mark's box in OUTPUT pixels: Vision's box of `span` on the source frame at `at`, moved by the clip's crop and scale."""
    frame = os.path.join(scratch, "frame-%s-%.2f.png" % (os.path.basename(src), at))
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "%.3f" % at, "-i", src, "-frames:v", "1", frame])
    box = json.loads(run([tool, frame, span]).strip().splitlines()[0])
    if not box["found"]:
        sys.exit("edit: the span %r is not read on %s at %.2f s: refusing to place a mark by eye" % (span, src, at))
    cw, ch, cx, cy = (int(v) for v in crop.split(":"))
    s = W / cw
    return {"x": round((box["x"] - cx) * s), "y": round((box["y"] + box["h"] * 0.93 - cy) * s), "w": round(box["w"] * s)}


def main():
    argv = sys.argv[1:]
    if not argv:
        sys.exit(__doc__)
    plan = json.load(open(argv[0], encoding="utf-8"))
    fps = plan.get("fps", 30)
    scratch = tempfile.mkdtemp(prefix="film3-edit-")
    tool = build_tool("locate", scratch)
    inputs, chains, labels = [], [], []
    for i, c in enumerate(plan["clips"]):
        d = float(c.get("dissolve", 0))
        if d > MAX_DISSOLVE:
            sys.exit("edit: clip %d dissolves %.2f s; the most is %.1f s" % (i, d, MAX_DISSOLVE))
        if "card" in c:
            inputs += ["-loop", "1", "-framerate", str(fps), "-t", "%.3f" % c["dur"], "-i", c["card"]]
            chains.append("[%d:v]fps=%d,scale=%d:%d,format=yuv420p,setsar=1[c%d]" % (len(labels), fps, W, H, i))
        else:
            cw, ch, cx, cy = (int(v) for v in c["crop"].split(":"))
            inputs += ["-ss", "%.3f" % c["ss"], "-t", "%.3f" % c["dur"], "-i", c["src"]]
            chains.append("[%d:v]fps=%d,crop=%d:%d:%d:%d,scale=%d:%d:flags=lanczos,format=yuv420p,setsar=1[c%d]" % (len(labels), fps, cw, ch, cx, cy, W, H, i))
        labels.append("c%d" % i)
    # the sequence: a dissolve where asked (xfade), a hard cut (concat) elsewhere
    cur, elapsed = labels[0], plan["clips"][0]["dur"]
    for i in range(1, len(labels)):
        d = float(plan["clips"][i].get("dissolve", 0))
        nxt = "s%d" % i
        if d:
            chains.append("[%s][%s]xfade=transition=fade:duration=%.3f:offset=%.3f,format=yuv420p[%s]" % (cur, labels[i], d, elapsed - d, nxt))
            elapsed += plan["clips"][i]["dur"] - d
        else:
            chains.append("[%s][%s]concat=n=2:v=1:a=0[%s]" % (cur, labels[i], nxt))
            elapsed += plan["clips"][i]["dur"]
        cur = nxt
    # marks: stepped underline, 240 ms left to right, held, out
    for k, m in enumerate(plan.get("marks", [])):
        b = locate(tool, m["src"], m["at"], m["crop"], m["span"], scratch)
        steps, t0, t1 = 6, m["t"], m["t"] + m["dur"]
        out = "m%d" % k
        for j in range(1, steps + 1):
            a, z = t0 + 0.24 * (j - 1) / steps, (t0 + 0.24 * j / steps) if j < steps else t1
            chains.append("[%s]drawbox=x=%d:y=%d:w=%d:h=3:color=%s:t=fill:enable='between(t,%.3f,%.3f)'[%s%d]"
                          % (cur, b["x"], b["y"], round(b["w"] * j / steps), MARK, a, z, out, j))
            cur = "%s%d" % (out, j)
    for k, c in enumerate(plan.get("captions", [])):
        idx = len([x for x in inputs if x == "-i"])
        inputs += ["-loop", "1", "-framerate", str(fps), "-t", "%.3f" % c["dur"], "-i", c["png"]]
        chains.append("[%d:v]format=rgba,fade=t=in:st=0:d=0.2:alpha=1,fade=t=out:st=%.3f:d=0.2:alpha=1,setpts=PTS+%.3f/TB[cap%d]" % (idx, c["dur"] - 0.2, c["t"], k))
        chains.append("[%s][cap%d]overlay=x=%d:y=%d:format=auto:eof_action=pass[o%d]" % (cur, k, c["x"], c["y"], k))
        cur = "o%d" % k
    out = plan["out"]
    os.makedirs(os.path.dirname(out), exist_ok=True)
    fc = ";".join(chains)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *inputs, "-filter_complex", fc + ";[%s]null[final]" % cur, "-map", "[final]", "-r", str(fps),
         "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out + ".mp4"])
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", out + ".mp4", "-vf", "scale=1280:720:flags=lanczos", "-r", "30", "-c:v", "libx264",
         "-preset", "fast", "-crf", "26", "-pix_fmt", "yuv420p", "-movflags", "+faststart", out + "-720p.mp4"])
    dur = run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", out + ".mp4"]).strip()
    print("edit: %s.mp4 (%s s, %dx%d, %d fps) and %s-720p.mp4" % (out, dur, W, H, fps, out))


main()
