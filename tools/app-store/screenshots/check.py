#!/usr/bin/env python3
"""Checks of the frames compose.sh made (run with python3 -I). rc 1 on any FAIL.

  check.py <out>               every frame in <out>/<loc>/<n>.png against the contract, then the self-test
  check.py <out> --no-self-test

Each check names the failure it blocks:
  format    App Store Connect refuses a screenshot that is not 2880 x 1800, has an alpha channel, or is over 10 MB; an untagged
            PNG can be shown in another colour space (sRGB profile required)
  truth     a translated pixel retouched or redrawn (App Review 2.3.3/2.3.7): inside each lens the frame must equal the app's render
            exactly, on the rest of the card the source, on the panel the app's capture (max channel difference 0)
  keep      a paper frame claims display equations stay as written: in the render each formula box (scenes.json <scene>.keep)
            equals the source
  caption   a caption over the lens, or a headline that wraps to a second line
  coverage  the app scene (cards and panel) under 55 % of the frame
  capheight the headline's capital height under 80 px at 2880 wide (unreadable at the store's thumbnail size)
  live      a live frame claims the screen changed under one lens: its cards must be one page (same file, window, crop, lens and
            parameters) at history counts one message apart, placed left to right at one height with the lens in the same place in
            each (a lens moved, another page or a skipped message would show a change the screen did not make)
  cut       a live frame whose cards show too much of the page that does not change: the lens (the only part that changes from
            moment to moment) starting below 40 % of the card, or with no original line above it (the in-place effect unreadable)
  step      the arrow and "+3s" between two moments too small to read at the store's thumbnail size (the label's capitals under
            63 px high at 2880 wide, 14 px at 640; the arrow under 82 px wide), the label saying other than the seconds the pages
            show, or a row not above the cards
  count     a locale folder that is not exactly the frames scenes.json lists, numbered 01.. without a gap, 1 to 10 of them
            (asc.py uploads every PNG in the folder in name order, and App Store Connect takes at most 10 per set)
The self-test breaks a copy of a frame once per check and expects that check to FAIL (FAIL-first).
"""
import copy, json, os, sys, urllib.parse

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
CFG = json.load(open(os.path.join(HERE, 'scenes.json'), encoding='utf-8'))
FW, FH = 2880, 1800
GLOW_ZONE = 24          # CSS px around a lens where the ring and glow may change the source (glow: 3 px out + blur 5)
SHADOW_TAIL = 24        # CSS px past a shadow's offset + blur where its Gaussian tail still rounds a pixel by 1
# 2026-10-19 as3b (vision FIX on frame 01: at 640 px wide the three panels read as the same chat, "+3s" was 5 px high). The cut:
# a live card's unchanged top (lens y over card height) at most 40 %, measured 212/566 = 37.5 % (was 334/688 = 48.5 %); 566 pt is
# the shortest panel the 55 % coverage floor allows for 3 x 420 pt cards (3 x 420 x 566 / (1440 x 900) = 55.03 %), so the share
# cannot go lower here without moving that floor. The label: capitals >= 63 px at 2880 (= 14 px at 640; it was 24, 5.3 px),
# the arrow >= 82 px wide (2 x the 41 px it was).
LIVE_TOP_MAX, LIVE_TOP_MIN_PT = 0.40, 24
STEP_CAP_MIN, STEP_ARROW_MIN = 63, 82


def load(path):
    return np.asarray(Image.open(path).convert('RGB')).astype(np.int16)


def box(r, grow=0):
    x, y, w, h = r
    return [2 * (x - grow), 2 * (y - grow), 2 * (x + w + grow), 2 * (y + h + grow)]


def inner_mask(w, h, radii):
    """True on a w x h picture except the corner squares of its rounded clip (radii: top-left, top-right, bottom-right,
    bottom-left, in CSS px): the part the clip leaves untouched."""
    m = np.ones((h, w), bool)
    tl, tr, br, bl = (2 * r for r in radii)
    m[:tl, :tl] = False
    m[:tr, w - tr:] = False
    m[h - br:, w - br:] = False
    m[h - bl:, :bl] = False
    return m


