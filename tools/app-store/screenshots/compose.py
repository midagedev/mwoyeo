#!/usr/bin/env python3
"""Stage-2 helpers of compose.sh (run with python3 -I): the frames as HTML, then the PNGs the store takes.

  compose.py html <out>        <out>/.work/html/<loc>-<n>.html per frame (and the card hairlines it shows), <out>/layout.json
                               (where every picture went, for check.py), and PROVENANCE.md beside this file
  compose.py finish <out>      <out>/.work/raw/<loc>-<n>.png (Chrome, 2880 x 1800) -> <out>/<loc>/<n>.png: RGB, no alpha, sRGB profile
  compose.py calib <dir>       two lens-only pages in the geometry of UICapture.lensShot (360 x 200 pt lens at 40, 60 on a 440 x 340
                               window): emphasized on the light backdrop, at rest on the dark one; tools/lens-look/profile.py
                               compares them with the app's own captures

Every picture is placed at scale 1.0 of its 2x source (1 CSS px = 2 px), so a pixel of the app's output is a pixel of the frame.
The lens frame is drawn as RegionFrameWindow draws it (App/Overlay/RegionFrameWindow.swift): the outline 1 pt outside the region,
radius 12, a 1.5 pt conic stroke in the tint (LensTint, App/Model/Settings.swift) starting at the bottom, and a 4 pt copy of it,
blurred, as the glow; ring and glow at the emphasized opacities (1.0, 0.7). The translation is clipped to the region with radius 12
(OverlayPanel's clip) and drawn over the glow, so nothing is drawn on a translated pixel.
"""
import hashlib, html, json, os, re, sys, urllib.parse

from PIL import Image, ImageChops, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = json.load(open(os.path.join(HERE, 'scenes.json'), encoding='utf-8'))
W, H = 1440, 900
TOP_CARD = (110, 212)                    # the card of the 'top' and 'panel' layouts; it runs to the bottom edge
PAIR_Y, PAIR_GAP = 236, 136              # the two cards of the 'pair' layout; the gap holds three keycaps (3 x 36 + 2 x 6) and 8 each side
KEY = 36                                 # keycap, CSS px
PANEL_AT = (984, 336)                    # the menu panel of the 'panel' layout: its shadow stays off the lens, and its edges sit
                                         # inside the sidebar card it covers (10 pt under the card's top edge, 35 pt under its last
                                         # text line), so no clipped line peeks out below or above it
PANEL_SHADOW = (18, 44)                  # its shadow: y offset and blur, CSS px
LIVE_GAP = 48                            # between the moments of the 'live' layout
STEP_ARROW, STEP_LABEL = 60, 50          # the arrow and the "+3s" that join two moments, font px: 2.1x and 2.9x what they were
                                         # (28 and 17; the label's capitals 24 px high at 2880 wide, now ~70, check.py: step); too wide
                                         # for the 48 px between two cards, so they sit in the band above the seam, never on a card
STEP_BOX = (70, 100, 10, 62)             # arrow box width, label box width, space between, row height (CSS px)
STEP_ABOVE = 22                          # between a step row and the cards' top edge
CARD_RADIUS = 18
GLOW_BLUR = 5.0                          # CSS px; fitted to the app's captures: profile.py falloff 15/14 px, peak 70/119 vs 14/15, 64/122
HAIRLINE = 0.09                          # the white hairline 1 CSS px outside a card, alpha
SRGB = '/System/Library/ColorSync/Profiles/sRGB Profile.icc'


def work(out, *p):
    """Chrome's inputs and outputs, under a dot directory so out/*/*.png is the frames only."""
    return os.path.join(out, '.work', *p)

# LensTint.spectrum and .mono (App/Model/Settings.swift). The CA conic gradient starts at the bottom and runs counter-clockwise
# on screen; CSS's runs clockwise, so the loop is reversed.
SPECTRUM = ['#FF9E0A', '#FF385E', '#BF59F2', '#5E5CE6', '#63D1FF']
MONO = ['#B8B8B8', '#666666', '#A3A3A3', '#5C5C5C']


