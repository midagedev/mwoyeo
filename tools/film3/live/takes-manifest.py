#!/usr/bin/env python3
"""The hand-over of film 3's takes to the motion round: one JSON with, per take, the file, its size and length, the moments in TAKE seconds (from the recorder's own events and a Vision
probe of the lens band: the second the Korean first shows), the app's log and the term counts. Run isolated:
  python3 -I takes-manifest.py <out dir of record-paper.sh> <name> [<name> ...] > takes.json
Moments: lens (the app started), ready (the reader answered), korean_first (Vision reads >= 100 Hangul in the lens band, 0.25 s steps from `lens`), korean_settled (the recorder's own
note), away (the page scrolled off, the cue closed). All relative to the first frame of the take (rec0)."""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REGION = (770, 382, 600, 270)


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8")
    if r.returncode:
        sys.exit("takes-manifest: %s failed: %s" % (cmd[0], r.stderr[-300:]))
    return r.stdout.strip()


def main():
    out, names = sys.argv[1], sys.argv[2:]
    if not names:
        sys.exit(__doc__)
    scratch = tempfile.mkdtemp(prefix="film3-manifest-")
    hangul = os.path.join(scratch, "hangul")
    run(["swiftc", "-O", os.path.join(HERE, "hangul.swift"), "-o", hangul])
    res = {}
    for name in names:
        mp4 = os.path.join(out, name + ".mp4")
        ev = {}
        for line in open(os.path.join(out, name + ".events.jsonl"), encoding="utf-8"):
            e = json.loads(line)
            ev[e["k"]] = e
        rec0 = float(ev["rec0"]["v"])
        dur = float(run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", mp4]))
        dims = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "csv=p=0", mp4])
        w, h = (int(v) for v in dims.split(","))
        rec = ev["rec"]["v"] if "rec" in ev else ""
        x0 = y0 = 0                              # the recorder's crop (px of the 2x capture), else the whole 1512 x 982 pt screen
        if rec.count(":") == 3:
            x0, y0 = (int(v) // 2 for v in rec.split(":")[2:])
        sx = sy = 2.0 if rec.count(":") == 3 else w / 1512.0
        band = "crop=%d:%d:%d:%d" % (REGION[2] * sx, REGION[3] * sy, (REGION[0] - x0) * sx, (REGION[1] - y0) * sy)
        t = ev["lens"]["t"] - rec0 if "lens" in ev else 0.0
        first = None
        png = os.path.join(scratch, "p.png")
        while t < dur:
            subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "%.2f" % t, "-i", mp4, "-frames:v", "1", "-vf", band, png], capture_output=True)
            if os.path.exists(png) and int(run([hangul, png])) >= 100:
                first = round(t, 2)
                break
            t += 0.25
        res[name] = {"file": mp4, "bytes": os.path.getsize(mp4), "seconds": round(dur, 3), "pixels": [w, h], "lens_region_pt": list(REGION), "crop": rec,
                     "moments_s": {k: round(ev[k]["t"] - rec0, 2) for k in ("preview", "lens", "ready", "korean", "away") if k in ev} | {"korean_first": first},
                     "log": os.path.join(out, name + ".jsonl"), "counts": os.path.join(out, name + ".count.txt"), "settings": os.path.join(out, name + ".settings.json")}
    print(json.dumps(res, ensure_ascii=False, indent=1))


main()
