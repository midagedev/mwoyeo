#!/usr/bin/env python3
"""Link-box pixels left in the translated blocks of the paper bench (arXiv 1706.03762 in Safari or PDFKit draws a 1 px frame round
every link: citations are light green; PDFKit's render of the bench pages has (0, 255, 0) frames, a live Safari capture (117, 251, 76)).
Usage: linkpx.py <out dir> [page ...]      (python3 with numpy and PIL; the pages default to p2-p10, whole pages)

For each page, counts the pixels of that frame colour inside the translated blocks (the `block:` rects of the render's .out, with
8 px around) in the source page (PAGES=<pages.sh output>, default /tmp/paper-quality/paper) and in the render. A frame the erase did
not take stays over the translation; one it half took leaves green smears where the glyphs were (the fill averages them in).
Round 2 (2026-10-18), p2-p10: 6890 px in the source's translated blocks, 9298 in the render before `TextEraser` took the frames
round glyphs (the fill smeared them), 678 after (the frames wider than the line's crop stay)."""
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import score  # noqa: E402


def green(path):
    a = np.asarray(Image.open(path).convert('RGB')).astype(int)
    return (a[..., 1] - a[..., 0] > 120) & (a[..., 1] - a[..., 2] > 120)


def main():
    out = sys.argv[1]
    pages = sys.argv[2:] or [f'p{n}' for n in range(2, 11)]
    src = os.environ.get('PAGES', '/tmp/paper-quality/paper')
    total = [0, 0]
    for n in pages:
        r = score.parse(os.path.join(out, n + '.out'))
        gs, go = green(os.path.join(src, n + '.png')), green(os.path.join(out, n + '.png'))
        mask = np.zeros(gs.shape, bool)
        for b in r['blocks']:
            x, y, w, h = b['core']
            mask[max(0, y - 8):y + h + 8, max(0, x - 8):x + w + 8] = True
        s, o = int((gs & mask).sum()), int((go & mask).sum())
        total[0] += s
        total[1] += o
        print(f'{n:<6} link-box px in translated blocks: source={s:5} render={o:5}')
    print(f'{"TOTAL":<6} link-box px in translated blocks: source={total[0]:5} render={total[1]:5}')


if __name__ == '__main__':
    main()