def conic(colors):
    loop = colors + colors[:1]
    rev = loop[::-1]
    stops = ', '.join(f'{c} {100 * i / (len(rev) - 1):.2f}%' for i, c in enumerate(rev))
    return f'conic-gradient(from 180deg, {stops})'


# Backdrops: a deep night with the lens's own colours as soft light, one weighting per frame so the set reads as a sequence.
GLOWS = [
    [('#FF385E', 0.36, '10% -8%'), ('#BF59F2', 0.40, '92% 4%'), ('#FF9E0A', 0.28, '50% 112%')],
    [('#BF59F2', 0.40, '10% -8%'), ('#5E5CE6', 0.50, '92% 4%'), ('#FF385E', 0.30, '50% 112%')],
    [('#5E5CE6', 0.48, '10% -8%'), ('#BF59F2', 0.40, '92% 4%'), ('#63D1FF', 0.26, '50% 112%')],
    [('#5E5CE6', 0.50, '10% -8%'), ('#63D1FF', 0.28, '92% 4%'), ('#BF59F2', 0.36, '50% 112%')],
    [('#63D1FF', 0.24, '10% -8%'), ('#5E5CE6', 0.48, '92% 4%'), ('#FF385E', 0.28, '50% 112%')],
    [('#BF59F2', 0.38, '10% -8%'), ('#FF385E', 0.32, '92% 4%'), ('#63D1FF', 0.24, '50% 112%')],
    [('#FF9E0A', 0.30, '10% -8%'), ('#FF385E', 0.38, '92% 4%'), ('#BF59F2', 0.34, '50% 112%')],
]


def rgba(hexc, a):
    r, g, b = (int(hexc[i:i + 2], 16) for i in (1, 3, 5))
    return f'rgba({r},{g},{b},{a})'


def backdrop(hue):
    layers = [f'radial-gradient(900px 620px at {at}, {rgba(c, a)}, {rgba(c, 0)} 72%)' for c, a, at in GLOWS[hue]]
    return ', '.join(layers + ['linear-gradient(180deg, #15112a 0%, #0c0a18 55%, #08070f 100%)'])


CSS = """
* { box-sizing: border-box; }
html, body { margin: 0; width: %(W)dpx; height: %(H)dpx; overflow: hidden; background: #0c0a18; }
body { position: relative; -webkit-font-smoothing: antialiased; }
.bg { position: absolute; inset: 0; }
.cap { position: absolute; left: 60px; right: 60px; top: 58px; text-align: center; color: #fff;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "Apple SD Gothic Neo", sans-serif; word-break: keep-all; }
.cap h1 { margin: 0; font-size: 64px; line-height: 1.12; font-weight: 700; letter-spacing: -0.015em; }
.cap .k { letter-spacing: -0.08em; padding-right: 0.08em; }
.cap p { margin: 14px 0 0; font-size: 26px; line-height: 1.35; font-weight: 500; color: rgba(255,255,255,.74); letter-spacing: 0; }
.card, .shade { position: absolute; box-shadow: 0 34px 90px rgba(0,0,0,.55); }
.card { overflow: hidden; background: #000; }
.card.flat { box-shadow: none; }
.card > img, .lens-content, .hair { position: absolute; display: block; }
.ring, .glow > div { position: absolute; -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
  -webkit-mask-composite: xor; mask-composite: exclude; }
.glow { position: absolute; }
.chip { position: absolute; display: flex; flex-direction: column; align-items: center; gap: 10px; color: #fff;
  font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; }
.chip .arrows { font-size: 30px; line-height: 1; color: rgba(255,255,255,.7); }
.chip .keys { display: flex; gap: 6px; }
.chip .keys span { width: %(K)dpx; height: %(K)dpx; display: grid; place-items: center; padding-bottom: 2px; font-size: 19px;
  font-weight: 600; background-size: 100%% 100%%; }
.step { position: absolute; display: flex; align-items: center; gap: %(SG)dpx; width: %(SW)dpx; height: %(SH)dpx;
  color: rgba(255,255,255,.92); font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", sans-serif; font-weight: 700;
  font-variant-numeric: tabular-nums; }
.step .arrows { flex: none; width: %(SAW)dpx; text-align: center; font-size: %(SA)dpx; line-height: 1; font-weight: 500;
  color: rgba(255,255,255,.78); }
.step .label { flex: none; width: %(SLW)dpx; text-align: center; font-size: %(SL)dpx; line-height: 1; }
.panel { position: absolute; border-radius: 16px; box-shadow: 0 %(SY)dpx %(SB)dpx rgba(0,0,0,.5); }
.panel img { display: block; }
""" % {'W': W, 'H': H, 'SY': PANEL_SHADOW[0], 'SB': PANEL_SHADOW[1], 'K': KEY, 'SA': STEP_ARROW, 'SL': STEP_LABEL,
         'SAW': STEP_BOX[0], 'SLW': STEP_BOX[1], 'SG': STEP_BOX[2], 'SH': STEP_BOX[3], 'SW': STEP_BOX[0] + STEP_BOX[2] + STEP_BOX[1]}


