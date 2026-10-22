#!/usr/bin/env python3
"""first117: one scripted first-lens run on the exported main build, on the shared monotonic clock (CLOCK_UPTIME_RAW, ns).

  drive.py --label cold1 --mode cold|warm --out <dir> [--key-after S] [--wait S] [--page-x ..]

cold: the three e5rt cache dirs of the build's own id are removed first and the app starts under `ane-env.sh run cold` (the lease);
warm: the id's caches are kept (a pool-kind start).  A page picture sits in a window of its own (tools/pagewin); at --key-after seconds
after the app's start ^L (posted as HID keys) opens the picker, the pointer goes to the left column, a click places today's lens (560 x 320
centred on the click). What is recorded: windows of the app (tools/watch: picker, lens, onboarding), the lens interior against its first frame
(the translation arriving), every stderr line of the app with its time, the events posted. Nothing of the user's is read or written.
"""
import argparse, json, os, signal, subprocess, sys, threading, time

ROOT = '/tmp/r117/first117'
APP = '/tmp/latin-runs/dd-first117/Build/Products/Release/Mwoyeo.app/Contents/MacOS/Mwoyeo'
ANE = '/Users/hckim/repo/mwoyeo/tools/ane-env.sh'
def now(): return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)

ap = argparse.ArgumentParser()
ap.add_argument('--label', required=True); ap.add_argument('--mode', choices=['cold', 'warm'], required=True)
ap.add_argument('--out', required=True); ap.add_argument('--key-after', type=float, default=20.0)
ap.add_argument('--wait', type=float, default=420.0); ap.add_argument('--page', default=f'{ROOT}/data/page-b.png')
ap.add_argument('--no-key', action='store_true'); ap.add_argument('--sample-stalls', action='store_true'); ap.add_argument('--no-frames', action='store_true'); ap.add_argument('--picker-loop', type=int, default=0); ap.add_argument('--settings-extra', default='{}'); ap.add_argument('--rm-mark', action='store_true'); ap.add_argument('--extra', default='')
ap.add_argument('--second', action='store_true', help='after the first Korean, open the picker again and place a second lens (warm numbers on a running app)')
a = ap.parse_args()
os.makedirs(a.out, exist_ok=True)
APPID = open(f'{ROOT}/data/cold-id.txt').read().strip()
ev = []                      # (t_ns, source, dict)
lock = threading.Lock()
_f = open(f'{a.out}/events.jsonl', 'w', buffering=1)
def put(t, src, d):
    with lock:
        ev.append((t, src, d))
        _f.write(json.dumps(dict(t=t, src=src, d=d)) + '\n')
def log(src, **kw): put(now(), src, kw)

# --- the page window
pw = subprocess.Popen([f'{ROOT}/tools/pagewin', a.page, '40', '70', '1184', '640'], stdout=subprocess.PIPE, text=True)
line = pw.stdout.readline().split()
wx, wy, ww, wh = [int(v) for v in line[5:9]]       # the window's frame, top-left origin, title bar included
page_pid = int(line[3])
import atexit
atexit.register(lambda: pw.poll() is None and pw.terminate())
log('page', frame=[wx, wy, ww, wh])
time.sleep(1.0)
# today's click lens: 560 x 320 centred on the click, inside the window below its 28 pt title bar
px, py = wx + 340, wy + 28 + 220
lx = min(max(px - 280, wx), wx + ww - 560)
ly = min(max(py - 160, wy + 28), wy + wh - 320)
lens = [lx, ly, 560, 320]
log('plan', click=[px, py], lens=lens)

# --- caches, settings
caches = os.path.expanduser('~/Library/Caches')
subprocess.run(['defaults', 'delete', f'first117.{a.label}'], stderr=subprocess.DEVNULL)   # no saved lens from an earlier run of this label
if a.mode == 'cold':
    for suffix in ('', '.reader.lines', '.reader.docs'):
        subprocess.run(['rm', '-rf', f'{caches}/{APPID}{suffix}'])
# a hot key of our own: ^L belongs to the user's Mwoyeo (and to other rounds' apps), which must not hear this run
json.dump(dict(json.loads(a.settings_extra), shortcuts={'addLens': {'display': '⌃⌥⌘J', 'keyCode': 38, 'modifiers': 6400}}), open(f'{a.out}/settings.json', 'w'), ensure_ascii=False)
if a.rm_mark:
    try: os.remove(f'{caches}/{APPID}.reader.lines/programs-verified')
    except FileNotFoundError: log('note', msg='no programs-verified mark to remove')
