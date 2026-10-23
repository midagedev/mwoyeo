#!/usr/bin/env python3
"""What a live take's trace says at each of its stills (round edges117b; the numbers of film4 F1, F5 and F16). usage: python3 -I take-report.py <take dir>   (a `tools/drive.py` take: summary.json, app.err)
For each still (summary.json steps with k == still, at rec0 + s): the last `lens edges`, `lens rows`, `pipeline emit` and `lens columns` lines before it, the blocks the pipeline had drawn
that stand at the right edge of the capture (a `render` patch that ends within 4 px of the capture's width: a translation of a cut paragraph), and the marks of the take (fit, reach, planned)."""
import glob, json, re, sys
d = sys.argv[1]
s = json.load(open(f'{d}/summary.json'))
rec0 = s['rec0']
stills = [(st['name'], rec0 + int(st['s'] * 1e9)) for st in s['steps'] if st.get('k') == 'still']
rows = []
for l in open(f'{d}/app.err', errors='replace'):
    m = re.match(r'(\d+) \[trace\] (.*)', l.rstrip())
    if m: rows.append((int(m.group(1)), m.group(2)))
t0 = rows[0][0] if rows else 0
def last(pref, t):
    r = [b for (ts, b) in rows if ts <= t and b.startswith(pref)]
    return r[-1] if r else None
print(f'{d}: {len(rows)} trace lines; rec0 {rec0}')
for k, st in enumerate(s['steps']):
    if st.get('k') in ('mark',):
        print(f"  mark {st.get('label')} at take second {st['s']}")
marks = [(ts, b) for (ts, b) in rows if re.match(r'(fit:|reach:|lens planned|fit probe|capture \d+×)', b)]
for ts, b in marks: print(f'  {(ts - rec0) / 1e9:7.2f} s  {b[:170]}')
cap = None
for name, t in stills:
    print(f'--- still {name} at take second {(t - rec0) / 1e9:.2f}')
    for pref in ('lens edges', 'lens rows', 'pipeline emit', 'lens columns'):
        r = last(pref, t)
        print(f'    {r[:240] if r else "(no " + pref + " line)"}')
    # blocks drawn at the right edge of the capture: the render lines up to the still, the latest per source
    cw = None
    for (ts, b) in rows:
        if ts > t: break
        m = re.match(r'fast: OCR (\d+)×(\d+)px', b)
        if m: cw = int(m.group(1))
    drawn = {}
    for (ts, b) in rows:
        if ts > t: break
        m = re.match(r"render '([^']*)' patch (\d+),(\d+) (\d+)x(\d+) .* size (\S+) lines (\d+)", b)
        if m: drawn[m.group(1)] = (int(m.group(2)), int(m.group(4)), b)
    if cw:
        edge = [src for src, (x, w, b) in drawn.items() if x + w >= cw - 4]
        print(f'    capture {cw} px wide; {len(edge)} rendered blocks end within 4 px of its right edge: {edge}')

# What the lens translated, from the take's transcript (the Transcripts folder of the scratch export): a cut column's line ends show here as words that are not words ('posi', 'whi', 'tal').
for f in sorted(glob.glob(f'{d}/export/Transcripts/*.jsonl')):
    print(f'--- transcript {f.split("/")[-1]}')
    for l in open(f, errors='replace'):
        try: t = json.loads(l)
        except ValueError: continue
        o = t.get('original', '')
        print(f"    {t.get('time', '')[11:23]}  {o[:44]!r} ... {o[-26:]!r}")
