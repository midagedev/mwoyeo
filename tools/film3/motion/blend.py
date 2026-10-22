#!/usr/bin/env python3
"""film3-motion: shoot.mjs's frame stream (per film frame: u32 n, then n x (u32 length, PNG)) -> raw RGB24 frames on stdout for ffmpeg.
A frame of n > 1 sub-frames is their mean in linear light (motion blur from the motion itself, not a filter). Run isolated:
  node shoot.mjs film ... | python3 -I blend.py [--first F] [--keep F1,F2,... --keep-dir DIR] | ffmpeg -f rawvideo -pix_fmt rgb24 -s 1920x1080 -r 60 -i - ...
--keep writes those film frames as PNG too (the self-check stills are the film's own frames)."""
import argparse
import io
import os
import struct
import sys

import numpy as np
from PIL import Image

ap = argparse.ArgumentParser()
ap.add_argument("--first", type=int, default=0)
ap.add_argument("--keep", default="")
ap.add_argument("--keep-dir", default="")
a = ap.parse_args()
keep = {int(v) for v in a.keep.split(",") if v}
if keep:
    os.makedirs(a.keep_dir, exist_ok=True)
LIN = ((np.arange(256) / 255.0) ** 2.2).astype(np.float32)
inp, out = sys.stdin.buffer, sys.stdout.buffer


def png(n):
    data = inp.read(n)
    if len(data) != n:
        sys.exit("blend: the stream ended inside a frame")
    return np.asarray(Image.open(io.BytesIO(data)).convert("RGB"))


f = a.first
while True:
    head = inp.read(4)
    if not head:
        break
    n = struct.unpack("<I", head)[0]
    if n == 1:
        frame = png(struct.unpack("<I", inp.read(4))[0])
    else:
        acc = None
        for _ in range(n):
            lin = LIN[png(struct.unpack("<I", inp.read(4))[0])]
            acc = lin if acc is None else acc + lin
        frame = (np.power(np.clip(acc / n, 0, 1), 1 / 2.2) * 255 + 0.5).astype(np.uint8)
    out.write(np.ascontiguousarray(frame).tobytes())
    if f in keep:
        Image.fromarray(frame).save(os.path.join(a.keep_dir, "f%05d.png" % f))
    f += 1
sys.stderr.write("blend: %d frames\n" % (f - a.first))
