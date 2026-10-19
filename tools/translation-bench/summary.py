#!/usr/bin/env python3
"""Regenerates runs/SUMMARY.md from the preserved runs. Never edit that file by hand.

    python3 -I summary.py            write runs/SUMMARY.md
    python3 -I summary.py --check    exit 1 when runs/SUMMARY.md is not what the runs produce now (stale or hand-edited)
    python3 -I summary.py --stdout   print it

For every model, one row per run (model runs only; oracle and smoke runs are scorer self-checks and are counted at the
end). Each run is scored by `score.py` against the corpus snapshot it was preserved with, so a row never changes when
the live corpus does; the sign test against condition A of the same model is printed only between runs on the same
snapshot. The output has no timestamps: the same runs give the same bytes."""
import argparse
import glob
import importlib.util
import json
import os
import re
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))

MODEL_ORDER = ["gemma3:4b", "gemma4:e4b", "translategemma:4b", "gemma4:26b", "llama3.2:1b", "qwen3:1.7b"]
CONDITION_ORDER = ["A", "B2", "B4", "W", "M", "L", "C16"]
TYPES = ("name", "pronoun", "register", "speech_level", "term")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


S = load("score")


def pct(k, n):
    return "-" if not n else "%.1f" % (100.0 * k / n)


def frac(pair):
    return pct(pair[0], pair[1])


def pval(p):
    return "<0.001" if p < 0.001 else "%.3f" % p


def num(v, spec="%.0f"):
    return "-" if v is None else spec % v


def machine_tag(note):
    """The load caveat `matrix.sh` writes into a note; None for runs that carry it in prose only."""
    m = re.search(r"\[machine load1m start=([\d.]+) end=([\d.]+) pageouts \+(\d+) swapouts \+(\d+)", note or "")
    return m.groups() if m else None


def cond_key(cond):
    return (CONDITION_ORDER.index(cond) if cond in CONDITION_ORDER else len(CONDITION_ORDER), cond or "")


def model_key(name):
    return (MODEL_ORDER.index(name) if name in MODEL_ORDER else len(MODEL_ORDER), name)


def collect(root):
    """Every preserved model run: manifest, summary, failures, grouped by model."""
    rows = []
    corpora = {}
    prices_by_snap = {}
    for run_dir in sorted(glob.glob(os.path.join(root, "runs", "*"))):
        if not os.path.isdir(run_dir) or os.path.basename(run_dir).startswith("_"):
            continue
        mp = os.path.join(run_dir, "MANIFEST.json")
        if not os.path.isfile(mp):
            continue
        m = S.load_json(mp)
        if m["kind"] != "model":
            continue
        snap = m["corpus"]["snapshot"]
        snap_root = os.path.join(root, "runs", snap)
        if snap not in corpora:
            corpora[snap] = S.load_corpus(snap_root)
            prices_by_snap[snap] = S.load_prices(snap_root)
        seqs, mems = corpora[snap]
        run = S.load_run(run_dir)
        rows.append({"name": m["run"], "manifest": m, "snap": snap, "run": run,
                     "sum": S.summarize(run, seqs, mems, prices_by_snap[snap]), "fail": S.failure_report(run, seqs)})
    models = {}
    for r in rows:
        models.setdefault(r["manifest"]["model"].get("name") or r["sum"]["model"], []).append(r)
    for rs in models.values():
        main = min((variant(x) for x in rs), key=lambda v: (len(v), v))   # the plain engine config first, variants after
        rs.sort(key=lambda r: (variant(r) != main, variant(r), cond_key(r["manifest"]["condition"]),
                               r["manifest"]["layout"] or "", r["name"]))
    return dict(sorted(models.items(), key=lambda kv: model_key(kv[0]))), len(rows)


def variant(r):
    """The engine config a run used (`engines/ollama-gemma4-e4b.json`, `...-fold.json`): runs of different configs of one
    model are different requests, so each is compared with the condition A of its own config."""
    return os.path.basename((r["manifest"].get("engine") or {}).get("config_file") or "")


def baseline(rs, r=None):
    """Condition A that run `r` is compared with: the earliest-dated A run on the same engine config, else on the model."""
    a = [x for x in rs if x["manifest"]["condition"] == "A"]
    same = [x for x in a if r is None or variant(x) == variant(r)]
    pool = same or a
    pool.sort(key=lambda x: (x["manifest"]["date"] or "", x["name"]))
    return pool[0] if pool else None


def vs_a(base, r):
    if base is None or r is base:
        return None
    if base["snap"] != r["snap"]:
        return "other corpus"
    return S.compare(base["sum"], r["sum"])


def label(r):
    m = r["manifest"]
    layout = "" if m["layout"] in (None, "reference") else " (%s layout)" % m["layout"]
    return "%s%s" % (m["condition"], layout)


