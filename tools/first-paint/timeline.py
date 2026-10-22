#!/usr/bin/env python3
"""fast117: where a first batch's time went. usage: timeline.py <run prefix>   (a run of run-render.sh with STAMP=1 and --first-paint-log)
Prints, in ms after the first batch was sent: the engine call, each model's results (`first-paint ll|hf landed`), what the pipeline did with them
(`pipeline provisional|streamed|emit`) and the batches' ends."""
import re, sys
p = sys.argv[1]
out = open(p + '.out').read()
t0 = int(re.search(r'start_uptime_ms=(\d+)', out).group(1)) + int(re.search(r'first_request_ms=(\d+)', out).group(1))
for l in open(p + '.err'):
    m = re.match(r'(\d+) \[trace\] (.*)', l)
    if not m: continue
    t, msg = int(m.group(1)) - t0, m.group(2)
    if -200 <= t <= 12000 and any(k in msg for k in ('engine ←', 'service result', 'pipeline ', 'first-paint', 'translate ×', 'first paint')):
        print(f'{t:7d}  {msg[:120]}')
