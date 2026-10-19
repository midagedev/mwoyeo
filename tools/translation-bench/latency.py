#!/usr/bin/env python3
"""Latency verdict of a condition against condition A with an A/A self-check: `python3 -I latency.py --aa <A run>... -- <run>...`

A latency number from one run of one condition is not a verdict on this shared Mac: the same condition measured twice differs
(A and A-r2 of gemma3:4b: 328 ms in the median). So the reference is not one A run but the A/A runs: the same condition A
repeated, taken in the same hours as the conditions under test and on the same requests. For every run the script reports, on the
sequences all the A/A runs have in common:

  - the per-request latency (`latency_ms` of a request: every attempt, so a fallback counts), its mean, p50 and p95, and the tokens
    in and out per request (as the engine reports them);
  - the delta of each A/A run against the mean of the other A/A runs, request by request (the noise), and the same delta of every
    run under test against the mean of all A/A runs (the effect). The median of the paired deltas is the figure to read: one request
    that runs into the engine's timeout (300 s, a model that loops) moves a mean by seconds. Such stalls (>= 30 s) are counted, and
    the mean delta is taken without them;
  - the verdict: an effect is *resolved* when its median delta is more than twice the A/A spread of the run p50s; the p95 rule of the
    design (section 9: within +20 % of A) is read from the p95 of the run against the mean p95 of the A/A runs.

Requests are matched by (sequence id, request number n): two conditions replay the same batches, so the pairing removes the
variance of the text. A request that exists in one run and not in another is left out of that pair. It never calls an engine.
"""
import argparse
import importlib.util
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("score", os.path.join(HERE, "score.py"))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

RESOLVED_FACTOR = 2.0
STALL_MS = 30000


def requests(run, seqs=None):
    """{(sequence id, request n): record} of a run, limited to `seqs` when given."""
    out = {}
    for sid, o in run["outs"].items():
        if seqs is not None and sid not in seqs:
            continue
        for r in o.get("requests", []):
            out[(sid, r["n"])] = r
    return out


def mean(v):
    return sum(v) / len(v) if v else None


def stats(reqs):
    lat = [r["latency_ms"] for r in reqs.values()]
    ins = [r["usage"]["in"] for r in reqs.values() if r.get("usage") and r["usage"].get("in")]
    outs = [r["usage"]["out"] for r in reqs.values() if r.get("usage") and r["usage"].get("out")]
    failed = sum(1 for r in reqs.values() for a in r.get("attempts", []) if not a.get("ok", True))
    return {"n": len(lat), "mean": mean(lat), "p50": S.percentile(lat, 0.5), "p95": S.percentile(lat, 0.95),
            "in": mean(ins), "out": mean(outs), "failed": failed, "stalls": sum(1 for x in lat if x >= STALL_MS)}


def paired(reqs, reference, stalls=True):
    """Per-request latency deltas of `reqs` against `reference` ({key: ms}) on the keys both have; `stalls` False leaves out the
    requests where either side took STALL_MS or more."""
    return [r["latency_ms"] - reference[k] for k, r in reqs.items()
            if k in reference and (stalls or (r["latency_ms"] < STALL_MS and reference[k] < STALL_MS))]


def reference_of(runs_reqs):
    """Mean latency per request key over several runs, on the keys all of them have."""
    keys = set.intersection(*[set(r) for r in runs_reqs])
    return {k: mean([r[k]["latency_ms"] for r in runs_reqs]) for k in keys}