env = dict(os.environ, MWOYEO_TRACE='1', MWOYEO_MEMORY_SECRETS='1', MWOYEO_SETTINGS_FILE=f'{a.out}/settings.json',
           MWOYEO_DEFAULTS_SUITE=f'first117.{a.label}')
kind = 'cold' if a.mode == 'cold' else 'pool'
cmd = [ANE, 'run', kind, '--', APP] + (a.extra.split() if a.extra else [])

# --- the app
t_spawn = now()
app = subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
def pump(stream, name):
    for l in stream:
        log(name, line=l.rstrip('\n'))
atexit.register(lambda: app.poll() is None and app.terminate())
threading.Thread(target=pump, args=(app.stderr, 'err'), daemon=True).start()
threading.Thread(target=pump, args=(app.stdout, 'out'), daemon=True).start()

def child_of(pid):
    r = subprocess.run(['pgrep', '-P', str(pid)], capture_output=True, text=True)
    return int(r.stdout.split()[0]) if r.stdout.split() else None
app_pid = None
t_wait_end = time.time() + 1800
while time.time() < t_wait_end and app_pid is None and app.poll() is None:
    app_pid = child_of(app.pid) if kind == 'cold' else app.pid
    if app_pid is None: time.sleep(0.02)
t_start = now()
log('app', pid=app_pid, spawn_ns=t_spawn, lease_wait_s=(t_start - t_spawn) / 1e9 if kind == 'cold' else 0.0)
if app_pid is None:
    print('no app'); sys.exit(1)

# --- watchers and the poster
wt = subprocess.Popen([f'{ROOT}/tools/watch', str(app_pid)] + ([] if a.no_frames else [str(v) for v in lens]), stdout=subprocess.PIPE, text=True, bufsize=1)
def pump_watch(proc, tag):
    for l in proc.stdout:
        try: d = json.loads(l)
        except Exception: continue
        src = tag if d['ev'] == 'frame' else ('watch' if tag == 'first' else 'watch2')
        put(d['t'], src, d)
