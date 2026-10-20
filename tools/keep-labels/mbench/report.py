#!/usr/bin/env python3
"""Formats the scored numbers (evaluate.py -> MB_SCRATCH/cache/metrics-<key>.json) and the timing (bench_time.py -> timing.json) as the tables of the RESULTS file.

usage: report.py [rules]            rules: only the judge-1 rows (what run.sh rules prints, also for another tree)
       report.py                    every judge that has metrics
Headings read H3 / H2 / OOF; the numbers of "H3" come from labels-h3/h3.jsonl scored by the unchanged rules_report.accumulate (see score.py)."""
import json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import data

ORDER = ['gbt', 'gbt-nopix', 'ngram', 'potion', 'potion+layout', 'e5', 'e5+layout', 'e5-int8', 'eg2', 'eg2+layout', 'eg2-int8', 'eg2-256', 'eg2-128', 'gbt-shuffled']
LANGS = ('ko', 'ja', 'en', 'zh-Hans')


def load(key):
    p = f'{data.SCRATCH}/cache/metrics-{key}.json'
    return json.load(open(p)) if os.path.exists(p) else None


def f2(x):
    return ' n/a' if x != x else f'{x:.2f}'


def row_block(name, v):
    s = v['all']; c = v['confusion']
    return (f'{name:30s} {f2(s["b_P"])} {f2(s["b_R"])} {f2(s["b_F1"])}   {s["w_fp"]:6d} {s["w_fn"]:6d}   {c.get("mixed->kept", 0):4d}/{c.get("mixed->kept", 0) + c.get("mixed->translated", 0):<4d}  '
            f'{c.get("translate->kept", 0):4d}/{c.get("translate->kept", 0) + c.get("translate->translated", 0):<4d}   {f2(s["w_P"])} {f2(s["w_R"])}')


def row_word(name, v):
    s = v['all']; i = v['inline_slice']
    return f'{name:30s} {f2(s["w_P"])} {f2(s["w_R"])} {f2(s["w_F1"])}   {f2(s["sp_F1"])}  ({s["sp_exact"]}/{s["sp_truth"]}/{s["sp_pred"]})   {f2(i["w_P"])} {f2(i["w_R"])}  ({i["w_tp"]}/{i["w_fp"]}/{i["w_fn"]})'


def row_both(name, v):
    s = v['all']
    return f'{name:30s} {f2(s["w_P"])} {f2(s["w_R"])} {f2(s["w_F1"])}   {s["w_fp"]:6d} {s["w_fn"]:6d}   {f2(s["sp_F1"])}'


def table(title, header, rows, out):
    out.append(title); out.append(header)
    out.extend(rows)
    out.append('')


def collect(setname, read, task, fn, out, with_judges=True, ops=('F1', 'P98'), with_rules=True):
    rows = []
    rules = load('rules')
    if rules and with_rules:
        for var, nm in (('rules', 'judge 1  rules only'), ('rules+region', 'judge 1  rules OR CodeRegion')):
            k = f'{var}|{task}|{setname}'
            if k in rules['rows']: rows.append(fn(nm, rules['rows'][k][read]))
    if with_judges:
        for key in ORDER:
            m = load(key)
            if not m: continue
            for op in ops:
                k = f'{task}|{op}|{setname}'
                if k in m['rows']: rows.append(fn(f'{key} @{op}', m['rows'][k][read]))
    return rows


def sections(setname, read, label, out):
    hb = 'judge @operating point             blkP  blkR  blkF1  tr->kept keep->tr  mixed kept  transl kept  wordP wordR'
    table(f'BLOCK TASK ({label}, {read} read): keep the whole block (binary); tr->kept = translate words kept, keep->tr = keep words translated; "mixed kept" = labelled-mixed blocks kept whole / all mixed; "transl kept" = pure-translate blocks kept whole / all',
          hb, collect(setname, read, 'block', row_block, out), out)
    hw = 'judge @operating point             wordP wordR wordF1  spanF1 (exact/truth/pred)   prose-block words P R (tp/fp/fn)'
    table(f'INLINE TASK ({label}, {read} read): per word over every scored word (needs=true everywhere, spans = the words the judge keeps); right: only words of blocks that hold a translate word',
          hw, collect(setname, read, 'inline', row_word, out), out)
    hb2 = 'judge @operating point             wordP wordR wordF1  tr->kept keep->tr  spanF1'
    table(f'HYBRID ({label}, {read} read): the rules OR CodeRegion decide the block, the judge\'s word model protects spans in the blocks the rules translate',
          hb2, collect(setname, read, 'hyb', row_both, out, with_rules=False), out)
    table(f'BOTH ({label}, {read} read): block judge decides, the word judge protects spans in the blocks that are translated (what a pipeline would do)', hb2, collect(setname, read, 'both', row_both, out), out)


