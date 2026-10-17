#!/usr/bin/env python3
"""Aggregate raw-*.jsonl and judge.jsonl into the RESULTS tables. Usage: python3 -I report.py DIR  (DIR holds raw-*.jsonl, judge.jsonl)"""
import glob, json, os, statistics, sys
d = sys.argv[1]
rows = [json.loads(l) for f in sorted(glob.glob(os.path.join(d, "raw-*.jsonl"))) for l in open(f) if "partial" not in f]
judge = [json.loads(l) for l in open(os.path.join(d, "judge.jsonl"))]
VENDOR = {"gemini": "gemini", "gpt": "openai"}  # engine prefix -> vendor whose judge is excluded
def vendor(e):
    for k, v in VENDOR.items():
        if e.startswith(k): return v
engines = list(dict.fromkeys(r["engine"] for r in rows))
pairs = sorted({r["pair"] for r in rows})
def q(e, pair=None):
    s = [j["score"] for j in judge if j["engine"] == e and j["judge"] != vendor(e) and j["score"] and (pair is None or j["pair"] == pair)]
    return statistics.mean(s) if s else None
fmt = lambda x, n=2: "-" if x is None else f"{x:.{n}f}"
print("| engine | where | warm median s / 3-line batch | p90 s | cold s | quality 1-5 | failures / lines |\n|---|---|---|---|---|---|---|")
for e in engines:
    er = [r for r in rows if r["engine"] == e]
    ok = [r for r in er if r["run"] == 0 or r["run"] == 1]  # first warm run covers each batch once
    warm = sorted(r["ms"] for r in er if r["run"] > 0 and r["ms"] and not r["error"])
    cold = next((r["ms"] for r in er if r["run"] == 0 and r["ms"]), None)
    fails = sum(3 if r["error"] else r.get("echo", 0) for r in er if r["run"] > 0)
    total = sum(3 for r in er if r["run"] > 0)
    na = [r["error"] for r in er if r["error"] and "pack" in r["error"]]
    p90 = warm[min(len(warm) - 1, int(.9 * len(warm)))] / 1000 if warm else None
    print(f"| {e} | {'this Mac' if e.startswith(('apple','translategemma','qwen')) else 'cloud'} | {fmt(statistics.median(warm)/1000 if warm else None)} | {fmt(p90)} | {fmt(cold/1000 if cold else None)} | {fmt(q(e),1)} | {fails}/{total} |" + ("  (zh-Hans-ko: pack not installed)" if na else ""))
print("\n| engine | " + " | ".join(pairs) + " |\n|---|" + "---|" * len(pairs))
for e in engines: print(f"| {e} | " + " | ".join(fmt(q(e, p), 1) for p in pairs) + " |")
# judge agreement: lines where both judges scored the same engine within 1
by = {}
for j in judge:
    if j["score"]: by.setdefault((j["pair"], j["batch"], j["line"], j["engine"]), {})[j["judge"]] = j["score"]
both = [v for v in by.values() if len(v) == 2]
print(f"\njudge agreement (|diff| <= 1): {sum(abs(v['openai']-v['gemini']) <= 1 for v in both)}/{len(both)} = {sum(abs(v['openai']-v['gemini']) <= 1 for v in both)/len(both):.2f}")
