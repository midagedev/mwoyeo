#!/usr/bin/env python3
"""Scorer for the translation bench. Run it isolated: `python3 -I score.py <run dir>...`.

A run dir is one condition on one engine, written by the runner: `meta.json` plus one `<sequence id>.json` per sequence.
This file is also the bench's shared library (probe checks, the Korean speech-level classifier, token estimate, sign
test); `validate.py` and `judge.py` load it by path, because `-I` keeps the script directory off `sys.path`.

Metrics (design/context-translation.md section 5):
  probe accuracy         by evidence (`memory`, `lines`, `none`), by type, by lookback distance of the evidence line
  sign test              exact, two-sided, on the probes where two runs disagree
  speech level           share of scored lines whose sentence endings match the speaker's level for that addressee;
                         "inconsistent" counts (speaker, level) groups whose lines show more than one level
  carry-over             a wrong rendering (a string from the probe's `none` list) that repeats on a later probe of the
                         same key; `fail streaks` counts consecutive failures of one key whatever the wrong form
  latency                p50 / p95 of one request, retries included
  tokens and cost        usage from the engine, prefix vs volatile split from the runner, price table prices.json
"""
import argparse
import glob
import importlib.util
import json
import math
import os
import re
import statistics
import sys
import unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))

LEVEL_CLASS = {"해요체": "haeyo", "합쇼체": "hapsyo", "반말": "banmal"}
DISTANCE_BUCKETS = [(1, 2, "1-2"), (3, 4, "3-4"), (5, 8, "5-8"), (9, 16, "9-16"), (17, 10**6, "17+")]


# ---------------------------------------------------------------------------------------------------------------------
# text helpers

def nfc(s):
    return unicodedata.normalize("NFC", s)


def est_tokens(text):
    """A script-aware token estimate, within about 30 % of a real tokenizer: one token per Hangul, kana or Han
    character, a quarter per ASCII letter or digit, none for whitespace, a half for other marks. The runner calibrates
    it per request against the usage the engine reports."""
    t = 0.0
    for ch in text:
        o = ord(ch)
        if ch.isspace():
            continue
        if (0xAC00 <= o <= 0xD7A3 or 0x3040 <= o <= 0x30FF or 0x3400 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF
                or 0x3131 <= o <= 0x318E):
            t += 1.0
        elif ch.isascii() and ch.isalnum():
            t += 0.27
        else:
            t += 0.5
    return t


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


# ---------------------------------------------------------------------------------------------------------------------
# Korean speech level, by sentence ending (LoCar: a judge confuses haeyo and hapsyo; a suffix check does not)

_QUOTED = re.compile(r"[“\"「『][^”\"」』]*[”\"」』]")
_SPLIT = re.compile(r"(?<=[.!?…。！？])\s*|\n+")
_HANGUL = re.compile(r"[가-힣]")


def _jongseong(ch):
    return (ord(ch) - 0xAC00) % 28


def sentence_class(sentence):
    """`hapsyo`, `haeyo`, `banmal` (the plain and intimate endings together) or `unk` (no Hangul ending to judge)."""
    s = sentence.rstrip()
    while s and not (_HANGUL.match(s[-1]) or (s[-1].isascii() and s[-1].isalnum())):
        s = s[:-1]
    if not s or not _HANGUL.match(s[-1]) or len(_HANGUL.findall(s)) < 2:
        return "unk"   # no Hangul ending, or one syllable ("네", "응"): an answer word, not an ending
    last = s[-1]
    if last in "요":                     # 요
        return "haeyo"
    if s.endswith("죠"):                 # 죠: the contraction of 지요
        return "haeyo"
    if len(s) >= 2:
        end = s[-2:]
        if end in ("니다", "니까", "시오"):      # 니다 니까 시오
            return "hapsyo"
        if end == "시다" and len(s) >= 3 and _HANGUL.match(s[-3]) and _jongseong(s[-3]) == 17:   # ㅂ시다
            return "hapsyo"
    return "banmal"