def by_lang(setname, read, out):
    hdr = 'judge @operating point             ' + '   '.join(f'{l:>22s}' for l in LANGS)
    rows = []
    rules = load('rules')
    if rules:
        for var, nm in (('rules', 'judge 1  rules only'), ('rules+region', 'judge 1  rules OR CodeRegion')):
            v = rules['rows'][f'{var}|both|{setname}'][read]
            rows.append(f'{nm:30s} ' + '   '.join(f'blkF1 {f2(v[l]["b_F1"])} w {f2(v[l]["w_P"])}/{f2(v[l]["w_R"])}' if l in v else ' ' * 22 for l in LANGS))
    for key in ORDER:
        m = load(key)
        if not m: continue
        for op in ('F1', 'P98'):
            v = m['rows'].get(f'both|{op}|{setname}')
            if v: rows.append(f'{key + " @" + op:30s} ' + '   '.join(f'blkF1 {f2(v[read][l]["b_F1"])} w {f2(v[read][l]["w_P"])}/{f2(v[read][l]["w_R"])}' if l in v[read] else ' ' * 22 for l in LANGS))
    table(f'PER LANGUAGE ({setname}, {read} read, BOTH): block keep F1, word P/R (ja / zh-Hans doc reads split Latin runs into one word per character: weigh by block)', hdr, rows, out)


def by_reason(setname, read, out, keys=('gbt', 'e5+layout', 'eg2+layout')):
    reasons = ['code', 'log', 'config', 'cmd', 'path', 'id', 'url', 'flag', 'hash', 'hotkey', 'diffmark']
    hdr = 'judge (BOTH)                  ' + ' '.join(f'{r:>9s}' for r in reasons)
    rows = []
    def line(nm, v):
        rec = v[read]['all']['rec']
        return f'{nm:30s}' + ' '.join((f'{rec[r][0] / rec[r][1]:6.2f}/{rec[r][1]:<3d}' if r in rec and rec[r][1] else ' ' * 9) for r in reasons)
    rules = load('rules')
    if rules:
        rows.append(line('judge 1  rules OR CodeRegion', rules['rows'][f'rules+region|both|{setname}']))
    for key in keys:
        m = load(key)
        if m and f'both|P98|{setname}' in m['rows']: rows.append(line(key + ' @P98', m['rows'][f'both|P98|{setname}']))
    table(f'KEEP-WORD RECALL BY REASON ({setname}, {read} read; recall/n)', hdr, rows, out)


def url_rows(out, setname='h3', read='doc'):
    rows = []
    def line(nm, v):
        u = v[read]['url_block_recall']
        return f'{nm:30s} ' + '   '.join((f'{l}: {u[l]["recall"]:.2f} ({u[l]["blocks"]} blocks)' if l in u else f'{l}: -') for l in ('all',) + LANGS)
    rules = load('rules')
    if rules and 'url_block_recall' in rules['rows'][f'rules+region|both|{setname}'][read]:
        rows.append(line('judge 1  rules OR CodeRegion', rules['rows'][f'rules+region|both|{setname}']))
    for key in ORDER:
        m = load(key)
        if m and f'both|P98|{setname}' in m['rows']: rows.append(line(key + ' @P98', m['rows'][f'both|P98|{setname}']))
    table(f'URL KEEP WORDS, BLOCK-WEIGHTED ({setname}, {read} read, BOTH): mean over blocks of the share of the block\'s url words kept', 'judge', rows, out)


