#!/usr/bin/env python3
"""film5 edit: one take, real time, a camera that follows the lens, captions, an end card, the music bed.
usage: edit.py <edit.json> <out.mp4> [--square] [--proxy] [--no-music]
The camera keys are (take s, centre x pt, centre y pt, zoom); between keys the move eases (smootherstep). Zoom 1 shows `base` pt
(16:9: the screen's width; 1:1: `base_square`). Frames come from ffmpeg (rgb24 at 60 fps), are cropped and scaled by PIL, and go
back to ffmpeg; outside the screen is the stage colour."""
import json, subprocess, sys, math
from PIL import Image, ImageDraw, ImageFont, ImageFilter

cfg = json.load(open(sys.argv[1])); out = sys.argv[2]
square = '--square' in sys.argv; proxy = '--proxy' in sys.argv; music = '--no-music' not in sys.argv
OW, OH = (1080, 1080) if square else (1920, 1080)
if proxy: OW, OH = OW * 2 // 3, OH * 2 // 3
FPS = 60 if not proxy else 30
S = 2.0                                   # take px per pt
SW, SH = 3024, 1964
T0, T1 = cfg['take_in'], cfg['take_out']
END = cfg['end_card']['seconds']
N = int(round((T1 - T0 + END) * FPS))
base = cfg['base_square'] if square else cfg['base']
stage = tuple(int(cfg['stage'][i:i + 2], 16) for i in (1, 3, 5))
keys = cfg['camera']


def ease(u): return u * u * u * (u * (u * 6 - 15) + 10)


def cam(t):
    if t <= keys[0][0]: return keys[0][1:]
    for a, b in zip(keys, keys[1:]):
        if a[0] <= t <= b[0]:
            u = ease((t - a[0]) / (b[0] - a[0]))
            # zoom moves in log space: a push feels even
            z = math.exp(math.log(a[3]) + (math.log(b[3]) - math.log(a[3])) * u)
            return (a[1] + (b[1] - a[1]) * u, a[2] + (b[2] - a[2]) * u, z)
    return keys[-1][1:]


def font(names, size):
    for n in names:
        try: return ImageFont.truetype(n, size)
        except OSError: pass
    return ImageFont.load_default()


k = OH / 1080
KO = font(['/System/Library/Fonts/AppleSDGothicNeo.ttc'], int(46 * k)) if not square else font(['/System/Library/Fonts/AppleSDGothicNeo.ttc'], int(44 * k))
EN = font(['/System/Library/Fonts/SFNS.ttf', '/System/Library/Fonts/Helvetica.ttc'], int(26 * k))
try:
    KO = ImageFont.truetype('/System/Library/Fonts/AppleSDGothicNeo.ttc', KO.size, index=6)   # Bold
except Exception:
    pass


