#!/usr/bin/env python3
"""fast117: one live take of a lens placed over a page, to watch the first paint replaced in playback (the lead's verdict; docs/design/first-lens.md §13).
usage: rec.py <build label> <scene p6|c01> <on|off> <out dir> [--secs 55] [--engine highFidelity] [--no-inpaint] [--source en]
Under `flock -n /tmp/r117/screen.lock` (the caller's job: the screen is shared). A page window (first117's tools/pagewin) shows the picture; the app starts on
scratch state through app.sh (settings file, defaults suite, MWOYEO_MEMORY_SECRETS=1; refuses otherwise); the hot key of this run (⌃⌥⌘J, in its own
settings file) opens the picker and a click places today's lens; `screencapture -v` (the CLI: no ScreenCaptureKit process of ours) records the screen.
Writes <out>/<scene>-<on|off>.mov (whole screen, VFR), .mp4 (the page window cropped, 720p, 30 fps), .err (the app's trace with the time of each line)
and .events (what this driver did and when). Nothing of the user's is read or written; the lens and the page window are closed at the end."""
import argparse, json, os, signal, subprocess, sys, threading, time
a = argparse.ArgumentParser()
a.add_argument('build'); a.add_argument('scene'); a.add_argument('mode'); a.add_argument('out')
a.add_argument('--no-inpaint', action='store_true'); a.add_argument('--source', default='auto'); a.add_argument('--secs', type=int, default=55); a.add_argument('--engine', default='highFidelity'); a.add_argument('--warmup', type=float, default=14.0)
o = a.parse_args()
PAGES = {'p6': ('/tmp/paper-quality/pages-own/p6.png', 680, 880, 0.30), 'c01': ('/tmp/latin-runs/pngs/c01-slack-en.png', 760, 720, 0.30)}
png, w, h, clicky = PAGES[o.scene]
TOOLS = '/tmp/r117/first117/tools'
BIN = f'/tmp/latin-runs/dd-{o.build}/Build/Products/Debug/Mwoyeo.app/Contents/MacOS/Mwoyeo'
os.makedirs(o.out, exist_ok=True)
name = f'{o.scene}-{o.mode}' + ('-noinp' if o.no_inpaint else '') + (f'-{o.source}' if o.source != 'auto' else ''); base = f'{o.out}/{name}'
t0 = time.monotonic(); ev = open(f'{base}.events', 'w', buffering=1)
def log(**kw): ev.write(json.dumps(dict(t=round(time.monotonic() - t0, 3), **kw), ensure_ascii=False) + '\n')
procs = []
def cleanup():
    for p in reversed(procs):
        if p.poll() is None:
            p.terminate()
            try: p.wait(5)
            except Exception: p.kill()
import atexit; atexit.register(cleanup)

settings = dict(engine=o.engine, shortcuts={'addLens': {'display': '⌃⌥⌘J', 'keyCode': 38, 'modifiers': 6400}})
if o.mode == 'on': settings['fastFirstPaint'] = True
# the erase is the slower term of a live lens under load (design first-lens §13.2): without the inpainting model the swap is what the take shows
if o.no_inpaint: settings['useInpaintingModel'] = False
# an explicit source warms that pair at launch (a Detect lens warms ja, section 13.4 item 4): it stands in for the picker's `prewarm(source: detected)` of first117
if o.source != 'auto': settings['sourceLanguage'] = o.source
sfile = f'{base}.settings.json'; json.dump(settings, open(sfile, 'w'), ensure_ascii=False)
suite = f'fast117.rec{o.scene}{o.mode}' + ('n' if o.no_inpaint else '') + ('s' if o.source != 'auto' else '')
subprocess.run(['defaults', 'delete', suite], stderr=subprocess.DEVNULL)
# the first-run window is not what is being filmed: this scratch suite has onboarding done
subprocess.run(['defaults', 'write', suite, 'settings', '-data', json.dumps({'hasCompletedOnboarding': True}).encode().hex()])

pw = subprocess.Popen([f'{TOOLS}/pagewin', png, '40', '60', str(w), str(h)], stdout=subprocess.PIPE, text=True); procs.append(pw)
line = pw.stdout.readline().split(); wx, wy, ww, wh = [int(v) for v in line[5:9]]
log(ev='page', frame=[wx, wy, ww, wh]); time.sleep(1.0)

env = dict(os.environ, MWOYEO_TRACE='1', MWOYEO_MEMORY_SECRETS='1', MWOYEO_SETTINGS_FILE=sfile, MWOYEO_DEFAULTS_SUITE=suite)
app = subprocess.Popen([os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.sh'), BIN], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1); procs.append(app)
errf = open(f'{base}.err', 'w', buffering=1)
def pump(stream):
    for l in stream: errf.write(f'{time.monotonic() - t0:8.3f} {l}')
threading.Thread(target=pump, args=(app.stderr,), daemon=True).start(); threading.Thread(target=pump, args=(app.stdout,), daemon=True).start()
log(ev='app', pid=app.pid); time.sleep(o.warmup)
po = subprocess.Popen([f'{TOOLS}/post'], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1); procs.append(po)
def post(cmd):
    po.stdin.write(cmd + '\n'); po.stdin.flush(); po.stdout.readline(); log(ev='post', cmd=cmd)

mov = f'{base}.mov'
rec = subprocess.Popen(['screencapture', '-x', '-v', '-C', '-V', str(o.secs), mov], stdout=open(f'{base}.rec.log', 'w'), stderr=subprocess.STDOUT); procs.append(rec)
log(ev='record', secs=o.secs); time.sleep(2.0)
cx, cy = wx + ww // 2, wy + 28 + int(wh * clicky)
post(f'move {cx - 40} {cy - 40}'); time.sleep(0.4)
post('key 38 ctrl,opt,cmd'); time.sleep(1.2)
post(f'move {cx} {cy}'); time.sleep(0.5)
post(f'click {cx} {cy}'); log(ev='lens placed', at=[cx, cy])
post(f'move {wx + ww + 120} {wy + 60}')       # the pointer leaves the lens
rec.wait(); log(ev='record done', rc=rec.returncode)
app.terminate(); pw.terminate()
# the page window cropped (points -> pixels at 2x), 720p, 30 fps
crop = f'crop={ww * 2}:{wh * 2}:{wx * 2}:{wy * 2}'
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', mov, '-vf', f'{crop},fps=30,scale=-2:720', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-crf', '21', f'{base}.mp4'])
log(ev='encoded', mp4=f'{base}.mp4')
