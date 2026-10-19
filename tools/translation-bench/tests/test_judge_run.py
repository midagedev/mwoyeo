#!/usr/bin/env python3
"""judge-run.py unit checks: `python3 -I tests/test_judge_run.py`. No judge is called; a fake `agy` (a script that answers from the
case text) stands in. Blocks: a call that exits 0 but whose result event is not SUCCESS counted as a verdict; a call whose answer
misses cases counted as done; a rerun that asks the judge again; a known-answer calibration that passes a judge with position bias
or a judge that prefers the wrong translation."""
import importlib.util
import json
import os
import stat
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)


def load(name, fname=None):
    spec = importlib.util.spec_from_file_location(name, os.path.join(BENCH, (fname or name) + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


S, J, R = load("score"), load("judge"), load("judge_run", "judge-run")

FAKE_AGY = r'''#!/usr/bin/env python3
import json, os, re, sys
argv = sys.argv
prompt = argv[argv.index("-p") + 1]
with open(os.environ["FAKE_AGY_COUNT"], "a") as f:
    f.write("call\n")
mode = os.environ.get("FAKE_AGY_MODE", "ref")
if mode == "error":                                   # exit 0, but the result event says ERROR
    print(json.dumps({"status": "ERROR", "response": "[]"}))
    sys.exit(0)
cases = re.split(r"### Case \d+\n", prompt)[1:]
rows = []
refs = set(json.load(open(os.environ["FAKE_AGY_REFS"]))) if os.environ.get("FAKE_AGY_REFS") else set()
for n, body in enumerate(cases, 1):
    t1 = body.split("Translation 1:\n")[1].split("\n\nTranslation 2:\n")[0].strip()
    t2 = body.split("Translation 2:\n")[1].strip()
    if t1 == t2:
        better = "tie"
    elif mode == "bias":                              # always the first one
        better = "1"
    elif mode == "wrong":                             # the translation that is not the reference
        better = "2" if t1 in refs else "1"
    else:                                             # "ref" and "short": the reference
        better = "1" if t1 in refs else "2"
    rows.append({"case": n, "better": better, "why": "fake"})
if mode == "short" and len(rows) > 1:                 # drops the last case of every call that asks for more than one
    rows = rows[:-1]
print(json.dumps({"status": "SUCCESS", "response": "```json\n" + json.dumps(rows) + "\n```", "usage": {}}))
'''


def make_fake(tmp):
    path = os.path.join(tmp, "fake-agy")
    with open(path, "w") as f:
        f.write(FAKE_AGY)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path


def env(tmp, mode, refs=None):
    count = os.path.join(tmp, "count.txt")
    open(count, "w").close()
    os.environ["FAKE_AGY_COUNT"] = count
    os.environ["FAKE_AGY_MODE"] = mode
    if refs is None:
        os.environ.pop("FAKE_AGY_REFS", None)
    else:
        p = os.path.join(tmp, "refs.json")
        with open(p, "w", encoding="utf-8") as f:
            json.dump(refs, f, ensure_ascii=False)
        os.environ["FAKE_AGY_REFS"] = p
    return count


def n_calls(count):
    with open(count) as f:
        return len(f.read().split())


def known_answer_pair(tmp, n_echo=4, n_bad=8):
    out = os.path.join(tmp, "cal")
    assert R.main(["known-answer", "--out", out, "--echo", str(n_echo), "--bad", str(n_bad), "--calibration", "2"]) == 0
    with open(os.path.join(out, "key.json"), encoding="utf-8") as f:
        key = json.load(f)
    refs = sorted({v["a_text"] for v in key["items"].values()})
    return out, key, refs


def run_pair(tmp, pair, out, agy, batch=5, jobs=2, tries=2):
    return R.main(["run", "--pair", pair, "--out", out, "--agy", agy, "--batch", str(batch), "--jobs", str(jobs), "--tries", str(tries),
                   "--timeout", "30", "--backoff", "0"])


def verdicts(out):
    p = os.path.join(out, "verdicts.jsonl")
    if not os.path.exists(p):
        return []
    with open(p, encoding="utf-8") as f:
        return [json.loads(l) for l in f]


class Parsing(unittest.TestCase):
    def test_case_body_and_batch_prompt(self):
        seqs, mems = S.load_corpus(BENCH)
        sid = sorted(seqs)[0]
        line = seqs[sid]["lines"][5]
        text = J.build_prompt(seqs[sid], mems[sid], line, "FIRST", "SECOND")
        body = R.case_body(text)
        self.assertTrue(body.startswith("Source language:"))
        self.assertNotIn("Answer with JSON only", body)
        self.assertIn("Translation 2:\nSECOND", body)
        p = R.batch_prompt([body, body, body])
        self.assertIn("### Case 3", p)
        self.assertIn(J.INSTRUCTIONS, p)
        self.assertEqual(p.count("Line to translate:"), 3)

    def test_parse_answer(self):
        ok = '```json\n[{"case": 1, "better": "2", "why": "x"}, {"case": 2, "better": "tie"}]\n```'
        got, problem = R.parse_answer(ok, 2)
        self.assertEqual((got[1][0], got[2][0], problem), ("2", "tie", None))
        got, problem = R.parse_answer('[{"case": 1, "better": "1"}, {"case": 1, "better": "2"}, {"case": 9, "better": "1"}, {"case": 2, "better": "maybe"}]', 3)
        self.assertEqual(list(got), [1])
        self.assertEqual(got[1][0], "1")                       # a duplicate does not replace the first
        self.assertIn("2 of 3", problem)
        self.assertEqual(R.parse_answer("I cannot decide", 2)[0], {})
        self.assertEqual(R.parse_answer("[1, 2", 2)[0], {})


class Run(unittest.TestCase):
    def test_every_prompt_gets_a_verdict_and_tally_reads_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            pair, key, refs = known_answer_pair(tmp)
            count = env(tmp, "ref", refs)
            out = os.path.join(tmp, "jr")
            self.assertEqual(run_pair(tmp, pair, out, make_fake(tmp)), 0)
            v = verdicts(out)
            self.assertEqual(len(v), 2 * len(key["items"]))
            self.assertEqual(len({x["id"] for x in v}), len(v))
            calls = n_calls(count)
            self.assertEqual(calls, -(-len(v) // 5))
            r = J.tally(key, v)
            self.assertEqual((r["a"], r["b"], r["disagree"], r["missing"]), (12, 0, 0, 0))
            self.assertTrue(r["calibration_ok"])
            # a rerun on the same --out asks nobody again
            self.assertEqual(run_pair(tmp, pair, out, make_fake(tmp)), 0)
            self.assertEqual(n_calls(count), calls)
            self.assertEqual(len(verdicts(out)), len(v))
            print("run: %d prompts in %d calls, tally a %d b %d, rerun asked 0 more calls" % (len(v), calls, r["a"], r["b"]))

    def test_exit_zero_with_a_failed_status_is_not_a_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            pair, key, refs = known_answer_pair(tmp)
            env(tmp, "error", refs)
            out = os.path.join(tmp, "jr")
            rc = run_pair(tmp, pair, out, make_fake(tmp))
            self.assertEqual(rc, 4)
            self.assertEqual(verdicts(out), [])
            tries = [f for f in os.listdir(os.path.join(out, "calls")) if f.endswith(".json")]
            for f in tries:
                with open(os.path.join(out, "calls", f), encoding="utf-8") as fh:
                    self.assertEqual(json.load(fh)["problem"], "status ERROR")
            print("FAIL-first: the CLI exits 0 with status ERROR -> run rc %d, %d verdicts counted, %d raw tries kept" % (rc, len(verdicts(out)), len(tries)))

    def test_a_short_answer_is_asked_again_and_its_raw_tries_are_kept(self):
        with tempfile.TemporaryDirectory() as tmp:
            pair, key, refs = known_answer_pair(tmp)
            count = env(tmp, "short", refs)
            out = os.path.join(tmp, "jr")
            rc = run_pair(tmp, pair, out, make_fake(tmp), batch=5, jobs=1, tries=3)
            v = verdicts(out)
            self.assertEqual(rc, 0)                            # try 1 misses the last case, try 2 asks that one case alone
            self.assertEqual(len(v), 2 * len(key["items"]))
            tries = [f for f in os.listdir(os.path.join(out, "calls")) if f.endswith(".json")]
            self.assertGreater(len(tries), n_calls(count) // 2)
            print("short answers: %d verdicts after %d tries (the missing cases were asked again, every try kept)" % (len(v), len(tries)))

    def test_a_larger_max_items_asks_a_superset(self):
        with tempfile.TemporaryDirectory() as tmp:
            pair, key, refs = known_answer_pair(tmp, n_echo=6, n_bad=10)
            env(tmp, "ref", refs)
            out = os.path.join(tmp, "jr")
            fake = make_fake(tmp)
            self.assertEqual(R.main(["run", "--pair", pair, "--out", out, "--agy", fake, "--batch", "5", "--jobs", "1", "--max-items", "6",
                                     "--backoff", "0"]), 0)
            small = {x["id"] for x in verdicts(out)}
            self.assertEqual(len({i.rpartition(".")[0] for i in small if key["items"][i.rpartition(".")[0]]["kind"] == "real"}), 6)
            self.assertEqual(R.main(["run", "--pair", pair, "--out", out, "--agy", fake, "--batch", "5", "--jobs", "1", "--max-items", "12",
                                     "--backoff", "0"]), 0)
            big = [x["id"] for x in verdicts(out)]
            self.assertTrue(small <= set(big))
            self.assertEqual(len(big), len(set(big)))              # nobody was asked twice
            print("max-items 6 then 12: %d verdicts, then %d, no id twice" % (len(small), len(big)))


class KnownAnswer(unittest.TestCase):
    def tally(self, mode):
        with tempfile.TemporaryDirectory() as tmp:
            pair, key, refs = known_answer_pair(tmp)
            env(tmp, mode, refs)
            out = os.path.join(tmp, "jr")
            self.assertEqual(run_pair(tmp, pair, out, make_fake(tmp)), 0)
            report, tot, cal, ok = R.known_answer_report(key, verdicts(out))
            return tot, cal, ok

    def test_a_judge_that_prefers_the_reference_passes(self):
        tot, cal, ok = self.tally("ref")
        self.assertTrue(ok)
        self.assertEqual((tot["ref_wins"], tot["ref_loses"], tot["disagree"]), (12, 0, 0))
        self.assertEqual((cal["pass"], cal["fail"]), (2, 0))

    def test_position_bias_and_a_wrong_preference_fail(self):
        tot, cal, ok = self.tally("bias")
        self.assertFalse(ok)
        self.assertEqual((tot["ref_wins"], tot["disagree"]), (0, 12))
        print("FAIL-first: a judge that always answers the first translation -> reference wins %d, orders disagree %d, calibration FAILED"
              % (tot["ref_wins"], tot["disagree"]))
        tot, cal, ok = self.tally("wrong")
        self.assertFalse(ok)
        self.assertEqual((tot["ref_wins"], tot["ref_loses"]), (0, 12))
        print("FAIL-first: a judge that prefers the wrong translation -> reference wins %d, loses %d, calibration FAILED" % (tot["ref_wins"], tot["ref_loses"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
