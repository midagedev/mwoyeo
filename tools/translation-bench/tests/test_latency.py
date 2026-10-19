#!/usr/bin/env python3
"""latency.py (the A/A self-check): `python3 -I tests/test_latency.py`.

A synthetic set of runs with known latencies pins the arithmetic (the deltas, the spread, the verdict word); the two preserved A
runs of gemma3:4b pin that the script reads real runs and finds the 200 ms-odd spread the T1 notes talk about; and a latency
verdict without an A/A pair, or with a run that is not condition A, is refused."""
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)
_spec = importlib.util.spec_from_file_location("latency", os.path.join(BENCH, "latency.py"))
L = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(L)


def make_run(tmp, name, condition, lats, seq="s1"):
    d = os.path.join(tmp, name)
    os.makedirs(d)
    with open(os.path.join(d, "meta.json"), "w") as f:
        json.dump({"condition": condition}, f)
    reqs = [{"n": i + 1, "latency_ms": ms, "usage": {"in": 100, "out": 40}, "attempts": [{"ok": True}], "items": [i + 1]} for i, ms in enumerate(lats)]
    with open(os.path.join(d, seq + ".json"), "w") as f:
        json.dump({"id": seq, "condition": condition, "translations": {}, "requests": reqs}, f)
    return d


class Latency(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = [1000, 1200, 800, 1500, 900, 1100, 2000, 700]
        self.base = base
        # three A/A runs whose means differ by 100 ms in total (-50, +50, 0 around the base)
        self.aa = [make_run(self.tmp.name, "A%d" % i, "A", [x + off for x in base]) for i, off in enumerate((-50, 50, 0))]
        self.big = make_run(self.tmp.name, "big", "B2", [x + 500 for x in base])
        self.small = make_run(self.tmp.name, "small", "B2", [x + 120 for x in base])

    def tearDown(self):
        self.tmp.cleanup()

    def analyse(self, *tested):
        return L.analyse([L.S.load_run(p) for p in self.aa], [L.S.load_run(p) for p in tested])

    def test_the_spread_and_the_deltas(self):
        a = self.analyse(self.big, self.small)
        self.assertEqual(a["requests"], 8)
        self.assertAlmostEqual(a["spread_mean"], 100, places=6)
        self.assertAlmostEqual(a["spread_p50"], 100, places=6)
        # A0 is 50 below the base, the other two average to 25 above it: -75
        self.assertAlmostEqual(a["aa"][0]["vs_others"], -75, places=6)
        self.assertAlmostEqual(a["aa"][0]["median_vs_others"], -75, places=6)
        big, small = a["tested"]
        self.assertAlmostEqual(big["delta"], 500, places=6)
        self.assertAlmostEqual(small["delta"], 120, places=6)
        self.assertEqual((big["in"], big["out"], big["failed"]), (100, 40, 0))

    def test_resolved_means_more_than_twice_the_spread(self):
        a = self.analyse(self.big, self.small)
        self.assertTrue(a["tested"][0]["resolved"])      # 500 > 2 * 100
        self.assertFalse(a["tested"][1]["resolved"])     # 120 < 200: inside the noise
        text = L.render(a)
        self.assertIn("resolved (5.0x the A/A spread of the p50s)", text)
        self.assertIn("inside the A/A noise (1.2x the A/A spread of the p50s)", text)

    def test_one_stalled_request_moves_neither_the_median_nor_the_mean_without_stalls(self):
        stalled = make_run(self.tmp.name, "stalled", "B2", [x + 500 for x in self.base[:-1]] + [300000])
        x = self.analyse(stalled)["tested"][0]
        self.assertEqual(x["stalls"], 1)
        self.assertAlmostEqual(x["delta_p50"], 500, places=6)
        self.assertAlmostEqual(x["delta"], 500, places=6)
        self.assertTrue(x["resolved"])

    def test_a_request_missing_from_one_run_is_left_out(self):
        short = make_run(self.tmp.name, "short", "B2", [x + 500 for x in self.base[:5]])
        a = self.analyse(short)
        self.assertEqual(a["tested"][0]["n"], 5)
        self.assertAlmostEqual(a["tested"][0]["delta"], 500, places=6)

    def test_the_preserved_a_runs_of_gemma3_have_a_spread_of_a_few_hundred_ms(self):
        runs = [L.S.load_run(os.path.join(BENCH, "runs", n)) for n in ("A-gemma3-4b", "A-gemma3-4b-r2")]
        a = L.analyse(runs, [L.S.load_run(os.path.join(BENCH, "runs", "M-gemma3-4b"))])
        self.assertEqual(a["requests"], 252)
        self.assertTrue(150 < a["spread_mean"] < 350, a["spread_mean"])
        self.assertTrue(a["tested"][0]["delta"] > 0)

    def test_it_refuses_a_single_a_run_and_a_run_that_is_not_condition_a(self):
        err = io.StringIO()
        old = sys.stderr
        sys.stderr = err
        try:
            self.assertEqual(L.main(["--aa", self.aa[0]]), 2)
            self.assertEqual(L.main(["--aa", self.aa[0], self.big]), 2)
        finally:
            sys.stderr = old
        self.assertIn("at least two", err.getvalue())
        self.assertIn("not condition A", err.getvalue())


if __name__ == "__main__":
    unittest.main(verbosity=2)
