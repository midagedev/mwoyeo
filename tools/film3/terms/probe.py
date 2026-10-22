#!/usr/bin/env python3 -I
"""Apple Translation en -> ko on each term in a few natural sentences, through `Mwoyeo --mcp` translate_text (the lens's own TranslationService), one sentence a call.
  python3 -I probe.py <app binary> probe-flat.json probe-out.json
probe-flat.json is probe-sentences.json ({term: [sentences]}) as one {term, i, line} per sentence; probe-out.json is the committed answer of the run of 2026-10-21
(build 786db0a). Scratch settings under /tmp/film3/evid; nothing of the user's is read."""
import json, os, subprocess, sys, time
binary, inp, out = sys.argv[1:4]
flat = json.load(open(inp, encoding="utf-8"))
D = "/tmp/film3/evid/s-apple-en"
os.makedirs(D, exist_ok=True)
json.dump({"sourceLanguage": "en", "targetLanguage": "ko", "agentConnection": True, "checksForUpdates": False, "savesTranscripts": False}, open(D + "/settings.json", "w"))
env = dict(os.environ, MWOYEO_SETTINGS_FILE=D + "/settings.json", MWOYEO_DEFAULTS_SUITE="film3.terms", MWOYEO_MEMORY_SECRETS="1")
reqs = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "film3", "version": "1"}}}, {"jsonrpc": "2.0", "method": "notifications/initialized"}]
for n, f in enumerate(flat, 1):
    reqs.append({"jsonrpc": "2.0", "id": n, "method": "tools/call", "params": {"name": "translate_text", "arguments": {"lines": [f["line"]], "engine": "apple"}}})
text = "".join(json.dumps(r, ensure_ascii=False) + "\n" for r in reqs)
p = subprocess.run([binary, "--mcp"], input=text, capture_output=True, encoding="utf-8", env=env, timeout=1500)
for l in p.stdout.split("\n"):
    if not l: continue
    r = json.loads(l)
    if r.get("id") and r["id"] <= len(flat):
        try: flat[r["id"] - 1]["dst"] = json.loads(r["result"]["content"][0]["text"])["rows"][0][0]
        except Exception: flat[r["id"] - 1]["dst"] = "ERR " + r["result"]["content"][0]["text"][:100]
json.dump(flat, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("done", len(flat), "rc", p.returncode)
