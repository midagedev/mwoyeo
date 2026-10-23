#!/usr/bin/env python3
"""prof-window: what the main thread was doing in a window of a take that has a Time Profiler recording (round snap117).

  prof-window.py <take dir> (--after "fit: auto" --ms 150 | --from <uptime ns> --to <uptime ns>) [--top 12] [--lead 40] [--samples] [--under NAME]

The take dir has app.err (MWOYEO_TRACE=1, stamped with CLOCK_UPTIME_RAW ns), events.jsonl with a `clock` event (wall_ns and up_ns taken together after the
recording began) and prof.trace (drive.py with `"xctrace": <seconds>` in the shot: `xcrun xctrace record --template 'Time Profiler' --attach <pid>`).
A sample's time is ns since the recording began; the trace's `start-date` (ms) and the clock pair put it on the take's clock (good to a ms or two).
`--after TEXT --ms N`: the window starts `--lead` ms before the first app.err line with TEXT and runs N ms from it.

Prints, for the main thread, the samples in the window in time order (1 ms each; a hole is a thread that was not running) with the frames of the stack
nearest the leaf and the first of ours; then the window's samples counted by the first frame of ours on the stack (Mwoyeo's own binary), and by the leaf.
"""
import collections, datetime, json, os, re, subprocess, sys
import xml.etree.ElementTree as ET


def export(take):
    trace = os.path.join(take, 'prof.trace'); xml = os.path.join(take, 'prof-time-profile.xml'); toc = os.path.join(take, 'prof-toc.xml')
    if not os.path.exists(xml):
        subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace, '--xpath', '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]', '--output', xml], check=True, capture_output=True)
        subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace, '--toc', '--output', toc], check=True, capture_output=True)
    return xml, toc


def uptime_of_sample_zero(take, toc):
    """The take's clock (ns, CLOCK_UPTIME_RAW) at the recording's first instant."""
    m = re.search(r'<start-date>([^<]+)</start-date>', open(toc).read())
    wall0 = int(datetime.datetime.fromisoformat(m[1]).timestamp() * 1e9)
    clock = [json.loads(l) for l in open(os.path.join(take, 'events.jsonl')) if '"clock"' in l]
    c = clock[-1]
    return c['up_ns'] + (wall0 - c['wall_ns'])


def rows(xml, keep):
    """(sample ns, thread, [(frame, binary), ...] leaf first, weight ns) of the time-profile rows whose sample time `keep(t)` accepts. An element that was
    written before (an `id`) is written again as `<tag ref="id"/>`, so every element with an id is kept and a row is read through them."""
    ids = {}
    for ev, el in ET.iterparse(xml, events=('end',)):
        if el.get('id'): ids[el.get('id')] = el
        if el.tag != 'row': continue
        def get(parent, tag):
            e = parent.find(tag)
            return ids[e.get('ref')] if e is not None and e.get('ref') else e
        t = int(get(el, 'sample-time').text)
        if keep(t):
            frames = []
            for f in get(el, 'tagged-backtrace').findall('frame'):
                f = ids[f.get('ref')] if f.get('ref') else f
                b = get(f, 'binary')
                frames.append((f.get('name', '?'), b.get('name', '?') if b is not None else '?'))
            w = get(el, 'weight')
            yield t, get(el, 'thread').get('fmt', ''), frames, int(w.text) if w is not None else 1_000_000
        el.clear()


def main():
    a = sys.argv[1:]
    if not a: sys.exit(__doc__)
    take = a[0]
    def opt(name, default=None, cast=str): return cast(a[a.index(name) + 1]) if name in a else default
    xml, toc = export(take)
    zero = uptime_of_sample_zero(take, toc)
    after, ms, lead = opt('--after'), opt('--ms', 150, float), opt('--lead', 40, float)
    if after:
        t0 = next(int(m[1]) for l in open(os.path.join(take, 'app.err'), errors='replace') if after in l and (m := re.match(r'^(\d+) ', l)))
        lo, hi = t0 - int(lead * 1e6), t0 + int(ms * 1e6)
    else:
        lo, hi = opt('--from', cast=int), opt('--to', cast=int)
    top = opt('--top', 12, int)
    got = [r for r in rows(xml, lambda t: lo <= zero + t <= hi)]
    threads = collections.Counter(r[1] for r in got)
    main_name = next((n for n, _ in threads.most_common() if 'Main Thread' in n), threads.most_common(1)[0][0] if threads else '')
    got = [r for r in got if r[1] == main_name]
    print(f'window {(hi - lo) / 1e6:.0f} ms: {len(got)} main-thread samples ({main_name})')
    ours = lambda b: b.startswith('Mwoyeo')
    if '--samples' in a:
        for t, th, frames, w in sorted(got):
            first = next((f for f, b in frames if ours(b)), None)
            print(f'  {(zero + t - lo) / 1e6:8.1f} ms  ' + ' < '.join(f[:60] for f, b in frames[:3]) + (f'   [ours: {first[:70]}]' if first else ''))
    by_ours, by_leaf = collections.Counter(), collections.Counter()
    for t, th, frames, w in got:
        first = next((f for f, b in frames if ours(b)), '(none)')
        by_ours[first] += 1; by_leaf[frames[0][0] if frames else '?'] += 1
    if '--under' in a:
        name = opt('--under')
        kids = collections.Counter()
        for t, th, frames, w in got:
            for k, (f, b) in enumerate(frames):
                if name in f:
                    kids[frames[k - 1][0] if k else '(self)'] += 1
                    break
        print(f'callees of {name} (samples whose stack has it, counted by the frame it called):')
        for k, v in kids.most_common(top): print(f'  {v:4d}  {k[:130]}')
    print('by the first frame of ours:')
    for k, v in by_ours.most_common(top): print(f'  {v:4d}  {k[:130]}')
    print('by the leaf:')
    for k, v in by_leaf.most_common(top): print(f'  {v:4d}  {k[:130]}')


if __name__ == '__main__':
    main()