def check_format(path, im):
    errs = []
    if im.size != (FW, FH):
        errs.append(f'size {im.size[0]}x{im.size[1]}')
    if im.mode != 'RGB' or 'transparency' in im.info:
        errs.append(f'mode {im.mode}{" with transparency" if "transparency" in im.info else ""} (alpha not allowed)')
    if b'sRGB' not in (im.info.get('icc_profile') or b''):
        errs.append('no sRGB profile')
    if os.path.getsize(path) > 10 * 1024 * 1024:
        errs.append(f'{os.path.getsize(path) / 1e6:.1f} MB > 10 MB')
    return errs


def check_truth(frame, placed, pics):
    errs, notes = [], []
    zones = []
    for p in placed:
        if p['kind'] == 'source':
            zones.append(box(p['lens'], GLOW_ZONE))
        if p['kind'] == 'panel':
            zones.append(box(p['rect'], sum(p['shadow']) + SHADOW_TAIL))
    for p in placed:
        x0, y0, x1, y1 = box(p['rect'])
        pic = pics[p['file']]
        h, w = pic.shape[:2]
        if (x1 - x0, y1 - y0) != (w, h):
            errs.append(f'{p["file"]} placed at {x1 - x0}x{y1 - y0}, picture is {w}x{h} (scale must be 1.0)')
            continue
        fx0, fy0, fx1, fy1 = max(x0, 0), max(y0, 0), min(x1, FW), min(y1, FH)
        got = frame[fy0:fy1, fx0:fx1]
        want = pic[fy0 - y0:fy1 - y0, fx0 - x0:fx1 - x0]
        mask = inner_mask(w, h, p.get('radius', [0] * 4))[fy0 - y0:fy1 - y0, fx0 - x0:fx1 - x0]
        if p['kind'] == 'panel':
            mask &= pics[p['file'] + '#alpha'][fy0 - y0:fy1 - y0, fx0 - x0:fx1 - x0] == 255
        if p['kind'] == 'source':
            for zx0, zy0, zx1, zy1 in zones:
                mask[max(zy0 - fy0, 0):max(zy1 - fy0, 0), max(zx0 - fx0, 0):max(zx1 - fx0, 0)] = False
        diff = np.abs(got[..., :3] - want[..., :3]).max(axis=2)[mask]
        worst = int(diff.max()) if diff.size else 0
        notes.append(f'{p["kind"]} {os.path.basename(p["file"])} {int(mask.sum())} px max {worst}')
        if worst != 0:
            errs.append(f'{p["kind"]} {p["file"]}: {int((diff > 0).sum())} px differ (max {worst})')
    return errs, notes


def check_keep(render, source_card, scene):
    s = CFG['scenes'][scene]
    lx, ly, lw, lh = s['lens']
    src = source_card[2 * ly:2 * (ly + lh), 2 * lx:2 * (lx + lw)]
    errs, notes = [], []
    for name, (x, y, w, h) in s['keep'].items():
        a = render[2 * y:2 * (y + h), 2 * x:2 * (x + w), :3]
        b = src[2 * y:2 * (y + h), 2 * x:2 * (x + w), :3]
        worst = int(np.abs(a - b).max())
        notes.append(f'{name} {a.shape[1]}x{a.shape[0]} px max {worst}')
        if worst != 0:
            errs.append(f'{name}: the render changed the formula (max {worst})')
    return errs, notes


def check_caption(frame, placed, steps=()):
    """Rows of caption ink (near-white) above the scene: one headline band and one sub band, ending above every lens (and above
    the step rows of a live frame, which sit between the caption and the cards and are checked by check_step)."""
    top = min(box(p['rect'])[1] for p in placed)
    top = min([top] + [2 * s['rect'][1] for s in steps])
    lens_top = min(box(p['lens'])[1] for p in placed if p['kind'] == 'source')
    band = frame[:top, 120:FW - 120]
    ink = (band.min(axis=2) > 170).any(axis=1)
    rows = np.where(ink)[0]
    errs = []
    if rows.size == 0:
        return ['no caption ink'], []
    runs, start = [], rows[0]
    for a, b in zip(rows, rows[1:]):
        if b - a > 12:
            runs.append((start, a)); start = b
    runs.append((start, rows[-1]))
    if len(runs) != 2:
        errs.append(f'{len(runs)} text bands above the scene (headline wrapped?): {runs}')
    if rows[-1] >= lens_top:
        errs.append(f'caption ink at row {rows[-1]} reaches the lens (top {lens_top})')
    if steps and rows[-1] >= top - 12:
        errs.append(f'caption ink at row {rows[-1]} runs into the step rows (top {top})')
    return errs, [f'bands {[(int(a), int(b)) for a, b in runs]}']


