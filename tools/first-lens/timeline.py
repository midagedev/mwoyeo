#!/usr/bin/env python3
"""first117: the stage timeline of one live run: windows, posted events, and the trace lines that mark a stage (not the per-block ones)."""
import json, sys, re
d = sys.argv[1]
ev = [json.loads(l) for l in open(f'{d}/events.jsonl')]
t0 = next(e['d']['spawn_ns'] + 0 for e in ev if e['src'] == 'app')
t0 = next(e['t'] for e in ev if e['src'] == 'app')   # the app's pid was found: the app's start
KEEP = re.compile(r'warm-up|fast:|seamless: (document OCR|erase|frame)|document read|translate ×|reader (auto|ready)|pass|lens|hint|preparing|ocr\.|first|columns|probe|ready|stall|fallback|rev3|vn3|rev2|read \(|OCR \d|OCR \(')
for e in ev:
    s, x = e['src'], e['d']
    ms = (e['t'] - t0) / 1e6
    if s == 'err':
        if KEEP.search(x['line']) and not re.search(r'ocr-block|runs:|sizes:|items:', x['line']):
            print('%9.0f  err   %s' % (ms, x['line'][:150]))
    elif s == 'out':
        print('%9.0f  out   %s' % (ms, x['line'][:120]))
    elif s == 'post':
        print('%9.0f  post  %s' % (ms, x['cmd']))
    elif s in ('watch', 'watch2') and x['ev'] in ('win+', 'win-') :
        print('%9.0f  win   %s layer=%s %s' % (ms, x['ev'], x.get('layer', ''), x.get('bounds', '')))
    elif s == 'korean':
        print('%9.0f  KOREAN big=%s' % (ms, x.get('big')))
    elif s in ('first', 'second') and x['ev'] == 'frame' and x['big'] > 0.02:
        pass