def sentence_classes(text):
    text = nfc(text)
    plain = _QUOTED.sub(" ", text)
    if not _HANGUL.search(plain):
        plain = re.sub(r"[“”\"「」『』]", "", text)
    return [sentence_class(p) for p in _SPLIT.split(plain) if p and _HANGUL.search(p)]


def line_level(text):
    """The one level every judged sentence of the line has: `hapsyo`, `haeyo`, `banmal`; `mixed` when they differ;
    None when there is nothing to judge."""
    classes = [c for c in sentence_classes(text) if c != "unk"]
    if not classes:
        return None
    return classes[0] if len(set(classes)) == 1 else "mixed"


# ---------------------------------------------------------------------------------------------------------------------
# probe checks

CHECK_KEYS = {"any", "none", "any_w", "none_w", "regex", "nregex", "level"}


def _word_in(word, text):
    return re.search(r"(?<![A-Za-z])" + re.escape(word) + r"(?![A-Za-z])", text, re.I) is not None


def check_probe(check, text):
    """True when `text` (one line's translation) satisfies the check. All given keys must hold:
    any: some string occurs; none: no string occurs; any_w / none_w: the same as whole words, for English;
    regex: it matches; nregex: it does not; level: the line's Korean speech level equals it."""
    t = nfc(text or "")
    low = t.casefold()
    if check.get("any") and not any(nfc(s).casefold() in low for s in check["any"]):
        return False
    if any(nfc(s).casefold() in low for s in check.get("none", [])):
        return False
    if check.get("any_w") and not any(_word_in(w, t) for w in check["any_w"]):
        return False
    if any(_word_in(w, t) for w in check.get("none_w", [])):
        return False
    if check.get("regex") and re.search(check["regex"], t, re.I) is None:
        return False
    if check.get("nregex") and re.search(check["nregex"], t, re.I) is not None:
        return False
    if check.get("level") and line_level(t) != check["level"]:
        return False
    return True


def wrong_forms(check, text):
    """The explicit wrong renderings (strings of the check's `none` / `none_w`) that `text` contains."""
    t = nfc(text or "")
    low = t.casefold()
    found = {nfc(s).casefold() for s in check.get("none", []) if nfc(s).casefold() in low}
    found |= {w.casefold() for w in check.get("none_w", []) if _word_in(w, t)}
    return found


# ---------------------------------------------------------------------------------------------------------------------
# statistics

def sign_test(a_only, b_only):
    """Exact two-sided sign test on the discordant probes: `a_only` right in run A only, `b_only` in run B only."""
    n = a_only + b_only
    if n == 0:
        return 1.0
    k = min(a_only, b_only)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - h) / d, (c + h) / d)


def percentile(values, q):
    if not values:
        return None
    v = sorted(values)
    i = (len(v) - 1) * q
    lo, hi = math.floor(i), math.ceil(i)
    return v[lo] + (v[hi] - v[lo]) * (i - lo)


# ---------------------------------------------------------------------------------------------------------------------
# corpus: sequences and memories

def load_corpus(root):
    seqs, mems = {}, {}
    for p in sorted(glob.glob(os.path.join(root, "sequences", "*.json"))):
        s = load_json(p)
        seqs[s["id"]] = s
        mp = os.path.join(root, "memory", s["id"] + ".json")
        mems[s["id"]] = load_json(mp) if os.path.exists(mp) else {}
    return seqs, mems


def probe_distance(seq, probe):
    """Lines between the probe's line and the nearest evidence line above it; None unless the evidence is in lines."""
    if probe.get("by") != "lines" or not probe.get("need"):
        return None
    return min(probe["line"] - n for n in probe["need"])


def distance_bucket(d):
    for lo, hi, name in DISTANCE_BUCKETS:
        if lo <= d <= hi:
            return name
    return "0"


