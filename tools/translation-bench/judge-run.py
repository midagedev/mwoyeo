#!/usr/bin/env python3
"""Runs the blind judge of `judge.py` through the agy CLI. Run it isolated: `python3 -I judge-run.py run|known-answer ...`.

  run           `--pair <dir from judge.py prompts> --out <dir>`: the prompt files of the pair (both orders of every item,
                calibration items included) are shuffled with a fixed seed, cut into calls of `--batch` cases, and each call goes to
                `agy -p ... --model gemini-3.8-flash-high` once. A case is one prompt file, so the two orders of one item mostly land in
                different calls. The call text carries `judge.py`'s instructions, the case bodies in a fresh order, no condition or model
                name; the answer is one JSON list `[{"case": n, "better": "1"|"2"|"tie", "why": ...}]`.
                Writes, per try, `<out>/calls/call-NNNN.tryK.prompt.txt` and `call-NNNN.tryK.json` (the CLI's own result event: status,
                response, usage; a retry asks only the cases still without a verdict) -- raw answers are experiment data and are never
                overwritten -- and `<out>/verdicts.jsonl`, one
                `{"id": "item-0007.1", "better": "1"|"2"|"tie", "why": ..., "call": n}` per case, which `judge.py tally` reads.
                Exit status 0 of the CLI is not success: the result event's `status` is, and so is an answer that parses and covers
                every case of the call. A call that fails is tried again up to `--tries` times; cases still missing are reported.
                A rerun on the same `--out` asks only the calls whose cases have no verdict yet.
  known-answer  `--out <dir>`: the instrument check with an answer. Pairs of the same line are built from the corpus, the reference
                translation against (a) the line's own source text, untranslated, and (b) the reference with a probe's known wrong
                rendering (`bad_sub`); the reference must win in both orders. Writes the pair directory (prompts, key.json) for `run`
                and `known-answer-tally` reads the verdicts back.
  known-answer-tally  `--pair <dir> --verdicts <file>`: reference wins / loses / ties / orders disagree, per kind, with the pass rule
                (reference wins in both orders on at least 90 % of the items and loses on at most 5 %, and every identical-text
                calibration item is a tie)."""
import argparse
import concurrent.futures
import importlib.util
import json
import os
import random
import re
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))


def _load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


S, J = _load("score"), _load("judge")

MODEL = "gemini-3.8-flash-high"
BODY_START, BODY_END = "Source language:", "Answer with JSON only"
BATCH_HEAD = """%s

You get %d independent cases below. They are unrelated: judge each one on its own, using only that case's text. Do not use tools.

Answer with JSON only, one list with one object per case, in any order:
[{"case": 1, "better": "1" or "2" or "tie", "why": "<at most 12 words>"}, ...]
"""
PASS_WIN, PASS_LOSS = 0.90, 0.05


