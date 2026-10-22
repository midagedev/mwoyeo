#!/usr/bin/env python3
"""fast117: the timing series of tools/first-paint/series.sh. usage: summ.py <series dir>
Per scene and config: n, the median (min..max) of
  read    = first_request_ms           the lens added -> the first batch sent (the read; the same for every config)
  tr      = first_drawn - first_request  the first batch sent -> the first translated line drawn (what the first paint moves)
  first   = first_drawn_ms             the lens added -> the first Korean on screen
  final   = the first batch sent -> the first final text landing in the pipeline (a line kept as it is was drawn at once: only its landing counts;
            from the quick text's time and how long it stayed, `shown`; for a run without the setting, the first line drawn)
  shown   = median ms a quick text was on screen; chg = lines repainted / painted, dist = characters changed, refit = lines whose text size or height moved
and the 1-minute load average at start and end of each run (the series runs under the machine's natural load)."""
import re, sys, glob, os, statistics as st
d = sys.argv[1]
rows = {}
for out in sorted(glob.glob(f'{d}/*.out')):
    name = os.path.basename(out)[:-4]
    m = re.match(r'(.+?)-(autod|auto|hf-[a-z]+)-([a-z])-(\d+)$', name)
    if not m: continue
    scene, cfg, warm, rep = m.groups()
    text = open(out).read()
    fp = re.search(r'^first-paint: (.*)$', text, re.M)
    if not fp: continue
    kv = dict(re.findall(r'(\w+)=(\S+)', fp.group(1)))
    f = lambda k: int(kv[k]) if kv.get(k, '-') != '-' else None
    summ = dict(re.findall(r'(\w+)=(\d+)', re.search(r'^fp-summary: (.*)$', text, re.M).group(1)))
    shown = re.search(r'shown_ms\[p50=(\d+)', text)
    loads = re.findall(r'load=([\d.]+)', open(out[:-4] + '.load').read())
    req, drawn = f('first_request_ms'), f('first_drawn_ms')
    # the first final text landing: a painted line's final lands `shown_ms` after its quick text; a line that was not painted is final when drawn
    lands = [int(re.search(r'drawn_ms=(\d+)', l).group(1)) + int(re.search(r'shown_ms=(\d+)', l).group(1))
             for l in text.splitlines() if l.startswith('fp-line:') and 'quick_first=1' in l and re.search(r'shown_ms=\d+', l)]
    fin = min(lands) if lands else drawn
    rows.setdefault((scene, f'{cfg}-{warm}'), []).append(dict(
        rep=rep, read=req, tr=drawn - req if drawn and req else None, first=drawn, final=fin - req if fin and req else None,
        shown=int(shown.group(1)) if shown else None, painted=int(summ.get('painted', 0)), repainted=int(summ.get('repainted', 0)),
        dist=int(summ.get('chars_changed', 0)), refit=int(summ.get('refit', 0)), load=loads))
def med(v):
    v = [x for x in v if x is not None]
    return f'{st.median(v):.0f} ({min(v)}..{max(v)})' if v else '-'
print(f'{"scene":5} {"config":13} {"n":>2} {"read":>18} {"tr (batch->drawn)":>20} {"first (lens->Korean)":>22} {"final (batch->hf)":>20} {"shown":>6} {"chg":>5} {"dist":>5} {"refit":>5}  load start/end')
for (scene, cfg), rs in sorted(rows.items()):
    ls = [(r['load'][0], r['load'][-1]) for r in rs if r['load']]
    print(f'{scene:5} {cfg:13} {len(rs):>2} {med([r["read"] for r in rs]):>18} {med([r["tr"] for r in rs]):>20} {med([r["first"] for r in rs]):>22} '
          f'{med([r["final"] for r in rs]):>20} {med([r["shown"] for r in rs]):>6} '
          f'{sum(r["repainted"] for r in rs)}/{sum(r["painted"] for r in rs):<3} {sum(r["dist"] for r in rs):>5} {sum(r["refit"] for r in rs):>5}  '
          f'{min(float(a) for a, b in ls):.0f}..{max(float(b) for a, b in ls):.0f}')