def expected_level(seq, mem, line):
    """The speech level class the line's speaker uses to the addressee, from the memory's `speaks_to`; None when the
    target is not Korean, the speaker is unknown, or the addressee is ambiguous."""
    if seq.get("target") != "ko" or not line.get("speaker"):
        return None
    ent = next((e for e in mem.get("entities", []) if e.get("name") == line["speaker"]), None)
    if not ent or not ent.get("speaks_to"):
        return None
    speaks = ent["speaks_to"]
    to = line.get("to")
    if to is None:
        levels = set(speaks.values())
        if len(levels) != 1:
            return None
        return LEVEL_CLASS.get(next(iter(levels)))
    return LEVEL_CLASS.get(speaks.get(to))


# ---------------------------------------------------------------------------------------------------------------------
# the user memory as the prompt shows it (the runner renders the same text; tests/check_render.py compares them)

MEMORY_SECTIONS = ("window", "document", "entities", "terms")


def render_memory(mem, sections=MEMORY_SECTIONS, speech=True):
    """The notes block of a prompt, one line per part, empty parts left out. Entities are `name (reading) = dst`,
    gender, role, `speaks to A: level, B: level` (addressees in code point order; left out when `speech` is false, as
    for subtitles whose speaker the lens cannot tell), joined by "; "."""
    lines = []
    if "window" in sections and mem.get("window"):
        w = mem["window"]
        parts = [w.get("title"), "app: " + w["app"] if w.get("app") else None,
                 "category: " + w["category"] if w.get("category") else None]
        parts = [x for x in parts if x]
        if parts:
            lines.append("Window: " + " | ".join(parts))
    if "document" in sections and mem.get("document"):
        d = mem["document"]
        parts = [x for x in (d.get("title"), d.get("domain"), d.get("summary")) if x]
        if parts:
            lines.append("Document: " + "; ".join(parts))
    if "entities" in sections and mem.get("entities"):
        lines.append("People:")
        for e in mem["entities"]:
            name = e["name"] + (" (%s)" % e["reading"] if e.get("reading") else "") + (" = %s" % e["dst"] if e.get("dst") else "")
            parts = [name, e.get("gender"), e.get("role")]
            if speech and e.get("speaks_to"):
                parts.append("speaks to " + ", ".join("%s: %s" % (k, v) for k, v in sorted(e["speaks_to"].items())))
            lines.append("- " + "; ".join(x for x in parts if x))
    if "terms" in sections and mem.get("terms"):
        lines.append("Terms: " + "; ".join("%s = %s" % (t["src"], t["dst"]) for t in mem["terms"]))
    return "\n".join(lines)


def resolve_memory_path(mem, path):
    """`entities.<name>.<field>`, `terms.<src>`, `document.<field>` or `window.<field>`: the value, else None."""
    head, _, rest = path.partition(".")
    if head == "entities":
        name, _, field = rest.partition(".")
        ent = next((e for e in mem.get("entities", []) if e.get("name") == name), None)
        return (ent or {}).get(field) if field else ent
    if head == "terms":
        t = next((t for t in mem.get("terms", []) if t.get("src") == rest), None)
        return t["dst"] if t else None
    if head in ("document", "window"):
        return (mem.get(head) or {}).get(rest)
    return None


# ---------------------------------------------------------------------------------------------------------------------
# runs

def load_run(path):
    meta = load_json(os.path.join(path, "meta.json"))
    outs = {}
    for p in sorted(glob.glob(os.path.join(path, "*.json"))):
        if os.path.basename(p) in ("meta.json", "MANIFEST.json"):   # MANIFEST.json: a preserved run (runs.py)
            continue
        o = load_json(p)
        outs[o["id"]] = o
    return {"path": path, "meta": meta, "outs": outs}


def translation_of(run, seq_id, line_id):
    out = run["outs"].get(seq_id)
    if not out:
        return ""
    return out.get("translations", {}).get(str(line_id), "")


