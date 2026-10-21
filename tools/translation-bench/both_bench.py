#!/usr/bin/env python3
"""Analysis of the both-bench arms (round both-bench, design names-and-context sections 5.2(d) and 10).
Run it isolated: `python3 -I both_bench.py table|noise|judge ...`

A run made with `bench-run run --apply both|both-names` records, per request, which item lines had the rows' targets written into
their source (`replaced`). The translations stay keyed by the ORIGINAL lines, so the probes, `film_consistency.py` and the judge read
the sequences unchanged. This script splits every line of a sequence into classes and never pools across them:

  N  names      lines rewritten under `both-names` (an entity's target written in; terms are hints)
  T  terms      lines rewritten under `both` but not under `both-names` (a term's target written in, no entity on the line)
  U  untouched  every other line: no arm wrote into it, so the arms differ there only through what the hint rows and the history did

`both` and `both-names` differ only on T (terms always have a target), so "both for all rows" is read on T and "both for names" on N.
The names-kept figure of N and T is inflated by construction (the source already holds the target; copying passes), so those classes are
decided by the particle check and the judge; U is where the hint can lose its power once other lines are rewritten.

  table   --engine LABEL --hint RUN --both-names RUN --both RUN [--root DIR] [--memory-dir memory-named] [--json FILE]
          per arm and class: lines, names and terms kept (the key lines whose output holds the memory's form, as film_consistency.py
          renders it), probes passed, echoed lines, kana lines; per arm against hint on the same lines: lines with identical output
          and the probes only one arm passes (sign test); the particle breaks of the rewritten lines (particles.py).
  noise   --old RUN --new RUN [--root DIR] [--memory-dir memory-named]
          two runs of one condition on one engine: the same measures, so a later delta inside this spread is "no difference".
  judge   --pair DIR --verdicts FILE --b-run RUN [--hint RUN] [--both-names RUN] [--both RUN] [--root DIR]
          the tally of a `judge.py prompts --a <hint> --b <arm>` pair, overall and per class, with the Wilson interval; the verdicts are
          counted where both orders agree; the particle breaks of the arm's rewritten lines come beside the replaced-line verdicts."""
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


S, F, P, J = _load("score"), _load("film_consistency"), _load("particles"), _load("judge")
CLASSES = ("N", "T", "U")
CLASS_NAME = {"N": "names (entity rows written in)", "T": "terms only (a term written in, no entity)", "U": "untouched"}
ARMS = ("hint", "both-names", "both")
POOL = False   # tests/test_both_bench.py --neuter: every line is "untouched", the classes pooled; the test must fail with it
SAME_OFF = False   # tests/test_both_bench.py --neuter: no sequence counts as identical to hint, so none is excluded; the test must fail


def pct(k, n):
    return "-" if not n else "%.1f%%" % (100.0 * k / n)


def frac(k, n):
    return "%d/%d (%s)" % (k, n, pct(k, n))


def ci(k, n):
    lo, hi = S.wilson(k, n)
    return "%.0f-%.0f%%" % (100 * lo, 100 * hi) if n else "-"


def load_named(root, memory_dir):
    seqs, _ = S.load_corpus(root)
    mems = {}
    for sid in seqs:
        p = os.path.join(root, memory_dir, sid + ".json")
        mems[sid] = S.load_json(p) if os.path.exists(p) else {}
    return seqs, mems


def replaced_ids(run, sid):
    """The ids of the lines of `sid` whose counted request carried a rewritten text (empty without `replaced`)."""
    out = run["outs"].get(sid)
    ids = set()
    for req in (out or {}).get("requests", []):
        ids.update(r["id"] for r in req.get("replaced") or [])
    return ids