def read_text(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def case_body(prompt_text):
    """The part of one `judge.py` prompt that is the case: languages, facts, earlier lines, the line and both translations."""
    a, b = prompt_text.index(BODY_START), prompt_text.index(BODY_END)
    return prompt_text[a:b].rstrip() + "\n"


def batch_prompt(bodies):
    out = [BATCH_HEAD % (J.INSTRUCTIONS, len(bodies))]
    for n, body in enumerate(bodies, 1):
        out.append("### Case %d\n%s" % (n, body))
    return "\n".join(out)


def parse_answer(response, n_cases):
    """({case number: (better, why)}, problem or None) from the CLI's response text: the first JSON list in it."""
    text = response or ""
    a, b = text.find("["), text.rfind("]")
    if a < 0 or b < a:
        return {}, "no JSON list in the answer"
    try:
        rows = json.loads(text[a:b + 1])
    except ValueError as e:
        return {}, "the answer is not JSON: %s" % e
    got = {}
    for r in rows if isinstance(rows, list) else []:
        if not isinstance(r, dict):
            continue
        try:
            case = int(r.get("case"))
        except (TypeError, ValueError):
            continue
        better = str(r.get("better", "")).strip().lower()
        if 1 <= case <= n_cases and better in ("1", "2", "tie") and case not in got:
            got[case] = (better, str(r.get("why", ""))[:200])
    missing = n_cases - len(got)
    return got, ("%d of %d cases missing or malformed" % (missing, n_cases)) if missing else None


def call_agy(agy, model, prompt, timeout_s, cwd):
    """The CLI's result event as a dict plus a problem string or None. A timeout or a non-zero exit is a problem; so is a status
    other than SUCCESS (exit 0 does not mean success)."""
    try:
        p = subprocess.run([agy, "-p", prompt, "--model", model, "--dangerously-skip-permissions", "--print-timeout",
                            "%ds" % timeout_s, "--output-format", "json"],
                           stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=timeout_s + 60, cwd=cwd)
    except subprocess.TimeoutExpired:
        return {"status": "TIMEOUT"}, "timeout"
    try:
        ev = json.loads(p.stdout)
    except ValueError:
        return {"status": "NOT_JSON", "stdout": p.stdout[:2000], "stderr": p.stderr[:2000], "rc": p.returncode}, "the CLI printed no JSON event (rc %d)" % p.returncode
    if not isinstance(ev, dict):
        return {"status": "NOT_JSON", "stdout": p.stdout[:2000]}, "the CLI event is not an object"
    if p.returncode != 0:
        return ev, "rc %d" % p.returncode
    if ev.get("status") != "SUCCESS":
        return ev, "status %s" % ev.get("status")
    if not (ev.get("response") or "").strip():
        # SUCCESS with an empty response and zero tokens: the CLI's own --print-timeout ran out while the model was still thinking
        return ev, "empty response (the CLI's print-timeout ran out?)"
    return ev, None


def cmd_run(args):
    key = S.load_json(os.path.join(args.pair, "key.json"))
    pdir = os.path.join(args.pair, "prompts")
    ids = sorted(f[:-4] for f in os.listdir(pdir) if f.endswith(".txt"))
    items = sorted({i.rpartition(".")[0] for i in ids})
    rng = random.Random(args.seed)
    if args.max_items and args.max_items < len(items):
        real = [i for i in items if key["items"][i]["kind"] == "real"]
        cal = [i for i in items if key["items"][i]["kind"] != "real"]
        order = rng.sample(real, len(real))                         # one seeded order: a larger --max-items later asks a superset
        keep = set(order[:args.max_items]) | set(cal)
        ids = [i for i in ids if i.rpartition(".")[0] in keep]
    rng.shuffle(ids)
    calls = [ids[k:k + args.batch] for k in range(0, len(ids), args.batch)]
    callsdir = os.path.join(args.out, "calls")
    os.makedirs(callsdir, exist_ok=True)
    vpath = os.path.join(args.out, "verdicts.jsonl")
    done = set()
    if os.path.exists(vpath):
        with open(vpath, encoding="utf-8") as f:
            done = {json.loads(l)["id"] for l in f if l.strip()}
    with open(os.path.join(args.out, "run.json"), "a", encoding="utf-8") as f:
        f.write(json.dumps({"started": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "pair": os.path.abspath(args.pair), "model": args.model,
                            "batch": args.batch, "jobs": args.jobs, "seed": args.seed, "tries": args.tries,
                            "max_items": args.max_items, "prompts": len(ids), "calls": len(calls)}) + "\n")
    lock = threading.Lock()
    stats = {"calls_ok": 0, "calls_failed": 0, "cases_missing": 0, "tries_failed": 0, "skipped": 0}
    cwd = os.path.join(args.out, "cwd")
    os.makedirs(cwd, exist_ok=True)

    def one(n, batch):
        pending = [i for i in batch if i not in done]
        if not pending:
            with lock:
                stats["skipped"] += 1
            return
        bodies = {i: case_body(read_text(os.path.join(pdir, i + ".txt"))) for i in pending}
        problem = "not tried"
        for k in range(1, args.tries + 1):
            prompt = batch_prompt([bodies[i] for i in pending])
            base = os.path.join(callsdir, "call-%04d.try%d" % (n, k))
            while os.path.exists(base + ".json"):                  # a rerun on the same --out never overwrites an earlier try
                base += "r"
            with open(base + ".prompt.txt", "w", encoding="utf-8") as f:
                f.write(prompt)
            ev, problem = call_agy(args.agy, args.model, prompt, args.timeout, cwd)
            got = {}
            if problem is None:
                got, problem = parse_answer(ev.get("response"), len(pending))
            with open(base + ".json", "w", encoding="utf-8") as f:
                json.dump({"call": n, "try": k, "ids": pending, "problem": problem, "event": ev}, f, ensure_ascii=False, indent=1)
            with lock:
                with open(vpath, "a", encoding="utf-8") as f:
                    for c, (better, why) in sorted(got.items()):
                        f.write(json.dumps({"id": pending[c - 1], "better": better, "why": why, "call": n}, ensure_ascii=False) + "\n")
                        done.add(pending[c - 1])
            pending = [i for i in pending if i not in done]
            if not pending:
                with lock:
                    stats["calls_ok"] += 1
                return
            with lock:
                stats["tries_failed"] += 1
            time.sleep(args.backoff * k)                           # an empty answer under load comes back at once; do not burn the tries
        with lock:
            stats["calls_failed"] += 1
            stats["cases_missing"] += len(pending)
        print("call %d: %d cases without a verdict after %d tries (%s)" % (n, len(pending), args.tries, problem), file=sys.stderr)

    t0 = time.time()
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = [ex.submit(one, n, b) for n, b in enumerate(calls, 1)]
        for k, fu in enumerate(concurrent.futures.as_completed(futs), 1):
            fu.result()
            if k % 10 == 0 or k == len(futs):
                print("  %d of %d calls done, %.0f s" % (k, len(futs), time.time() - t0), file=sys.stderr, flush=True)
    with open(vpath, encoding="utf-8") as f:
        n_verdicts = sum(1 for l in f if l.strip())
    print("judge-run: %d prompts in %d calls (batch %d, jobs %d): ok %d, skipped %d, failed %d, failed tries %d, prompts without a verdict %d; "
          "%d verdicts in %s; %.0f s"
          % (len(ids), len(calls), args.batch, args.jobs, stats["calls_ok"], stats["skipped"], stats["calls_failed"], stats["tries_failed"],
             stats["cases_missing"], n_verdicts, vpath, time.time() - t0))
    return 0 if stats["calls_failed"] == 0 else 4


def known_answer_items(seqs, mems, n_echo, n_bad, seed):
    """(kind, seq id, line, reference text, wrong text) for lines with a known better translation. `echo`: the source text against
    the reference (the reference must win). `bad`: a probe's `bad_sub` applied to the reference (a wrong name, term, level)."""
    rng = random.Random(seed)
    echo, bad = [], []
    for sid, seq in seqs.items():
        lines = {l["id"]: l for l in seq["lines"]}
        probe_lines = set()
        for p in seq["probes"]:
            line = lines[p["line"]]
            probe_lines.add(line["id"])
            if p.get("bad_sub"):
                a, b = p["bad_sub"]
                wrong = line["ref"].replace(a, b, 1)
                if wrong != line["ref"]:
                    bad.append(("bad", sid, line, S.nfc(line["ref"]), S.nfc(wrong)))
        for l in seq["lines"]:
            if l["text"].strip() != l["ref"].strip():
                echo.append(("echo", sid, l, S.nfc(l["ref"]), S.nfc(l["text"])))
    rng.shuffle(echo)
    rng.shuffle(bad)
    return echo[:n_echo] + bad[:n_bad]


def cmd_known_answer(args):
    seqs, mems = S.load_corpus(args.root)
    items = known_answer_items(seqs, mems, args.echo, args.bad, args.seed)
    rng = random.Random(args.seed + 1)
    rng.shuffle(items)
    pdir = os.path.join(args.out, "prompts")
    os.makedirs(pdir, exist_ok=True)
    key = {"a": "reference", "b": "wrong", "identical": 0, "items": {}}
    for n, (kind, sid, line, ref, wrong) in enumerate(items, 1):
        item = "item-%04d" % n
        key["items"][item] = {"seq": sid, "line": line["id"], "kind": "real", "known": kind, "a_text": ref, "b_text": wrong}
        for order, (first, second) in (("1", (ref, wrong)), ("2", (wrong, ref))):
            with open(os.path.join(pdir, "%s.%s.txt" % (item, order)), "w", encoding="utf-8") as f:
                f.write(J.build_prompt(seqs[sid], mems[sid], line, first, second))
    # identical-text items, as judge.py makes them: the judge must call them a tie
    cal = [(sid, l) for sid, seq in seqs.items() for l in seq["lines"]]
    rng.shuffle(cal)
    for n, (sid, line) in enumerate(cal[:args.calibration], len(items) + 1):
        item = "item-%04d" % n
        text = S.nfc(line["ref"])
        key["items"][item] = {"seq": sid, "line": line["id"], "kind": "calibration", "a_text": text, "b_text": text}
        for order in ("1", "2"):
            with open(os.path.join(pdir, "%s.%s.txt" % (item, order)), "w", encoding="utf-8") as f:
                f.write(J.build_prompt(seqs[sid], mems[sid], line, text, text))
    with open(os.path.join(args.out, "key.json"), "w", encoding="utf-8") as f:
        json.dump(key, f, ensure_ascii=False, indent=1)
    print("known-answer pairs: %d (echo %d, bad_sub %d) + %d identical-text calibration items, %d prompt files in %s"
          % (len(items), sum(1 for i in items if i[0] == "echo"), sum(1 for i in items if i[0] == "bad"), args.calibration,
             2 * (len(items) + args.calibration), pdir))
    return 0


def known_answer_report(key, verdicts):
    """Per kind: reference wins / loses / ties / disagree in both orders, and the calibration result."""
    votes = {}
    for v in verdicts:
        item, _, order = v["id"].rpartition(".")
        got = J.parse_verdict(v)
        if item in key["items"] and order in ("1", "2") and got:
            votes.setdefault(item, {})[order] = J.winner(order, got)
    out = {}
    cal = {"pass": 0, "fail": 0, "missing": 0}
    for item, info in key["items"].items():
        v = votes.get(item, {})
        if info["kind"] == "calibration":
            if len(v) < 2:
                cal["missing"] += 1
            elif v["1"] == v["2"] == "tie":
                cal["pass"] += 1
            else:
                cal["fail"] += 1
            continue
        r = out.setdefault(info["known"], {"items": 0, "ref_wins": 0, "ref_loses": 0, "tie": 0, "disagree": 0, "missing": 0})
        r["items"] += 1
        if len(v) < 2:
            r["missing"] += 1
        elif v["1"] != v["2"]:
            r["disagree"] += 1
        elif v["1"] == "a":
            r["ref_wins"] += 1
        elif v["1"] == "b":
            r["ref_loses"] += 1
        else:
            r["tie"] += 1
    tot = {k: sum(r[k] for r in out.values()) for k in ("items", "ref_wins", "ref_loses", "tie", "disagree", "missing")}
    ok = (tot["items"] > 0 and tot["ref_wins"] >= PASS_WIN * tot["items"] and tot["ref_loses"] <= PASS_LOSS * tot["items"]
          and cal["fail"] == 0 and cal["missing"] == 0 and cal["pass"] > 0)
    return out, tot, cal, ok


def cmd_known_answer_tally(args):
    key = S.load_json(os.path.join(args.pair, "key.json"))
    with open(args.verdicts, encoding="utf-8") as f:
        verdicts = [json.loads(l) for l in f if l.strip()]
    out, tot, cal, ok = known_answer_report(key, verdicts)
    for kind, r in sorted(out.items()):
        print("  %-5s items %3d: reference wins %3d, loses %2d, tie %2d, orders disagree %2d, missing %d"
              % (kind, r["items"], r["ref_wins"], r["ref_loses"], r["tie"], r["disagree"], r["missing"]))
    print("  all   items %3d: reference wins %3d (%.1f%%), loses %d (%.1f%%), tie %d, orders disagree %d, missing %d"
          % (tot["items"], tot["ref_wins"], 100 * tot["ref_wins"] / max(1, tot["items"]), tot["ref_loses"],
             100 * tot["ref_loses"] / max(1, tot["items"]), tot["tie"], tot["disagree"], tot["missing"]))
    print("  identical-text calibration: passed %d, failed %d, missing %d" % (cal["pass"], cal["fail"], cal["missing"]))
    print("known-answer calibration %s (rule: reference wins >= %d %% and loses <= %d %% of the items, identical text is a tie)"
          % ("PASSED" if ok else "FAILED", round(100 * PASS_WIN), round(100 * PASS_LOSS)))
    return 0 if ok else 1


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--pair", required=True)
    r.add_argument("--out", required=True)
    r.add_argument("--batch", type=int, default=15)
    r.add_argument("--jobs", type=int, default=3)
    r.add_argument("--tries", type=int, default=3)
    r.add_argument("--backoff", type=float, default=20.0, help="seconds to wait after a failed try, times the try number")
    r.add_argument("--timeout", type=int, default=240, help="seconds the CLI may take for one call (its --print-timeout)")
    r.add_argument("--seed", type=int, default=11)
    r.add_argument("--max-items", type=int, default=0, help="at most this many real items (0: all); calibration items are always kept")
    r.add_argument("--model", default=MODEL)
    r.add_argument("--agy", default="agy")
    r.set_defaults(fn=cmd_run)
    k = sub.add_parser("known-answer")
    k.add_argument("--out", required=True)
    k.add_argument("--root", default=HERE)
    k.add_argument("--echo", type=int, default=20)
    k.add_argument("--bad", type=int, default=60)
    k.add_argument("--calibration", type=int, default=4)
    k.add_argument("--seed", type=int, default=5)
    k.set_defaults(fn=cmd_known_answer)
    t = sub.add_parser("known-answer-tally")
    t.add_argument("--pair", required=True)
    t.add_argument("--verdicts", required=True)
    t.set_defaults(fn=cmd_known_answer_tally)
    args = ap.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main())