def score_probes(run, seqs, mems):
    """Per probe: id -> {ok, type, by, bucket, key, line, seq, wrong}."""
    res = {}
    for sid, seq in seqs.items():
        if sid not in run["outs"]:
            continue
        for p in seq.get("probes", []):
            text = translation_of(run, sid, p["line"])
            ok = check_probe(p["check"], text)
            res[sid + "/" + p["id"]] = {
                "ok": ok, "type": p["type"], "by": p["by"], "key": p.get("key"), "line": p["line"], "seq": sid,
                "bucket": distance_bucket(probe_distance(seq, p)) if p["by"] == "lines" else None,
                "wrong": wrong_forms(p["check"], text) if not ok else set(),
                "pair": seq["source"] + ">" + seq["target"], "kind": seq["kind"],
            }
    return res


def carry_over(results):
    """repeat_same: probes of a key (names, terms, registers) that show a wrong form an earlier probe of the same key
    already showed. after_wrong: probes that follow a probe of the key which showed a wrong form. fail_streak:
    consecutive failures of one key, whatever the wrong form."""
    groups = {}
    for r in results.values():
        if r["key"]:
            groups.setdefault((r["seq"], r["key"]), []).append(r)
    repeat_same = after_wrong = fail_streak = streak_chances = 0
    for rs in groups.values():
        rs.sort(key=lambda r: r["line"])
        seen = set()
        prev_failed = False
        for i, r in enumerate(rs):
            if seen:
                after_wrong += 1
                if r["wrong"] & seen:
                    repeat_same += 1
            if i > 0:
                streak_chances += 1
                if prev_failed and not r["ok"]:
                    fail_streak += 1
            seen |= r["wrong"]
            prev_failed = not r["ok"]
    return {"repeat_same": repeat_same, "after_wrong": after_wrong, "fail_streak": fail_streak,
            "streak_chances": streak_chances}


def speech_scores(run, seqs, mems):
    scored = match = mixed = 0
    per_speaker = {}
    for sid, seq in seqs.items():
        if sid not in run["outs"]:
            continue
        for line in seq["lines"]:
            exp = expected_level(seq, mems[sid], line)
            if not exp:
                continue
            got = line_level(translation_of(run, sid, line["id"]))
            if got is None:
                continue
            scored += 1
            ok = got == exp
            match += ok
            mixed += got == "mixed"
            d = per_speaker.setdefault((sid, line["speaker"], exp), set())
            d.add(got)
    inconsistent = sum(1 for levels in per_speaker.values() if len(levels) > 1)
    return {"scored": scored, "match": match, "mixed": mixed, "speakers": len(per_speaker),
            "inconsistent_speakers": inconsistent}


def requests_of(run):
    for out in run["outs"].values():
        for r in out.get("requests", []):
            yield r


def load_prices(root):
    path = os.path.join(root, "prices.json")
    return load_json(path) if os.path.exists(path) else {"models": {}}


def price_for(run, prices):
    meta = run["meta"]
    key = meta.get("price") or meta.get("model") or ""
    return prices.get("models", {}).get(key)


def cost_usd(run, prices):
    p = price_for(run, prices)
    if p is None:
        return None
    total = 0.0
    for r in requests_of(run):
        u = r.get("usage") or {}
        cached = u.get("cached") or 0
        written = u.get("cache_write") or 0
        fresh = max(0, (u.get("in") or 0) - cached - written)
        total += (fresh * p["in"] + cached * p.get("cached", p["in"]) + written * p.get("write", p["in"])
                  + (u.get("out") or 0) * p["out"]) / 1e6
    return total