def classes_of(both_names_run, both_run, seqs):
    """{sid: {line id: 'N'|'T'|'U'}} from the two arms' own records. `both-names` lines are expected to be a subset of `both` lines."""
    out, notes = {}, []
    for sid, seq in seqs.items():
        if sid not in both_run["outs"] or sid not in both_names_run["outs"]:
            continue
        n, r = replaced_ids(both_names_run, sid), replaced_ids(both_run, sid)
        if n - r:
            notes.append("%s: lines %s rewritten under both-names but not under both" % (sid, sorted(n - r)))
        out[sid] = {l["id"]: ("U" if POOL else "N" if l["id"] in n else "T" if l["id"] in r else "U") for l in seq["lines"]}
    return out, notes


def request_key(req):
    """What the engine was asked, without what came back: the items and context lines, the layout's character counts, the rows added."""
    lay = req.get("layout", {})
    return (tuple(req.get("items", [])), tuple(req.get("context", [])), lay.get("stable_chars"), lay.get("volatile_chars"),
            lay.get("history_chars"), json.dumps(req.get("terms_added"), ensure_ascii=False))


def identical_sequences(run_a, run_b):
    """The sequences whose requests are the same in both runs (no rewritten line, same counts): the arms cannot differ there except by
    the engine's own noise, so they are listed and kept out of the evidence."""
    same = set()
    for sid in sorted(set(run_a["outs"]) & set(run_b["outs"])):
        ra, rb = run_a["outs"][sid].get("requests", []), run_b["outs"][sid].get("requests", [])
        if not SAME_OFF and len(ra) == len(rb) and all(not b.get("replaced") and request_key(a) == request_key(b) for a, b in zip(ra, rb)):
            same.add(sid)
    return same


def measure(run, seqs, mems, classes):
    """Per class: lines, key-lines kept (entities, terms), probes by type and kind, echoes, kana lines, failed lines."""
    acc = {c: {"lines": 0, "ent": [0, 0], "term": [0, 0], "probes": [0, 0], "by_type": {}, "by_kind": {}, "echo": 0, "kana": 0,
               "empty": 0} for c in CLASSES}
    for sid, cls in classes.items():
        if sid not in run["outs"]:
            continue
        seq, mem = seqs[sid], mems[sid]
        outs = {l["id"]: S.translation_of(run, sid, l["id"]) for l in seq["lines"]}
        for l in seq["lines"]:
            a = acc[cls[l["id"]]]
            a["lines"] += 1
            a["echo"] += bool(S.is_echo(seq, l, outs[l["id"]]))
            a["kana"] += seq["target"] == "ko" and any(0x3040 <= ord(ch) <= 0x30FF for ch in outs[l["id"]])
            a["empty"] += not outs[l["id"]].strip()
        for kind, src in F.keys_of(seq, mem):
            dst, accepted, wrong = F.key_forms(seq, mem, kind, src)
            for l in seq["lines"]:
                if src not in l["text"]:
                    continue
                r = F.rendering(outs[l["id"]], l["ref"], src, dst, accepted, wrong)
                a = acc[cls[l["id"]]]["ent" if kind == "ent" else "term"]
                a[1] += 1
                a[0] += r == dst
        for r in S.score_probes(run, {sid: seq}, {sid: mem}).values():
            a = acc[cls[r["line"]]]
            a["probes"][1] += 1
            a["probes"][0] += r["ok"]
            for group, key in (("by_type", r["type"]), ("by_kind", r["kind"])):
                cell = a[group].setdefault(key, [0, 0])
                cell[1] += 1
                cell[0] += r["ok"]
    return acc