def check_coverage(placed):
    m = np.zeros((FH // 2, FW // 2), bool)
    for p in placed:
        if p['kind'] in ('source', 'panel'):
            x, y, w, h = p['rect']
            m[max(y, 0):y + h, max(x, 0):x + w] = True
    share = m.mean()
    return ([f'scene covers {share:.1%} < 55 %'] if share < 0.55 else []), [f'scene {share:.1%}']


def check_capheight(probe):
    a = load(probe)
    rows = np.where((a.min(axis=2) > 128).any(axis=1))[0]
    h = int(rows[-1] - rows[0] + 1) if rows.size else 0
    return ([f'cap height {h} px < 80'] if h < 80 else []), [f'cap height {h} px (at 640 wide: {h * 640 / FW:.1f} px)']


def check_live(placed, scenes):
    """placed: a live frame's placements; scenes: the scenes.json entries of its moments, in time order."""
    errs = []
    urls = [urllib.parse.urlsplit(s.get('page', '')) for s in scenes]
    q = [dict(urllib.parse.parse_qsl(u.query)) for u in urls]
    rest = [({k: v for k, v in d.items() if k != 'history'}, u.path, s.get('window'), s.get('crop'), s.get('lens'), s.get('budget'))
            for d, u, s in zip(q, urls, scenes)]
    if len(scenes) < 2 or any(r != rest[0] for r in rest):
        errs.append('the moments are not one page, window, crop and lens')
    try:
        hist = [int(d['history']) for d in q]
    except (KeyError, ValueError):
        hist = []
    if not hist or any(b - a != 1 for a, b in zip(hist, hist[1:])) or int(q[0].get('every', 0)) <= 0:
        errs.append(f'history {hist or "missing"}, every {q[0].get("every") if q else None}: not one new message apart')
    srcs = [p for p in placed if p['kind'] == 'source']
    offs = {(p['lens'][0] - p['rect'][0], p['lens'][1] - p['rect'][1], p['lens'][2], p['lens'][3], p['rect'][2], p['rect'][3]) for p in srcs}
    if len(srcs) != len(scenes) or len(offs) != 1:
        errs.append(f'{len(srcs)} cards for {len(scenes)} moments, lens/card geometry {sorted(offs)}')
    if any(b['rect'][0] < a['rect'][0] + a['rect'][2] or b['rect'][1] != a['rect'][1] for a, b in zip(srcs, srcs[1:])):
        errs.append('the cards are not left to right at one height')
    return errs, [f'{len(srcs)} moments, history {hist}, every {q[0].get("every") if q else None} s, one lens']


def check_cut(placed):
    """placed: a live frame's placements. The lens's offset in each card, over the card's height."""
    errs, notes = [], []
    for p in (q for q in placed if q['kind'] == 'source'):
        off, h = p['lens'][1] - p['rect'][1], p['rect'][3]
        notes.append(f'lens at {off} of {h} pt ({off / h:.1%})')
        if off / h > LIVE_TOP_MAX:
            errs.append(f'{os.path.basename(p["file"])}: the unchanged top is {off / h:.1%} of the card (> {LIVE_TOP_MAX:.0%})')
        if off < LIVE_TOP_MIN_PT:
            errs.append(f'{os.path.basename(p["file"])}: {off} pt of original above the lens (< {LIVE_TOP_MIN_PT})')
    return errs, sorted(set(notes))


def ink_extent(frame, rect, axis):
    """First and last row (axis 0) or column (axis 1) of near-white ink in `rect` (CSS px) of the 2880 x 1800 frame."""
    x0, y0, x1, y1 = box(rect)
    ink = (frame[y0:y1, x0:x1].min(axis=2) > 128).any(axis=1 - axis)
    idx = np.where(ink)[0]
    return (int(idx[0]), int(idx[-1])) if idx.size else None


def check_step(frame, steps, placed, every, moments):
    """steps: a live frame's step rows (layout.json), one between each two of its `moments`; every: seconds between the pages."""
    errs, notes = [], []
    if len(steps) != moments - 1:
        errs.append(f'{len(steps)} step rows between {moments} moments')
    top = min(p['rect'][1] for p in placed)
    for s in steps:
        if s['text'] != f'+{every}s':
            errs.append(f'label {s["text"]!r}, the pages are {every} s apart')
        lab, arr = ink_extent(frame, s['label'], 0), ink_extent(frame, s['arrow'], 1)
        cap = lab[1] - lab[0] + 1 if lab else 0
        width = arr[1] - arr[0] + 1 if arr else 0
        notes.append(f'{s["text"]} capitals {cap} px (at 640 wide: {cap * 640 / FW:.1f}), arrow {width} px wide')
        if cap < STEP_CAP_MIN:
            errs.append(f'{s["text"]}: capitals {cap} px high < {STEP_CAP_MIN}')
        if width < STEP_ARROW_MIN:
            errs.append(f'{s["text"]}: arrow {width} px wide < {STEP_ARROW_MIN}')
        if s['rect'][1] + s['rect'][3] > top:
            errs.append(f'{s["text"]}: the row reaches the cards (bottom {s["rect"][1] + s["rect"][3]}, cards at {top})')
    return errs, notes


def check_count(files, numbers):
    """files: the PNGs in a locale folder; numbers: the frame numbers scenes.json lists for that locale."""
    want = [f'{i:02d}.png' for i in range(1, len(numbers) + 1)]
    errs = []
    if [f'{n}.png' for n in numbers] != want:
        errs.append(f'frames numbered {numbers}, not 01..{len(numbers):02d}')
    if not 1 <= len(numbers) <= 10:
        errs.append(f'{len(numbers)} frames (1 to 10 per set)')
    if sorted(files) != want:
        errs.append(f'the folder holds {sorted(files)}')
    return errs, [f'{len(files)} frames, {" ".join(sorted(files))}']


def keep_files(fr):
    """The render and the source card of a frame's scene, as check_keep reads them."""
    return f'renders/{fr["scene"]}.{fr["tgt"]}.png', f'renders/{fr["scene"]}.source.png'


def run(out, layout, frames, pics, probes):
    fails, lines = 0, []
    for key in sorted(layout):
        fr = layout[key]
        path = os.path.join(out, fr['loc'], f'{fr["n"]}.png')
        im = frames[key]
        arr = np.asarray(im.convert('RGB')).astype(np.int16)
        results = {'format': (check_format(path, im), [f'{os.path.getsize(path) / 1e6:.1f} MB']),
                   'truth': check_truth(arr, fr['placed'], pics),
                   'caption': check_caption(arr, fr['placed'], fr['steps']),
                   'coverage': check_coverage(fr['placed'])}
        if 'keep' in CFG['scenes'][fr['scene']]:
            render, source = keep_files(fr)
            results['keep'] = check_keep(pics[render], pics[source], fr['scene'])
        if fr['layout'] == 'live':
            moments = [CFG['scenes'][s] for s in fr['scenes']]
            every = int(dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(moments[0]['page']).query)).get('every', 0))
            results['live'] = check_live(fr['placed'], moments)
            results['cut'] = check_cut(fr['placed'])
            results['step'] = check_step(arr, fr['steps'], fr['placed'], every, len(moments))
        for name, (errs, notes) in results.items():
            fails += bool(errs)
            lines.append(f'{"FAIL" if errs else "ok  "} {key} {name}: {"; ".join(errs) if errs else ", ".join(notes)}')
    for loc, probe in probes.items():
        errs, notes = check_capheight(probe)
        fails += bool(errs)
        lines.append(f'{"FAIL" if errs else "ok  "} {loc} capheight: {"; ".join(errs) if errs else ", ".join(notes)}')
    for loc, frs in CFG['frames'].items():
        d = os.path.join(out, loc)
        files = sorted(f for f in os.listdir(d) if f.endswith('.png')) if os.path.isdir(d) else []
        errs, notes = check_count(files, [f['n'] for f in frs])
        fails += bool(errs)
        lines.append(f'{"FAIL" if errs else "ok  "} {loc} count: {"; ".join(errs) if errs else ", ".join(notes)}')
    return fails, lines


