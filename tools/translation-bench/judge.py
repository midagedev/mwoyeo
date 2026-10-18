#!/usr/bin/env python3
"""Pairwise blind judge harness. Run it isolated: `python3 -I judge.py prompts|tally ...`. It never calls a judge.

  prompts   `--a <run dir> --b <run dir> --out <dir>`: for every line whose two translations differ, one prompt file per
            order in `<dir>/prompts/` (`item-0007.1.txt`: A's text first, `item-0007.2.txt`: B's first). The prompts carry
            no condition name.
            Identical translations are not asked (a tie by construction); a few calibration items, the same text twice,
            are mixed in under neutral names: the judge must call them a tie in both orders. `<dir>/key.json` (keep it
            away from the judge) maps items to conditions.
  tally     `--key <out>/key.json --verdicts <file>`: one JSON object per line, `{"id": "item-0007.1", "better": "1"}`
            (`"1"`, `"2"` or `"tie"`; a model's raw answer under `"answer"` is parsed). Only items on which both orders
            agree are counted; items whose orders disagree are position bias and are reported, not counted.

Design (context-translation.md section 5): blind to the condition, both orders, agreement only, at least 150 decided
pairs per comparison, a calibration pair per round."""
import argparse
import importlib.util
import json
import os
import random
import re
import sys

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("score", os.path.join(HERE, "score.py"))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

LANG_NAME = {"ja": "Japanese", "zh": "Chinese (Simplified)", "en": "English", "ko": "Korean"}
CONTEXT_LINES = 6
MIN_DECIDED = 150

INSTRUCTIONS = """You are judging two candidate translations of one line of text captured from a computer screen.
Judge only the translation of the line marked "Line to translate". The earlier lines are context; the facts block, when
present, is known to be true and outranks any guess. Prefer the translation that is more faithful in meaning and that
gets the names, the pronouns (who is meant, and their gender), the terms, the register and (for Korean) the speech level
of that speaker right; then the one that reads more naturally. Ignore length and formatting. If they are equally good,
answer "tie"."""


def label(seq, line):
    return "[%s] %s" % (line["speaker"], line["text"]) if seq.get("speaker_visible", True) and line.get("speaker") else line["text"]


def build_prompt(seq, mem, line, first, second):
    out = [INSTRUCTIONS, "", "Source language: %s. Target language: %s." % (LANG_NAME[seq["source"]], LANG_NAME[seq["target"]])]
    facts = S.render_memory(mem) if mem else ""
    if facts:
        out += ["", "Facts known to be true (from the user; not part of the text):", facts]
    ctx = [l for l in seq["lines"] if l["id"] < line["id"]][-CONTEXT_LINES:]
    if ctx:
        out += ["", "Earlier lines (source language, context only):"] + [label(seq, l) for l in ctx]
    out += ["", "Line to translate:", label(seq, line), "", "Translation 1:", first, "", "Translation 2:", second, "",
            'Answer with JSON only: {"better": "1" or "2" or "tie", "why": "<at most 15 words>"}']
    return "\n".join(out) + "\n"


def cmd_prompts(args):
    seqs, mems = S.load_corpus(args.root)
    ra, rb = S.load_run(args.a), S.load_run(args.b)
    ca, cb = ra["meta"]["condition"], rb["meta"]["condition"]
    rng = random.Random(args.seed)
    real, identical = [], []
    for sid, seq in seqs.items():
        if args.seq and sid not in args.seq:
            continue
        if sid not in ra["outs"] or sid not in rb["outs"]:
            continue
        for line in seq["lines"]:
            ta, tb = S.nfc(S.translation_of(ra, sid, line["id"])).strip(), S.nfc(S.translation_of(rb, sid, line["id"])).strip()
            if not ta or not tb:
                continue
            (identical if ta == tb else real).append((sid, line, ta, tb))
    rng.shuffle(real)
    if args.max:
        real = real[:args.max]
    # calibration: identical pairs; when every pair differs, a differing line's text from run A against itself
    pool = identical if identical else [(sid, line, ta, ta) for sid, line, ta, _ in real[:args.calibration]]
    rng.shuffle(pool)
    calibration = pool[:args.calibration]
    items = [("real", x) for x in real] + [("calibration", x) for x in calibration]
    rng.shuffle(items)
    prompts_dir = os.path.join(args.out, "prompts")
    os.makedirs(prompts_dir, exist_ok=True)
    key = {"a": ca, "b": cb, "identical": len(identical), "items": {}}
    for n, (kind, (sid, line, ta, tb)) in enumerate(items, 1):
        item = "item-%04d" % n
        key["items"][item] = {"seq": sid, "line": line["id"], "kind": kind, "a_text": ta, "b_text": tb}
        for order, (first, second) in (("1", (ta, tb)), ("2", (tb, ta))):
            with open(os.path.join(prompts_dir, "%s.%s.txt" % (item, order)), "w", encoding="utf-8") as f:
                f.write(build_prompt(seqs[sid], mems[sid], line, first, second))
    with open(os.path.join(args.out, "key.json"), "w", encoding="utf-8") as f:
        json.dump(key, f, ensure_ascii=False, indent=1)
    print("%d items (%d real, %d calibration), %d prompt files in %s/prompts; %d identical translations not asked"
          % (len(items), len(real), len(calibration), 2 * len(items), args.out, len(identical)))
    print("give each item-NNNN.O.txt to the judge as one call; collect JSONL: {\"id\": \"item-NNNN.O\", \"better\": \"1|2|tie\"}")
    return 0