def summarize(run, seqs, mems, prices):
    probes = score_probes(run, seqs, mems)
    n = len(probes)
    ok = sum(r["ok"] for r in probes.values())

    def acc(sel):
        rs = [r for r in probes.values() if sel(r)]
        return (sum(r["ok"] for r in rs), len(rs))

    reqs = list(requests_of(run))
    lat = [r["latency_ms"] for r in reqs if r.get("latency_ms") is not None]
    usage = [r.get("usage") or {} for r in reqs]
    layouts = [r.get("layout") or {} for r in reqs]

    def mean(vals):
        vals = [v for v in vals if v is not None]
        return sum(vals) / len(vals) if vals else None

    return {
        "condition": run["meta"].get("condition"), "engine": run["meta"].get("engine"), "model": run["meta"].get("model"),
        "jobs": run["meta"].get("jobs", 1), "sequences": len(run["outs"]), "requests": len(reqs),
        "probes": {"n": n, "ok": ok,
                   "by": {b: acc(lambda r, b=b: r["by"] == b) for b in ("memory", "lines", "none")},
                   "type": {t: acc(lambda r, t=t: r["type"] == t) for t in sorted({r["type"] for r in probes.values()})},
                   "pair": {t: acc(lambda r, t=t: r["pair"] == t) for t in sorted({r["pair"] for r in probes.values()})},
                   "kind": {t: acc(lambda r, t=t: r["kind"] == t) for t in sorted({r["kind"] for r in probes.values()})},
                   "distance": {name: acc(lambda r, name=name: r["bucket"] == name) for _, _, name in DISTANCE_BUCKETS}},
        "speech": speech_scores(run, seqs, mems),
        "carry": carry_over(probes),
        "attempts_failed": sum(1 for r in reqs for a in r.get("attempts", []) if not a.get("ok", True)),
        "fallback_lines": sum(len(r.get("fallback", [])) for r in reqs),
        "failed_lines": sum(len(r.get("failed", [])) for r in reqs),
        "latency": {"p50": percentile(lat, 0.5), "p95": percentile(lat, 0.95)},
        "tokens": {
            "in": sum(u.get("in") or 0 for u in usage), "out": sum(u.get("out") or 0 for u in usage),
            "cached": sum(u.get("cached") or 0 for u in usage),
            "mean_in": mean([u.get("in") for u in usage]), "mean_out": mean([u.get("out") for u in usage]),
            "stable": mean([l.get("stable_tok") for l in layouts]), "history": mean([l.get("history_tok") for l in layouts]),
            "volatile": mean([l.get("volatile_tok") for l in layouts]), "lcp": mean([l.get("lcp_tok") for l in layouts]),
            "memory": mean([l.get("memory_tok") for l in layouts]),
        },
        "cost_usd": cost_usd(run, prices),
        "_probes": probes,
    }


def compare(a, b):
    """Sign tests of run b against run a over the probes both runs scored: all, and by evidence kind."""
    pa, pb = a["_probes"], b["_probes"]
    out = {}
    for name, sel in (("all", lambda r: True), ("memory", lambda r: r["by"] == "memory"),
                      ("lines", lambda r: r["by"] == "lines"), ("none", lambda r: r["by"] == "none")):
        a_only = b_only = both = neither = 0
        for k in pa.keys() & pb.keys():
            if not sel(pa[k]):
                continue
            x, y = pa[k]["ok"], pb[k]["ok"]
            if x and y:
                both += 1
            elif x:
                a_only += 1
            elif y:
                b_only += 1
            else:
                neither += 1
        n = both + neither + a_only + b_only
        out[name] = {"n": n, "a_only": a_only, "b_only": b_only,
                     "delta_pts": (100.0 * (b_only - a_only) / n) if n else 0.0, "p": sign_test(a_only, b_only)}
    return out


# ---------------------------------------------------------------------------------------------------------------------
# report

def pct(k, n):
    return "  -  " if n == 0 else "%5.1f%%" % (100.0 * k / n)


def fmt(v, spec="%.0f"):
    return "-" if v is None else spec % v


