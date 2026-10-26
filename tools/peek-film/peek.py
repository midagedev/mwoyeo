#!/usr/bin/env python3
"""film: one take of the whole screen while held (Peek) on a stage of web windows. peek.py <shot.json> <out dir>  (out under /tmp/film4/takes)

shot: name, build (a /tmp/film4/builds snapshot), webs [{url, window [x y w h], app}], settings (merged over scratch defaults), steps:
  ["sleep", s] ["mark", label] ["path", ms, x0, y0, x1, y1] ["keydown", code, "ctrl,opt"] ["keyup", code, "ctrl,opt"]
Writes events.jsonl (uptime ns: rec, mark, keys), app.err (each stderr line with its uptime ns), <name>.mp4 (the main display, 60 fps).
Scratch state only (app.sh refuses otherwise); every process it starts is stopped at the end.
"""
import json, os, re, signal, subprocess, sys, threading, time

T = '/tmp/film4/tools'
def now(): return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)
def sh(cmd, **kw): return subprocess.run(cmd, capture_output=True, text=True, **kw)

shot = json.load(open(sys.argv[1])); out = sys.argv[2]; name = shot['name']
os.makedirs(f'{out}/export', exist_ok=True)
ev = open(f'{out}/events.jsonl', 'w', buffering=1)
def put(k, **d): ev.write(json.dumps(dict(t=now(), k=k, **d), ensure_ascii=False) + '\n')

settings = {"sourceLanguage": "auto", "targetLanguage": "ko", "checksForUpdates": False, "profiles": []}
settings.update(shot.get('settings', {}))
json.dump(settings, open(f'{out}/settings.json', 'w'), ensure_ascii=False, indent=2)
suite = 'film4.' + re.sub(r'[^a-z0-9]', '', name.lower())
env = dict(os.environ, MWOYEO_SETTINGS_FILE=f'{out}/settings.json', MWOYEO_DEFAULTS_SUITE=suite, MWOYEO_MEMORY_SECRETS='1', MWOYEO_TRACE='1')
r = sh([f'{T}/app.sh', shot['build'], '--check-settings', f'{out}/settings.json'], env=env)
if r.stdout.strip() != 'ok': sys.exit(f'peek: settings refused: {r.stdout} {r.stderr}')
sh(['defaults', 'delete', suite])
blob = b'{"hasCompletedOnboarding":true}'.hex()
for k in ('settings', 'settingsMirror'): sh(['defaults', 'write', suite, k, '-data', blob])

procs = []
def stop_all():
    for p in reversed(procs):
        if p.poll() is None:
            p.send_signal(signal.SIGINT if p.args[0] == 'ffmpeg' else signal.SIGTERM)
    for p in reversed(procs):
        try: p.wait(timeout=8)
        except subprocess.TimeoutExpired: p.kill()

try:
    webs = [f'backdrop|{shot.get("backdrop", "0.16,0.17,0.2")}'] + [f'{w["url"]}|{"|".join(str(v) for v in w["window"])}|{w.get("app", "")}' for w in shot['webs']]
    procs.append(subprocess.Popen([f'{T}/webwin'] + webs, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    time.sleep(2.0)
    app = subprocess.Popen([f'{T}/app.sh', shot['build']], env=env, stdin=subprocess.DEVNULL, stdout=open(f'{out}/app.out', 'w'),
                           stderr=subprocess.PIPE, text=True, bufsize=1)
    procs.append(app); put('app', pid=app.pid)
    err_f = open(f'{out}/app.err', 'w', buffering=1)
    def pump():
        for l in app.stderr: err_f.write(f'{now()} {l.rstrip()}\n')
    threading.Thread(target=pump, daemon=True).start()
    time.sleep(shot.get('settle', 8.0))
    dev = re.search(r'\[(\d+)\] Capture screen 0', sh(['ffmpeg', '-hide_banner', '-f', 'avfoundation', '-list_devices', 'true', '-i', '']).stderr)
    if not dev: sys.exit('peek: no Capture screen 0')
    ff = subprocess.Popen(['ffmpeg', '-hide_banner', '-loglevel', 'info', '-nostats', '-y', '-f', 'avfoundation', '-capture_cursor', '1',
                           '-framerate', '60', '-pixel_format', 'nv12', '-i', f'{dev.group(1)}:none', '-fps_mode', 'cfr', '-r', '60',
                           '-c:v', 'h264_videotoolbox', '-b:v', '40M', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', f'{out}/{name}.mp4'],
                          stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=open(f'{out}/ffmpeg.log', 'w'))
    procs.append(ff); put('rec', pid=ff.pid)
    time.sleep(1.5)
    po = subprocess.Popen([f'{T}/post', f'{out}/post.jsonl'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    procs.append(po)
    def post(line):
        po.stdin.write(line + '\n'); po.stdin.flush(); po.stdout.readline()
    for step in shot['steps']:
        op, rest = step[0], step[1:]
        if op == 'sleep': time.sleep(rest[0])
        elif op == 'mark': put('mark', label=rest[0])
        elif op == 'path': post('path ' + ' '.join(str(v) for v in rest))
        elif op in ('keydown', 'keyup'): post(f'{op} {rest[0]} {rest[1]}'); put(op, code=rest[0])
        if app.poll() is not None: sys.exit(f'peek: the app quit (rc {app.returncode})')
    put('end')
    # The capture's first frame on the same clock (avfoundation stamps uptime seconds): video seconds = event ns / 1e9 - this.
    m = re.search(r'start: ([\d.]+)', open(f'{out}/ffmpeg.log').read())
    if m: put('video0', seconds=float(m.group(1)))
finally:
    stop_all()
    print(json.dumps(dict(name=name, out=out)))