threading.Thread(target=pump_watch, args=(wt, 'first'), daemon=True).start()
atexit.register(lambda: wt.poll() is None and wt.terminate())
po = subprocess.Popen([f'{ROOT}/tools/post'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
def post(cmdline):
    po.stdin.write(cmdline + '\n'); po.stdin.flush()
    t = int(po.stdout.readline().split()[1])
    put(t, 'post', dict(cmd=cmdline))
    return t

def find(pred, since=0, timeout=10.0):
    end = time.time() + timeout
    while time.time() < end:
        with lock:
            for t, s, d in ev:
                if t >= since and pred(s, d): return t, d
        time.sleep(0.005)
    return None

def big_window(s, d, layer_min=100):
    return s == 'watch' and d['ev'] in ('win+', 'win~') and d.get('layer', 0) >= layer_min and d['bounds'][2] >= 1000 and d.get('onscreen')
def lens_window(s, d):
    return s == 'watch' and d['ev'] == 'win+' and 20 <= d.get('layer', 0) <= 40 and d['bounds'][2] < 1000

def place(tag, since, px, py, lens, watcher):
    """^L, the pointer to the click point, the click; returns the times"""
    r = {}
    r['t_key'] = post('key 38 ctrl,opt,cmd')
    p = find(lambda s, d: big_window(s, d), since=r['t_key'] - 1_000_000, timeout=15)
    r['t_picker'] = p[0] if p else None
    if not p:
        return r
    time.sleep(0.45)                                   # the hand travels
    post(f'move {px - 120} {py - 60}'); time.sleep(0.12)
    post(f'move {px} {py}'); time.sleep(0.35)
    r['t_click'] = post(f'click {px} {py}')
    pc = find(lambda s, d: s == 'watch' and d['ev'] in ('win-', 'win~') and (d['ev'] == 'win-' or not d.get('onscreen', True)), since=r['t_click'], timeout=5)
    r['t_picker_gone'] = pc[0] if pc else None
    lw = find(lens_window, since=r['t_click'], timeout=15)
    r['t_lens'] = lw[0] if lw else None
    if lw:
        os.kill(watcher.pid, signal.SIGUSR1)           # the lens's first frame is the page as it was
    return r

def first_korean(since, timeout, rect_tag='first'):
    if a.no_frames:
        k = find(lambda s, d: s == 'err' and __import__('re').match(r'\[trace\] translate ×\d+ \d+ ms', d['line']), since=since, timeout=timeout)
        return (k[0], {'by': 'trace'}) if k else None
    """the first frame after `since` in which more than 2 % of the lens interior differ, twice in a row"""
    end = time.time() + timeout
    while time.time() < end:
        with lock:
            fr = [(t, d) for t, s, d in ev if s == rect_tag and d['ev'] == 'frame' and t >= since + 150_000_000]
        for i in range(1, len(fr)):
            if fr[i][1]['big'] > 0.02 and fr[i - 1][1]['big'] > 0.02: return fr[i - 1][0], fr[i - 1][1]
        time.sleep(0.05)
    return None

log('load', uptime=subprocess.run(['uptime'], capture_output=True, text=True).stdout.strip(), others=subprocess.run('pgrep -fl "Mwoyeo.app/Contents/MacOS/Mwoyeo" | wc -l', shell=True, capture_output=True, text=True).stdout.strip())
log('note', msg=f'waiting {a.key_after} s after the app start')
time.sleep(max(0, a.key_after - (now() - t_start) / 1e9))
res = {}
loop = []
for i in range(a.picker_loop):
    t_k = post('key 38 ctrl,opt,cmd')
    p = find(lambda s, d: big_window(s, d), since=t_k - 1_000_000, timeout=0.8)
    if not p and a.sample_stalls:
        log('stall', i=i)
        subprocess.run(['/usr/bin/sample', str(app_pid), '3', '-file', f'{a.out}/stall{i}.txt'], capture_output=True)
    if not p:
        p = find(lambda s, d: big_window(s, d), since=t_k - 1_000_000, timeout=20)
    time.sleep(0.5)
    t_e = post('key 53')
    g = find(lambda s, d: s == 'watch' and d['ev'] == 'win-', since=t_e, timeout=5)
    loop.append(dict(up_ms=round((p[0] - t_k) / 1e6, 1) if p else None, esc_ms=round((g[0] - t_e) / 1e6, 1) if g else None))
    time.sleep(0.7)
if loop: res['picker_loop'] = loop
if not a.no_key:
    res.update(place('first', t_start, px, py, lens, wt))
    if res.get('t_lens'):
        k = first_korean(res['t_lens'], a.wait)
        res['t_korean'] = k[0] if k else None
        res['frames_at_korean'] = k[1] if k else None
        log('korean', found=bool(k), **(k[1] if k else {}))
        time.sleep(1.5)
        subprocess.run(['screencapture', '-x', '-R', f'{wx},{wy},{ww},{wh}', f'{a.out}/after-first.png'])
    if a.second and res.get('t_korean'):
        time.sleep(2.0)
        px2, py2 = wx + 880, wy + 28 + 220
        lens2 = [min(max(px2 - 280, wx), wx + ww - 560), min(max(py2 - 160, wy + 28), wy + wh - 320), 560, 320]
        time.sleep(1.0)
        res['second'] = place('second', now(), px2, py2, lens2, wt)
res['t_start'] = t_start
if a.mode == 'cold':
    w = find(lambda s, d: s == 'err' and 'warm-up docs' in d['line'] and 'done' in d['line'], timeout=900)
    res['t_docs_warm'] = w[0] if w else None
    w = find(lambda s, d: s == 'err' and 'warm-up lines' in d['line'] and 'done' in d['line'], timeout=5)
    res['t_lines_warm'] = w[0] if w else None
pids = [str(app_pid)] + sorted({m for t_, s_, d_ in ev if s_ in ('out', 'err') for m in __import__('re').findall(r'reader: (?:lines|docs) pid=(\d+)', d_.get('line', ''))})
ps = subprocess.run(['ps', '-o', 'pid=,cputime=,rss=,etime=', '-p', ','.join(pids)], capture_output=True, text=True).stdout
log('cpu', ps=ps.strip().splitlines())
log('load', at='end', uptime=subprocess.run(['uptime'], capture_output=True, text=True).stdout.strip())
# --- the end
subprocess.run(['screencapture', '-x', f'{a.out}/end-screen.png'])
for p in (wt, po):
    try: p.terminate()
    except Exception: pass
app.terminate()
try: app.wait(timeout=20)
except Exception: app.kill()
pw.terminate()
def ms(x): return None if x is None else round((x - t_start) / 1e6, 1)
out = {k: (ms(v) if k.startswith('t_') else v) for k, v in res.items() if k != 'second'}
if 'second' in res: out['second'] = {k: (ms(v) if k.startswith('t_') else v) for k, v in res['second'].items()}
json.dump(out, open(f'{a.out}/summary.json', 'w'), indent=1)
print(json.dumps(out))
