#!/usr/bin/env python3
"""Terms wrong / term occurrences in the Korean, before and after a term script. Run isolated:
  python3 -I count-terms.py <script.js> <dir of --render .out files> [--from "6.6 What the numbers"] [--to "7 Related work"] [--log log.jsonl]
A term occurrence is one match of its English pattern in a source block; a WRONG occurrence is one of the renderings listed for it in TERMS found in
the Korean (Apple's loose or literal renderings, measured in /tmp/film3/evidence-paper.md); OK forms are the established ones. The script runs in node,
as the app runs it (check-sites.py checks every site it makes). Rows with no entry in the script show what it leaves alone."""
import argparse
import re
import subprocess
import sys
import json
import os

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# (name, English pattern, established forms, loose or literal forms Apple gave). "noise" is not here: Google's Korean ML glossary titles it 소음 (Apple's word).
TERMS = [
    ("ground truth", r"ground truth", ["정답", "그라운드 트루스"], ["땅의 진실", "기본 진실", "기본 진리", "지상 진실"]),
    ("precision", r"\bprecision\b", ["정밀도"], ["정확성", "정확도"]),
    ("recall", r"\brecall\b", ["재현율"], ["기억", "리콜"]),
    ("control(s)", r"\bcontrols?\b", ["대조군"], ["제어 장치", "제어", "컨트롤"]),
    ("sign test", r"\bsign test\b", ["부호 검정", "부호검정"], ["사인 테스트"]),
    ("warm cache", r"\bwar[mn] cache\b", ["웜 캐시"], ["따뜻한 캐시", "경고 캐시", "워밍 캐시"]),
    ("held-out", r"\bheld[- ]out\b", ["홀드아웃"], ["보류된", "유지된"]),
]


def load_pairs(path):
    out = []
    for f in sorted(os.listdir(path)):
        if not f.endswith(".out"):
            continue
        lines = open(os.path.join(path, f), encoding="utf-8").read().split("\n")
        i = 0
        while i < len(lines):
            if lines[i].startswith("  ") and not lines[i].startswith("    →") and i + 1 < len(lines) and lines[i + 1].startswith("    →"):
                out.append((lines[i].strip(), lines[i + 1].strip()[2:].strip()))
                i += 2
            else:
                i += 1
    return out


def run_script(script, pairs):
    harness = ("const fs = require('fs'); const after = new Function(fs.readFileSync(process.argv[1], 'utf8') + '; return after')();\n"
               "const rows = JSON.parse(fs.readFileSync(0, 'utf8')); const ctx = {app: '', profile: 'x', source: 'en', target: 'ko'};\n"
               "console.log(JSON.stringify(rows.map(([s, d]) => after(s, d, ctx))));")
    r = subprocess.run(["node", "-e", harness, script], input=json.dumps(pairs, ensure_ascii=False), capture_output=True, encoding="utf-8")
    if r.returncode:
        sys.exit("count-terms: node failed: " + r.stderr[-600:])
    return json.loads(r.stdout)


def count(pairs, shown):
    rows = {}
    for (src, dst), after in zip(pairs, shown):
        for name, rx, ok, loose in TERMS:
            n = len(re.findall(rx, src, flags=re.I))
            if not n:
                continue
            r = rows.setdefault(name, [0, 0, 0, 0])
            r[0] += n
            r[1] += sum(len(re.findall(re.escape(f), dst)) for f in loose)      # wrong, raw
            r[2] += sum(len(re.findall(re.escape(f), after)) for f in loose)    # wrong, after the script
            r[3] += sum(len(re.findall(re.escape(f), after)) for f in ok)       # established, after the script
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("script")
    ap.add_argument("dir")
    ap.add_argument("--from", dest="start", default="6.6 What the numbers")
    ap.add_argument("--to", dest="stop", default="7 Related work")
    ap.add_argument("--log")
    opts = ap.parse_args()
    pairs = load_pairs(opts.dir)
    if opts.log:
        pairs = [(json.loads(l)["original"], json.loads(l)["translation"]) for l in open(opts.log, encoding="utf-8") if l.strip()]
    else:
        a = next(i for i, p in enumerate(pairs) if p[0].startswith(opts.start))
        b = next(i for i, p in enumerate(pairs) if i > a and p[0].startswith(opts.stop))
        pairs = pairs[a:b]
    shown = run_script(opts.script, pairs)
    rows = count(pairs, shown)
    print("%-14s %6s %10s %12s %12s" % ("term", "n", "wrong raw", "wrong script", "ok script"))
    tot = [0, 0, 0]
    for name, (n, raw, aft, ok) in rows.items():
        print("%-14s %6d %10d %12d %12d" % (name, n, raw, aft, ok))
        tot[0] += n; tot[1] += raw; tot[2] += aft
    print("%-14s %6d %10d %12d   (%d blocks)" % ("all", tot[0], tot[1], tot[2], len(pairs)))


main()
