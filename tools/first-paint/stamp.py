#!/usr/bin/env python3
"""Puts the uptime in ms (CLOCK_UPTIME_RAW) in front of every line it reads: `app 2>&1 | stamp.py` (run-render.sh STAMP=1)."""
import sys, time
for l in sys.stdin:
    sys.stdout.write('%d %s' % (time.clock_gettime_ns(time.CLOCK_UPTIME_RAW) // 1_000_000, l)); sys.stdout.flush()
