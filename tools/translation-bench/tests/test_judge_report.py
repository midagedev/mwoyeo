#!/usr/bin/env python3
"""judge-report.py unit checks: `python3 -I tests/test_judge_report.py`. Planted verdicts for two judge models over one pair: the counts of
wins, ties, position bias and one-order-only items, the consensus of the two models, the calibration result and the split by lines
copied back untranslated."""
import contextlib
import importlib.util
import io
import json
import os
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


S, R = load("score"), load("judge_report", "judge-report")


def key_for(seqs):
    sid = sorted(seqs)[0]
    lines = seqs[sid]["lines"]
    items = {}
    for n in range(1, 6):
        src = lines[n]["text"]
        # item 5: B left the line untranslated (its text is the source text)
        items["item-%04d" % n] = {"seq": sid, "line": lines[n]["id"], "kind": "real", "a_text": "translated A %d" % n,
                                  "b_text": src if n == 5 else "translated B %d" % n}
    items["item-0006"] = {"seq": sid, "line": lines[6]["id"], "kind": "calibration", "a_text": "same", "b_text": "same"}
    return {"a": "A", "b": "B", "identical": 0, "items": items}


def verdict(item, order, better):
    return {"id": "item-%04d.%s" % (item, order), "better": better}


# order 1 shows A first, order 2 shows B first: "1" in order 1 and "2" in order 2 both mean A
MODEL1 = [verdict(1, "1", "1"), verdict(1, "2", "2"),            # item 1: A in both orders
          verdict(2, "1", "2"), verdict(2, "2", "1"),            # item 2: B in both orders
          verdict(3, "1", "1"), verdict(3, "2", "1"),            # item 3: always the first one shown: position bias
          verdict(4, "1", "tie"), verdict(4, "2", "tie"),        # item 4: tie
          verdict(5, "1", "1"),                                  # item 5: only one order answered
          verdict(6, "1", "tie"), verdict(6, "2", "tie")]        # calibration passes
MODEL2 = [verdict(1, "1", "2"), verdict(1, "2", "1"),            # item 1: B in both orders (the models split)
          verdict(2, "1", "2"), verdict(2, "2", "1"),            # item 2: B
          verdict(6, "1", "1"), verdict(6, "2", "tie")]          # calibration fails


class Report(unittest.TestCase):
    def setUp(self):
        self.seqs, _ = S.load_corpus(BENCH)
        self.key = key_for(self.seqs)

    def test_counts(self):
        out = R.item_outcomes(self.key, MODEL1)
        c = R.counts(out)
        self.assertEqual((c["a"], c["b"], c["tie"], c["disagree"], c["partial"], c["decided"]), (1, 1, 1, 1, 1, 2))
        self.assertEqual(R.calibration(self.key, MODEL1), (1, 0, 0))
        self.assertEqual(R.calibration(self.key, MODEL2), (0, 1, 0))
        # what an implementation that counts the first order only would say: item 3 (position bias) becomes a win for A
        first_only = {"a": 0, "b": 0}
        for v in MODEL1:
            if v["id"].endswith(".1") and v["better"] in ("1", "2") and "item-0006" not in v["id"]:
                first_only["a" if v["better"] == "1" else "b"] += 1
        self.assertEqual(first_only, {"a": 3, "b": 1})
        print("FAIL-first: counting the first order only gives A %d, B %d; counting both orders gives A %d, B %d (item 3 is position bias, item 5 has one order)"
              % (first_only["a"], first_only["b"], c["a"], c["b"]))

    def test_report_tables_and_consensus(self):
        with tempfile.TemporaryDirectory() as tmp:
            for model, verdicts in (("m1", MODEL1), ("m2", MODEL2)):
                d = os.path.join(tmp, model, "pairX")
                os.makedirs(d)
                with open(os.path.join(d, "key.json"), "w", encoding="utf-8") as f:
                    json.dump(self.key, f)
                with open(os.path.join(d, "verdicts.jsonl"), "w", encoding="utf-8") as f:
                    for v in verdicts:
                        f.write(json.dumps(v) + "\n")
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                self.assertEqual(R.main([tmp, "--echo", "--root", BENCH]), 0)
            text = buf.getvalue()
            self.assertIn("| pairX | m1 | 5 | 1 | 1 | 1 | 1 | 1 |", text)
            # consensus of both models over the items both finished (1 and 2): item 1 splits, item 2 is B for both
            self.assertIn("| pairX | consensus of m1+m2 | 2 | 0 | 1 | 0 | split 1 |", text)
            self.assertIn("| pairX | m1 | both translated (4) |", text)
            self.assertIn("| pairX | m1 | only B copied back (1) | 0 | 0 | 0 | 0 | - |", text)   # item 5: one order only, nothing counted
            print("report: " + text.splitlines()[2])


if __name__ == "__main__":
    unittest.main(verbosity=2)
