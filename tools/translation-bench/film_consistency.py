#!/usr/bin/env python3
"""How consistently does an engine render the names and terms of a sequence, and how many speech-level probes does it pass?
Run it isolated: `python3 -I film_consistency.py [--root DIR] [--seq ID] [--detail] [--json FILE] <run dir>...`

For every name (entity) and term of the sequence's memory, over the lines whose source text contains it, the script finds the
Korean rendering each line carries and counts the distinct ones. A rendering is found in this order:
  1. a known form: the memory's `dst`, the `any` and `none` strings and the `bad_sub` replacement of the probes that carry the
     key, and the source string itself (an untranslated name). The longest form found wins, so a listed wrong form that
     contains the right one ("쉬잔느" over "쉬잔") is not mistaken for it. Spaces are ignored, so "월영사당" and "월영 사당" are one.
     Every accepted form counts as the memory's `dst`.
  2. otherwise the string found at the `dst`'s position: the line's hand-written `ref` is aligned with the output (difflib,
     characters, spaces dropped) and the output characters opposite the `dst` in the `ref` are the rendering. An empty span is
     "(omitted)", a span much longer than the `dst` is "(unaligned)", an empty line is "(empty)". The alignment drags a
     neighbouring word in now and then ("월계의신사" and "월계의신사는내" are one rendering), so among the aligned strings a
     longer one that contains a shorter one (two characters or more) counts as the shorter.
`--detail` lists the renderings found, so a reader can see what the aligned ones look like. The distinct count is what the
table shows; a name or term with one rendering is "consistent" (it need not be the memory's form: the `canonical` columns say
whether it is). A name or term that occurs in fewer than two lines is not counted.

`--repeat A B` (given once per pair) compares two runs of the same condition: lines with identical output, probes with the same
verdict, keys with the same renderings. At temperature 0 it tells whether the inconsistency of a condition is stable or noise.

Speech level is the pass count of the sequence's `speech_level` probes; `probes` is every probe of the sequence (score.py's
`check_probe`). `echo/kana` counts the lines copied back untranslated (score.py's `is_echo`) and the lines that still hold a
kana: an engine that echoes its source is consistent in the trivial way, and the table must not hide it."""
import argparse
import difflib
import importlib.util
import json
import os
import sys
import unicodedata

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("score", os.path.join(HERE, "score.py"))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

# a span this many characters longer than the `dst` is a failed alignment, not a rendering
UNALIGNED_SLACK = 8


def squash(text):
    """NFC, case-folded, without whitespace: the form two renderings are compared in."""
    return "".join(unicodedata.normalize("NFC", text or "").casefold().split())


def key_forms(seq, mem, kind, src):
    """(dst, accepted forms, listed wrong forms, source) of one name or term."""
    if kind == "ent":
        ent = next((e for e in mem.get("entities", []) if e.get("name") == src), {})
        dst = ent.get("dst") or ""
    else:
        dst = next((t["dst"] for t in mem.get("terms", []) if t.get("src") == src), "")
    accepted, wrong = set(), set()
    if dst:
        accepted.add(dst)
    for p in seq.get("probes", []):
        if p.get("key") != "%s:%s" % (kind, src):
            continue
        chk = p.get("check", {})
        accepted.update(chk.get("any", []))
        wrong.update(chk.get("none", []))
        if p.get("bad_sub"):
            wrong.add(p["bad_sub"][1])
    if not dst and accepted:
        dst = sorted(accepted, key=len)[0]
    return dst, accepted, wrong - accepted


def aligned_span(ref, out, dst):
    """The output characters opposite `dst` in `ref` (both squashed), or a marker when there are none to give."""
    r, o, d = squash(ref), squash(out), squash(dst)
    if not o:
        return "(empty)"
    i = r.find(d)
    if not d or i < 0:
        return "(unaligned)"
    j = i + len(d)
    start = end = None
    for tag, i1, i2, j1, j2 in difflib.SequenceMatcher(None, r, o, autojunk=False).get_opcodes():
        if tag == "equal":
            lo, hi = max(i1, i), min(i2, j)
            if lo >= hi:
                continue
            a, b = j1 + (lo - i1), j1 + (hi - i1)
        else:
            if i2 <= i or i1 >= j:
                continue
            a, b = j1, j2
        start = a if start is None else min(start, a)
        end = b if end is None else max(end, b)
    if start is None or end is None or start == end:
        return "(omitted)"
    span = o[start:end]
    return span if len(span) <= len(d) + UNALIGNED_SLACK else "(unaligned)"


