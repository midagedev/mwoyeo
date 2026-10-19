#!/usr/bin/env python3
"""Failure and leak accounting (G2): `python3 -I tests/test_failures.py`.

FAIL-first: a clean run counts 0 leaks; the same run with leaks planted (a context line's words appended to an output, a
neighbour's translation copied into another line, an untranslated echo) counts exactly the planted ones; and a real
preserved run (M on gemma3:4b) with three context leaks planted counts three more than its own baseline. With `--neuter`
the leak detection is switched off first (`score._reproduces` always false, no context rebuilt for a fallback request): the same tests must then FAIL, which is the
unfixed-code failure line `run-all.sh` checks for."""
import copy
import importlib.util
import json
import os
import sys
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)
GOLDEN = os.path.join(HERE, "golden")

NEUTER = "--neuter" in sys.argv
if NEUTER:
    sys.argv.remove("--neuter")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(BENCH, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


S = load("score")
if NEUTER:
    S._reproduces = lambda *a, **k: False
    S.attempt_context_ids = lambda *a, **k: []


def mini_run(translations=None, attempts_by_request=None):
    """The golden `mini` sequence (10 Japanese chat lines to Korean) as a run of 4 requests: [1,2,3], [4,5,6] with
    lines 2,3 as context, [7,8,9] with 5,6 as context, [10] with 8,9."""
    seqs, _ = S.load_corpus(GOLDEN)
    seq = seqs["mini"]
    trs = {str(l["id"]): l["ref"] for l in seq["lines"]}
    trs.update(translations or {})
    plan = [([1, 2, 3], []), ([4, 5, 6], [2, 3]), ([7, 8, 9], [5, 6]), ([10], [8, 9])]
    reqs = []
    for n, (items, ctx) in enumerate(plan, 1):
        attempts = (attempts_by_request or {}).get(n) or [{"ok": True, "latency_ms": 100, "retries": 0, "stateless": False, "error": None}]
        reqs.append({"n": n, "screen": 1, "items": items, "context": ctx, "attempts": attempts, "latency_ms": 100, "reply": "{}",
                     "usage": None, "layout": {}, "fallback": [], "failed": [], "terms_added": []})
    run = {"path": "", "meta": {"condition": "M"}, "outs": {"mini": {"id": "mini", "condition": "M", "translations": trs, "requests": reqs}}}
    return run, seqs


class MiniRun(unittest.TestCase):
    def test_clean_run_has_no_leaks_and_no_echoes(self):
        run, seqs = mini_run()
        f = S.failure_report(run, seqs)
        self.assertEqual((f["leaked_context_lines"], f["leaked_batch_lines"], f["echoed_lines"], f["lines"]), (0, 0, 0, 10))

    def test_planted_leaks_are_counted(self):
        run0, seqs = mini_run()
        seq = seqs["mini"]
        src = {l["id"]: l["text"] for l in seq["lines"]}
        ref = {l["id"]: l["ref"] for l in seq["lines"]}
        run, _ = mini_run({
            "5": ref[5] + " " + src[3],          # the output carries context line 3 (request 2 shows 2 and 3)
            "7": ref[7],
            "8": ref[7],                          # a neighbour in the batch copied in place of line 8
            "10": src[10],                        # untranslated
        })
        f = S.failure_report(run, seqs)
        print("FAIL-first (clean -> planted): context leaks %d -> %d, batch leaks %d -> %d, echoed %d -> %d"
              % (0, f["leaked_context_lines"], 0, f["leaked_batch_lines"], 0, f["echoed_lines"]))
        self.assertEqual(f["leaks"], [["mini", 5, [3], "context"], ["mini", 8, [7], "batch"]])
        self.assertEqual((f["leaked_context_lines"], f["leaked_batch_lines"], f["leaked_requests"]), (1, 1, 2))
        self.assertEqual(f["echoed_lines"], 1)
        self.assertEqual(S.failure_report(run0, seqs)["leaked_context_lines"], 0)

    def test_shared_short_phrases_and_repeated_source_lines_are_not_leaks(self):
        # a 2-syllable fragment of another line's translation (아직) is under the threshold
        run, seqs = mini_run({"8": "소우는 튼튼하니까 괜찮아. 아직."})
        self.assertEqual(S.failure_report(run, seqs)["leaks"], [])
        # the same words said twice in the text (line 10 repeats line 9) translate the same way: nothing to tell apart
        seqs = copy.deepcopy(seqs)
        lines = {l["id"]: l for l in seqs["mini"]["lines"]}
        lines[10]["text"], lines[10]["ref"] = lines[9]["text"], lines[9]["ref"]
        run, _ = mini_run({"10": lines[9]["ref"]})
        self.assertEqual(S.failure_report(run, seqs)["leaks"], [])

    def test_failed_attempts_by_reason(self):
        run0, seqs = mini_run()
        src = {l["id"]: l["text"] for l in seqs["mini"]["lines"]}

        def bad(error, reply=None, stateless=False):
            a = {"ok": False, "latency_ms": 100, "retries": 0, "stateless": stateless, "error": error}
            if reply is not None:
                a["reply"] = reply
            return a

        ok = {"ok": True, "latency_ms": 100, "retries": 0, "stateless": True, "error": None}
        run, seqs = mini_run(attempts_by_request={
            1: [bad("malformed: content has no JSON", '{"translations": ["a"'), ok],
            2: [bad("count mismatch: expected 3, got 5", '{"translations": ["' + src[2] + '", "' + src[3] + '", "x", "y", "z"]}'), ok],
            3: [bad("count mismatch: expected 3, got 6", '{"translations": ["a", "b", "c", "d", "e", "f"]}'),
                bad("count mismatch: expected 3, got 1", '{"translations": ["a"]}', stateless=True)],
            4: [bad("network: -1001"), bad("HTTP 500: model runner has unexpectedly stopped", stateless=True)],
        })
        f = S.failure_report(run, seqs)
        print("failed attempts by reason:", f["reasons"], "| count with more lines than items:", f["count_more"],
              "| raw replies:", f["raw_replies"])
        self.assertEqual(f["reasons"], {"parse": 1, "count": 2, "leak": 1, "timeout": 1, "http": 1, "other": 0})
        self.assertEqual(f["attempts_failed"], 6)
        self.assertEqual(f["count_more"], 2)
        self.assertEqual(f["raw_replies"], 4)
        self.assertEqual(f["leak_inferred"], 0)
        # a run without stored replies (made before 2026-10-19) cannot show the leak in the reply, but request 2 returned two
        # lines more than its items with two context lines: inferred from the count. Request 3 returned three more.
        for r in run["outs"]["mini"]["requests"]:
            for a in r["attempts"]:
                a.pop("reply", None)
        g = S.failure_report(run, seqs)
        self.assertEqual((g["reasons"]["leak"], g["leak_inferred"], g["reasons"]["count"], g["reasons"]["parse"]), (1, 1, 2, 1))
        self.assertEqual(S.failure_report(run0, seqs)["attempts_failed"], 0)

    def test_the_context_of_a_request_that_fell_back_is_rebuilt_from_the_condition(self):
        # a request that fell back records no context, but its first attempt had the 2 lines before the batch (B2)
        bad = {"ok": False, "latency_ms": 100, "retries": 0, "stateless": False, "error": "count mismatch: expected 3, got 4"}
        ok = {"ok": True, "latency_ms": 100, "retries": 0, "stateless": True, "error": None}
        run, seqs = mini_run(attempts_by_request={3: [bad, ok]})
        run["outs"]["mini"]["requests"][2]["context"] = []
        run["meta"]["condition"] = "B2"
        f = S.failure_report(run, seqs)
        self.assertEqual((f["reasons"]["leak"], f["leak_inferred"]), (1, 1))
        run["meta"]["condition"] = "A"          # no context in A: more lines than items is a plain count error
        f = S.failure_report(run, seqs)
        self.assertEqual((f["reasons"]["leak"], f["reasons"]["count"]), (0, 1))
        run["meta"]["condition"] = "C16"        # a conversation window cannot be rebuilt
        self.assertEqual(S.failure_report(run, seqs)["reasons"]["count"], 1)

    def test_report_prints(self):
        run, seqs = mini_run({"10": seqs_text()})
        import io
        buf = io.StringIO()
        S.print_failures(S.failure_report(run, seqs), buf)
        self.assertIn("1 are their own source text", buf.getvalue())


def seqs_text():
    seqs, _ = S.load_corpus(GOLDEN)
    return next(l["text"] for l in seqs["mini"]["lines"] if l["id"] == 10)


class RealRun(unittest.TestCase):
    """M on gemma3:4b, a preserved run: three context leaks planted into a copy count three more than its baseline."""

    def test_three_planted_context_leaks_count_three_more(self):
        run_dir = os.path.join(BENCH, "runs", "M-gemma3-4b")
        manifest = S.load_json(os.path.join(run_dir, "MANIFEST.json"))
        root = os.path.join(BENCH, "runs", manifest["corpus"]["snapshot"])
        seqs, _ = S.load_corpus(root)
        run = S.load_run(run_dir)
        base = S.failure_report(run, seqs)
        doctored = copy.deepcopy(run)
        planted = []
        for sid in sorted(doctored["outs"]):
            by_id = {l["id"]: l for l in seqs[sid]["lines"]}
            trs = doctored["outs"][sid]["translations"]
            for r in doctored["outs"][sid]["requests"]:
                if r["failed"] or not r["context"] or len(planted) >= 3 or any(p[0] == sid for p in planted):
                    continue
                item, c = by_id[r["items"][0]], by_id[r["context"][0]]
                if c["id"] in r["items"] or len(S.squash(c["text"])) < 6 or S.squash(c["text"]) in S.squash(item["text"]):
                    continue
                mode = len(planted)
                if mode == 0:       # the context line's words appended
                    trs[str(item["id"])] = trs[str(item["id"])] + " " + c["text"]
                elif mode == 1:     # the context line's source in place of the translation
                    trs[str(item["id"])] = c["text"]
                else:               # the model's translation of the context line in place of this one's
                    if len(S.squash(trs.get(str(c["id"]), ""))) < 8:
                        continue
                    trs[str(item["id"])] = trs[str(c["id"])]
                planted.append((sid, item["id"]))
        self.assertEqual(len(planted), 3, planted)
        after = S.failure_report(doctored, seqs)
        print("FAIL-first (M-gemma3-4b, 3 planted): context leaks %d -> %d, batch leaks %d -> %d"
              % (base["leaked_context_lines"], after["leaked_context_lines"], base["leaked_batch_lines"], after["leaked_batch_lines"]))
        self.assertEqual(after["leaked_context_lines"], base["leaked_context_lines"] + 3)
        hit = {(l[0], l[1]) for l in after["leaks"] if l[3] == "context"}
        self.assertTrue(set(planted) <= hit, (planted, hit))


if __name__ == "__main__":
    unittest.main(verbosity=2)