LEFT = ("model", "run", "condition", "compared with")


def table(header, rows):
    out = ["| " + " | ".join(header) + " |", "|" + "|".join(":---" if h in LEFT else "---:" for h in header) + "|"]
    out += ["| " + " | ".join(str(c) for c in row) + " |" for row in rows]
    return out


def render(root):
    models, total = collect(root)
    n_other = len([p for p in glob.glob(os.path.join(root, "runs", "*", "MANIFEST.json"))]) - total
    o = []
    w = o.append
    w("# Translation bench: summary of the preserved runs")
    w("")
    w("<!-- Generated by tools/translation-bench/summary.py from the runs in this directory. Do not edit by hand: "
      "`python3 -I summary.py` rewrites it, `python3 -I summary.py --check` fails when it is stale. -->")
    w("")
    first = next(iter(models.values()))[0] if models else None
    shape = ("%d planted probes in %d sequences" % (first["sum"]["probes"]["n"], first["sum"]["sequences"])) if first else "no runs"
    w("%d model runs on %d model%s, one row per run. Every run is scored by `score.py` against the corpus snapshot it was "
      "preserved with (`runs/_corpus/<hash>`), over %s. Conditions: `A` today's "
      "request; `B2` + the previous 2 source lines; `W` + the window title, app and category; `M` + the user memory "
      "(window, document, people with speech levels, terms). A `(tg layout)` suffix is a bench prompt variant (README, "
      "Conditions); a `(t2 layout)` suffix is the product's own request (`RequestLayout`, README, The seam for T2): it sends the "
      "window card on every context request and no speaker channel, so its `B2` and `M` differ from the unsuffixed runs in more "
      "than the prompt text. Memory-only probes (`memory`) are the ones only the user memory can decide; `lines` need an earlier "
      "line; `none` are controls any engine should get right." % (total, len(models), "" if len(models) == 1 else "s", shape))
    w("")
    w("Reading the columns. **delta** is points of probe accuracy against condition A of the same model; **p** is the exact "
      "two-sided sign test on the probes where the two runs disagree (a default earns its place only against A with p < "
      "0.05 on at least 250 probes). A run on another engine config of the same model (the `-fold` runs send the system "
      "prompt inside the user message) is compared with the A of that config. **Failed attempts** are replies that were not the JSON asked for or had the wrong number of lines, or timed out; the number in brackets counts those whose reply carried the context (it repeats a context line, or has more lines than items but no more than the context has lines). **Fallback lines** came from the stateless request after a failed attempt; **empty** "
      "lines no attempt translated (counted wrong). **Context leaks** are output lines that repeat a context line (the "
      "design's no-regression rule); **batch leaks** repeat another item of the same batch (condition A has these too: the "
      "model's own floor); **echoed** lines are their own source text returned untranslated. Latency is per request with "
      "retries included at `--jobs 1`; the machine was shared with other work, so latencies are comparable only inside one "
      "model's rows and carry the load shown. A latency verdict needs the A/A self-check of `latency.py` (the same condition A "
      "repeated; the preserved `A` and `A-r2` of gemma3:4b differ by 328 ms in the median).")
    w("")

    # ---- overview
    w("## Overview: the rows that decide defaults")
    w("")
    head = ["model", "run", "condition", "probes %", "memory %", "delta vs A (pts)", "p", "compared with", "failed attempts (leak)",
            "fallback + empty lines", "context leaks", "echoed", "tokens in / request", "p50 ms"]
    rows = []
    for name, rs in models.items():
        for r in rs:
            base = baseline(rs, r)
            s, f, c = r["sum"], r["fail"], vs_a(base, r)
            d = "-" if c is None else ("n/a" if c == "other corpus" else "%+.1f" % c["all"]["delta_pts"])
            p = "-" if c is None or c == "other corpus" else pval(c["all"]["p"])
            rows.append([name, r["name"], label(r), frac((s["probes"]["ok"], s["probes"]["n"])), frac(s["probes"]["by"]["memory"]),
                         d, p, base["name"] if c not in (None, "other corpus") else "-",
                         "%d (%d)" % (f["attempts_failed"], f["reasons"]["leak"]),
                         "%d + %d" % (s["fallback_lines"], s["failed_lines"]), f["leaked_context_lines"], f["echoed_lines"],
                         num(s["tokens"]["mean_in"], "%.0f"), num(s["latency"]["p50"])])
    o += table(head, rows)
    w("")

    # ---- per model
    for name, rs in models.items():
        digests = sorted({r["manifest"]["model"].get("digest", "")[:12] for r in rs})
        det = rs[0]["manifest"]["model"].get("details") or {}
        w("## %s" % name)
        w("")
        w("Ollama id %s%s; %s." % (", ".join(d or "unrecorded" for d in digests),
                                   "" if len(digests) == 1 else " (the digest changed between runs)",
                                   ", ".join(x for x in (det.get("parameter_size"), det.get("quantization_level")) if x) or
                                   "details unrecorded"))
        w("")
        w("### Accuracy")
        w("")
        rows = []
        for r in rs:
            base = baseline(rs, r)
            s, c = r["sum"], vs_a(base, r)
            p = s["probes"]
            if c is None:
                cells = ["-", "-", "-", "-"]
            elif c == "other corpus":
                cells = ["n/a"] * 4
            else:
                cells = ["%+.1f" % c["all"]["delta_pts"], pval(c["all"]["p"]), "%+.1f" % c["memory"]["delta_pts"], pval(c["memory"]["p"])]
            rows.append([r["name"], label(r), "%d/%d" % (p["ok"], p["n"]), pct(p["ok"], p["n"]), frac(p["by"]["memory"]),
                         frac(p["by"]["lines"]), frac(p["by"]["none"])] + cells + [base["name"] if c not in (None,) and base else "-"])
        o += table(["run", "condition", "probes", "%", "memory %", "lines %", "none %", "delta (pts)", "p", "delta memory (pts)",
                    "p memory", "compared with"], rows)
        w("")
        w("### By probe type, and speech level")
        w("")
        rows = []
        for r in rs:
            s = r["sum"]
            sp = s["speech"]
            rows.append([r["name"]] + [frac(s["probes"]["type"].get(t, (0, 0))) for t in TYPES] +
                        [pct(sp["match"], sp["scored"]), sp["mixed"], "%d of %d" % (sp["inconsistent_speakers"], sp["speakers"])])
        o += table(["run"] + ["%s %%" % t for t in TYPES] + ["speech level match %", "mixed lines", "inconsistent speakers"], rows)
        w("")
        w("### Failures, fallbacks, leaks")
        w("")
        rows = []
        for r in rs:
            s, f = r["sum"], r["fail"]
            re_ = f["reasons"]
            rows.append([r["name"], s["requests"], f["attempts_failed"],
                         " / ".join(str(re_[k]) for k in S.REASONS), f["raw_replies"], s["fallback_lines"], s["failed_lines"],
                         f["leaked_context_lines"], f["leaked_batch_lines"], f["echoed_lines"]])
        o += table(["run", "requests", "failed attempts", "parse / count / leak / timeout / http / other",
                    "raw replies kept", "fallback lines", "empty lines", "context leaks", "batch leaks", "echoed"], rows)
        w("")
        w("### Cost and latency")
        w("")
        rows = []
        for r in rs:
            s, m = r["sum"], r["manifest"]
            t = s["tokens"]
            tag = machine_tag(m.get("note"))
            load = "%s to %s" % (tag[0], tag[1]) if tag else "in the note"
            swap = "+%s / +%s" % (tag[2], tag[3]) if tag else "-"
            rows.append([r["name"], num(t["mean_in"], "%.1f"), num(t["mean_out"], "%.1f"), num(t["stable"], "%.1f"),
                         num(t["history"], "%.1f"), num(t["memory"], "%.1f"), num(s["latency"]["p50"]), num(s["latency"]["p95"]),
                         "%.0f" % (m["seconds"] or 0), load, swap])
        o += table(["run", "tokens in / request", "tokens out / request", "system prompt", "context lines", "user memory",
                    "p50 ms", "p95 ms", "wall s", "load average (1 min) start to end", "pageouts / swapouts during"], rows)
        w("")
    w("## Not in the tables")
    w("")
    w("%d oracle or smoke runs (scorer self-checks and size accounting; the oracle replays each line's reference "
      "translation and scores 100 %%) are preserved next to these and checked by `runs.py verify`." % n_other)
    w("")
    return "\n".join(o)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=HERE, help="the bench directory (runs/ is read from it)")
    ap.add_argument("--check", action="store_true", help="exit 1 when runs/SUMMARY.md is not what the runs produce")
    ap.add_argument("--stdout", action="store_true", help="print instead of writing")
    ap.add_argument("--out", help="write here instead of runs/SUMMARY.md")
    args = ap.parse_args(argv)
    text = render(args.root)
    path = args.out or os.path.join(args.root, "runs", "SUMMARY.md")
    if args.stdout:
        sys.stdout.write(text)
        return 0
    if args.check:
        have = open(path, encoding="utf-8").read() if os.path.exists(path) else None
        if have != text:
            print("runs/SUMMARY.md is %s; run `python3 -I summary.py`" % ("missing" if have is None else "stale or hand-edited"),
                  file=sys.stderr)
            return 1
        print("runs/SUMMARY.md is current")
        return 0
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    print("wrote %s (%d bytes)" % (os.path.relpath(path, args.root), len(text.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
