"""first117: one row per live run (ms since the app's start unless said), then medians."""
import json, re, os, statistics as st, sys
R = '/tmp/r117/first117/data/runs'
def load(k):
    ev = [json.loads(l) for l in open(f'{R}/{k}/events.jsonl')]
    return ev
def row(k):
    ev = load(k); S = json.load(open(f'{R}/{k}/summary.json'))
    t0 = next(e['t'] for e in ev if e['src'] == 'app')
    ms = lambda t: round((t - t0) / 1e6)
    r = dict(run=k)
    ob = next((e for e in ev if e['src'] == 'watch' and e['d']['ev'] == 'win+' and e['d'].get('layer') == 0 and 500 < e['d']['bounds'][2] < 700), None)
    r['onboarding_ms'] = ms(ob['t']) if ob else None
    for e in ev:
        if e['src'] == 'err':
            m = re.match(r'\[trace\] reader warm-up (lines|docs) \[[^\]]*\] done, (\d+) ms', e['d']['line'])
            if m: r['warm_' + m[1] + '_ms'] = int(m[2]); r['warm_' + m[1] + '_done_at'] = ms(e['t'])
    if S.get('t_key') is not None and S.get('t_picker') is not None: r['key_to_picker'] = round(S['t_picker'] - S['t_key'])
    if S.get('t_click') is not None and S.get('t_lens') is not None: r['click_to_lens'] = round(S['t_lens'] - S['t_click'])
    if S.get('t_click') is not None and S.get('t_picker_gone') is not None: r['click_to_picker_gone'] = round(S['t_picker_gone'] - S['t_click'])
    if S.get('t_korean') is not None and S.get('t_lens') is not None: r['lens_to_korean_px'] = round(S['t_korean'] - S['t_lens'])
    tl = S.get('t_lens')
    if tl is not None:
        t_lens_abs = t0 + tl * 1e6
        reads = [e for e in ev if e['src'] == 'err' and e['t'] > t_lens_abs and re.match(r'\[trace\] (fast: OCR|seamless: document OCR|document read)', e['d']['line'])]
        if reads: r['lens_to_first_read_done'] = round((reads[0]['t'] - t_lens_abs) / 1e6)
        trs = [e for e in ev if e['src'] == 'err' and e['t'] > t_lens_abs and re.match(r'\[trace\] translate ×\d+ (\d+) ms', e['d']['line'])]
        if trs:
            r['lens_to_translate_done'] = round((trs[0]['t'] - t_lens_abs) / 1e6)
            r['first_translate_ms'] = int(re.match(r'\[trace\] translate ×\d+ (\d+) ms', trs[0]['d']['line'])[1])
    if S.get('picker_loop'):
        r['picker_loop_up'] = [x['up_ms'] for x in S['picker_loop']]; r['picker_loop_esc'] = [x['esc_ms'] for x in S['picker_loop']]
    sec = S.get('second') or {}
    if sec.get('t_key') is not None and sec.get('t_picker') is not None: r['second_key_to_picker'] = round(sec['t_picker'] - sec['t_key'])
    if sec.get('t_click') is not None and sec.get('t_lens') is not None: r['second_click_to_lens'] = round(sec['t_lens'] - sec['t_click'])
    loads = [e['d'].get('uptime', '') for e in ev if e['src'] == 'load']
    r['load'] = [re.search(r'averages: ([\d.]+)', x)[1] for x in loads if 'averages' in x]
    cpu = next((e['d']['ps'] for e in ev if e['src'] == 'cpu'), [])
    r['cpu'] = [' '.join(x.split()[1:3]) for x in cpu]
    return r
if __name__ == '__main__':
    rows = [row(k) for k in sys.argv[1:]]
    for r in rows: print(json.dumps(r))
