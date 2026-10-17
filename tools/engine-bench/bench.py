#!/usr/bin/env python3
"""Speed benchmark for HTTP translation engines and Ollama. Stdlib only; run with `python3 -I bench.py`.

Keys come from the environment (GEMINI_API_KEY, DEEPL_API_KEY, OPENAI_API_KEY, MWOYEO_CLAUDE_API_KEY and optional
MWOYEO_CLAUDE_WORKSPACE); an engine whose key is missing is skipped with a message. Keys are never written anywhere.
Rows: {engine, model, pair, batch, run, ms, lines_out, error, out, ...}; run 0 is the cold call (batch 0), runs 1-3 warm.
"""
import argparse, json, os, re, statistics, sys, time, urllib.request, urllib.error

HERE = os.path.dirname(os.path.abspath(__file__))
LANG = {"ja": "Japanese", "ko": "Korean", "en": "English", "zh-Hans": "Simplified Chinese"}
DEEPL_LANG = {"ja": "JA", "ko": "KO", "en": "EN", "zh-Hans": "ZH-HANS"}
# Same wording as ChatTranslation.systemPrompt in Core (no glossary).
def system_prompt(src, tgt):
    return (f"Translate each line of the user's JSON into {LANG[tgt]} from {LANG[src]}. "
            "Keep names, numbers, emoji, URLs and @handles unchanged. Give one translation per line, in the same order."
            "\nReply with only {\"translations\": [...]}.")
def user_message(lines):
    return json.dumps({"lines": lines}, ensure_ascii=False, separators=(",", ":"))

# name -> config. kind: chat (OpenAI-compatible), claude, deepl, ollama-native (TranslateGemma prompt).
ENGINES = {
    "gemini-3.1-flash-lite": dict(kind="chat", model="gemini-3.1-flash-lite", key="GEMINI_API_KEY",
        url="https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", extra={"reasoning_effort": "minimal"}, where="cloud"),
    "gemini-3.5-flash-lite": dict(kind="chat", model="gemini-3.5-flash-lite", key="GEMINI_API_KEY",
        url="https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", extra={"reasoning_effort": "minimal"}, where="cloud"),
    # Free tier allows only 20 requests/day for this model: too few for a full run; use a paid key.
    "gemini-3.8-flash": dict(kind="chat", model="gemini-3.8-flash", key="GEMINI_API_KEY",
        url="https://generativelanguage.googleapis.com/v1beta/openai/chat/completions", extra={"reasoning_effort": "low"}, where="cloud"),
    "gpt-4o-mini": dict(kind="chat", model="gpt-4o-mini", key="OPENAI_API_KEY",
        url="https://api.openai.com/v1/chat/completions", extra={}, where="cloud"),
    "gpt-5.4-mini": dict(kind="chat", model="gpt-5.4-mini", key="OPENAI_API_KEY",
        url="https://api.openai.com/v1/chat/completions", extra={"reasoning_effort": "none"}, notemp=True, where="cloud"),
    "gpt-5.6-luna": dict(kind="chat", model="gpt-5.6-luna", key="OPENAI_API_KEY",
        url="https://api.openai.com/v1/chat/completions", extra={"reasoning_effort": "none"}, notemp=True, where="cloud"),
    "claude-haiku-5-5": dict(kind="claude", model="claude-haiku-5-5", where="cloud"),
    "claude-sonnet-5-5": dict(kind="claude", model="claude-sonnet-5-5", where="cloud"),
    "deepl": dict(kind="deepl", model="deepl-free", key="DEEPL_API_KEY", where="cloud"),
    "translategemma:4b": dict(kind="ollama-native", model="translategemma:4b", where="local"),
    "qwen3.5:2b": dict(kind="chat", model="qwen3.5:2b", url="http://localhost:11434/v1/chat/completions",
        extra={"reasoning_effort": "none"}, where="local"),
}

def http(url, body, headers, timeout=90, method="POST"):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json", **headers}, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())

