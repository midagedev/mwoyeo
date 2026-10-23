#!/usr/bin/env python3
"""snap-capture: where a live resize's right edge stood against the column's edge, frame by frame, from one take (round snap117).

  snap-capture.py <take dir> [--json]

A take dir is what tools such as skinland117's drive.py leave: app.err (MWOYEO_TRACE=1: `lens frame resize x y w h` per frame, `snap: edge=right target=T
offset=O` as the guide comes up, and since snap117 `snap: live hand=H edge=E guide=G capturing=C` per frame), post.jsonl (every posted mouse event) and
events.jsonl (`lens` rects). One drag is a `down` to the next `up` in post.jsonl that has `lens frame resize` lines.

Per drag it prints, in the take's own clock (ns of CLOCK_UPTIME_RAW):
  frames          mouseDragged frames (+ the display frames of a held hand, which have the same trace line)
  entries         each run of frames with the hand edge within 8 pt of the target (kept while within 12): the frame it began on, and the first frame of the run
                  the shown edge is on the target (within 0.05 pt): the lag in frames and ms (0 frames: captured on the same frame)
  step            the largest per-frame step of the shown edge and of the hand's, and the largest ratio (shown / hand) over frames where the hand moved
  hold            the gaps of the hand's and of the shown edge to the target at the last frame before the up
  after the up    how far the lens's right edge moved after the up (the glide of a settle), and the ms until its last frame

The hand's edge is `snap: live hand=`; a take of a build without that line (the base) takes it from post.jsonl: the lens's right edge at the down (the last
`lens` event) plus the pointer's x less the down's x, at the pointer's last event before each frame.
"""
import json, os, re, sys

FRAME = re.compile(r'^(\d+) \[trace\] lens frame resize ([-\d.e]+) ([-\d.e]+) ([-\d.e]+) ([-\d.e]+)')
LIVE = re.compile(r'^(\d+) \[trace\] snap: live hand=([-\d.e]+) edge=([-\d.e]+) guide=(\w+) capturing=(\w+)')
ENTER = re.compile(r'^(\d+) \[trace\] snap: edge=(left|right) target=([-\d.e]+) offset=([-\d.e]+)')


def load(take):
    err = [l.rstrip('\n') for l in open(os.path.join(take, 'app.err'), errors='replace')]
    post = [json.loads(l) for l in open(os.path.join(take, 'post.jsonl'))]
    events = [json.loads(l) for l in open(os.path.join(take, 'events.jsonl'))]
    return err, post, events


def drags(post):
    out, cur = [], None
    for e in post:
        if e['e'] == 'down':
            cur = {'down': e, 'moves': [], 'up': None}
        elif e['e'] == 'drag' and cur:
            cur['moves'].append(e)
        elif e['e'] == 'up' and cur:
            cur['up'] = e
            out.append(cur)
            cur = None
    return out


def analyse(take):
    err, post, events = load(take)
    frames, lives, enters = [], [], []
    for l in err:
        m = FRAME.match(l)
        if m: frames.append((int(m[1]), float(m[2]), float(m[4])))               # t, left, width
        m = LIVE.match(l)
        if m: lives.append((int(m[1]), float(m[2]), float(m[3]), m[4] == 'true', m[5] == 'true'))
        m = ENTER.match(l)
        if m and m[2] == 'right': enters.append((int(m[1]), float(m[3])))      # t, target
    lens_events = [e for e in events if e['k'] == 'lens']
    report = []
    for d in drags(post):
        t0, t1 = d['down']['t'], d['up']['t']
        before_up = [f for f in frames if t0 <= f[0] <= t1]
        after_up = [f for f in frames if t1 < f[0] <= t1 + 1_500_000_000]
        start = [e for e in lens_events if e['t'] <= t0]
        start_right = (start[-1]['region'][0] + start[-1]['region'][2]) if start else None
        rows = []                                                                  # t, hand edge, shown edge, target
        for (t, left, width) in before_up:
            lv = [x for x in lives if t - 4_000_000 <= x[0] <= t]
            if lv:
                hand = lv[-1][1]
            elif start_right is not None:
                last = [m for m in d['moves'] if m['t'] <= t]
                hand = start_right + ((last[-1]['x'] if last else d['down']['x']) - d['down']['x'])
            else:
                hand = left + width
            tg = [x for x in enters if x[0] <= t]
            rows.append((t, hand, left + width, tg[-1][1] if tg else None))
        if not rows: continue
        # each run of frames with the hand within 8 pt of the target: the frame it began on, and the first frame of it the shown edge is on the target
        entries, i = [], 0
        while i < len(rows):
            if rows[i][3] is not None and abs(rows[i][1] - rows[i][3]) <= 8.0:
                j = i
                while j + 1 < len(rows) and rows[j + 1][3] is not None and abs(rows[j + 1][1] - rows[j + 1][3]) <= 12.0: j += 1     # the guide is kept to 12
                on = next((k for k in range(i, j + 1) if abs(rows[k][2] - rows[k][3]) <= 0.05), None)
                entries.append({'frame': i, 'run_frames': j - i + 1, 'hand_gap_at_entry': round(rows[i][1] - rows[i][3], 2), 'shown_gap_at_entry': round(rows[i][2] - rows[i][3], 2),
                                'captured_frame': on, 'lag_frames': None if on is None else on - i,
                                'lag_ms': None if on is None else round((rows[on][0] - rows[i][0]) / 1e6, 1),
                                'shown_gap_at_run_end': round(rows[j][2] - rows[j][3], 2)})
                i = j + 1
            else:
                i += 1
        steps = [abs(rows[k][2] - rows[k - 1][2]) for k in range(1, len(rows))]
        hsteps = [abs(rows[k][1] - rows[k - 1][1]) for k in range(1, len(rows))]
        ratios = [s / h for s, h in zip(steps, hsteps) if h > 1e-6]
        last = rows[-1]
        report.append({'frames': len(rows), 'entries': entries,
                       'max_edge_step': round(max(steps), 3) if steps else 0, 'max_hand_step': round(max(hsteps), 3) if hsteps else 0,
                       'max_step_ratio': round(max(ratios), 2) if ratios else None,
                       'hand_gap_at_up': None if last[3] is None else round(last[1] - last[3], 3),
                       'shown_gap_at_up': None if last[3] is None else round(last[2] - last[3], 3),
                       'edge_after_up': round(after_up[-1][1] + after_up[-1][2], 3) if after_up else None,
                       'moved_after_up': round(abs(after_up[-1][1] + after_up[-1][2] - last[2]), 3) if after_up else 0,
                       'ms_up_to_rest': round((after_up[-1][0] - t1) / 1e6) if after_up else None})
    return report


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not args: sys.exit(__doc__)
    rep = analyse(args[0])
    if '--json' in sys.argv:
        print(json.dumps(rep, indent=1))
    else:
        for i, r in enumerate(rep):
            print(f'drag {i}: ' + ' '.join(f'{k}={v}' for k, v in r.items() if k != 'entries'))
            for e in r['entries']: print('   entry: ' + ' '.join(f'{k}={v}' for k, v in e.items()))
