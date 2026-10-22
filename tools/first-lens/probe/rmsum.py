"""first117: the read-latency matrix of the picker's map read: one headless read of a full-display picture (3024 x 1964 px = 1512 x 982 pt)."""
import re, glob, os, statistics as st, collections
D = '/tmp/r117/first117/data/rm'
rows = collections.defaultdict(list)
for f in sorted(glob.glob(f'{D}/*-?.err')):
    name = os.path.basename(f)[:-4]
    sc, p, rep = name.rsplit('-', 2)
    t = open(f, errors='replace').read()
    m = re.search(r'seamless: document OCR \((\d+) blocks\) (\d+) ms', t)
    d = re.search(r'document read \(Docs service\) (\d+) ms', t)
    wu = re.search(r'reader warm-up lines \[[^\]]*\] done, (\d+) ms', t)
    load = open(f'{D}/{name}.load').read().split()
    rows[(sc, p)].append((int(m[2]) if m else None, int(m[1]) if m else None, int(d[1]) if d else None, float(load[1])))
print('%-14s %-6s %-26s %-8s %-22s %s' % ('picture', 'path', 'read+group ms (3 runs)', 'median', 'document read ms', 'blocks / load(1 min)'))
for (sc, p), v in rows.items():
    r = [x[0] for x in v if x[0] is not None]
    dd = [x[2] for x in v if x[2] is not None]
    print('%-14s %-6s %-26s %-8s %-22s %s / %s' % (sc, p, sorted(r), st.median(r) if r else '-', sorted(dd) if dd else '-', sorted({x[1] for x in v}), [int(x[3]) for x in v]))