def caption_layer(c, alpha):
    layer = Image.new('RGBA', (OW, OH), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    ko, en = c['ko'], c['en']
    kb = d.textbbox((0, 0), ko, font=KO); eb = d.textbbox((0, 0), en, font=EN)
    w = max(kb[2] - kb[0], eb[2] - eb[0]) + int(64 * k); h = (kb[3] - kb[1]) + (eb[3] - eb[1]) + int(54 * k)
    x0 = (OW - w) // 2; y0 = OH - h - int((70 if not square else 60) * k)
    pill = Image.new('RGBA', (OW, OH), (0, 0, 0, 0))
    ImageDraw.Draw(pill).rounded_rectangle((x0, y0, x0 + w, y0 + h), radius=int(26 * k), fill=(20, 20, 24, int(225 * alpha)))
    layer = Image.alpha_composite(layer, pill); d = ImageDraw.Draw(layer)
    a = int(255 * alpha)
    d.text(((OW - (kb[2] - kb[0])) // 2 - kb[0], y0 + int(20 * k) - kb[1]), ko, font=KO, fill=(255, 255, 255, a))
    d.text(((OW - (eb[2] - eb[0])) // 2 - eb[0], y0 + int(28 * k) + (kb[3] - kb[1]) - eb[1]), en, font=EN, fill=(235, 235, 240, int(a * 0.85)))
    return layer


KEY = font(['/System/Library/Fonts/SFNS.ttf'], int(40 * k))


def keycap_layer(text, alpha):
    """The held keys, top centre: a light keycap with a soft shadow."""
    layer = Image.new('RGBA', (OW, OH), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    b = d.textbbox((0, 0), text, font=KEY)
    w, h = b[2] - b[0] + int(56 * k), b[3] - b[1] + int(36 * k)
    x0, y0 = (OW - w) // 2, int(46 * k)
    sh = Image.new('RGBA', (OW, OH), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle((x0, y0 + int(6 * k), x0 + w, y0 + h + int(6 * k)), radius=int(16 * k), fill=(0, 0, 0, int(110 * alpha)))
    layer = Image.alpha_composite(layer, sh.filter(ImageFilter.GaussianBlur(int(10 * k))))
    d = ImageDraw.Draw(layer)
    d.rounded_rectangle((x0, y0, x0 + w, y0 + h), radius=int(16 * k), fill=(246, 246, 248, int(240 * alpha)), outline=(200, 200, 206, int(255 * alpha)), width=max(1, int(2 * k)))
    d.text((x0 + (w - (b[2] - b[0])) // 2 - b[0], y0 + (h - (b[3] - b[1])) // 2 - b[1]), text, font=KEY, fill=(28, 28, 30, int(255 * alpha)))
    return layer


def fade(t, a, b, f=0.35):
    if t < a or t > b: return 0.0
    return min(1.0, (t - a) / f, (b - t) / f)


ec = cfg['end_card']
icon = Image.open(ec['icon']).convert('RGBA') if ec.get('icon') else None
TITLE = font(['/System/Library/Fonts/SFNS.ttf'], int(64 * k))
SUB = KO.font_variant(size=int(34 * k)) if hasattr(KO, 'font_variant') else KO


def end_layer(u):
    """u 0..1 over the card's fade-in; the card is the stage colour with the icon, the name and the line."""
    layer = Image.new('RGBA', (OW, OH), stage + (int(255 * u),))
    d = ImageDraw.Draw(layer)
    a = int(255 * max(0.0, min(1.0, (u - 0.3) / 0.7)))
    cy = OH // 2 - int(40 * k)
    if icon:
        sz = int(170 * k); ic = icon.resize((sz, sz), Image.LANCZOS)
        ic.putalpha(ic.getchannel('A').point(lambda v: v * a // 255))
        layer.alpha_composite(ic, ((OW - sz) // 2, cy - sz))
    tb = d.textbbox((0, 0), ec['title'], font=TITLE)
    dark = sum(stage) < 384
    d.text(((OW - (tb[2] - tb[0])) // 2 - tb[0], cy + int(26 * k) - tb[1]), ec['title'], font=TITLE, fill=((245, 245, 247) if dark else (29, 29, 31)) + (a,))
    sb = d.textbbox((0, 0), ec['line'], font=SUB)
    d.text(((OW - (sb[2] - sb[0])) // 2 - sb[0], cy + int(120 * k) - sb[1]), ec['line'], font=SUB, fill=((170, 170, 178) if dark else (110, 110, 115)) + (a,))
    return layer


dec = subprocess.Popen(['ffmpeg', '-v', 'error', '-ss', str(T0), '-i', cfg['take'], '-t', str(T1 - T0), '-vf', f'fps={FPS}',
                        '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], stdout=subprocess.PIPE)
enc_args = ['ffmpeg', '-v', 'error', '-y', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{OW}x{OH}', '-r', str(FPS), '-i', '-']
if music and cfg.get('music'):
    m = cfg['music']; dur = N / FPS
    enc_args += ['-i', m['path'], '-filter_complex',
                 f"[1:a]atrim=start={m.get('start', 0)},asetpts=PTS-STARTPTS,volume={m.get('gain_db', 0)}dB,"
                 f"afade=t=in:st=0:d={m.get('fade_in', 0.2)},afade=t=out:st={dur - m.get('fade_out', 1.5)}:d={m.get('fade_out', 1.5)}[a]",
                 '-map', '0:v', '-map', '[a]', '-c:a', 'aac', '-b:a', '256k', '-shortest']
enc_args += ['-c:v', 'libx264', '-preset', 'medium' if not proxy else 'veryfast', '-crf', '16' if not proxy else '26', '-pix_fmt', 'yuv420p',
             '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709', '-movflags', '+faststart', out]
enc = subprocess.Popen(enc_args, stdin=subprocess.PIPE)
frame_bytes = SW * SH * 3
last = None
for i in range(N):
    t_film = i / FPS; t = T0 + t_film
    if t < T1:
        buf = dec.stdout.read(frame_bytes)
        if len(buf) == frame_bytes: last = Image.frombuffer('RGB', (SW, SH), buf)
    img = last
    cx, cy, z = cam(t)
    vw, vh = base[0] / z * S, base[1] / z * S
    x0, y0 = cx * S - vw / 2, cy * S - vh / 2
    if vw <= SW: x0 = min(max(x0, 0), SW - vw)
    else: x0 = (SW - vw) / 2
    if vh <= SH: y0 = min(max(y0, 0), SH - vh)
    else: y0 = (SH - vh) / 2
    view = img.resize((OW, OH), Image.BICUBIC, box=(x0, y0, x0 + vw, y0 + vh)) if (x0 >= 0 and y0 >= 0 and x0 + vw <= SW and y0 + vh <= SH) else None
    if view is None:
        scale = OW / vw
        view = Image.new('RGB', (OW, OH), stage)
        sx0, sy0 = max(0, x0), max(0, y0); sx1, sy1 = min(SW, x0 + vw), min(SH, y0 + vh)
        part = img.resize((max(1, int(round((sx1 - sx0) * scale))), max(1, int(round((sy1 - sy0) * scale)))), Image.BICUBIC, box=(sx0, sy0, sx1, sy1))
        view.paste(part, (int(round((sx0 - x0) * scale)), int(round((sy0 - y0) * scale))))
    frame = view.convert('RGBA')
    for c in cfg.get('keycaps', []):
        a = fade(t_film, c['t'][0], c['t'][1], 0.12)
        if a > 0: frame = Image.alpha_composite(frame, keycap_layer(c['text'], a))
    for c in cfg['captions']:
        a = fade(t_film, c['t'][0], c['t'][1])
        if a > 0: frame = Image.alpha_composite(frame, caption_layer(c, a))
    te = t_film - (T1 - T0) + ec.get('lead', 0.6)
    if te > 0: frame = Image.alpha_composite(frame, end_layer(min(1.0, te / ec.get('fade', 0.8))))
    enc.stdin.write(frame.convert('RGB').tobytes())
    if i % 300 == 0: print(f'{i}/{N}', flush=True)
enc.stdin.close(); enc.wait(); dec.kill()
print(out, enc.returncode)
