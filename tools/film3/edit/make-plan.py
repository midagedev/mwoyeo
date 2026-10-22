#!/usr/bin/env python3
"""Film 3's edit plan from the takes: the moments are MEASURED on the takes (the second the lens's Korean appears = Vision reads Hangul in the lens band), never typed.
Run isolated: `python3 -I make-plan.py --before B.mp4 --after A.mp4 --caps /tmp/film3/caps --out /tmp/film3/out/mwoyeo-1.1.5-script [--ui ui.json] [--crop-pt 500:250]`
then `python3 -I edit.py <out>.plan.json`.
  --before/--after   the take mp4s of live/record-paper.sh (cropped at record time; --crop-pt = the crop's x0:y0 in points, default 500:250; the lens band is REGION 770,382,600,270)
  --caps             a folder with c1.png c2.png c3.png (caption pills) and card.png (end card) made by caption.swift from the lead's words
  --ui               optional JSON [{"src": "ui.mp4", "ss": 3.2, "dur": 2.0, "crop": "w:h:x:y"}, ...]: beat 2's cuts (waits cut, no speed), joined by dissolves
Timeline (the board): beat 1 = the English under the lens for 1.0 s, then the Korean with its wrong terms, marks under the five spans; beat 2 = the --ui cuts; beat 3 = the same
paragraph with the script, marks under the replacements; the end card."""
import argparse
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
BEFORE_SPANS = ["제어 및", "컨트롤이며", "컨트롤이 표시", "제어가 35", "사인 테스트는"]
AFTER_SPANS = ["대조군 및", "대조군이며", "대조군이 표시", "대조군이 35", "부호 검정은"]
REGION = (770, 382, 600, 270)


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8")
    if r.returncode:
        sys.exit("make-plan: %s failed:\n%s" % (cmd[0], r.stderr[-800:]))
    return r.stdout.strip()


def korean_at(take, band, hangul, scratch, start, minko=100, step=0.5, limit=240.0):
    """The first take second (multiple of `step`) at which Vision reads >= minko Hangul in the lens band."""
    w, h, x, y = band
    t = start
    png = os.path.join(scratch, "probe.png")
    while t < limit:
        r = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-ss", "%.2f" % t, "-i", take, "-frames:v", "1", "-vf", "crop=%d:%d:%d:%d" % (w, h, x, y), png],
                           capture_output=True)
        if r.returncode or not os.path.exists(png):
            break
        if int(run([hangul, png])) >= minko:
            return t
        t += step
    sys.exit("make-plan: no Korean (>= %d Hangul) in the lens band of %s before %.0f s" % (minko, take, t))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--before", required=True)
    ap.add_argument("--after", required=True)
    ap.add_argument("--caps", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--ui")
    ap.add_argument("--crop-pt", default="500:250")
    ap.add_argument("--cap-y", type=int, default=48)
    a = ap.parse_args()
    x0, y0 = (int(v) for v in a.crop_pt.split(":"))
    band = (int(REGION[2] * 2), int(REGION[3] * 2), (REGION[0] - x0) * 2, (REGION[1] - y0) * 2)
    scratch = tempfile.mkdtemp(prefix="film3-plan-")
    hangul = os.path.join(scratch, "hangul")
    run(["swiftc", "-O", os.path.join(HERE, "..", "live", "hangul.swift"), "-o", hangul])
    tb = korean_at(a.before, band, hangul, scratch, 1.0)
    ta = korean_at(a.after, band, hangul, scratch, 1.0)
    crop = "2000:1124:0:0"
    ui = json.load(open(a.ui, encoding="utf-8")) if a.ui else []
    clips = [{"src": a.before, "ss": round(tb - 1.0, 2), "dur": 6.0, "crop": crop}]
    for c in ui:
        clips.append({"src": c["src"], "ss": c["ss"], "dur": c["dur"], "crop": c.get("crop", crop), "dissolve": 0.25})
    t3 = 6.0 + sum(c["dur"] - 0.25 for c in ui)
    clips.append({"src": a.after, "ss": round(ta - 1.0, 2), "dur": 8.0, "crop": crop, "dissolve": 0.25})
    t_end = t3 + 8.0 - 0.25
    clips.append({"card": os.path.join(a.caps, "card.png"), "dur": 2.0, "dissolve": 0.25})
    marks = [{"t": round(1.8 + 0.12 * i, 2), "dur": 1.8, "src": a.before, "at": round(tb + 4.0, 2), "crop": crop, "span": s} for i, s in enumerate(BEFORE_SPANS)]
    marks += [{"t": round(t3 + 1.6 + 0.12 * i, 2), "dur": 1.4, "src": a.after, "at": round(ta + 4.0, 2), "crop": crop, "span": s} for i, s in enumerate(AFTER_SPANS)]
    caps = [{"t": 0.4, "dur": 5.2, "png": os.path.join(a.caps, "c1.png"), "x": 96, "y": a.cap_y}]
    if ui:
        caps.append({"t": 6.4, "dur": t3 - 6.8, "png": os.path.join(a.caps, "c2.png"), "x": 96, "y": a.cap_y})
    caps.append({"t": round(t3 + 0.4, 2), "dur": round(t_end - t3 - 0.8, 2), "png": os.path.join(a.caps, "c3.png"), "x": 96, "y": a.cap_y})
    plan = {"out": a.out, "fps": 30, "clips": clips, "marks": marks, "captions": caps}
    path = a.out + ".plan.json"
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    json.dump(plan, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
    print("make-plan: Korean appears at %.1f s (before take), %.1f s (after take); beat 3 starts at %.2f s; plan %s" % (tb, ta, t3, path))


main()
