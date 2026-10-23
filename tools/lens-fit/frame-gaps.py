#!/usr/bin/env python3
"""frame-gaps: the longest stretch the main thread went without stepping the lens, in one take (round snap117).

  frame-gaps.py <take dir or app.err> [--after "fit: auto"] [--first N] [--hz 60]

app.err (MWOYEO_TRACE=1) has one `lens frame resize|move x y w h` line per display frame the lens was placed on (`RegionSession.traceFrame`), each stamped
with the take's clock (ns of CLOCK_UPTIME_RAW). A burst is a run of such lines less than 100 ms apart; its gaps are the time between consecutive lines. A gap
of 2 frames or more at the display's rate (8.3 ms at 120 Hz) is the main thread busy with something else (the display link fires on the main run loop).
`--after TEXT`: only the burst that begins after the first line that has TEXT (the Auto Fit take: "fit: auto"); `--first N`: print its first N gaps.
`--hz`: the rate frames are counted at (default 60: a 16.7 ms frame, as the video of a take sees it).
"""
import os, re, sys

LINE = re.compile(r'^(\d+) \[trace\] (.*)$')
FRAME = re.compile(r'^lens frame (resize|move) ')


def bursts(path, after=None):
    t_after = None
    frames = []
    for l in open(path, errors='replace'):
        m = LINE.match(l.rstrip('\n'))
        if not m: continue
        t, text = int(m[1]), m[2]
        if after and t_after is None and after in text: t_after = t
        if FRAME.match(text): frames.append((t, text))
    if after:
        frames = [f for f in frames if t_after is not None and f[0] >= t_after]
    out, cur = [], []
    for f in frames:
        if cur and f[0] - cur[-1][0] > 100_000_000:
            out.append(cur); cur = []
        cur.append(f)
    if cur: out.append(cur)
    return out


def main():
    args = [a for a in sys.argv[1:]]
    if not args: sys.exit(__doc__)
    take = args[0]
    path = take if take.endswith('.err') else os.path.join(take, 'app.err')
    after = args[args.index('--after') + 1] if '--after' in args else None
    first = int(args[args.index('--first') + 1]) if '--first' in args else 0
    hz = float(args[args.index('--hz') + 1]) if '--hz' in args else 60.0
    bs = bursts(path, after)
    if after: bs = bs[:1]
    for i, b in enumerate(bs):
        gaps = [(b[k][0] - b[k - 1][0]) / 1e6 for k in range(1, len(b))]
        if not gaps: continue
        worst = max(gaps)
        srt = sorted(gaps)
        print(f'burst {i}: frames={len(b)} span={(b[-1][0] - b[0][0]) / 1e6:.0f} ms median_gap={srt[len(srt) // 2]:.1f} ms max_gap={worst:.1f} ms '
              f'(= {worst * hz / 1000:.1f} frames at {hz:g} fps) at frame {gaps.index(worst) + 1}')
        if first: print('   first gaps (ms): ' + ' '.join(f'{g:.1f}' for g in gaps[:first]))


if __name__ == '__main__':
    main()