def rendering(out, ref, src, dst, accepted, wrong):
    """The memory's `dst` for an accepted form, else the wrong form or the source found, else the aligned span."""
    t = squash(out)
    if not t:
        return "(empty)"
    forms = [(squash(f), dst) for f in accepted] + [(squash(f), f) for f in wrong] + [(squash(src), src)]
    found = [(f, label) for f, label in forms if f and f in t]
    if found:
        return max(found, key=lambda fl: len(fl[0]))[1]
    return aligned_span(ref, out, dst)


def merge_contained(spans):
    """Maps each aligned string to the shortest string of the set that it contains (itself when none). Markers stay as they are."""
    reps, out = [], {}
    for sp in sorted(set(spans), key=lambda x: (len(x), x)):
        if sp.startswith("("):
            out[sp] = sp
            continue
        base = next((r for r in reps if len(r) >= 2 and r in sp), sp)
        if base == sp:
            reps.append(sp)
        out[sp] = base
    return out


def keys_of(seq, mem):
    out = [("ent", e["name"]) for e in mem.get("entities", [])]
    out += [("term", t["src"]) for t in mem.get("terms", [])]
    return out


def measure(run, seq, mem):
    """One run of one sequence: the renderings of every counted key, the speech and probe passes."""
    sid = seq["id"]
    keys = {}
    for kind, src in keys_of(seq, mem):
        lines = [l for l in seq["lines"] if src in l["text"]]
        if len(lines) < 2:
            continue
        dst, accepted, wrong = key_forms(seq, mem, kind, src)
        found = [rendering(S.translation_of(run, sid, l["id"]), l["ref"], src, dst, accepted, wrong) for l in lines]
        known = {dst, src} | wrong
        merged = merge_contained([f for f in found if f not in known])
        counts = {}
        for f in found:
            r = merged.get(f, f)
            counts[r] = counts.get(r, 0) + 1
        keys["%s:%s" % (kind, src)] = {
            "kind": kind, "src": src, "dst": dst, "lines": len(lines), "renderings": counts, "distinct": len(counts),
            "canonical": set(counts) == {dst}}
    probes = S.score_probes(run, {sid: seq}, {sid: mem})
    outs = {l["id"]: S.translation_of(run, sid, l["id"]) for l in seq["lines"]}
    echoed = sum(S.is_echo(seq, l, outs[l["id"]]) for l in seq["lines"])
    kana = sum(any(0x3040 <= ord(ch) <= 0x30FF for ch in outs[l["id"]]) for l in seq["lines"])
    speech = [r["ok"] for r in probes.values() if r["type"] == "speech_level"]
    names = [k for k in keys.values() if k["kind"] == "ent"]
    terms = [k for k in keys.values() if k["kind"] == "term"]
    return {
        "run": os.path.basename(os.path.normpath(run["path"])), "engine": run["meta"].get("engine", ""),
        "condition": run["meta"].get("condition", ""), "layout": run["meta"].get("layout", ""),
        "keys": keys,
        "names_consistent": [sum(k["distinct"] == 1 for k in names), len(names)],
        "terms_consistent": [sum(k["distinct"] == 1 for k in terms), len(terms)],
        "canonical": [sum(k["canonical"] for k in keys.values()), len(keys)],
        "speech": [sum(speech), len(speech)],
        "echo_kana": [echoed, kana, len(seq["lines"])],
        "probes": [sum(r["ok"] for r in probes.values()), len(probes)],
    }


def agreement(run_a, run_b, seq, mem):
    """Two runs of one sequence: lines with identical output, probes with the same verdict, keys with the same renderings."""
    sid = seq["id"]
    same_lines = sum(S.translation_of(run_a, sid, l["id"]) == S.translation_of(run_b, sid, l["id"]) for l in seq["lines"])
    pa = S.score_probes(run_a, {sid: seq}, {sid: mem})
    pb = S.score_probes(run_b, {sid: seq}, {sid: mem})
    same_probes = sum(pa[k]["ok"] == pb[k]["ok"] for k in pa)
    ma, mb = measure(run_a, seq, mem), measure(run_b, seq, mem)
    same_keys = sum(ma["keys"][k]["renderings"] == mb["keys"][k]["renderings"] for k in ma["keys"])
    return {"a": ma["run"], "b": mb["run"], "lines": [same_lines, len(seq["lines"])], "probes": [same_probes, len(pa)],
            "keys": [same_keys, len(ma["keys"])]}


