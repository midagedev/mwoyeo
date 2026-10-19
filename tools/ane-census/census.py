#!/usr/bin/env python3
"""Census of the system's Neural Engine compiler and of the e5rt caches. It reads logs and directories; it never compiles.

  census.py net <svc.log> [...]        per service pid: networks compiled, busy seconds, bursts (a gap over 60 s starts a new one), the
                                       compile that never ended; per network signature (procedures + the three smallest Dram sizes)
                                       how often and how long it was compiled
  census.py window <start> [<end>]     one `/usr/bin/log show` of ANECompilerService for [start, end] (default now), saved to --out
                                       (default $TMPDIR/ane-census-<start>.log), then `net` on it. 'YYYY-MM-DD HH:MM:SS', local time.
                                       One call costs 10 s or more: take it once after a run, never per snapshot
  census.py tmp [<cache root>]         the `*.tmp.<pid>_<n>.bundle` leftovers of aborted compiles: pid, mtime, cache id
  census.py caches [<cache root>]      per cache id (the app, .reader.lines, .reader.docs): bundles, leftovers, created; ids per day
  census.py diag [<file or dir> ...]   the header of cpu_resource / .diag reports of ANECompilerService (default
                                       /Library/Logs/DiagnosticReports): when, pid, who the samples are on behalf of, the cpu line

Reading a census (round ane-root, 2026-10-19): a service pid that is "busy" 5 % of its life is not spinning; `etime` is the age of the
process, not CPU time. A burst of networks at gaps under 3 s is a queue, not a loop. Every Start has an End unless a client was killed.
"""
import collections, datetime, glob, os, re, subprocess, sys, tempfile

CACHE = 'com.apple.e5rt.e5bundlecache'
DEFAULT_ROOT = os.path.expanduser('~/Library/Caches')
DIAG_DIR = '/Library/Logs/DiagnosticReports'


def ts(s):
    return datetime.datetime.strptime(s, '%Y-%m-%d %H:%M:%S.%f')


def net(files):
    lines = set()
    for f in files:
        for l in open(f, errors='ignore'):
            if 'ANECompilerService[' in l:
                lines.add(l)
    lines = sorted(lines, key=lambda l: l[:23])
    cur, blocks = {}, []
    for l in lines:
        m = re.match(r'(\S+ \S+) .*ANECompilerService\[(\d+):\w+\] \(ANECompiler\) (Start|End) of compilation of network', l)
        if m:
            t, pid, kind = m.groups()
            if kind == 'Start':
                cur[pid] = {'t': t, 'pid': pid, 'dram': []}
            elif pid in cur:
                b = cur.pop(pid)
                b['end'] = t
                b['dur'] = (ts(t) - ts(b['t'])).total_seconds()
                blocks.append(b)
            continue
        m = re.search(r'ANECompilerService\[(\d+):\w+\].*Dram Required for procedure <private> is (\d+)', l)
        if m and m.group(1) in cur:
            cur[m.group(1)]['dram'].append(int(m.group(2)))
    print('== per pid')
    for pid in sorted({b['pid'] for b in blocks}):
        bs = [b for b in blocks if b['pid'] == pid]
        bursts, c = [], [bs[0]]
        for b in bs[1:]:
            if (ts(b['t']) - ts(c[-1]['end'])).total_seconds() > 60:
                bursts.append(c)
                c = [b]
            else:
                c.append(b)
        bursts.append(c)
        print('pid %s: %d networks, busy %.0f s' % (pid, len(bs), sum(b['dur'] for b in bs)))
        for c in bursts:
            print('   %s -> %s  n=%d busy=%.0f s' % (c[0]['t'][5:19], c[-1]['end'][11:19], len(c), sum(b['dur'] for b in c)))
    print('unfinished (Start without End):', {p: b['t'] for p, b in cur.items()} or 'none')
    print('== per network signature')
    sig = collections.defaultdict(list)
    for b in blocks:
        sig[(len(b['dram']), tuple(sorted(b['dram']))[:3])].append(b)
    for s, bs in sorted(sig.items(), key=lambda x: -sum(b['dur'] for b in x[1])):
        d = sorted(b['dur'] for b in bs)
        print('procedures=%2d  compiled %3d x  dur min/med/max = %.1f/%.1f/%.1f s  total %.0f s' % (s[0], len(bs), d[0], d[len(d) // 2], d[-1], sum(d)))


def window(start, end, out):
    out = out or os.path.join(tempfile.gettempdir(), 'ane-census-%s.log' % re.sub(r'\W', '', start))
    cmd = ['/usr/bin/log', 'show', '--start', start, '--style', 'compact', '--info', '--debug', '--predicate', 'process == "ANECompilerService"']
    if end:
        cmd += ['--end', end]
    with open(out, 'w') as f:
        subprocess.run(cmd, stdout=f, stderr=subprocess.DEVNULL, check=False)
    print('log: %s (%d bytes)' % (out, os.path.getsize(out)))
    net([out])


def caches(root):
    return sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d, CACHE)))