def by_look(out, read='doc'):
    """H3 block-keep F1 per look (analysis only: `look` is never a feature) for the rules and the judges that have records."""
    import dataset, score
    h3 = dataset.load(['h3'])['h3']['blocks']
    recs = {}
    for nm, path in (('rules OR CodeRegion', f'{data.SCRATCH}/records/rules+region.block.-.h3.jsonl'),
                     ('gbt-nopix @P98', f'{data.SCRATCH}/records/gbt-nopix.block.P98.h3.jsonl'),
                     ('e5+layout @P98', f'{data.SCRATCH}/records/e5+layout.block.P98.h3.jsonl'),
                     ('eg2+layout @P98', f'{data.SCRATCH}/records/eg2+layout.block.P98.h3.jsonl')):
        if os.path.exists(path): recs[nm] = {json.loads(l)['id']: json.loads(l) for l in open(path)}
    looks = sorted({b['look'] for b in h3})
    hdr = 'look                 blocks ' + ' '.join(f'{n:>20s}' for n in recs)
    rows = []
    for lk in looks:
        sub = [b for b in h3 if b['look'] == lk]
        cells = []
        for n, r in recs.items():
            sm = score.summary(score.accumulate(sub, lambda b, r=r: r[b['id']], read))
            cells.append(f'P {f2(sm["b_P"])} R {f2(sm["b_R"])} F1 {f2(sm["b_F1"])}')
        rows.append(f'{lk:20s} {sum(1 for b in sub if b["read"] == read):5d}  ' + ' '.join(f'{c:>20s}' for c in cells))
    table(f'PER LOOK (H3, {read} read, BLOCK TASK; analysis only): block keep P / R / F1', hdr, rows, out)


def speed(out):
    p = f'{data.SCRATCH}/cache/timing.json'
    if not os.path.exists(p): return
    t = json.load(open(p))
    out.append(f'SPEED (CPU, single thread, Python; {t["reps"]} repetitions x {t["pages"]} H3 doc pages with {sum(t["blocks_per_page"])} blocks; judges interleaved per repetition; uptime at start: {t["uptime_start"]})')
    out.append('  every number includes the feature extraction from the raw inputs (word boxes, tint read from the pixels, chip backgrounds); PNG decode excluded; Python = upper bound for Swift')
    h = 'judge             block b=1 ms (med / p95)   block batched ms/blk (med / p95)   word b=1 ms/word (med / p95)   word batched ms/word (med / p95)   load s    RSS MB'
    out.append('  ' + h)
    base = t['child'].get('baseline', {}).get('rss_mb', 0)
    for k, v in t['judges'].items():
        c = t['child'].get(k, {})
        out.append(f'  {k:16s}  {v["block1"]["median"]:8.2f} / {v["block1"]["p95"]:8.2f}         {v["blockb"]["median"]:8.3f} / {v["blockb"]["p95"]:8.3f}            '
                   f'{v["word1"]["median"]:8.3f} / {v["word1"]["p95"]:8.3f}           {v["wordb"]["median"]:8.3f} / {v["wordb"]["p95"]:8.3f}          {c.get("load_s", float("nan")):6.2f}  {c.get("rss_mb", float("nan")):7.0f}')
    r = t['rules']
    out.append(f'  judge 1 (Swift, in process, {r["blocks"]} H3 blocks of both reads): TranslationFilter.needsTranslation + InlineMath.spans per block alone (batch=1): median {r["filter_spans_ms"]["median"] * 1e3:.1f} us, p95 {r["filter_spans_ms"]["p95"] * 1e3:.1f} us '
               f'(filter {r["filter_ms"]["median"] * 1e3:.1f} us, spans {r["spans_ms"]["median"] * 1e3:.1f} us)')
    out.append(f'                   CodeRegion.keep per read: {r["region_ms_per_block"]["median"]:.2f} ms/block median, p95 {r["region_ms_per_block"]["p95"]:.2f}; regionfeed over the pictures (tint, line rects; includes PNG decode): '
               f'{r["regionfeed_ms_per_block"]["median"]:.2f} ms/block')
    pl = f'{data.SCRATCH}/cache/timing-light.json'
    if os.path.exists(pl):
        tl = json.load(open(pl))
        out.append(f'  second pass at another load ({tl["reps"]} repetitions x {tl["pages"]} pages, uptime at start: {tl["uptime_start"].split("load averages:")[-1].strip()}, end: {tl["uptime_end"].split("load averages:")[-1].strip()}): '
                   'block b=1 / block batched / word b=1 / word batched (median ms)')
        for k, v in tl['judges'].items():
            out.append(f'    {k:14s} {v["block1"]["median"]:8.2f}  {v["blockb"]["median"]:8.3f}  {v["word1"]["median"]:8.3f}  {v["wordb"]["median"]:8.3f}')
        r2 = tl['rules']
        out.append(f'    judge 1 (Swift): filter+spans {r2["filter_spans_ms"]["median"] * 1e3:.1f} us/block, CodeRegion {r2["region_ms_per_block"]["median"]:.2f} ms/block, regionfeed {r2["regionfeed_ms_per_block"]["median"]:.2f} ms/block')
    q = f'{data.SCRATCH}/cache/int8-latency.jsonl'
    if os.path.exists(q):
        out.append('  embedding forward pass only, fp32 vs torch dynamic int8, same H3 block texts, 1 thread (int8_latency.py): model, batch=1 median / p95 ms per text, batched ms per text')
        for l in open(q):
            r = json.loads(l)
            out.append(f'    {r["model"]:10s} {r["batch1_median_ms"]:8.1f} / {r["batch1_p95_ms"]:8.1f}   batched {r["batched_ms_per_text"]:8.1f}   ({r["texts"]} texts; {r["uptime"].split("load averages:")[-1].strip()})')
    out.append(f'  python + torch import baseline RSS {base:.0f} MB (subtract for the model\'s own footprint)')
    out.append('  uptime per judge (first repetition): ' + '; '.join(f'{k}: {v["uptime"][0].split("load averages:")[-1].strip()}' for k, v in t['judges'].items()))
    out.append('')


