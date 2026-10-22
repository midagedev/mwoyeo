"""shapes117: a 720p30 prototype of the one-click preview gliding along the planned pointer path, drawn over the stage picture from
`shapes sweep` output. The preview is the picker's (first-lens.md 4.2): the 0.32 dim with a punched hole, an accent ring 3 pt at 0.85,
radius 10; a change of target glides by the critically damped spring of LensTarget.Glide (omega 30, additive steps, 8/30 s), the
ghost follows the pointer at once. A small tag names the kind (review aid, not product UI).
  usage: proto.py <sweep.txt> <stage.png (2x)> <out.mp4> [--no-tags]"""
import sys, os, math, subprocess, tempfile, shutil
from PIL import Image, ImageDraw, ImageFont
sweep, png, out = sys.argv[1], sys.argv[2], sys.argv[3]
tags = '--no-tags' not in sys.argv
W, H, SS = 1280, 720, 2                       # output size, supersampling
stage = Image.open(png).convert('RGB')        # 3024 x 1890 (2x of 1512 x 945 pt)
k = H * SS / 945.0                            # px per pt in the supersampled canvas
sw = int(round(1512 * k)); ox = (W * SS - sw) // 2
base = Image.new('RGB', (W * SS, H * SS), (28, 28, 30))
base.paste(stage.resize((sw, H * SS), Image.LANCZOS), (ox, 0))
GLIDE = 8 / 30.0
def progress(t): x = 8 * max(0.0, t) / GLIDE; return 1 - (1 + x) * math.exp(-x)
rows = [l.split() for l in open(sweep) if not l.startswith('#')]
target, steps, frames = None, [], []
last_kind = None
for r in rows:
    t = float(r[1]); p = (float(r[2]), float(r[3])); kind = r[4]; rect = tuple(map(float, r[5:9]))
    if target is not None and rect != target:
        follow = kind == 'ghost' and last_kind == 'ghost'
        if not follow:
            steps.append((target[0] - rect[0], target[1] - rect[1], target[2] - rect[2], target[3] - rect[3], t))
    target, last_kind = rect, kind
    cur = list(rect)
    for dx0, dy0, dx1, dy1, t0 in steps:
        if t < t0 + GLIDE:
            left = 1 - progress(t - t0)
            cur = [cur[0] + dx0 * left, cur[1] + dy0 * left, cur[2] + dx1 * left, cur[3] + dy1 * left]
    steps = [s for s in steps if t < s[4] + GLIDE]
    frames.append((p, kind, cur))
font = None
for f in ('/System/Library/Fonts/SFNS.ttf', '/System/Library/Fonts/Helvetica.ttc'):
    if os.path.exists(f): font = ImageFont.truetype(f, 13 * SS); break
tmp = tempfile.mkdtemp(prefix='shapes-proto-')
def P(x, y): return (ox + x * k, y * k)
for i, (p, kind, r) in enumerate(frames):
    im = base.copy()
    dim = Image.new('L', im.size, int(255 * 0.32))
    md = ImageDraw.Draw(dim)
    x0, y0 = P(r[0], r[1]); x1, y1 = P(r[2], r[3])
    md.rounded_rectangle((x0, y0, x1, y1), radius=10 * k, fill=0)
    im.paste(Image.new('RGB', im.size, (0, 0, 0)), (0, 0), dim)
    d = ImageDraw.Draw(im, 'RGBA')
    d.rounded_rectangle((x0, y0, x1, y1), radius=10 * k, outline=(10, 132, 255, int(255 * 0.85)), width=max(1, int(round(3 * k))))
    if tags and font:
        label = kind
        tw = d.textlength(label, font=font)
        ty = y0 - 22 * SS if y0 > 24 * SS else y1 + 4 * SS
        d.rounded_rectangle((x0, ty, x0 + tw + 14 * SS, ty + 18 * SS), radius=9 * SS, fill=(10, 132, 255, 220))
        d.text((x0 + 7 * SS, ty + 2 * SS), label, fill=(255, 255, 255), font=font)
    cx, cy = P(*p); s = 1.0 * SS
    arrow = [(0, 0), (0, 17), (4.5, 13), (7.5, 20), (10, 19), (7, 12.5), (12.5, 12.5)]
    d.polygon([(cx + ax * s, cy + ay * s) for ax, ay in arrow], fill=(0, 0, 0))
    inner = [(1.3, 2.8), (1.3, 14.2), (4.8, 11), (7.9, 18.2), (9, 17.7), (6, 11), (10, 11)]
    d.polygon([(cx + ax * s, cy + ay * s) for ax, ay in inner], fill=(255, 255, 255))
    im.resize((W, H), Image.LANCZOS).save(f'{tmp}/f{i:04d}.png')
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-framerate', '30', '-i', f'{tmp}/f%04d.png', '-c:v', 'libx264', '-pix_fmt', 'yuv420p',
                '-crf', '18', out], check=True)
keep = os.environ.get('PROTO_FRAMES')
if keep:
    os.makedirs(keep, exist_ok=True)
    for i in range(0, len(frames), 6): shutil.copy(f'{tmp}/f{i:04d}.png', f'{keep}/f{i:04d}.png')
shutil.rmtree(tmp)
print(len(frames), 'frames ->', out)