def lens(region, colors, ring=1.0, glow=0.7):
    """The ring and the glow of a lens around `region` (x, y, w, h), in the coordinates of its container."""
    x, y, w, h = region
    g = conic(colors)
    # outline = region grown by 1 pt, radius 12; ring stroke 1.5 pt and glow stroke 4 pt centred on it
    gl = (f'<div class="glow" style="left:{x - 3}px;top:{y - 3}px;width:{w + 6}px;height:{h + 6}px;filter:blur({GLOW_BLUR}px);opacity:{glow}">'
          f'<div style="inset:0;padding:4px;border-radius:14px;background:{g}"></div></div>')
    rg = (f'<div class="ring" style="left:{x - 1.75}px;top:{y - 1.75}px;width:{w + 3.5}px;height:{h + 3.5}px;padding:1.5px;'
          f'border-radius:12.75px;background:{g};opacity:{ring}"></div>')
    return gl + rg


def rel(path, out):
    return os.path.relpath(path, work(out, 'html'))


def hairline(out, w, h, radii):
    """The card's hairline as a picture, 1 CSS px outside the card (w x h CSS px, radii per corner), drawn here at 2x and 4x
    supersampled. A CSS spread shadow does the same, but Chrome antialiases its rounded corners one of two ways from run to run
    (1 in ~14 shots under load), and the frames must come out the same bytes every time."""
    r = {x for x in radii if x}
    assert len(r) <= 1, radii
    r = r.pop() if r else 0
    S = 4
    size = ((2 * w + 4) * S, (2 * h + 4) * S)
    corners = tuple(bool(x) for x in radii)
    outer, inner = Image.new('L', size, 0), Image.new('L', size, 0)
    ImageDraw.Draw(outer).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=2 * (r + 1) * S, fill=255, corners=corners)
    ImageDraw.Draw(inner).rounded_rectangle((2 * S, 2 * S, size[0] - 1 - 2 * S, size[1] - 1 - 2 * S), radius=2 * r * S, fill=255,
                                            corners=corners)
    cover = ImageChops.subtract(outer, inner).resize((2 * w + 4, 2 * h + 4), Image.BOX)
    pic = Image.new('RGBA', cover.size, (255, 255, 255, 0))
    pic.putalpha(cover.point(lambda v: round(v * HAIRLINE)))
    path = work(out, 'html', f'hair-{w}x{h}-{"-".join(map(str, radii))}.png')
    if not os.path.exists(path):
        pic.save(path)
    return path


def keycap(out):
    """A keycap (KEY CSS px, radius 8) as a picture, for the same reason as hairline(): a white face at 12 %, a 1 px edge at
    26 % over it, 3 px at the bottom."""
    S, n = 4, 2 * KEY
    outer, inner = Image.new('L', (n * S, n * S), 0), Image.new('L', (n * S, n * S), 0)
    ImageDraw.Draw(outer).rounded_rectangle((0, 0, n * S - 1, n * S - 1), radius=16 * S, fill=255)
    ImageDraw.Draw(inner).rounded_rectangle((2 * S, 2 * S, n * S - 1 - 2 * S, n * S - 1 - 6 * S), radius=14 * S, fill=255)
    o, i = (m.resize((n, n), Image.BOX) for m in (outer, inner))
    edge = 1 - (1 - 0.12) * (1 - 0.26)
    alpha = ImageChops.subtract(o.point(lambda v: round(v * edge)), i.point(lambda v: round(v * (edge - 0.12))))
    pic = Image.new('RGBA', (n, n), (255, 255, 255, 0))
    pic.putalpha(alpha)
    path = work(out, 'html', f'key-{KEY}.png')
    if not os.path.exists(path):
        pic.save(path)
    return path