def bundle(out):
    p = f'{data.SCRATCH}/cache/bundle.json'
    if not os.path.exists(p): return
    b = json.load(open(p))
    out.append('BUNDLE SIZE ESTIMATE (MB): what the judge would ship; embedding weights as held at run time (fp32), the int8 twin where measured (torch dynamic quantisation: Linear layers int8, token table fp32),')
    out.append('classifier = pickle of the fitted object (LightGBM: its text model; logistic regression: coefficients + scaler). Core ML could hold the embedding model in fp16 (half of fp32) or lower; not measured here.')
    out.append('judge             embedding fp32   embedding int8   block clf   word clf   note')
    for k in ORDER:
        if k not in b: continue
        r = b[k]; e = r.get('embedding')
        out.append(f'  {k:16s} {e["fp32_MB"] if e else 0:9.0f}        {e["int8_MB"] if e else 0:9.0f}        {r["block_clf_MB"]:7.2f}    {r["word_clf_MB"]:7.2f}   '
                   + (f'{e["params_M"]:.0f}M params' if e else (f'{r["trees"][0]} + {r["trees"][1]} trees' if 'trees' in r else '2^19 hashed char n-grams')))
    out.append('')


def main():
    only_rules = sys.argv[1:] == ['rules']
    out = []
    for setname, label in (('h3', 'H3, test'), ('h2', 'H2, out-of-fold')):
        for read in ('doc', 'vn'):
            sections(setname, read, label, out) if not only_rules else None
            if only_rules:
                for var, nm in (('rules', 'rules only'), ('rules+region', 'rules OR CodeRegion')):
                    m = load('rules')
                    for task in ('block', 'both'):
                        v = m['rows'][f'{var}|{task}|{setname}'][read]['all']
                        out.append(f'{setname.upper()} {nm:22s} {task:6s} read {read}: word P {f2(v["w_P"])} R {f2(v["w_R"])} (tp {v["w_tp"]} fp {v["w_fp"]} fn {v["w_fn"]}); block keep P {f2(v["b_P"])} R {f2(v["b_R"])} F1 {f2(v["b_F1"])}')
    if not only_rules:
        for setname in ('h3',):
            for read in ('doc', 'vn'): by_lang(setname, read, out)
        by_reason('h3', 'doc', out)
        url_rows(out)
        by_look(out)
        speed(out)
        bundle(out)
    print('\n'.join(out))


if __name__ == '__main__':
    main()
