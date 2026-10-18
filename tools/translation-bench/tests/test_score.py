#!/usr/bin/env python3
"""Scorer unit checks (G2): `python3 -I tests/test_score.py`.

FAIL-first: the golden mini-sequence (hand-written expected translations) scores 100 % on its own probes; the same
output with one name swapped everywhere drops probe accuracy and raises the carry-over count. Every number a
measurement relies on (sign test, percentiles, cost, speech level, probe checks) is pinned against a hand computation."""
import importlib.util
import io
import json
import os
import shutil
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)
GOLDEN = os.path.join(HERE, "golden")


def load(name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(BENCH, name + ".py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


S = load("score")


def summarize(run_name, root=GOLDEN):
    seqs, mems = S.load_corpus(root)
    run = S.load_run(os.path.join(root, "runs", run_name))
    return S.summarize(run, seqs, mems, S.load_prices(root))


class Golden(unittest.TestCase):
    def test_correct_output_scores_100_percent(self):
        s = summarize("correct")
        self.assertEqual((s["probes"]["ok"], s["probes"]["n"]), (8, 8))
        self.assertEqual(s["probes"]["by"], {"memory": (6, 6), "lines": (1, 1), "none": (1, 1)})
        self.assertEqual(s["speech"]["scored"], 10)
        self.assertEqual(s["speech"]["match"], 10)
        self.assertEqual(s["carry"]["repeat_same"], 0)
        self.assertEqual(s["carry"]["fail_streak"], 0)

    def test_swapped_name_drops_accuracy_and_raises_carry_over(self):
        good, bad = summarize("correct"), summarize("swapped-name")
        print("FAIL-first: probe accuracy %d/%d -> %d/%d; carry-over (repeated wrong forms) %d -> %d; fail streaks %d -> %d"
              % (good["probes"]["ok"], good["probes"]["n"], bad["probes"]["ok"], bad["probes"]["n"],
                 good["carry"]["repeat_same"], bad["carry"]["repeat_same"], good["carry"]["fail_streak"], bad["carry"]["fail_streak"]))
        self.assertEqual(bad["probes"]["ok"], 6)
        self.assertLess(bad["probes"]["ok"], good["probes"]["ok"])
        # the name 海 is probed at lines 1 and 7 (the only key with two probes: one streak chance); both come out as 바다,
        # so the second repeats the first
        self.assertEqual(bad["carry"], {"repeat_same": 1, "after_wrong": 1, "fail_streak": 1, "streak_chances": 1})
        self.assertGreater(bad["carry"]["repeat_same"], good["carry"]["repeat_same"])

    def test_sign_test_between_the_two_runs(self):
        seqs, mems = S.load_corpus(GOLDEN)
        a = summarize("correct")
        b = summarize("swapped-name")
        c = S.compare(a, b)
        self.assertEqual((c["all"]["a_only"], c["all"]["b_only"], c["all"]["n"]), (2, 0, 8))
        self.assertAlmostEqual(c["all"]["p"], 0.5)
        self.assertAlmostEqual(c["all"]["delta_pts"], -25.0)
        self.assertEqual(c["memory"]["a_only"], 2)
        self.assertEqual(c["lines"]["a_only"], 0)

    def test_latency_tokens_and_cost(self):
        s = summarize("correct")
        self.assertAlmostEqual(s["latency"]["p50"], 250.0)
        self.assertAlmostEqual(s["latency"]["p95"], 385.0)
        t = s["tokens"]
        self.assertEqual((t["in"], t["out"], t["cached"]), (460, 92, 150))
        self.assertAlmostEqual(t["mean_in"], 115.0)
        self.assertAlmostEqual(t["stable"], 50.0)
        self.assertAlmostEqual(t["lcp"], 40.0)
        # fresh 100 + 60 + 70 + 80 = 310 at 1.0, cached 150 at 0.1, out 92 at 2.0, per million tokens
        self.assertAlmostEqual(s["cost_usd"], (310 * 1.0 + 150 * 0.1 + 92 * 2.0) / 1e6)

    def test_report_prints(self):
        buf = io.StringIO()
        S.print_summary(summarize("correct"), buf)
        text = buf.getvalue()
        self.assertIn("probes 8: 8 correct = 100.0%", text)
        self.assertIn("latency ms: p50 250 p95 385", text)


class Pieces(unittest.TestCase):
    def test_sign_test(self):
        # research-ctxmgmt 6.4: 25 discordant with 18 for one side p=0.043; 30 with 21 p=0.043; 100 with 62 p=0.021
        self.assertAlmostEqual(S.sign_test(18, 7), 0.0433, places=3)
        self.assertAlmostEqual(S.sign_test(21, 9), 0.0428, places=3)
        self.assertAlmostEqual(S.sign_test(62, 38), 0.021, places=3)
        self.assertEqual(S.sign_test(0, 0), 1.0)
        self.assertAlmostEqual(S.sign_test(3, 0), 0.25)

    def test_wilson(self):
        lo, hi = S.wilson(60, 100)
        self.assertAlmostEqual(lo, 0.502, places=3)
        self.assertAlmostEqual(hi, 0.691, places=3)

    def test_percentile(self):
        self.assertEqual(S.percentile([], 0.5), None)
        self.assertAlmostEqual(S.percentile([1, 2, 3, 4], 0.5), 2.5)
        self.assertAlmostEqual(S.percentile([10], 0.95), 10)

    def test_speech_levels(self):
        cases = [("싸네요! 감사해요!", "haeyo"), ("감사합니다!", "hapsyo"), ("괜찮아, 우리가 있잖아.", "banmal"),
                 ("네, 조금요. 그래도 기대돼요.", "haeyo"), ("안녕하세요. 가자.", "mixed"), ("ㅋㅋㅋ", None),
                 ("함께 갑시다.", "hapsyo"), ("“가자”라고 했어요.", "haeyo"), ("네! 기대돼요.", "haeyo"), ("OK 😊", None),
                 ("가시죠~", "haeyo"), ("뭐 먹을까?", "banmal"), ("확인했습니다 ㅎㅎ", "hapsyo")]
        for text, want in cases:
            self.assertEqual(S.line_level(text), want, text)

    def test_probe_checks(self):
        c = S.check_probe
        self.assertTrue(c({"any": ["카이"], "none": ["바다"]}, "카이가 왔어"))
        self.assertFalse(c({"any": ["카이"], "none": ["바다"]}, "바다가 왔어"))
        self.assertFalse(c({"any": ["카이"], "none": ["바다"]}, "카이는 바다에 갔어"))
        self.assertTrue(c({"any_w": ["she"], "none_w": ["he"]}, "She said the shell is hers"))
        self.assertFalse(c({"any_w": ["she"], "none_w": ["he"]}, "he said"))
        self.assertTrue(c({"regex": "셨"}, "하셨어"))
        self.assertFalse(c({"regex": "셨", "nregex": "하셨"}, "하셨어"))
        self.assertTrue(c({"level": "haeyo"}, "좋아요"))
        self.assertFalse(c({"level": "haeyo"}, "좋아"))
        self.assertTrue(c({"any": ["Seoyoon"]}, "seoyoon is here"))   # case-folded
        self.assertEqual(S.wrong_forms({"none": ["바다", "우미"]}, "바다와 우미"), {"바다", "우미"})

    def test_render_memory_is_stable(self):
        with open(os.path.join(GOLDEN, "memory", "mini.json"), encoding="utf-8") as f:
            mem = json.load(f)
        want = ("Window: テニス部 | app: LINE | category: Social Networking\nPeople:\n- Mina; female; speaks to 海: 해요체\n"
                "- 海 (かい); male; speaks to Mina: 반말\nTerms: 合宿 = 엠티")
        self.assertEqual(S.render_memory(mem), want)
        self.assertNotIn("speaks to", S.render_memory(mem, speech=False))
        self.assertEqual(S.render_memory(mem, sections=("window",)), "Window: テニス部 | app: LINE | category: Social Networking")

    def test_est_tokens(self):
        self.assertAlmostEqual(S.est_tokens("가나다"), 3.0)
        self.assertAlmostEqual(S.est_tokens("abcd"), 1.08)
        self.assertAlmostEqual(S.est_tokens("a b"), 0.54)


class Corpus(unittest.TestCase):
    """The oracle (every line's own `ref`) scores 100 % on every probe of the real corpus; the validator already pins
    that each check passes on its ref and fails on its bad text, this runs it through the run format and the scorer."""

    def make_run(self, root, path, transform=lambda seq, line, text: text):
        seqs, _ = S.load_corpus(root)
        os.makedirs(path, exist_ok=True)
        for sid, seq in seqs.items():
            tr = {str(l["id"]): transform(seq, l, l["ref"]) for l in seq["lines"]}
            with open(os.path.join(path, sid + ".json"), "w", encoding="utf-8") as f:
                json.dump({"id": sid, "condition": "oracle", "translations": tr, "requests": []}, f, ensure_ascii=False)
        with open(os.path.join(path, "meta.json"), "w") as f:
            json.dump({"condition": "oracle", "engine": "oracle", "model": "oracle", "jobs": 1}, f)

    def test_oracle_scores_100_percent_and_a_swapped_term_does_not(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.make_run(BENCH, os.path.join(tmp, "ok"))
            seqs, mems = S.load_corpus(BENCH)
            s = S.summarize(S.load_run(os.path.join(tmp, "ok")), seqs, mems, {"models": {}})
            self.assertEqual(s["probes"]["ok"], s["probes"]["n"])
            self.assertGreaterEqual(s["probes"]["n"], 250)
            self.assertEqual(s["speech"]["match"], s["speech"]["scored"])
            self.assertEqual(s["carry"]["repeat_same"], 0)

            def wreck(seq, line, text):
                # every probe's own wrong rendering, applied to the lines the probes sit on
                for p in seq["probes"]:
                    if p["line"] == line["id"] and "bad_sub" in p and p["bad_sub"][0] in text:
                        return text.replace(p["bad_sub"][0], p["bad_sub"][1])
                return text
            self.make_run(BENCH, os.path.join(tmp, "bad"), wreck)
            b = S.summarize(S.load_run(os.path.join(tmp, "bad")), seqs, mems, {"models": {}})
            print("corpus oracle: %d/%d probes; with the wrong renderings applied: %d/%d, carry-over %d"
                  % (s["probes"]["ok"], s["probes"]["n"], b["probes"]["ok"], b["probes"]["n"], b["carry"]["repeat_same"]))
            self.assertLess(b["probes"]["ok"], s["probes"]["n"] * 0.5)
            self.assertGreater(b["carry"]["repeat_same"], 0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
