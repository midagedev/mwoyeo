#!/usr/bin/env python3
"""fast117: the playback sheet of the swap. Puts the `off` take (today) and the `on` take (`fastFirstPaint`) of each scene side by side, both aligned at the
click that places the lens, with a timer in seconds since that click, as one 720p30 mp4 for the lead's verdict (docs/design/first-lens.md §13).
usage: swap.py <out.mp4> <label>=<off take base>,<on take base>[,<seconds after the click>] [...] [--before 1.0] [--length 28]
A take base is `<dir>/<name>` of rec.py's output (`.mp4` and `.events`). The recording runs on a loaded machine and its media time is not the driver's clock,
so the click is found, not computed: the first frame that differs from the first one is the picker opening (the hot key), and the click follows the key by
the time the events say. Needs ffmpeg and Pillow; draws its own labels (ffmpeg here has no drawtext)."""
import argparse, json, os, subprocess, sys, tempfile
from PIL import Image, ImageDraw, ImageFont

a = argparse.ArgumentParser()
a.add_argument('out'); a.add_argument('pairs', nargs='+')
a.add_argument('--before', type=float, default=1.0); a.add_argument('--length', type=float, default=28.0)
o = a.parse_args()
W, H, FPS = 728, 720, 30
FONT = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 22)
BIG = ImageFont.truetype('/System/Library/Fonts/Helvetica.ttc', 30)

def events(base):
    ev = [json.loads(l) for l in open(base + '.events')]
    t = lambda pred: next(e['t'] for e in ev if pred(e))
    return t(lambda e: e.get('cmd', '').startswith('key 38')), t(lambda e: e.get('ev') == 'lens placed')

def click_in_clip(base):
    """Seconds into the clip at which the lens was placed. The recording runs on a loaded machine and its media time is not the driver's clock, so it is
    found from the picture: the first Korean on screen (the first frame whose text rows differ from the rows just after the click) is the trace's first
    `pipeline provisional|streamed` line, and the click is that trace time earlier by what the events and the trace say."""
    ev = [json.loads(l) for l in open(base + '.events')]
    key = next(e['t'] for e in ev if e.get('cmd', '').startswith('key 38')); click = next(e['t'] for e in ev if e.get('ev') == 'lens placed')
    first = next(float(l.split()[0]) for l in open(base + '.err') if 'pipeline provisional' in l or 'pipeline streamed' in l)
    # a rough click: the picker opening (the first frame that differs from the first one) plus the key to click time
    sw, sh = 64, 64
    raw = subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', base + '.mp4', '-vf', 'fps=10,scale=64:64,format=gray', '-f', 'rawvideo', '-'], capture_output=True).stdout
    fr = [raw[i:i + sw * sh] for i in range(0, len(raw) - sw * sh + 1, sw * sh)]
    d = lambda x, y: sum(abs(p - q) for p, q in zip(x, y)) / len(x)
    k1 = next((k for k in range(3, len(fr)) if d(fr[k], fr[0]) > 2.0), None)
    if k1 is None: sys.exit(f'swap.py: no change found in {base}.mp4')
    rough = k1 / 10 + (click - key)
    # the text rows (the left 70 %, the top 40 %) at 30 fps; the reference is 1.5 s after the rough click, the first Korean is the first frame that leaves it (still rows differ by 0.0 to 0.3, a Korean line by 2 or more)
    tw, th = 140, 60
    raw = subprocess.run(['ffmpeg', '-loglevel', 'error', '-i', base + '.mp4', '-vf', f'crop=iw*0.7:ih*0.4:0:ih*0.04,scale={tw}:{th},fps=30,format=gray', '-f', 'rawvideo', '-'], capture_output=True).stdout
    fr = [raw[i:i + tw * th] for i in range(0, len(raw) - tw * th + 1, tw * th)]
    ref = int((rough + 1.5) * 30)
    k = next((k for k in range(ref + 10, len(fr)) if d(fr[k], fr[ref]) > 1.0), None)
    if k is None: sys.exit(f'swap.py: no Korean found after the click in {base}.mp4')
    return k / 30 - (first - click)

def click_time(base): return click_in_clip(base)

def overlay(dirpath, title, n):
    """One RGBA frame per output frame: the title of the pair, the label of each half and the timer (seconds since the click) of each half."""
    for i in range(n):
        im = Image.new('RGBA', (2 * W, H), (0, 0, 0, 0)); d = ImageDraw.Draw(im)
        t = i / FPS - o.before
        d.rectangle([0, 0, 2 * W, 34], fill=(0, 0, 0, 170))
        d.text((12, 5), title, font=FONT, fill=(255, 255, 255, 255))
        for x, tag in ((0, 'today (high fidelity only)'), (W, 'first paint on (fastFirstPaint)')):
            d.rectangle([x, H - 44, x + W, H], fill=(0, 0, 0, 170))
            d.text((x + 12, H - 36), tag, font=FONT, fill=(255, 255, 255, 255))
            d.text((x + W - 130, H - 42), f'{t:+5.1f} s' if t < 0 else f'{t:5.1f} s', font=BIG, fill=(255, 220, 80, 255) if t >= 0 else (160, 160, 160, 255))
        d.line([(W, 0), (W, H)], fill=(255, 255, 255, 255), width=2)
        im.save(f'{dirpath}/o{i:05d}.png')

segs = []
work = tempfile.mkdtemp(prefix='swap-')
for k, spec in enumerate(o.pairs):
    label, rest = spec.split('=', 1); off, on, *more = rest.split(',')
    length = float(more[0]) if more else o.length
    n = int((o.before + length) * FPS)
    od = f'{work}/ov{k}'; os.makedirs(od); overlay(od, f'{label}   (the timer: seconds since the lens was placed)', n)
    inputs, filt = [], []
    for j, base in enumerate((off, on)):
        start = max(0.0, click_time(base) - o.before)
        inputs += ['-ss', f'{start:.3f}', '-t', f'{o.before + length:.3f}', '-i', base + '.mp4']
        filt.append(f'[{j}:v]fps={FPS},scale=-2:{H},pad={W}:{H}:({W}-iw)/2:0:color=0x202020,setsar=1[v{j}]')
    seg = f'{work}/seg{k}.mp4'
    cmd = ['ffmpeg', '-y', '-loglevel', 'error'] + inputs + ['-framerate', str(FPS), '-i', f'{od}/o%05d.png',
           '-filter_complex', ';'.join(filt) + ';[v0][v1]hstack=inputs=2[h];[h][2:v]overlay=0:0:shortest=1,format=yuv420p[out]',
           '-map', '[out]', '-t', f'{o.before + length:.3f}', '-c:v', 'libx264', '-crf', '21', '-r', str(FPS), seg]
    subprocess.run(cmd, check=True); segs.append(seg)
lst = f'{work}/list.txt'; open(lst, 'w').write(''.join(f"file '{s}'\n" for s in segs))
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'concat', '-safe', '0', '-i', lst, '-c', 'copy', o.out], check=True)
print(o.out, subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height,r_frame_rate,duration', '-of', 'csv=p=0', o.out], capture_output=True, text=True).stdout.strip())
