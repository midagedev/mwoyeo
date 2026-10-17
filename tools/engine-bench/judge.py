#!/usr/bin/env python3
"""Blind quality judging. Stdlib only. Usage: python3 -I judge.py RAW.jsonl [RAW2.jsonl ...] --out judge.jsonl

Takes the first warm run (run=1) of each engine x pair x batch, shuffles the candidates per line under neutral labels,
and asks two judges from different vendors (OpenAI, Gemini) to score each 1-5. The judge of an engine's own vendor is
excluded later by report.py. Env: OPENAI_API_KEY, GEMINI_API_KEY (never written out).
"""
import argparse, json, os, random, sys, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
JUDGES = {
    "openai": dict(model="gpt-5.4", url="https://api.openai.com/v1/chat/completions", key="OPENAI_API_KEY", extra={"reasoning_effort": "low"}),
    "gemini": dict(model="gemini-3.7-flash", url="https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", key="GEMINI_API_KEY", extra={}),
}
LANG = {"ja": "Japanese", "ko": "Korean", "en": "English", "zh-Hans": "Simplified Chinese"}
SYSTEM = ("You are a strict bilingual reviewer. You get several numbered source lines; each has several candidate translations "
          "with neutral labels. Score every candidate 1-5 for accuracy plus naturalness, as text a person reads on a screen "
          "(5 = accurate and natural, 3 = understandable but stiff or slightly wrong, 1 = wrong, untranslated or unusable). "
          "Reply with only JSON: {\"scores\": {\"<line number>\": {\"<label>\": {\"score\": <1-5>, \"why\": \"<one short phrase>\"}}}}.")

def ask(j, user):
    body = {"model": j["model"], "messages": [{"role": "system", "content": SYSTEM}, {"role": "user", "content": user}], **j["extra"]}
    req = urllib.request.Request(j["url"], data=json.dumps(body).encode(), headers={
        "Content-Type": "application/json", "Authorization": "Bearer " + os.environ[j["key"]]})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                c = json.loads(r.read())["choices"][0]["message"]["content"]
            a, b = c.find("{"), c.rfind("}")
            return json.loads(c[a:b + 1])["scores"]
        except urllib.error.HTTPError as e:
            if e.code in (429, 503) and attempt < 3: time.sleep(15 * (attempt + 1)); continue
            return {"_error": f"HTTP {e.code}"}
        except Exception as e:
            if attempt == 3: return {"_error": type(e).__name__}
            time.sleep(3)

def main():
    ap = argparse.ArgumentParser(description="Blind two-vendor translation judging.")
    ap.add_argument("raw", nargs="+"); ap.add_argument("--out", default=os.path.join(HERE, "judge.jsonl"))
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()
    data = json.load(open(os.path.join(HERE, "data.json")))["pairs"]
    cand = {}  # (pair, batch) -> {engine: [lines]}
    def c_names(cand, pair, b): return list(cand[(pair, b)])
    c = cand
    for path in a.raw:
        for l in open(path):
            r = json.loads(l)
            if r["run"] == 1 and r["out"] and len(r["out"]) == len(data[r["pair"]]["batches"][r["batch"]]):
                cand.setdefault((r["pair"], r["batch"]), {})[r["engine"]] = r["out"]
    rng = random.Random(a.seed)
    # One call per pair and judge (free Gemini quota is a few requests a day per model).
    with open(a.out, "w") as f:
        for pair, p in sorted(data.items()):
            lines, items = [], []  # items: (global line no, {engine: text})
            for b, batch in enumerate(p["batches"]):
                for i, src in enumerate(batch):
                    eng = {n: c[(pair, b)][n][i] for n in c_names(cand, pair, b)} if (pair, b) in cand else {}
                    if len(eng) > 1: items.append((len(lines), b, i, src, eng))
                    lines.append(src)
            blocks, labelmaps = [], {}
            for k, b, i, src, eng in items:
                names = list(eng); rng.shuffle(names)
                labelmaps[k] = {chr(65 + n): name for n, name in enumerate(names)}
                inv = {v: kk for kk, v in labelmaps[k].items()}
                blocks.append(f"Line {k}: {src}\n" + "\n".join(f"{inv[n]}: {eng[n]}" for n in sorted(names, key=inv.get)))
            user = f"Source language: {LANG[p['source']]}. Target language: {LANG[p['target']]}.\n\n" + "\n\n".join(blocks)
            for vendor, j in JUDGES.items():
                res = ask(j, user)
                for k, b, i, src, eng in items:
                    got = (res or {}).get(str(k)) if isinstance(res, dict) else None
                    for label, name in labelmaps[k].items():
                        s_ = got.get(label) if isinstance(got, dict) else None
                        f.write(json.dumps({"judge": vendor, "pair": pair, "batch": b, "line": i, "engine": name,
                                            "score": s_.get("score") if isinstance(s_, dict) else None,
                                            "why": s_.get("why") if isinstance(s_, dict) else (res or {}).get("_error")}, ensure_ascii=False) + "\n")
                f.flush()
if __name__ == "__main__": main()