def load_all(out):
    layout = json.load(open(os.path.join(out, 'layout.json'), encoding='utf-8'))
    frames, pics = {}, {}
    for key, fr in layout.items():
        frames[key] = Image.open(os.path.join(out, fr['loc'], f'{fr["n"]}.png'))
        frames[key].load()
        for p in fr['placed']:
            if p['file'] not in pics:
                im = Image.open(os.path.join(HERE, p['file']))
                pics[p['file']] = np.asarray(im.convert('RGB')).astype(np.int16)
                if p['kind'] == 'panel':
                    pics[p['file'] + '#alpha'] = np.asarray(im.convert('RGBA'))[..., 3]
    probes = {loc: os.path.join(out, '.work', 'raw', f'probe-{loc}.png') for loc in CFG['frames']}
    return layout, frames, pics, probes


def self_test(out, layout, frames, pics, probes):
    """Each check on a broken copy must FAIL."""
    key = sorted(layout)[0]
    fr = layout[key]
    path = os.path.join(out, fr['loc'], f'{fr["n"]}.png')
    arr = np.asarray(frames[key].convert('RGB')).astype(np.int16)
    render = next(p for p in fr['placed'] if p['kind'] == 'render')
    source = next(p for p in fr['placed'] if p['kind'] == 'source')
    caught = []

    def pixel(a, r, dx, dy):
        b = a.copy()
        x, y = 2 * (r[0] + dx), 2 * (r[1] + dy)
        b[y, x, 0] = (b[y, x, 0] + 7) % 256
        return b
    caught.append(('truth: one translated pixel retouched', bool(check_truth(pixel(arr, render['rect'], 40, 40), fr['placed'], pics)[0])))
    caught.append(('truth: one source pixel outside the lens changed', bool(check_truth(pixel(arr, source['rect'], 8, source['rect'][3] - 4), fr['placed'], pics)[0])))
    scaled = copy.deepcopy(fr['placed'])
    next(p for p in scaled if p['kind'] == 'render')['rect'][2] -= 1
    caught.append(('truth: render placed at another scale', bool(check_truth(arr, scaled, pics)[0])))
    rgba = frames[key].convert('RGBA')
    rgba.info['icc_profile'] = frames[key].info.get('icc_profile')
    caught.append(('format: alpha channel', bool(check_format(path, rgba))))
    caught.append(('format: 2880 x 1799', bool(check_format(path, frames[key].crop((0, 0, FW, FH - 1))))))
    bare = Image.frombytes('RGB', frames[key].size, frames[key].tobytes())
    caught.append(('format: no sRGB profile', bool(check_format(path, bare))))
    kf = next(f for f in layout.values() if 'keep' in CFG['scenes'][f['scene']])
    render_file, source_file = keep_files(kf)
    paper = pics[render_file].copy()
    kx, ky, _, _ = next(iter(CFG['scenes'][kf['scene']]['keep'].values()))
    paper[2 * ky + 10, 2 * kx + 10, 1] ^= 0x20
    caught.append(('keep: one formula pixel changed', bool(check_keep(paper, pics[source_file], kf['scene'])[0])))
    lf = next(f for f in layout.values() if f['layout'] == 'live')
    moments = [CFG['scenes'][s] for s in lf['scenes']]
    moved = copy.deepcopy(lf['placed'])
    [p for p in moved if p['kind'] == 'source'][-1]['lens'][1] += 1
    caught.append(('live: the lens 1 pt lower in the last moment', bool(check_live(moved, moments)[0])))
    skipped = copy.deepcopy(moments)
    u = urllib.parse.urlsplit(skipped[-1]['page'])
    qd = dict(urllib.parse.parse_qsl(u.query))
    qd['history'] = str(int(qd['history']) + 1)
    skipped[-1]['page'] = urllib.parse.urlunsplit(u._replace(query=urllib.parse.urlencode(qd)))
    caught.append(('live: a message skipped between two moments', bool(check_live(lf['placed'], skipped)[0])))
    other = copy.deepcopy(moments)
    other[0]['page'] = other[0]['page'].replace('lang=ja', 'lang=en')
    caught.append(('live: one moment from another page', bool(check_live(lf['placed'], other)[0])))
    low = copy.deepcopy(fr['placed'])
    for p in low:
        if p['kind'] == 'source':
            p['lens'][1] = 20
    caught.append(('caption: lens moved under the caption', bool(check_caption(arr, low, fr['steps'])[0])))
    wrapped = arr.copy()
    wrapped[2 * 190:2 * 196, 400:2400] = 255
    caught.append(('caption: a third text band', bool(check_caption(wrapped, fr['placed'], fr['steps'])[0])))
    sub_low = arr.copy()
    sub_low[2 * 175:2 * fr['steps'][0]['rect'][1] - 2, 400:2400] = 255      # the sub line's ink continued down into the step rows
    caught.append(('caption: ink running into the step rows', bool(check_caption(sub_low, fr['placed'], fr['steps'])[0])))
    cut = copy.deepcopy(lf['placed'])
    for p in cut:
        if p['kind'] == 'source':
            p['rect'][3] = 688
            p['lens'][1] = p['rect'][1] + 334
    caught.append(('cut: the lens 334 pt down a 688 pt card (49 %, the card before as3b)', bool(check_cut(cut)[0])))
    none = copy.deepcopy(lf['placed'])
    for p in none:
        if p['kind'] == 'source':
            p['lens'][1] = p['rect'][1] + 8
    caught.append(('cut: no original line above the lens', bool(check_cut(none)[0])))
    every = int(dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(moments[0]['page']).query)).get('every', 0))
    big = np.asarray(frames[next(k for k, f in layout.items() if f is lf)].convert('RGB')).astype(np.int16)
    for what, name in (('label', 'label at half size'), ('arrow', 'arrow at half size')):
        small_step = big.copy()
        x0, y0, x1, y1 = box(lf['steps'][0][what])
        crop = Image.fromarray(big[y0:y1, x0:x1].astype(np.uint8))
        shrunk = np.asarray(crop.resize((crop.width // 2, crop.height // 2), Image.BOX)).astype(np.int16)
        small_step[y0:y1, x0:x1] = big[y0, x0]
        oy, ox = (y1 - y0 - shrunk.shape[0]) // 2, (x1 - x0 - shrunk.shape[1]) // 2
        small_step[y0 + oy:y0 + oy + shrunk.shape[0], x0 + ox:x0 + ox + shrunk.shape[1]] = shrunk
        caught.append((f'step: {name}', bool(check_step(small_step, lf['steps'], lf['placed'], every, len(moments))[0])))
    caught.append(('step: a label saying +9s over pages 3 s apart', bool(check_step(big, [{**lf['steps'][0], 'text': '+9s'}] + lf['steps'][1:], lf['placed'], every, len(moments))[0])))
    lowrow = copy.deepcopy(lf['steps'])
    lowrow[0]['rect'][1] += 40
    caught.append(('step: a row 40 px lower, on the cards', bool(check_step(big, lowrow, lf['placed'], every, len(moments))[0])))
    small = copy.deepcopy(fr['placed'])
    for p in small:
        p['rect'][2] //= 2
    caught.append(('coverage: half the scene', bool(check_coverage(small)[0])))
    tiny = os.path.join(out, '.work', 'raw', 'selftest-probe.png')
    half = Image.open(probes[next(iter(probes))]).reduce(2)
    canvas = Image.new('RGB', (FW, FH)); canvas.paste(half, (0, 0)); canvas.save(tiny)
    caught.append(('capheight: headline at half size', bool(check_capheight(tiny)[0])))
    os.remove(tiny)
    five = [f'{i:02d}.png' for i in range(1, 6)]
    caught.append(('count: a stray 06.png beside five frames', bool(check_count(five + ['06.png'], ['01', '02', '03', '04', '05'])[0])))
    caught.append(('count: frames numbered with a gap', bool(check_count(['01.png', '02.png', '04.png'], ['01', '02', '04'])[0])))
    caught.append(('count: eleven frames', bool(check_count([f'{i:02d}.png' for i in range(1, 12)], [f'{i:02d}' for i in range(1, 12)])[0])))
    return caught


def main(a):
    if not a or a[0].startswith('-'):
        sys.exit(__doc__)
    out = a[0]
    layout, frames, pics, probes = load_all(out)
    fails, lines = run(out, layout, frames, pics, probes)
    print('\n'.join(lines))
    print(f'check: {len(lines) - fails}/{len(lines)} ok, {fails} FAIL')
    total = sum(os.path.getsize(os.path.join(HERE, 'renders', f)) for f in os.listdir(os.path.join(HERE, 'renders')))
    print(f'renders/: {total / 1e6:.1f} MB')
    if '--no-self-test' not in a:
        caught = self_test(out, layout, frames, pics, probes)
        for name, ok in caught:
            print(f'{"ok  " if ok else "MISS"} self-test {name}: {"FAIL as it should" if ok else "passed a broken copy"}')
        missed = sum(1 for _, ok in caught if not ok)
        print(f'self-test: {len(caught) - missed}/{len(caught)} broken copies FAIL')
        fails += missed
    sys.exit(1 if fails else 0)


if __name__ == '__main__':
    main(sys.argv[1:])