def extract_json(s):
    s = s.strip()
    if s.startswith("```"):
        s = s.split("\n", 1)[-1].strip()
        if s.endswith("```"): s = s[:-3]
    s = s.strip()
    if s.startswith("["): return s
    a, b = s.find("{"), s.rfind("}")
    return s[a:b + 1] if 0 <= a < b else s

def parse_translations(content):
    v = json.loads(extract_json(content))
    t = v.get("translations") if isinstance(v, dict) else v
    if not isinstance(t, list) or not all(isinstance(x, str) for x in t): raise ValueError("not an array of strings")
    return t

def call(cfg, src, tgt, lines):
    """Returns (outputs, error_kind_or_None). Raises HTTPError for transport problems."""
    k = cfg["kind"]
    if k == "deepl":
        key = os.environ["DEEPL_API_KEY"]
        host = "api-free.deepl.com" if key.endswith(":fx") else "api.deepl.com"
        r = http(f"https://{host}/v2/translate", {"text": lines, "source_lang": DEEPL_LANG[src].split("-")[0], "target_lang": DEEPL_LANG[tgt]},
                 {"Authorization": f"DeepL-Auth-Key {key}"})
        return [x["text"] for x in r["translations"]], None
    if k == "claude":
        h = {"x-api-key": os.environ["MWOYEO_CLAUDE_API_KEY"], "anthropic-version": "2023-06-01"}
        if os.environ.get("MWOYEO_CLAUDE_WORKSPACE"): h["anthropic-workspace-id"] = os.environ["MWOYEO_CLAUDE_WORKSPACE"]
        r = http("https://api.anthropic.com/v1/messages", {"model": cfg["model"], "max_tokens": 1024,  # no temperature: deprecated on current Claude models
                 
                 "system": system_prompt(src, tgt), "messages": [{"role": "user", "content": user_message(lines)}]}, h)
        content = "".join(b.get("text", "") for b in r["content"] if b.get("type") == "text")
    elif k == "ollama-native":
        prompt = (f"You are a professional {LANG[src]} ({src}) to {LANG[tgt]} ({tgt}) translator. Your goal is to accurately convey the "
                  f"meaning and nuances of the original {LANG[src]} text while adhering to {LANG[tgt]} grammar, vocabulary, and cultural "
                  f"sensitivities.\nProduce only the {LANG[tgt]} translation, without any additional explanations or commentary. "
                  f"Please translate the following {LANG[src]} text into {LANG[tgt]}, one output line per input line:\n\n\n" + "\n".join(lines))
        r = http("http://localhost:11434/api/chat", {"model": cfg["model"], "stream": False, "options": {"temperature": 0},
                 "messages": [{"role": "user", "content": prompt}]}, {}, timeout=300)
        out = [l for l in r["message"]["content"].strip().split("\n") if l.strip()]
        return out, None
    else:
        key = os.environ.get(cfg.get("key", ""), "")
        body = {"model": cfg["model"], "stream": False,
                "messages": [{"role": "system", "content": system_prompt(src, tgt)}, {"role": "user", "content": user_message(lines)}], **cfg["extra"]}
        if not cfg.get("notemp"): body["temperature"] = 0
        r = http(cfg["url"], body, {"Authorization": f"Bearer {key}"} if key else {}, timeout=300 if cfg["where"] == "local" else 90)
        content = r["choices"][0]["message"].get("content") or ""
    try:
        return parse_translations(content), None
    except Exception:
        return [], "non-JSON reply"

def script_ratio(text, tgt):
    letters = [c for c in text if c.isalpha()]
    if not letters: return 1.0
    if tgt == "ko": ok = [c for c in letters if "가" <= c <= "힣" or "ᄀ" <= c <= "ᇿ"]
    elif tgt == "ja": ok = [c for c in letters if "぀" <= c <= "ヿ" or "一" <= c <= "鿿"]
    else: ok = letters
    return len(ok) / len(letters)