def print_summary(s, out):
    p = s["probes"]
    label = "%s | %s %s | jobs=%s" % (s["condition"], s["engine"], s["model"], s["jobs"])
    print("== run %s | %d sequences, %d requests" % (label, s["sequences"], s["requests"]), file=out)
    print("probes %d: %d correct = %s" % (p["n"], p["ok"], pct(p["ok"], p["n"]).strip()), file=out)
    print("  by evidence: " + "  ".join("%s %d/%d %s" % (b, *p["by"][b], pct(*p["by"][b]).strip())
                                        for b in ("memory", "lines", "none")), file=out)
    print("  by type:     " + "  ".join("%s %d/%d %s" % (t, *v, pct(*v).strip()) for t, v in p["type"].items()), file=out)
    print("  by distance: " + "  ".join("%s %d/%d %s" % (t, *v, pct(*v).strip()) for t, v in p["distance"].items()
                                         if v[1]), file=out)
    print("  by pair:     " + "  ".join("%s %s" % (t, pct(*v).strip()) for t, v in p["pair"].items()), file=out)
    sp = s["speech"]
    print("speech level: %d lines judged, %d match the speaker's level = %s, %d mixed, %d of %d speaker-level groups inconsistent"
          % (sp["scored"], sp["match"], pct(sp["match"], sp["scored"]).strip(), sp["mixed"], sp["inconsistent_speakers"],
             sp["speakers"]), file=out)
    c = s["carry"]
    print("carry-over: %d repeated wrong forms after %d probes that followed a wrong form; %d fail streaks in %d chances"
          % (c["repeat_same"], c["after_wrong"], c["fail_streak"], c["streak_chances"]), file=out)
    print("failed attempts %d, fallback lines %d, empty lines %d" % (s["attempts_failed"], s["fallback_lines"],
                                                                    s["failed_lines"]), file=out)
    lat = s["latency"]
    print("latency ms: p50 %s p95 %s" % (fmt(lat["p50"]), fmt(lat["p95"])), file=out)
    t = s["tokens"]
    print("tokens: in %d (mean %s: stable %s + history %s + volatile %s; shared prefix with the previous request %s; "
          "user memory %s) out %d (mean %s) cached %d" % (
              t["in"], fmt(t["mean_in"], "%.1f"), fmt(t["stable"], "%.1f"), fmt(t["history"], "%.1f"),
              fmt(t["volatile"], "%.1f"), fmt(t["lcp"], "%.1f"), fmt(t["memory"], "%.1f"), t["out"],
              fmt(t["mean_out"], "%.1f"), t["cached"]), file=out)
    print("cost estimate: %s" % ("no price for this model" if s["cost_usd"] is None else "$%.4f" % s["cost_usd"]), file=out)


def print_compare(a, b, cmp, out):
    print("-- %s vs %s (probes both scored; + means %s is better)" % (a["condition"], b["condition"], b["condition"]),
          file=out)
    for name in ("all", "memory", "lines", "none"):
        c = cmp[name]
        print("   %-6s n=%3d  only %s right %3d  only %s right %3d  delta %+5.1f pts  sign test p=%.4f"
              % (name, c["n"], a["condition"], c["a_only"], b["condition"], c["b_only"], c["delta_pts"], c["p"]),
              file=out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", help="run directories (one condition on one engine each)")
    ap.add_argument("--root", default=HERE, help="the bench directory (sequences/, memory/, prices.json)")
    ap.add_argument("--baseline", help="condition name the others are compared with (default: the first run)")
    ap.add_argument("--json", help="write the numbers here")
    args = ap.parse_args(argv)

    seqs, mems = load_corpus(args.root)
    prices = load_prices(args.root)
    sums = [summarize(load_run(r), seqs, mems, prices) for r in args.runs]
    for s in sums:
        print_summary(s, sys.stdout)
    base = next((s for s in sums if s["condition"] == args.baseline), sums[0])
    jobs = {s["jobs"] for s in sums}
    models = {(s["engine"], s["model"]) for s in sums}
    if len(models) > 1:
        print("note: runs use different engines or models; the deltas below mix engine and condition", file=sys.stdout)
    if len(jobs) > 1:
        print("note: runs used different --jobs; latency is not comparable", file=sys.stdout)
    for s in sums:
        if s is not base:
            print_compare(base, s, compare(base, s), sys.stdout)
    if args.json:
        slim = [{k: v for k, v in s.items() if k != "_probes"} for s in sums]
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(slim, f, ensure_ascii=False, indent=1, default=lambda o: sorted(o) if isinstance(o, set) else o)
    return 0


if __name__ == "__main__":
    sys.exit(main())
