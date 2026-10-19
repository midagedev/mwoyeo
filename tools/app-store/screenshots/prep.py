#!/usr/bin/env python3
"""Stage-1 helpers of render.sh (run with python3 -I). Reads scenes.json beside this file.

  prep.py pages [scene ...]           one line per web scene: id, page, window width, height, virtual-time budget (for Chrome)
  prep.py pdfs [scene ...]            one line per paper scene: id, PDF page, px per pt
  prep.py renders [scene ...]         one line per render: scene id, source language, target language
  prep.py cards <scratch> <renders> [scene ...]
                                      crops each scene's card out of <scratch>/src/<id>.png into <renders>/<id>.source.png (RGB)
                                      and its lens out of the card into <scratch>/lens/<id>.png (the picture --render reads)
  prep.py panel <capture> <out> <titlebar px>
                                      the menu panel: the capture without its title bar, the top corners cut like the bottom ones
  prep.py region <loc>                hex of the one scratch lens the panel lists (its size is the panel frame's lens, in pt)
  prep.py manifest <renders>          <renders>/MANIFEST.tsv: every file, its bytes and sha256
With scenes named, only those (render.sh's partial run); an unknown name is an error.
"""
import hashlib, json, os, sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = json.load(open(os.path.join(HERE, 'scenes.json'), encoding='utf-8'))


def px(r):
    """A CSS rect (x, y, w, h) as a PIL box in 2x pixels."""
    x, y, w, h = r
    return (2 * x, 2 * y, 2 * (x + w), 2 * (y + h))


def clean(im):
    """RGB with no ancillary chunks: the picture's pixels and nothing else (Chrome draws an untagged PNG as sRGB)."""
    return Image.frombytes('RGB', im.size, im.convert('RGB').tobytes())


def scenes(names):
    """The scenes named (all of them when none are), in scenes.json order."""
    unknown = set(names) - set(CFG['scenes'])
    if unknown:
        sys.exit(f'prep.py: no scene {", ".join(sorted(unknown))} in scenes.json')
    return {sid: s for sid, s in CFG['scenes'].items() if not names or sid in names}


def cards(scr, out, names):
    os.makedirs(os.path.join(scr, 'lens'), exist_ok=True)
    for sid, s in scenes(names).items():
        page = Image.open(os.path.join(scr, 'src', f'{sid}.png'))
        want = (2 * s['window'][0], 2 * s['window'][1])
        if page.size != want:
            sys.exit(f'prep.py: {sid}: source is {page.size}, expected {want}')
        card = clean(page.crop(px(s['crop'])))
        card.save(os.path.join(out, f'{sid}.source.png'), compress_level=9)
        card.crop(px(s['lens'])).save(os.path.join(scr, 'lens', f'{sid}.png'), compress_level=9)
        print(f'card {sid} {card.size[0]}x{card.size[1]} lens {s["lens"]}')


def panel(capture, out, bar):
    im = Image.open(capture).convert('RGBA')
    w, h = im.size
    body = im.crop((0, bar, w, h))
    # The window's bottom corners are transparent outside its rounded shape: the top corners get the same shape, mirrored.
    a = body.getchannel('A')
    r = 40
    for x0 in (0, w - r):
        corner = a.crop((x0, a.size[1] - r, x0 + r, a.size[1])).transpose(Image.Transpose.FLIP_TOP_BOTTOM)
        a.paste(corner, (x0, 0))
    body.putalpha(a)
    Image.frombytes('RGBA', body.size, body.tobytes()).save(out, compress_level=9)
    print(f'panel {out} {body.size[0]}x{body.size[1]}')


def region(loc):
    p = CFG['panel']
    _, _, w, h = CFG['scenes'][p['lens_of']]['lens']
    regions = [{'id': '6D0E5A3C-1B2F-4C1D-9E4A-0A5E7F1B2C3D', 'name': p['lens_name'][loc], 'rect': [[240, 160], [w, h]], 'isEnabled': True}]
    print(json.dumps(regions, ensure_ascii=False, separators=(',', ':')).encode().hex())


def manifest(out):
    rows = []
    for name in sorted(os.listdir(out)):
        path = os.path.join(out, name)
        if name == 'MANIFEST.tsv' or not os.path.isfile(path):
            continue
        b = open(path, 'rb').read()
        rows.append(f'{name}\t{len(b)}\t{hashlib.sha256(b).hexdigest()}')
    open(os.path.join(out, 'MANIFEST.tsv'), 'w').write('file\tbytes\tsha256\n' + '\n'.join(rows) + '\n')
    total = sum(int(r.split('\t')[1]) for r in rows)
    print(f'manifest {len(rows)} files, {total / 1e6:.1f} MB')


def main(a):
    if a[:1] == ['pages']:
        for sid, s in scenes(a[1:]).items():
            if 'page' in s:
                print(f'{sid}\t{s["page"]}\t{s["window"][0]}\t{s["window"][1]}\t{s.get("budget", 3000)}')
    elif a[:1] == ['pdfs']:
        for sid, s in scenes(a[1:]).items():
            if 'pdf' in s:
                print(f'{sid}\t{s["pdf"]}\t{s["pdf_scale"]}')
    elif a[:1] == ['renders']:
        wanted = scenes(a[1:])
        for sid, tgt in CFG['renders']:
            if sid in wanted:
                print(f'{sid}\t{CFG["scenes"][sid]["src"]}\t{tgt}')
    elif a[:1] == ['cards'] and len(a) >= 3:
        cards(a[1], a[2], a[3:])
    elif a[:1] == ['panel'] and len(a) == 4:
        panel(a[1], a[2], int(a[3]))
    elif a[:1] == ['region'] and len(a) == 2:
        region(a[1])
    elif a[:1] == ['manifest'] and len(a) == 2:
        manifest(a[1])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