def paired(run_a, run_b, seqs, mems, classes):
    """Per class, run B against run A on the same lines: lines with identical output; probes only A passes / only B passes."""
    res = {c: {"lines": 0, "same": 0, "a_only": 0, "b_only": 0, "probes": 0, "types": {}} for c in CLASSES}
    for sid, cls in classes.items():
        if sid not in run_a["outs"] or sid not in run_b["outs"]:
            continue
        seq = seqs[sid]
        for l in seq["lines"]:
            r = res[cls[l["id"]]]
            r["lines"] += 1
            r["same"] += S.nfc(S.translation_of(run_a, sid, l["id"])).strip() == S.nfc(S.translation_of(run_b, sid, l["id"])).strip()
        pa = S.score_probes(run_a, {sid: seq}, {sid: mems[sid]})
        pb = S.score_probes(run_b, {sid: seq}, {sid: mems[sid]})
        for k in pa:
            r = res[cls[pa[k]["line"]]]
            r["probes"] += 1
            a_only, b_only = pa[k]["ok"] and not pb[k]["ok"], pb[k]["ok"] and not pa[k]["ok"]
            r["a_only"] += a_only
            r["b_only"] += b_only
            cell = r["types"].setdefault(pa[k]["type"], [0, 0, 0])
            cell[0] += a_only
            cell[1] += b_only
            cell[2] += 1
    for r in res.values():
        r["p"] = S.sign_test(r["a_only"], r["b_only"])
    return res


def particle_summary(run, seqs, plan=None):
    rows = P.check_run(run, seqs, plan)
    return {"written": len(rows), "kept": sum(r["kept"] for r in rows), "breaks": sum(len(r["particle"]) for r in rows),
            "with_particle": sum(r["with_particle"] for r in rows),
            "kana_after": sum(len(r["kana_after"]) for r in rows),
            "kana_examples": [(r["seq"], r["line"], r["target"], c) for r in rows for c in r["kana_after"]],
            "kana_lines": sorted({(r["seq"], r["line"]) for r in rows if r["kana_after"]}),
            "one_char": sum(bool(r["one_char"]) for r in rows),
            "examples": [(r["seq"], r["line"], r["target"], b["found"], b["want"], b["context"]) for r in rows for b in r["particle"]],
            "one_char_examples": [(r["seq"], r["line"], r["matched"], r["target"], r["one_char"][0]) for r in rows if r["one_char"]],
            "break_lines": sorted({(r["seq"], r["line"]) for r in rows if r["particle"]})}


def table_rows(label, acc):
    rows = []
    for c in CLASSES:
        a = acc[c]
        rows.append("| %s | %s | %d | %s | %s | %s | %d | %d |" % (
            label, c, a["lines"], frac(*a["ent"]), frac(*a["term"]), frac(*a["probes"]), a["echo"], a["kana"]))
    return rows


def kind_rows(label, acc):
    cells = []
    for g in ("by_kind", "by_type"):
        keys = sorted({k for c in CLASSES for k in acc[c][g]})
        for k in keys:
            u = acc["U"][g].get(k, [0, 0])
            cells.append("%s %s %d/%d" % (g[3:], k, *u))
    return "| %s | %s |" % (label, "; ".join(cells))


HEAD = ["| arm | class | lines | entity key-lines kept | term key-lines kept | probes passed | echoed | kana |",
        "|---|---|---|---|---|---|---|---|"]


