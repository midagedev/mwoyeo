#!/usr/bin/env python3
"""Tallies of preserved judge passes. Run it isolated: `python3 -I judge-report.py <judge dir> [--models a,b,c]`.

A judge dir holds `<judge model label>/<pair>/{key.json, verdicts.jsonl}` (what `judge-run.py run` writes next to the `key.json` of
`judge.py prompts`). Per pair and judge model it prints what `judge.py tally` counts, over the items that were asked: wins of A and B
where both orders agree, ties, items whose orders disagree (position bias, not counted), items still missing an order, the share of B
among the decided with its Wilson interval and the sign test. Then, per pair, the consensus of the judge models: an item counts for A
or B when every model that finished both orders of it picked the same side; a tie when all of them said tie; otherwise it is `split`
(not counted). Two judges that agree plus a passed calibration is a verdict; one judge alone is a screen.

With `--echo` a second table splits each pair's outcomes by whether a side left the line untranslated (its text equals the line's
source text): the judge's verdict on lines both sides translated, and on lines one side copied back. Exit 0."""
import argparse
import importlib.util
import json
import os
import sys

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


S, J = _load("score"), _load("judge")


def read_verdicts(path):
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [json.loads(l) for l in f if l.strip()]


def item_outcomes(key, verdicts):
    """{item: 'a' | 'b' | 'tie' | 'disagree' | 'partial'} for the real items with at least one verdict. The last verdict of an id wins."""
    votes = {}
    for v in verdicts:
        item, _, order = v["id"].rpartition(".")
        got = J.parse_verdict(v)
        if item in key["items"] and key["items"][item]["kind"] == "real" and order in ("1", "2") and got:
            votes.setdefault(item, {})[order] = J.winner(order, got)
    out = {}
    for item, v in votes.items():
        out[item] = "partial" if len(v) < 2 else (v["1"] if v["1"] == v["2"] else "disagree")
    return out


def calibration(key, verdicts):
    """(passed, failed, missing) over the identical-text items: both orders must say tie."""
    votes = {}
    for v in verdicts:
        item, _, order = v["id"].rpartition(".")
        got = J.parse_verdict(v)
        if item in key["items"] and key["items"][item]["kind"] == "calibration" and order in ("1", "2") and got:
            votes.setdefault(item, {})[order] = J.winner(order, got)
    cal = [i for i, info in key["items"].items() if info["kind"] == "calibration"]
    ok = sum(1 for i in cal if len(votes.get(i, {})) == 2 and votes[i]["1"] == votes[i]["2"] == "tie")
    missing = sum(1 for i in cal if len(votes.get(i, {})) < 2)
    return ok, len(cal) - ok - missing, missing


def counts(outcomes):
    c = {"a": 0, "b": 0, "tie": 0, "disagree": 0, "partial": 0}
    for o in outcomes.values():
        c[o] += 1
    c["decided"] = c["a"] + c["b"]
    c["asked"] = len(outcomes)
    return c


def share_text(c):
    if not c["decided"]:
        return "-"
    lo, hi = S.wilson(c["b"], c["decided"])
    return "%.1f%% (%.1f-%.1f)" % (100 * c["b"] / c["decided"], 100 * max(0.0, lo), 100 * min(1.0, hi))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir")
    ap.add_argument("--models", help="comma-separated judge model labels (default: every sub-directory, sorted)")
    ap.add_argument("--echo", action="store_true", help="also split by untranslated (copied back) lines")
    ap.add_argument("--root", default=HERE, help="the corpus, for --echo")
    args = ap.parse_args(argv)
    models = args.models.split(",") if args.models else sorted(d for d in os.listdir(args.dir) if os.path.isdir(os.path.join(args.dir, d)))
    pairs = sorted({p for m in models for p in os.listdir(os.path.join(args.dir, m)) if os.path.exists(os.path.join(args.dir, m, p, "key.json"))})
    print("| pair (A vs B) | judge | items asked | A wins | B wins | tie | orders disagree | one order only | B share of decided (95% CI) | p | calibration ok/failed/missing |")
    print("|:---|:---|---:|---:|---:|---:|---:|---:|:---|---:|:---|")
    for p in pairs:
        outs = {}
        for m in models:
            kp = os.path.join(args.dir, m, p, "key.json")
            if not os.path.exists(kp):
                continue
            key = S.load_json(kp)
            verdicts = read_verdicts(os.path.join(args.dir, m, p, "verdicts.jsonl"))
            o = item_outcomes(key, verdicts)
            outs[m] = o
            c = counts(o)
            ok, failed, missing = calibration(key, verdicts)
            print("| %s | %s | %d | %d | %d | %d | %d | %d | %s | %s | %d/%d/%d |"
                  % (p, m, c["asked"], c["a"], c["b"], c["tie"], c["disagree"], c["partial"], share_text(c),
                     "%.4f" % S.sign_test(c["a"], c["b"]) if c["decided"] else "-", ok, failed, missing))
        if len(outs) > 1:
            both = set.intersection(*[{i for i, o in m.items() if o in ("a", "b", "tie")} for m in outs.values()])
            c = {"a": 0, "b": 0, "tie": 0, "split": 0}
            for i in both:
                sides = {m[i] for m in outs.values()}
                c[next(iter(sides)) if len(sides) == 1 else "split"] += 1
            decided = c["a"] + c["b"]
            share = "-"
            if decided:
                lo, hi = S.wilson(c["b"], decided)
                share = "%.1f%% (%.1f-%.1f)" % (100 * c["b"] / decided, 100 * max(0.0, lo), 100 * min(1.0, hi))
            print("| %s | consensus of %s | %d | %d | %d | %d | split %d | | %s | %s | |"
                  % (p, "+".join(outs), len(both), c["a"], c["b"], c["tie"], c["split"], share,
                     "%.4f" % S.sign_test(c["a"], c["b"]) if decided else "-"))
    if args.echo:
        seqs, _ = S.load_corpus(args.root)
        print()
        print("| pair (A vs B) | judge | lines | A wins | B wins | tie | orders disagree | B share of decided |")
        print("|:---|:---|:---|---:|---:|---:|---:|:---|")
        for p in pairs:
            for m in models:
                kp = os.path.join(args.dir, m, p, "key.json")
                if not os.path.exists(kp):
                    continue
                key = S.load_json(kp)
                out = item_outcomes(key, read_verdicts(os.path.join(args.dir, m, p, "verdicts.jsonl")))
                tab = {}
                for item, o in out.items():
                    info = key["items"][item]
                    src = S.nfc(next(l["text"] for l in seqs[info["seq"]]["lines"] if l["id"] == info["line"])).strip()
                    ea, eb = info["a_text"] == src, info["b_text"] == src
                    cat = "both translated" if not ea and not eb else "only A copied back" if ea and not eb else "only B copied back" if eb and not ea else "both copied back"
                    c = tab.setdefault(cat, {"a": 0, "b": 0, "tie": 0, "disagree": 0, "partial": 0})
                    c[o] += 1
                for cat in ("both translated", "only A copied back", "only B copied back", "both copied back"):
                    c = tab.get(cat)
                    if c:
                        dec = c["a"] + c["b"]
                        print("| %s | %s | %s (%d) | %d | %d | %d | %d | %s |"
                              % (p, m, cat, sum(c.values()), c["a"], c["b"], c["tie"], c["disagree"],
                                 "%.0f%%" % (100 * c["b"] / dec) if dec else "-"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
