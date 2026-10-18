#!/usr/bin/env python3
"""Judge harness unit checks (G3): `python3 -I tests/test_judge.py`.

An A-vs-A comparison (identical translations) produces a sample prompt pair: the calibration items, the same text in
both orders. The prompts carry no condition or engine name. The tally counts only items on which both orders agree."""
import importlib.util
import json
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(BENCH, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


S, J = load("score"), load("judge")


def make_run(path, condition, engine, change=None):
    """A run of the whole corpus translated by the sequences' own `ref`; `change(seq_id, line)` may edit a line."""
    seqs, _ = S.load_corpus(BENCH)
    os.makedirs(path, exist_ok=True)
    for sid, seq in seqs.items():
        tr = {str(l["id"]): (change(sid, l) if change and change(sid, l) is not None else l["ref"]) for l in seq["lines"]}
        with open(os.path.join(path, sid + ".json"), "w", encoding="utf-8") as f:
            json.dump({"id": sid, "condition": condition, "translations": tr, "requests": []}, f, ensure_ascii=False)
    with open(os.path.join(path, "meta.json"), "w") as f:
        json.dump({"condition": condition, "engine": engine, "model": engine, "jobs": 1}, f)


class Prompts(unittest.TestCase):
    def test_identical_runs_give_a_calibration_pair_and_no_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_run(os.path.join(tmp, "a1"), "A", "secret-engine")
            make_run(os.path.join(tmp, "a2"), "A", "secret-engine")
            out = os.path.join(tmp, "judge")
            self.assertEqual(J.main(["prompts", "--a", os.path.join(tmp, "a1"), "--b", os.path.join(tmp, "a2"), "--out", out]), 0)
            files = sorted(os.listdir(os.path.join(out, "prompts")))
            self.assertEqual(files[:2], ["item-0001.1.txt", "item-0001.2.txt"])
            self.assertEqual(len(files), 8)   # 4 calibration items x 2 orders, nothing real to ask
            p1 = open(os.path.join(out, "prompts", files[0]), encoding="utf-8").read()
            p2 = open(os.path.join(out, "prompts", files[1]), encoding="utf-8").read()
            self.assertEqual(p1, p2)          # identical text in both orders
            self.assertIn("Translation 1:", p1)
            self.assertIn('"better"', p1)
            for name in ("secret-engine", "oracle"):
                self.assertNotIn(name, p1)
            key = json.load(open(os.path.join(out, "key.json"), encoding="utf-8"))
            self.assertEqual({v["kind"] for v in key["items"].values()}, {"calibration"})
            self.assertEqual(key["identical"], sum(len(s["lines"]) for s in S.load_corpus(BENCH)[0].values()))
            print("sample prompt pair:", files[0], files[1], "(%d chars each)" % len(p1))

    def test_differing_lines_are_asked_in_both_orders(self):
        with tempfile.TemporaryDirectory() as tmp:
            make_run(os.path.join(tmp, "a"), "A", "e1")
            make_run(os.path.join(tmp, "b"), "B2", "e2", lambda sid, l: l["ref"][::-1] if sid == "chat-ja-ko-1" and l["id"] in (1, 2) else None)
            out = os.path.join(tmp, "judge")
            J.main(["prompts", "--a", os.path.join(tmp, "a"), "--b", os.path.join(tmp, "b"), "--out", out])
            key = json.load(open(os.path.join(out, "key.json"), encoding="utf-8"))
            real = [(k, v) for k, v in key["items"].items() if v["kind"] == "real"]
            self.assertEqual(len(real), 2)
            item, info = real[0]
            first = open(os.path.join(out, "prompts", item + ".1.txt"), encoding="utf-8").read()
            second = open(os.path.join(out, "prompts", item + ".2.txt"), encoding="utf-8").read()
            self.assertNotEqual(first, second)
            self.assertLess(first.index(info["a_text"]), first.index(info["b_text"]))
            self.assertLess(second.index(info["b_text"]), second.index(info["a_text"]))
            self.assertNotIn("B2", first)


class Tally(unittest.TestCase):
    key = {"a": "A", "b": "B2", "identical": 9, "items": {
        "item-0001": {"kind": "real"}, "item-0002": {"kind": "real"}, "item-0003": {"kind": "real"},
        "item-0004": {"kind": "real"}, "item-0005": {"kind": "real"}, "item-0006": {"kind": "real"},
        "item-0007": {"kind": "calibration"}, "item-0008": {"kind": "calibration"}}}

    @staticmethod
    def v(item, order, better):
        return {"id": "%s.%s" % (item, order), "better": better}

    def test_counts_only_agreeing_verdicts(self):
        v = self.v
        verdicts = [
            v("item-0001", "1", "1"), v("item-0001", "2", "2"),     # order 1 has A first, order 2 has B first: both say A
            v("item-0002", "1", "2"), v("item-0002", "2", "1"),     # both say B
            v("item-0003", "1", "tie"), v("item-0003", "2", "tie"),
            v("item-0004", "1", "1"), v("item-0004", "2", "1"),     # always the first text: position bias
            v("item-0005", "1", "tie"), v("item-0005", "2", "1"),   # one tie, one B
            v("item-0006", "1", "1"),                               # order 2 missing
            v("item-0007", "1", "tie"), v("item-0007", "2", "tie"),  # calibration passed
            v("item-0008", "1", "1"), v("item-0008", "2", "1"),      # calibration failed
        ]
        r = J.tally(self.key, verdicts)
        self.assertEqual((r["a"], r["b"], r["tie"], r["disagree"], r["missing"]), (1, 1, 1, 2, 1))
        self.assertEqual((r["cal_pass"], r["cal_fail"], r["cal_missing"]), (1, 1, 0))
        self.assertFalse(r["calibration_ok"])
        self.assertEqual(r["decided"], 2)
        self.assertAlmostEqual(r["b_rate"], 0.5)
        self.assertEqual(r["identical"], 9)
        print("tally of the fake set: A %d, B %d, tie %d, disagree %d, missing %d; calibration passed %d failed %d"
              % (r["a"], r["b"], r["tie"], r["disagree"], r["missing"], r["cal_pass"], r["cal_fail"]))

    def test_calibration_ok_when_every_identical_pair_ties(self):
        verdicts = [self.v("item-0007", o, "tie") for o in "12"] + [self.v("item-0008", o, "tie") for o in "12"]
        r = J.tally(self.key, verdicts)
        self.assertTrue(r["calibration_ok"])

    def test_raw_model_answers_are_parsed(self):
        self.assertEqual(J.parse_verdict({"answer": 'Sure. {"better": "2", "why": "x"}'}), "2")
        self.assertEqual(J.parse_verdict({"better": 1}), "1")
        self.assertIsNone(J.parse_verdict({"better": "maybe"}))
        self.assertIsNone(J.parse_verdict({"answer": "no json"}))

    def test_winner_mapping(self):
        self.assertEqual(J.winner("1", "1"), "a")
        self.assertEqual(J.winner("1", "2"), "b")
        self.assertEqual(J.winner("2", "1"), "b")
        self.assertEqual(J.winner("2", "2"), "a")
        self.assertEqual(J.winner("2", "tie"), "tie")

    def test_cli_prints_the_counts(self):
        with tempfile.TemporaryDirectory() as tmp:
            kp, vp = os.path.join(tmp, "key.json"), os.path.join(tmp, "v.jsonl")
            with open(kp, "w") as f:
                json.dump(self.key, f)
            with open(vp, "w") as f:
                for v in [self.v("item-0001", "1", "1"), self.v("item-0001", "2", "2"), self.v("item-0007", "1", "tie"), self.v("item-0007", "2", "tie")]:
                    f.write(json.dumps(v) + "\n")
            import contextlib
            import io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                J.main(["tally", "--key", kp, "--verdicts", vp])
            text = buf.getvalue()
            self.assertIn("A wins 1, B2 wins 0, tie 0", text)
            self.assertIn("decided pairs 1 (need at least 150): NOT ENOUGH", text)


if __name__ == "__main__":
    unittest.main(verbosity=2)