def pct(a, b):
    return "%.0f%%" % (100.0 * a / b) if b else "-"


def print_table(rows, keys, out):
    head = ["run", "engine", "cond"] + ["%s" % k.split(":", 1)[1] for k in keys] + [
        "names 1-form", "terms 1-form", "canonical", "speech", "echo/kana", "probes"]
    lines = ["| " + " | ".join(head) + " |", "|" + "|".join("---" for _ in head) + "|"]
    for r in rows:
        cells = [r["run"], r["engine"], r["condition"]]
        cells += [str(r["keys"][k]["distinct"]) if k in r["keys"] else "-" for k in keys]
        cells += ["%d/%d" % tuple(r["names_consistent"]), "%d/%d" % tuple(r["terms_consistent"]),
                  "%d/%d" % tuple(r["canonical"]), "%d/%d" % tuple(r["speech"]),
                  "%d/%d of %d" % tuple(r["echo_kana"]),
                  "%d/%d (%s)" % (r["probes"][0], r["probes"][1], pct(*r["probes"]))]
        lines.append("| " + " | ".join(cells) + " |")
    print("\n".join(lines), file=out)
    print("\ncolumns after cond: distinct Korean renderings of each name/term over its lines (1 = consistent). names/terms 1-form: "
          "keys with one rendering; canonical: keys whose every line carries the memory's form; speech: speech-level probes passed; "
          "echo/kana: lines copied back untranslated / lines that still hold a kana; probes: all probes passed.", file=out)


def print_detail(rows, out):
    for r in rows:
        print("\n%s (%s, %s)" % (r["run"], r["engine"], r["condition"]), file=out)
        for k, v in r["keys"].items():
            forms = ", ".join("%s x%d" % (f, n) for f, n in sorted(v["renderings"].items(), key=lambda fn: (-fn[1], fn[0])))
            print("  %-22s %s" % (k, forms), file=out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="*", help="run directories (a scratch run or a preserved one under runs/)")
    ap.add_argument("--root", default=HERE, help="the bench directory (sequences/, memory/)")
    ap.add_argument("--seq", help="the sequence id (default: the only sequence a run holds)")
    ap.add_argument("--repeat", nargs=2, action="append", default=[], metavar=("RUN_A", "RUN_B"),
                    help="two runs of one condition: how much of their output agrees (once per pair)")
    ap.add_argument("--detail", action="store_true", help="list the renderings found per name and term")
    ap.add_argument("--json", help="write the numbers here")
    args = ap.parse_args(argv)

    if not args.runs and not args.repeat:
        ap.error("give at least one run directory")
    seqs, mems = S.load_corpus(args.root)
    rows = []
    for path in args.runs:
        run = S.load_run(path)
        sid = args.seq or (next(iter(run["outs"])) if len(run["outs"]) == 1 else None)
        if sid is None or sid not in run["outs"] or sid not in seqs:
            print("%s: pass --seq with one of %s" % (path, sorted(run["outs"])), file=sys.stderr)
            return 2
        rows.append(measure(run, seqs[sid], mems[sid]))
    keys = []
    for r in rows:
        keys += [k for k in r["keys"] if k not in keys]
    if rows:
        print_table(rows, keys, sys.stdout)
    if args.detail:
        print_detail(rows, sys.stdout)
    repeats = []
    for pa, pb in args.repeat:
        ra, rb = S.load_run(pa), S.load_run(pb)
        sid = args.seq or (next(iter(ra["outs"])) if len(ra["outs"]) == 1 else None)
        if sid is None or sid not in ra["outs"] or sid not in rb["outs"] or sid not in seqs:
            print("%s, %s: pass --seq with a sequence both runs hold" % (pa, pb), file=sys.stderr)
            return 2
        ag = agreement(ra, rb, seqs[sid], mems[sid])
        repeats.append(ag)
        print("\nrepeat %s vs %s: identical lines %d/%d, same probe verdicts %d/%d, same renderings for %d/%d keys" % (
            ag["a"], ag["b"], *ag["lines"], *ag["probes"], *ag["keys"]))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({"runs": rows, "repeats": repeats}, f, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