def cmd_table(args):
    seqs, mems = load_named(args.root, args.memory_dir)
    runs = {"hint": S.load_run(args.hint), "both-names": S.load_run(args.both_names), "both": S.load_run(args.both)}
    classes, notes = classes_of(runs["both-names"], runs["both"], seqs)
    print("## %s: arms over %d sequences, classes by the arms' own `replaced` records" % (args.engine, len(classes)))
    for n in notes:
        print("WARNING %s" % n)
    sizes = {c: sum(1 for cls in classes.values() for v in cls.values() if v == c) for c in CLASSES}
    print("classes: " + ", ".join("%s %s = %d lines" % (c, CLASS_NAME[c], sizes[c]) for c in CLASSES) + "\n")
    out = {"engine": args.engine, "sizes": sizes, "arms": {}, "paired": {}, "particles": {}}
    lines = list(HEAD)
    accs = {}
    for arm in ARMS:
        accs[arm] = measure(runs[arm], seqs, mems, classes)
        lines += table_rows(arm, accs[arm])
        out["arms"][arm] = accs[arm]
    print("\n".join(lines))
    print("\nuntouched-line probes by sequence kind and by type (did the hint lose power once other lines were rewritten?)")
    for arm in ARMS:
        print(kind_rows(arm, accs[arm]))
    print("\nagainst hint, same lines (identical output; probes only hint passes / only the arm passes; two-sided sign test)")
    same_seqs = {arm: identical_sequences(runs["hint"], runs[arm]) for arm in ("both-names", "both")}
    out["identical"] = {arm: sorted(v) for arm, v in same_seqs.items()}
    for arm, same in same_seqs.items():
        print("requests identical to hint (excluded from the %s rows below): %s" % (arm, ", ".join(sorted(same)) or "none"))
    print("| arm | class | lines | identical output | probes | hint only | arm only | p |\n|---|---|---|---|---|---|---|---|")
    for arm in ("both-names", "both"):
        same = same_seqs[arm]
        pr = paired(runs["hint"], runs[arm], seqs, mems, {sid: c for sid, c in classes.items() if sid not in same})
        out["paired"][arm] = pr
        for c in CLASSES:
            r = pr[c]
            print("| %s | %s | %d | %s | %d | %d | %d | %.3f |" % (arm, c, r["lines"], frac(r["same"], r["lines"]), r["probes"], r["a_only"], r["b_only"], r["p"]))
    print("\nthe same flips by probe type (hint only / arm only / probes of the type), classes N and T")
    for arm in ("both-names", "both"):
        for c in ("N", "T"):
            t = out["paired"][arm][c]["types"]
            print("%s %s: %s" % (arm, c, "; ".join("%s %d/%d of %d" % (k, v[0], v[1], v[2]) for k, v in sorted(t.items()))))
    print("\nparticles and one-character rows of the rewritten lines (hint: the same targets looked for in the hint arm's output, which wrote none)")
    for arm in ("hint", "both-names", "both"):
        ps = particle_summary(runs[arm], seqs, None if arm != "hint" else runs["both"])
        out["particles"][arm] = {k: v for k, v in ps.items()}
        print("%s: %d targets written, %d held by the output, %d followed by a particle, %d particle breaks, %d with a kana left right after the target, %d one-character rows inside a longer word"
              % (arm, ps["written"], ps["kept"], ps["with_particle"], ps["breaks"], ps["kana_after"], ps["one_char"]))
        for sid, line, target, ctx in ps["kana_examples"]:
            print("  kana %s/%d: %s  ...%s..." % (sid, line, target, ctx))
        for sid, line, target, found, want, ctx in ps["examples"]:
            print("  break %s/%d: %s + %s (wants %s)  ...%s..." % (sid, line, target, found, want, ctx))
        for sid, line, matched, target, ctx in ps["one_char_examples"]:
            print("  one-char %s/%d: %s -> %s inside %s" % (sid, line, matched, target, ctx))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(out, f, ensure_ascii=False, indent=1, default=list)
    return 0


def cmd_noise(args):
    seqs, mems = load_named(args.root, args.memory_dir)
    old, new = S.load_run(args.old), S.load_run(args.new)
    common = sorted(set(old["outs"]) & set(new["outs"]) & set(seqs))
    classes = {sid: {l["id"]: "U" for l in seqs[sid]["lines"]} for sid in common}
    print("## noise floor: %s (old) vs %s (new), %d common sequences" % (os.path.basename(args.old.rstrip("/")), os.path.basename(args.new.rstrip("/")), len(common)))
    print("\n".join(HEAD))
    for label, run in (("old", old), ("new", new)):
        for row in table_rows(label, measure(run, seqs, mems, classes)):
            if "| U |" in row:
                print(row.replace("| U |", "| all |"))
    r = paired(old, new, seqs, mems, classes)["U"]
    print("\nold vs new, the same lines: identical output %s; probes %d: only old passes %d, only new passes %d, sign test p=%.3f"
          % (frac(r["same"], r["lines"]), r["probes"], r["a_only"], r["b_only"], r["p"]))
    return 0


