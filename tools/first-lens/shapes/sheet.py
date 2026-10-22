"""shapes117: what the pointer gets where, drawn over a scene. Reads `shapes grid` output (x y kind x0 y0 x1 y1 cut) and the scene's
picture; every grid point is a dot in its kind's colour, every distinct rect a thin outline in it (red and thick when it cuts a block).
  usage: sheet.py <grid.txt> <picture.png> <px per pt> <out.png> [title]"""
import sys
from PIL import Image, ImageDraw
COL = dict(column=(30, 110, 230), table=(0, 150, 120), thread=(150, 70, 200), dialog=(230, 140, 0), subtitles=(220, 40, 120),
           group=(90, 90, 90), ghost=(200, 200, 200))
grid, png, ppp, out = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
im = Image.open(png).convert('RGB')
im = im.resize((int(im.width / ppp), int(im.height / ppp)))
d = ImageDraw.Draw(im, 'RGBA')
rects = {}
for l in open(grid):
    f = l.split()
    x, y, k = float(f[0]), float(f[1]), f[2]
    c = COL.get(k, (0, 0, 0))
    d.ellipse((x - 2, y - 2, x + 2, y + 2), fill=c + (200,))
    if k != 'ghost':
        rects[tuple(map(float, f[3:7]))] = (k, f[7] == '1')
for (x0, y0, x1, y1), (k, cut) in rects.items():
    d.rectangle((x0, y0, x1, y1), outline=(255, 0, 0, 255) if cut else COL[k] + (150,), width=3 if cut else 1)
if len(sys.argv) > 5:
    d.rectangle((0, 0, 8 * len(sys.argv[5]) + 8, 16), fill=(255, 255, 255, 220)); d.text((4, 2), sys.argv[5], fill=(0, 0, 0))
im.save(out)
