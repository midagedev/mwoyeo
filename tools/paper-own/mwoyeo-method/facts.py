#!/usr/bin/env python3
"""Facts of the paper that are counted or computed from committed files, not read off one line. check.py runs this script and
looks for the needles of the `cmd:` rows of sources.tsv in its output. Usage: python3 -I facts.py  (from anywhere)

  usecase    scenes and expected units per use case of tools/usecase-bench/set (units: tools/usecase-bench/score.py `rows`)
  bench      sequences, lines and probes of tools/translation-bench/sequences, probes by where the deciding fact lives; the oracle runs
  drift      how many committed result files report drift (the self-test prints it; none holds a number)
  predictor  the numbers the paper derives from the constants of Core/Sources/MwoyeoCore/ScrollPredictor.swift and the spring of
             App/Overlay/OverlayPanel.swift (read from the source, so a changed constant changes the output)"""
import collections
import importlib.util
import json
import math
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..', '..'))


def read(path):
    return open(os.path.join(ROOT, path), encoding='utf-8').read()


def usecase():
    spec = importlib.util.spec_from_file_location('ucscore', os.path.join(ROOT, 'tools/usecase-bench/score.py'))
    uc = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(uc)
    rows = [l.rstrip('\n').split('\t') for l in open(os.path.join(ROOT, 'tools/usecase-bench/set/index.tsv'), encoding='utf-8')][1:]
    scenes, units, keep, inline = collections.Counter(), collections.Counter(), collections.Counter(), collections.Counter()
    for name, case, *_ in rows:
        scenes[case] += 1
        for text, opt, kept, cls, subs in uc.rows(os.path.join(ROOT, 'tools/usecase-bench/set', name + '.expected.txt')):
            units[case] += 1
            keep[case] += bool(kept)
            inline[case] += bool(subs)
    print(f'usecase scenes {sum(scenes.values())} in {len(scenes)} use cases: ' + ', '.join(f'{c} {scenes[c]}' for c in scenes))
    print(f'usecase units {sum(units.values())}: ' + ', '.join(f'{c} {units[c]}' for c in units))
    print(f'usecase marked keep {sum(keep.values())} inline {sum(inline.values())}')


def bench():
    d = os.path.join(ROOT, 'tools/translation-bench/sequences')
    seqs = [json.load(open(os.path.join(d, f), encoding='utf-8')) for f in sorted(os.listdir(d)) if f.endswith('.json')]
    by = collections.Counter(p['by'] for s in seqs for p in s['probes'])
    kinds = collections.Counter(s['kind'] for s in seqs)
    print(f'bench sequences {len(seqs)} ({", ".join(f"{k} {n}" for k, n in sorted(kinds.items()))}) lines {sum(len(s["lines"]) for s in seqs)} '
          f'probes {sum(by.values())} (memory {by["memory"]}, lines {by["lines"]}, none {by["none"]})')


def oracle():
    """The oracle runs replay each line's reference translation: every probe must pass, under every condition."""
    d = os.path.join(ROOT, 'tools/translation-bench/runs')
    runs = [r for r in sorted(os.listdir(d)) if r.startswith('oracle-')]
    ok, conditions = 0, set()
    for r in runs:
        m = json.load(open(os.path.join(d, r, 'MANIFEST.json'), encoding='utf-8'))
        if any(l.startswith('probes 312: 312 correct') for l in m['score_summary']):
            ok += 1
            conditions.add(m['condition'])
    print(f'bench oracle runs {ok} over {len(conditions)} conditions, all 312 of 312' if ok == len(runs) else f'bench oracle runs FAIL {ok} of {len(runs)}')


def drift_files():
    """Result files that report drift: the self-test prints it, but no committed result file holds a number for it."""
    hits = 0
    for top in ('tools', 'docs'):
        for dirpath, dirs, files in os.walk(os.path.join(ROOT, top)):
            dirs[:] = [x for x in dirs if x not in ('paper-own', '.build', 'node_modules', '__pycache__')]
            for f in files:
                path = os.path.join(dirpath, f)
                low = path.lower()
                if ('result' in f.lower() or '/results/' in low) and f.endswith(('.txt', '.md', '.json', '.jsonl', '.tsv')):
                    if re.search(r'\bdrift\b', open(path, encoding='utf-8', errors='replace').read(), re.I):
                        hits += 1
    print(f'committed result files that report drift: {hits}')


def predictor():
    src = read('Core/Sources/MwoyeoCore/ScrollPredictor.swift')
    lam = float(re.search(r'var latency = ([\d.]+)', src).group(1))
    T = float(re.search(r'var stepDuration = ([\d.]+)', src).group(1))
    half = T * (1 - 0.5 ** (1 / 3)) * 1000
    ninety = T * (1 - 0.1 ** (1 / 3)) * 1000
    print(f'predictor latency {lam * 1000:.0f} ms, step {T * 1000:.0f} ms, initial speed {3 / T:.0f} per s, half {half:.0f} ms, ninety percent {ninety:.0f} ms')
    panel = read('App/Overlay/OverlayPanel.swift')
    k = float(re.search(r'spring\.stiffness = ([\d.]+)', panel).group(1))
    m = float(re.search(r'spring\.mass = ([\d.]+)', panel).group(1))
    w = math.sqrt(k / m)
    c = 2 * math.sqrt(k * m)

    def settle(frac):
        lo, hi = 0.0, 100.0
        for _ in range(100):
            x = (lo + hi) / 2
            if (1 + x) * math.exp(-x) > frac:
                lo = x
            else:
                hi = x
        return hi / w * 1000
    print(f'spring omega {w:.0f} rad/s, damping {c:.0f}, down to 5% after {settle(0.05):.0f} ms, to 1% after {settle(0.01):.0f} ms')
    rho = 1 + 0.3 * (60 / 50 - 1)
    print(f'worked example: sample 1.2, rho becomes {rho:.2f}, offset for the event of -50 is {-50 * rho:.0f}')
    print(f'inpainting window step {512 * 3 // 4} pixels')
    print(f'ratio error after 5 reports {0.7 ** 5 * 100:.0f}%, after 10 reports {0.7 ** 10 * 100:.1f}%')
    fps = float(re.search(r'var framesPerSecond = ([\d.]+)', read('App/Model/Settings.swift')).group(1))
    print(f'capture period {1000 / fps:.0f} ms at {fps:.0f} frames per second, lag at 1000 points per second {1000 / fps:.0f} points')


if __name__ == '__main__':
    usecase()
    bench()
    oracle()
    drift_files()
    predictor()