def cmd_judge(args):
    seqs, mems = load_named(args.root, args.memory_dir)
    key = S.load_json(os.path.join(args.pair, "key.json"))
    with open(args.verdicts, encoding="utf-8") as f:
        verdicts = [json.loads(l) for l in f if l.strip()]
    brun = S.load_run(args.b_run)
    classes = None
    if args.hint and args.both_names and args.both:
        classes, _ = classes_of(S.load_run(args.both_names), S.load_run(args.both), seqs)
    ps = particle_summary(brun, seqs)
    broken = set(ps["break_lines"]) | set(ps["kana_lines"])
    print("## judge %s (A) vs %s (B), %d items asked, %d identical translations not asked" % (key["a"], key["b"], sum(i["kind"] == "real" for i in key["items"].values()), key["identical"]))
    groups = {"all": None}
    if classes:
        groups.update({c: c for c in CLASSES})
    for name, c in groups.items():
        sub = {"a": key["a"], "b": key["b"], "identical": key["identical"], "items": {
            k: v for k, v in key["items"].items()
            if v["kind"] == "calibration" or c is None or (classes.get(v["seq"], {}).get(v["line"]) == c)}}
        t = J.tally(sub, verdicts)
        agreed = t["a"] + t["b"] + t["tie"]
        loss = "loss rate %s of %d agreed (CI %s)" % (pct(t["a"], agreed), agreed, ci(t["a"], agreed)) if agreed else "no agreed items"
        win = "B wins %d of %d decided = %s (CI %s)" % (t["b"], t["decided"], pct(t["b"], t["decided"]), ci(t["b"], t["decided"])) if t["decided"] else "no decided items"
        print("- %s: A wins %d, B wins %d, tie %d; orders disagree %d (not counted), missing %d. %s; %s; sign test p=%.3f"
              % (name, t["a"], t["b"], t["tie"], t["disagree"], t["missing"], win, loss, t["p"]))
        if name == "all":
            print("  calibration (identical text, both orders must say tie): passed %d, failed %d, missing %d => %s"
                  % (t["cal_pass"], t["cal_fail"], t["cal_missing"], "OK" if t["calibration_ok"] else "FAILED: a screen, not a verdict"))
        if c in ("N", "T"):
            # the judge ranks name correctness above naturalness: a copied name with a broken particle can win
            votes = {}
            for v in verdicts:
                item, _, order = v["id"].rpartition(".")
                got = J.parse_verdict(v)
                if item in sub["items"] and got:
                    votes.setdefault(item, {})[order] = J.winner(order, got)
            b_wins = [i for i, o in votes.items() if sub["items"][i]["kind"] == "real" and len(o) == 2 and o["1"] == o["2"] == "b"]
            with_break = [i for i in b_wins if (sub["items"][i]["seq"], sub["items"][i]["line"]) in broken]
            print("  of the %d B wins on class %s lines, %d carry a particle break or a kana left after the target in B's output" % (len(b_wins), c, len(with_break)))
    print("particle breaks of B's rewritten lines overall: %d of %d targets followed by a particle (%d written); %d lines with a kana left after a target"
          % (ps["breaks"], ps["with_particle"], ps["written"], ps["kana_after"]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name, fn in (("table", cmd_table), ("noise", cmd_noise), ("judge", cmd_judge)):
        p = sub.add_parser(name)
        p.add_argument("--root", default=HERE)
        p.add_argument("--memory-dir", default="memory-named", help="the memories the dst forms are read from")
        p.set_defaults(fn=fn)
        if name == "table":
            p.add_argument("--engine", required=True)
            for arm in ("hint", "both-names", "both"):
                p.add_argument("--" + arm, required=True)
            p.add_argument("--json")
        elif name == "noise":
            p.add_argument("--old", required=True)
            p.add_argument("--new", required=True)
        else:
            p.add_argument("--pair", required=True)
            p.add_argument("--verdicts", required=True)
            p.add_argument("--b-run", required=True)
            for arm in ("hint", "both-names", "both"):
                p.add_argument("--" + arm)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