def card_html(out, scene, at, radius, render, colors, place, flat=False):
    """A card: the source picture, the lens frame, and the translation (when `render`) clipped to the lens. `flat`: without its
    shadow, which shade_html() then draws under every card (a later card's own shadow would fall on an earlier card)."""
    s = CFG['scenes'][scene]
    cx, cy = at
    _, _, cw, ch = s['crop']
    lx, ly, lw, lh = s['lens']
    src = os.path.join(HERE, 'renders', f'{scene}.source.png')
    hair = hairline(out, cw, ch, radius_px(radius))
    parts = [f'<img class="hair" src="{rel(hair, out)}" style="left:{cx - 1}px;top:{cy - 1}px;width:{cw + 2}px;height:{ch + 2}px">',
             f'<div class="card{" flat" if flat else ""}" style="left:{cx}px;top:{cy}px;width:{cw}px;height:{ch}px;border-radius:{radius}">',
             f'<img src="{rel(src, out)}" style="left:0;top:0;width:{cw}px;height:{ch}px">', lens(s['lens'], colors)]
    place.append({'kind': 'source', 'file': os.path.relpath(src, HERE), 'rect': [cx, cy, cw, ch], 'radius': radius_px(radius),
                  'lens': [cx + lx, cy + ly, lw, lh]})
    if render:
        parts.append(f'<img class="lens-content" src="{rel(render, out)}" '
                     f'style="left:{lx}px;top:{ly}px;width:{lw}px;height:{lh}px;border-radius:12px">')
        place.append({'kind': 'render', 'file': os.path.relpath(render, HERE), 'rect': [cx + lx, cy + ly, lw, lh], 'radius': [12] * 4})
    parts.append('</div>')
    return ''.join(parts)


def shade_html(scene, at, radius):
    """The shadow a flat card leaves out."""
    _, _, cw, ch = CFG['scenes'][scene]['crop']
    return f'<div class="shade" style="left:{at[0]}px;top:{at[1]}px;width:{cw}px;height:{ch}px;border-radius:{radius}"></div>'


def radius_px(css):
    """A CSS border-radius as [top-left, top-right, bottom-right, bottom-left] in CSS px."""
    v = [int(t.rstrip('px')) for t in css.split()]
    return (v * 4)[:4] if len(v) == 1 else v


def frame_scenes(f):
    """The scenes a frame shows: one, or the moments of a 'live' frame in time order."""
    return f['scenes'] if f['layout'] == 'live' else [f['scene']]


def live_steps(ids):
    """The seconds between the moments of a 'live' frame, read from their pages so the label cannot say more than the pages
    show: one page that adds a message every `every` seconds, at history counts one apart, so moment k + 1 is what moment k's
    page shows `every` seconds later. The moments show one lens: same card size, same lens."""
    q = [dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(CFG['scenes'][i]['page']).query)) for i in ids]
    p = [urllib.parse.urlsplit(CFG['scenes'][i]['page']).path for i in ids]
    rest = [{k: v for k, v in d.items() if k != 'history'} for d in q]
    geo = [(CFG['scenes'][i]['window'], CFG['scenes'][i]['crop'], CFG['scenes'][i]['lens'], CFG['scenes'][i]['budget']) for i in ids]
    if len(ids) < 2 or len(set(p)) != 1 or any(r != rest[0] for r in rest) or any(g != geo[0] for g in geo):
        sys.exit(f'compose.py: live moments {ids} are not one page and one lens at different times')
    every = int(rest[0].get('every', 0))
    hist = [int(d['history']) for d in q]
    if every <= 0 or any(b - a != 1 for a, b in zip(hist, hist[1:])):
        sys.exit(f'compose.py: live moments {ids}: history {hist} every {every} (one new message apart, every > 0)')
    return [every] * (len(ids) - 1)