def echoes(out, src_lines, tgt):
    return sum(1 for o, s in zip(out, src_lines) if o.strip() == s.strip() or script_ratio(o, tgt) < 0.3)

def keys_present(name, cfg):
    k = cfg.get("key") or ("MWOYEO_CLAUDE_API_KEY" if cfg["kind"] == "claude" else None)
    return k is None or bool(os.environ.get(k))

def run_one(name, cfg, pair, p, batch, run, outf):
    row = {"engine": name, "model": cfg["model"], "pair": pair, "batch": batch, "run": run, "ms": None, "lines_out": None, "error": None, "out": None}
    lines = p["batches"][batch]
    for attempt in range(4):
        t = time.perf_counter(); row["error"] = None
        try:
            out, err = call(cfg, p["source"], p["target"], lines)
            row["ms"] = round((time.perf_counter() - t) * 1000)
            row["lines_out"] = len(out); row["out"] = out
            if err: row["error"] = err
            elif len(out) != len(lines): row["error"] = f"line count {len(out)}!={len(lines)}"
            else:
                e = echoes(out, lines, p["target"])
                if e: row["echo"] = e
            row["retries"] = attempt
            break
        except urllib.error.HTTPError as ex:
            row["error"] = f"HTTP {ex.code}"
            if ex.code == 400: row["error"] += " " + ex.read().decode("utf8", "replace")[:100]
            if ex.code in (429, 503) and attempt < 3: time.sleep(20 * (attempt + 1)); continue
            break
        except Exception as ex:
            row["error"] = f"{type(ex).__name__}: {str(ex)[:80]}"
            break
    outf.write(json.dumps(row, ensure_ascii=False) + "\n"); outf.flush()
    return row

def summarize(rows):
    for name in dict.fromkeys(r["engine"] for r in rows):
        warm = sorted(r["ms"] for r in rows if r["engine"] == name and r["run"] > 0 and r["ms"] is not None and not r["error"])
        cold = [r["ms"] for r in rows if r["engine"] == name and r["run"] == 0 and r["ms"] is not None]
        errs = sum(1 for r in rows if r["engine"] == name and r["error"])
        if warm:
            p90 = warm[min(len(warm) - 1, int(0.9 * len(warm)))]
            print(f"{name}: warm median {statistics.median(warm)/1000:.2f}s p90 {p90/1000:.2f}s cold {cold[0]/1000 if cold else float('nan'):.2f}s errors {errs}")
        else: print(f"{name}: no successful warm rows, errors {errs}")

def main():
    ap = argparse.ArgumentParser(description="Speed benchmark of translation engines (HTTP + Ollama). Apple: apple.swift.")
    ap.add_argument("--engines", default="all", help="comma list of: " + ", ".join(ENGINES) + " (default: all whose key is set)")
    ap.add_argument("--pairs", default="all"); ap.add_argument("--runs", type=int, default=3)
    ap.add_argument("--gap", type=float, default=0.5, help="seconds between calls")
    ap.add_argument("--out", default=os.path.join(HERE, "raw-http.jsonl"))
    a = ap.parse_args()
    data = json.load(open(os.path.join(HERE, "data.json")))["pairs"]
    pairs = list(data) if a.pairs == "all" else a.pairs.split(",")
    names = list(ENGINES) if a.engines == "all" else a.engines.split(",")
    rows = []
    with open(a.out, "a") as f:
        for name in names:
            cfg = ENGINES[name]
            if not keys_present(name, cfg): print(f"skip {name}: key not set"); continue
            for pair in pairs:
                p = data[pair]
                rows.append(run_one(name, cfg, pair, p, 0, 0, f)); time.sleep(a.gap)  # cold
                for b in range(len(p["batches"])):
                    for r in range(1, a.runs + 1):
                        rows.append(run_one(name, cfg, pair, p, b, r, f)); time.sleep(a.gap)
            summarize([r for r in rows if r["engine"] == name])
if __name__ == "__main__": main()
