#!/usr/bin/env python3
"""film3-motion end to end: film.json -> prep -> probe -> frames -> blend -> <out>/film.mp4 (1920x1080, 60 fps, h264 crf 16, yuv420p, music) and
<out>/proxy-720p30.mp4 (720p, 30 fps, crf 28: what the motion is judged on). Run isolated: `python3 -I make.py [film.json] [--skip-prep] [--skip-probe]`.
The music is cut so its drop (clip beat 64) lands where the whip does; music.start in film.json is that clip second at film 0."""
import argparse
import hashlib
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run(cmd):
    r = subprocess.run(cmd, capture_output=True, encoding="utf-8")
    if r.returncode:
        sys.exit("make: %s failed:\n%s" % (cmd[0], (r.stderr or r.stdout)[-1500:]))
    return r.stdout + r.stderr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("config", nargs="?", default=os.path.join(HERE, "film.json"))
    ap.add_argument("--skip-prep", action="store_true")
    ap.add_argument("--skip-probe", action="store_true")
    a = ap.parse_args()
    cfg = json.load(open(a.config, encoding="utf-8"))
    work, out = cfg["work"], cfg["out"]
    os.makedirs(out, exist_ok=True)
    if not a.skip_prep:
        print(run(["python3", "-I", os.path.join(HERE, "prep.py"), a.config]).strip())
    probe = os.path.join(work, "probe.json")
    if not a.skip_probe:
        print(run(["node", os.path.join(HERE, "shoot.mjs"), "probe", "--work", work, "--out", probe]).strip().splitlines()[-1])
    p = json.load(open(probe, encoding="utf-8"))
    dur, fps = p["duration"], p["fps"]
    music = cfg["music"]
    if hashlib.sha256(open(music["path"], "rb").read()).hexdigest() != music["sha256"]:
        sys.exit("make: %s is not the bed film 2 used (sha256)" % music["path"])
    w, h = cfg["size"]
    master = os.path.join(out, "film.mp4")
    shoot = subprocess.Popen(["node", os.path.join(HERE, "shoot.mjs"), "film", "--work", work, "--probe", probe], stdout=subprocess.PIPE,
                             stderr=open(os.path.join(work, "shoot.log"), "w"))
    blend = subprocess.Popen(["python3", "-I", os.path.join(HERE, "blend.py")], stdin=shoot.stdout, stdout=subprocess.PIPE,
                             stderr=open(os.path.join(work, "blend.log"), "w"))
    shoot.stdout.close()
    fade0 = dur - music["fade_out"]
    enc = subprocess.Popen(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
                            "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", "%dx%d" % (w, h), "-r", str(fps), "-i", "-",
                            "-ss", "%.4f" % music["start"], "-t", "%.4f" % dur, "-i", music["path"],
                            "-filter_complex", "[1:a]volume=%.1fdB,afade=t=in:st=0:d=0.25,afade=t=out:st=%.3f:d=%.3f[a]" % (music["gain_db"], fade0, music["fade_out"]),
                            "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-preset", "slow", "-crf", "16", "-pix_fmt", "yuv420p",
                            "-vf", "scale=out_color_matrix=bt709:out_range=tv", "-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
                            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", "-t", "%.4f" % dur, master],
                           stdin=blend.stdout, stderr=subprocess.PIPE)
    blend.stdout.close()
    _, err = enc.communicate()
    for name, proc in (("shoot", shoot), ("blend", blend)):
        if proc.wait():
            sys.exit("make: %s failed (see %s/%s.log)" % (name, work, name))
    if enc.returncode:
        sys.exit("make: ffmpeg failed: %s" % err.decode()[-800:])
    proxy = os.path.join(out, "proxy-720p30.mp4")
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", master, "-vf", "scale=-2:720:flags=lanczos,fps=30", "-c:v", "libx264", "-preset", "medium",
         "-crf", "28", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", proxy])
    for f in (master, proxy):
        print("make: " + run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name,width,height,r_frame_rate,pix_fmt:format=duration,size", "-of", "compact", f]).strip().replace("\n", " | ") + "  " + f)


main()