def analyse(aa_runs, tested):
    """The numbers of the verdict. `aa_runs`: loaded A runs (>= 2); `tested`: loaded runs under test."""
    seqs = set.intersection(*[set(r["outs"]) for r in aa_runs])
    aa = [requests(r, seqs) for r in aa_runs]
    keys = set.intersection(*[set(r) for r in aa])
    aa = [{k: r[k] for k in keys} for r in aa]
    out = {"sequences": sorted(seqs), "requests": len(keys), "aa": [], "tested": []}
    for i, r in enumerate(aa):
        others = [x for j, x in enumerate(aa) if j != i]
        ref = reference_of(others)
        d = paired(r, ref)
        out["aa"].append({"name": os.path.basename(aa_runs[i]["path"].rstrip("/")), **stats(r), "vs_others": mean(paired(r, ref, False)),
                          "median_vs_others": S.percentile(d, 0.5)})
    means = [x["mean"] for x in out["aa"]]
    p50s = [x["p50"] for x in out["aa"]]
    p95s = [x["p95"] for x in out["aa"]]
    out["spread_mean"] = max(means) - min(means)
    out["spread_p50"] = max(p50s) - min(p50s)
    out["spread_p95"] = max(p95s) - min(p95s)
    out["aa_mean"], out["aa_p50"], out["aa_p95"] = mean(means), mean(p50s), mean(p95s)
    ref_all = reference_of(aa)
    for run in tested:
        reqs = {k: v for k, v in requests(run, seqs).items() if k in ref_all}
        st = stats(reqs)
        d = paired(reqs, ref_all)
        median = S.percentile(d, 0.5)
        st.update({"name": os.path.basename(run["path"].rstrip("/")), "delta": mean(paired(reqs, ref_all, False)), "delta_p50": median,
                   "resolved": abs(median) > RESOLVED_FACTOR * out["spread_p50"], "p95_ratio": st["p95"] / out["aa_p95"] - 1})
        out["tested"].append(st)
    return out


def f0(v):
    return "-" if v is None else "%.0f" % v


def render(a):
    L = []
    L.append("sequences (%d): %s; %d requests each" % (len(a["sequences"]), ", ".join(a["sequences"]), a["requests"]))
    L.append("")
    L.append("| run | role | requests | mean ms | p50 ms | p95 ms | tokens in | tokens out | failed attempts | stalls (>= 30 s) | median delta (ms) | mean delta without stalls (ms) | p95 vs A/A mean | verdict |")
    L.append("|:---|:---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|:---|")
    for x in a["aa"]:
        L.append("| %s | A/A, against the other A/A runs | %d | %s | %s | %s | %s | %s | %d | %d | %+.0f | %+.0f | - | - |" % (
            x["name"], x["n"], f0(x["mean"]), f0(x["p50"]), f0(x["p95"]), f0(x["in"]), f0(x["out"]), x["failed"], x["stalls"],
            x["median_vs_others"], x["vs_others"]))
    for x in a["tested"]:
        verdict = "%s (%.1fx the A/A spread of the p50s)" % ("resolved" if x["resolved"] else "inside the A/A noise",
                                                             abs(x["delta_p50"]) / a["spread_p50"] if a["spread_p50"] else float("inf"))
        L.append("| %s | tested, against the A/A mean | %d | %s | %s | %s | %s | %s | %d | %d | %+.0f | %+.0f | %+.0f %% | %s |" % (
            x["name"], x["n"], f0(x["mean"]), f0(x["p50"]), f0(x["p95"]), f0(x["in"]), f0(x["out"]), x["failed"], x["stalls"],
            x["delta_p50"], x["delta"], 100 * x["p95_ratio"], verdict))
    L.append("")
    L.append("A/A: spread of the run p50s %.0f ms, of the run means %.0f ms, of the p95s %.0f ms (A/A mean of p50 %.0f, of means %.0f, of p95 %.0f ms). "
             "An effect is resolved when its median delta is more than %.0f times the spread of the p50s." % (
                 a["spread_p50"], a["spread_mean"], a["spread_p95"], a["aa_p50"], a["aa_mean"], a["aa_p95"], RESOLVED_FACTOR))
    return "\n".join(L) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--aa", nargs="+", required=True, help="the A/A run directories (condition A repeated; at least two)")
    ap.add_argument("tested", nargs="*", help="run directories to judge against the A/A runs")
    args = ap.parse_args(argv)
    if len(args.aa) < 2:
        print("error: the A/A self-check needs at least two A runs", file=sys.stderr)
        return 2
    aa = [S.load_run(p) for p in args.aa]
    bad = [r["path"] for r in aa if r["meta"].get("condition") != "A"]
    if bad:
        print("error: not condition A: " + ", ".join(bad), file=sys.stderr)
        return 2
    sys.stdout.write(render(analyse(aa, [S.load_run(p) for p in args.tested])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