def frame_html(loc, f, out):
    place, steps = [], []
    # the modifier-key glyphs come from a fallback face with wide side bearings: only their spacing is tightened
    keys = lambda t: re.sub('([⌃⌥⇧⌘]+)', r'<span class="k">\1</span>', html.escape(t))
    hl, sub = keys(f['headline']), keys(f['sub'])
    body = [f'<div class="bg" style="background:{backdrop(f["hue"])}"></div>',
            f'<header class="cap"><h1>{hl}</h1><p>{sub}</p></header>']
    scene = frame_scenes(f)[0]
    render = os.path.join(HERE, 'renders', f'{scene}.{f["tgt"]}.png')
    if f['layout'] == 'live':
        # the same lens at moments of a changing page, left to right, each card its own real render, the cards running to the
        # bottom edge; between two moments an arrow and the seconds that passed, above the seam (never on a card)
        ids = frame_scenes(f)
        _, _, cw, ch = CFG['scenes'][ids[0]]['crop']
        left = (W - len(ids) * cw - (len(ids) - 1) * LIVE_GAP) // 2
        at = [(left + k * (cw + LIVE_GAP), H - ch) for k in range(len(ids))]
        radius = f'{CARD_RADIUS}px {CARD_RADIUS}px 0 0'
        body += [shade_html(sid, a, radius) for sid, a in zip(ids, at)]
        for sid, a in zip(ids, at):
            body.append(card_html(out, sid, a, radius, os.path.join(HERE, 'renders', f'{sid}.{f["tgt"]}.png'), SPECTRUM, place, flat=True))
        aw, lw, sg, sh = STEP_BOX
        for k, secs in enumerate(live_steps(ids)):
            x = left + (k + 1) * cw + k * LIVE_GAP + LIVE_GAP // 2 - (aw + sg + lw) // 2
            y = H - ch - STEP_ABOVE - sh
            body.append(f'<div class="step" style="left:{x}px;top:{y}px"><div class="arrows">→</div><div class="label">+{secs}s</div></div>')
            steps.append({'text': f'+{secs}s', 'rect': [x, y, aw + sg + lw, sh], 'arrow': [x, y, aw, sh], 'label': [x + aw + sg, y, lw, sh]})
    elif f['layout'] in ('top', 'panel'):
        body.append(card_html(out, scene, TOP_CARD, f'{CARD_RADIUS}px {CARD_RADIUS}px 0 0', render, SPECTRUM, place))
    elif f['layout'] == 'pair':
        _, _, cw, ch = CFG['scenes'][scene]['crop']
        left = (W - 2 * cw - PAIR_GAP) // 2
        right = left + cw + PAIR_GAP
        # left: the lens showing the original (its ring turns grey, as the app's does); right: the same lens translating
        body.append(card_html(out, scene, (left, PAIR_Y), f'{CARD_RADIUS}px', None, MONO, place))
        body.append(card_html(out, scene, (right, PAIR_Y), f'{CARD_RADIUS}px', render, SPECTRUM, place))
        lx, ly, lw, lh = CFG['scenes'][scene]['lens']
        cyc = PAIR_Y + ly + lh // 2
        cap = f'style="background-image:url({rel(keycap(out), out)})"'
        body.append(f'<div class="chip" style="left:{left + cw}px;width:{PAIR_GAP}px;top:{cyc - 48}px">'
                    f'<div class="arrows">⇄</div><div class="keys">'
                    + ''.join(f'<span {cap}>{k}</span>' for k in ('⌃', '⌥', 'O')) + '</div></div>')
    if f['layout'] == 'panel':
        p = os.path.join(HERE, 'renders', f'menu.{f["panel"]}.png')
        pw, ph = Image.open(p).size
        body.append(f'<div class="panel" style="left:{PANEL_AT[0]}px;top:{PANEL_AT[1]}px;width:{pw // 2}px;height:{ph // 2}px">'
                    f'<img src="{rel(p, out)}" style="width:{pw // 2}px;height:{ph // 2}px"></div>')
        place.append({'kind': 'panel', 'file': os.path.relpath(p, HERE), 'rect': [PANEL_AT[0], PANEL_AT[1], pw // 2, ph // 2],
                      'shadow': list(PANEL_SHADOW)})
    doc = (f'<!doctype html><html lang="{loc}"><head><meta charset="utf-8"><title>{loc}-{f["n"]}</title>'
           f'<style>{CSS}</style></head><body>{"".join(body)}</body></html>\n')
    return doc, place, steps


def sha(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()


def provenance(layout):
    run = open(os.path.join(HERE, 'renders', 'RUN.txt')).read().rstrip()
    L = ['# Provenance of the App Store screenshots',
         '',
         'Generated by `compose.py html` from `scenes.json` and `renders/`; do not edit. Every translated pixel in a frame is a pixel',
         'of a `renders/<scene>.<target>.png` that `Mwoyeo --render` wrote, placed at scale 1.0 (one 2x pixel per frame pixel) and',
         'clipped to the lens; every other page pixel is the source card; the menu panel is `Mwoyeo --capture-ui menu-default`.',
         '`compose.sh` checks this pixel for pixel (check.py: `truth`).',
         '',
         'Render command (render.sh, the lens picture is the card cropped to the lens):',
         '',
         '    Mwoyeo --render <lens picture> renders/<scene>.<tgt>.png --src <src> --tgt <tgt> --scale 2 --warm --max-wait 240',
         '',
         'Run:',
         '',
         *['    ' + l for l in run.splitlines()],
         '',
         '## Scenes',
         '',
         '| scene | source | window (pt) | card crop (pt, in the window) | lens (pt, in the card) | shown in |',
         '|---|---|---|---|---|---|']
    for sid, s in CFG['scenes'].items():
        where = (f'`demo/{s["page"]}`, headless Chrome at 2x' if 'page' in s else
                 f'`tools/paper-own/mwoyeo-method` main.pdf (build.sh) page {s["pdf"]} at {s["pdf_scale"]} px/pt')
        shown = ', '.join(k for k in sorted(layout) if sid in layout[k]['scenes']) or f'retired: {s.get("retired", "no frame")}'
        L.append(f'| {sid} | {where} | {s["window"][0]}x{s["window"][1]} | {s["crop"]} | {s["lens"]} | {shown} |')
    L += ['', '## Frames', '', '| frame | scene | render (scale 1.0) | render sha256 | source sha256 | lens in the frame (pt) |',
          '|---|---|---|---|---|---|']
    for key in sorted(layout):
        fr = layout[key]
        srcs = [p for p in fr['placed'] if p['kind'] == 'source']
        rnds = [p for p in fr['placed'] if p['kind'] == 'render']
        panel = [p for p in fr['placed'] if p['kind'] == 'panel']
        live = fr['layout'] == 'live'
        for k, r in enumerate(rnds if live else rnds[:1] or [None]):
            name = f'{key} {k + 1}/{len(rnds)}' if live else key
            src = srcs[k] if live else srcs[0]
            L.append(f'| {name} | {fr["scenes"][k] if live else fr["scene"]} {fr["src"]}>{fr["tgt"]} | {r["file"] if r else "-"} | '
                     f'{sha(os.path.join(HERE, r["file"]))[:16] if r else "-"} | {sha(os.path.join(HERE, src["file"]))[:16]} | '
                     f'{r["rect"] if r else src["lens"]} |')
        for p in panel:
            L.append(f'| {key} panel | menu-default | {p["file"]} | {sha(os.path.join(HERE, p["file"]))[:16]} | - | panel at {p["rect"]} |')
    pairs = ', '.join(k for k in sorted(layout) if layout[k]['layout'] == 'pair')
    lives = ', '.join(k for k in sorted(layout) if layout[k]['layout'] == 'live')
    kept = ', '.join(f'{k} ({layout[k]["scene"]}.keep)' for k in sorted(layout) if 'keep' in CFG['scenes'][layout[k]['scene']])
    L += ['', f'The pair frames ({pairs}) show the same lens twice: on the left showing the original (the source, grey ring), on the',
          'right translating.',
          f'The live frames ({lives}) show one lens at moments of one page, left to right (k/n in the table): each moment is its own',
          'page state shot and rendered on its own; the page adds a message every `every` seconds and the moments are one message',
          'apart, so the label above the seam between two moments (+<every>s, compose.py live_steps) is the time that passed on the page.',
          f'Paper frames show our English paper translated en>ko; `check.py` measures their formula boxes in the render against the source:',
          f'{kept}. A retired scene is one no frame shows any more; its renders stay in `renders/` as the record of why.',
          'A partial render.sh run adds a `rerun` line to RUN.txt; the last line naming a scene made its current render. A `recut` line',
          'says a scene\'s source card was cut again from the recorded card (new crop in scenes.json) and its renders were left as they were.', '']
    notes = [f'- {sid}: {s["note"]}' for sid, s in CFG['scenes'].items() if 'note' in s]
    if notes:
        L += ['Notes:', '', *notes, '']
    open(os.path.join(HERE, 'PROVENANCE.md'), 'w').write('\n'.join(L))


def build_html(out):
    os.makedirs(work(out, 'html'), exist_ok=True)
    layout = {}
    for loc, frames in CFG['frames'].items():
        for f in frames:
            doc, place, steps = frame_html(loc, f, out)
            open(work(out, 'html', f'{loc}-{f["n"]}.html'), 'w', encoding='utf-8').write(doc)
            ids = frame_scenes(f)
            layout[f'{loc}-{f["n"]}'] = {'loc': loc, 'n': f['n'], 'scene': ids[0], 'scenes': ids, 'src': CFG['scenes'][ids[0]]['src'],
                                         'tgt': f['tgt'], 'layout': f['layout'], 'placed': place, 'steps': steps}
    # the headline's face at its size, for the cap-height check
    for loc in CFG['frames']:
        open(work(out, 'html', f'probe-{loc}.html'), 'w', encoding='utf-8').write(
            f'<!doctype html><html lang="{loc}"><head><meta charset="utf-8"><style>{CSS}</style></head><body style="background:#000">'
            f'<header class="cap"><h1>HHHH</h1></header></body></html>\n')
    json.dump(layout, open(os.path.join(out, 'layout.json'), 'w'), indent=1, ensure_ascii=False)
    provenance(layout)
    print(f'html {len(layout)} frames')


def finish(out):
    icc = open(SRGB, 'rb').read()
    for loc, frames in CFG['frames'].items():
        os.makedirs(os.path.join(out, loc), exist_ok=True)
        for f in frames:
            raw = Image.open(work(out, 'raw', f'{loc}-{f["n"]}.png'))
            if raw.size != (2 * W, 2 * H):
                sys.exit(f'compose.py: {loc}-{f["n"]} is {raw.size}')
            rgb = Image.frombytes('RGB', raw.size, raw.convert('RGB').tobytes())
            rgb.save(os.path.join(out, loc, f'{f["n"]}.png'), icc_profile=icc, compress_level=9)
    print('finish done')


def calib(d):
    os.makedirs(d, exist_ok=True)
    region = (40, 60, 360, 200)
    for name, bg, colors, ring, glow in (('light-emphasized', '#f5f5f5', SPECTRUM, 1.0, 0.7), ('dark-rest', '#1f1f1f', SPECTRUM, 0.8, 0.35)):
        open(os.path.join(d, f'{name}.html'), 'w').write(
            f'<!doctype html><html><head><meta charset="utf-8"><style>{CSS} html,body{{width:440px;height:340px;background:{bg}}}</style>'
            f'</head><body>{lens(region, colors, ring, glow)}</body></html>\n')
    print(f'calib {d}')


def main(a):
    if a[:1] == ['html'] and len(a) == 2:
        build_html(a[1])
    elif a[:1] == ['finish'] and len(a) == 2:
        finish(a[1])
    elif a[:1] == ['calib'] and len(a) == 2:
        calib(a[1])
    else:
        sys.exit(__doc__)


if __name__ == '__main__':
    main(sys.argv[1:])