def tmp(root):
    n = 0
    for cid in caches(root):
        for dirpath, _, names in os.walk(os.path.join(root, cid, CACHE)):
            for name in names:
                m = re.search(r'\.tmp\.(\d+)_(\d+)', name)
                if not m:
                    continue
                n += 1
                mt = datetime.datetime.fromtimestamp(os.stat(os.path.join(dirpath, name)).st_mtime)
                print('pid %s  %s  %s  %s' % (m.group(1), mt.strftime('%Y-%m-%d %H:%M'), cid, name))
    print('%d leftover(s)' % n)


def count(root):
    days = collections.Counter()
    for cid in caches(root):
        base = os.path.join(root, cid, CACHE)
        bundles = leftovers = 0
        for _, _, names in os.walk(base):
            for name in names:
                if name.endswith('.bundle'):
                    if '.tmp.' in name:
                        leftovers += 1
                    else:
                        bundles += 1
        st = os.stat(base)
        born = datetime.datetime.fromtimestamp(getattr(st, 'st_birthtime', st.st_mtime))
        days[born.strftime('%m-%d')] += 1
        print('%s bundles=%d tmp=%d created=%s' % (cid, bundles, leftovers, born.strftime('%Y-%m-%d %H:%M')))
    print('%d cache dirs; created per day: %s' % (sum(days.values()), ', '.join('%s %d' % kv for kv in sorted(days.items())) or 'none'))


def diag(paths):
    files = []
    for p in paths or [DIAG_DIR]:
        files += sorted(glob.glob(os.path.join(p, 'ANECompilerService*.diag'))) if os.path.isdir(p) else [p]
    keys = ('Date/Time', 'End time', 'PID', 'Event', 'On Behalf Of', 'CPU')
    for f in files:
        try:
            head = open(f, errors='ignore').read(4000)
        except OSError as e:
            print('%s: unreadable (%s)' % (os.path.basename(f), e.strerror))
            continue
        fields = {m.group(1): m.group(2).strip() for m in re.finditer(r'^(%s):\s+(.*)$' % '|'.join(re.escape(k) for k in keys), head, re.M)}
        print('%s  pid %s  %s -> %s  %s' % (os.path.basename(f).split('_hckim')[0], fields.get('PID', '?'), fields.get('Date/Time', '?'), fields.get('End time', '?'), fields.get('Event', '')))
        for k in ('CPU', 'On Behalf Of'):
            if k in fields:
                print('    %s: %s' % (k, fields[k]))


def main(argv):
    out = None
    if '--out' in argv:
        i = argv.index('--out')
        out = argv[i + 1]
        del argv[i:i + 2]
    cmd, args = (argv[1] if len(argv) > 1 else ''), argv[2:]
    if cmd == 'net' and args:
        net(args)
    elif cmd == 'window' and args:
        window(args[0], args[1] if len(args) > 1 else None, out)
    elif cmd == 'tmp':
        tmp(args[0] if args else DEFAULT_ROOT)
    elif cmd == 'caches':
        count(args[0] if args else DEFAULT_ROOT)
    elif cmd == 'diag':
        diag(args)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