def parse_verdict(obj):
    """'1', '2' or 'tie' from a verdict object, or None."""
    v = obj.get("better")
    if v is None:
        raw = obj.get("answer") or obj.get("text") or ""
        m = re.search(r"\{.*\}", raw, re.S)
        if m:
            try:
                v = json.loads(m.group(0)).get("better")
            except ValueError:
                v = None
    v = str(v).strip().lower() if v is not None else None
    return v if v in ("1", "2", "tie") else None


def winner(order, verdict):
    """'a', 'b' or 'tie' for a verdict in order 1 (A first) or 2 (B first)."""
    if verdict == "tie":
        return "tie"
    first_is_a = order == "1"
    return "a" if (verdict == "1") == first_is_a else "b"


def tally(key, verdicts):
    votes = {}
    for v in verdicts:
        item, _, order = v["id"].rpartition(".")
        got = parse_verdict(v)
        if item in key["items"] and order in ("1", "2") and got:
            votes.setdefault(item, {})[order] = winner(order, got)
    res = {"a": 0, "b": 0, "tie": 0, "disagree": 0, "missing": 0, "cal_pass": 0, "cal_fail": 0, "cal_missing": 0,
           "identical": key.get("identical", 0), "disagree_ids": []}
    for item, info in key["items"].items():
        v = votes.get(item, {})
        if info["kind"] == "calibration":
            if len(v) < 2:
                res["cal_missing"] += 1
            elif v["1"] == v["2"] == "tie":
                res["cal_pass"] += 1
            else:
                res["cal_fail"] += 1
            continue
        if len(v) < 2:
            res["missing"] += 1
        elif v["1"] == v["2"]:
            res[v["1"]] += 1
        else:
            res["disagree"] += 1
            res["disagree_ids"].append(item)
    decided = res["a"] + res["b"]
    res["decided"] = decided
    res["b_rate"] = res["b"] / decided if decided else None
    res["ci"] = S.wilson(res["b"], decided) if decided else None
    res["p"] = S.sign_test(res["a"], res["b"])
    res["calibration_ok"] = res["cal_fail"] == 0 and res["cal_missing"] == 0 and res["cal_pass"] > 0
    return res


def cmd_tally(args):
    key = S.load_json(args.key)
    with open(args.verdicts, encoding="utf-8") as f:
        verdicts = [json.loads(l) for l in f if l.strip()]
    r = tally(key, verdicts)
    a, b = key["a"], key["b"]
    print("judge tally: %s (A) vs %s (B)" % (a, b))
    print("  agreeing in both orders: %s wins %d, %s wins %d, tie %d" % (a, r["a"], b, r["b"], r["tie"]))
    print("  orders disagree (position bias, not counted): %d; missing verdicts: %d; identical translations not asked: %d"
          % (r["disagree"], r["missing"], r["identical"]))
    print("  decided pairs %d (need at least %d): %s" % (r["decided"], args.min_decided, "enough" if r["decided"] >= args.min_decided else "NOT ENOUGH"))
    if r["decided"]:
        print("  %s win rate among decided %.1f%%  95%% CI %.1f-%.1f%%  sign test p=%.4f"
              % (b, 100 * r["b_rate"], 100 * r["ci"][0], 100 * r["ci"][1], r["p"]))
    print("  calibration (identical text, both orders must say tie): passed %d, failed %d, missing %d => %s"
          % (r["cal_pass"], r["cal_fail"], r["cal_missing"], "OK" if r["calibration_ok"] else "FAILED: treat the verdicts as a screen only"))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prompts")
    p.add_argument("--a", required=True)
    p.add_argument("--b", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--root", default=HERE)
    p.add_argument("--seq", nargs="*")
    p.add_argument("--max", type=int, default=0, help="at most this many real items (0: all)")
    p.add_argument("--calibration", type=int, default=4)
    p.add_argument("--seed", type=int, default=7)
    p.set_defaults(fn=cmd_prompts)
    t = sub.add_parser("tally")
    t.add_argument("--key", required=True)
    t.add_argument("--verdicts", required=True)
    t.add_argument("--min-decided", type=int, default=MIN_DECIDED)
    t.set_defaults(fn=cmd_tally)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
