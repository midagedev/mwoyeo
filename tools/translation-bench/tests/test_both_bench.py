#!/usr/bin/env python3
"""both_bench.py unit checks (round both-bench): `python3 -I tests/test_both_bench.py [--neuter]`.

Mini runs of chat-ja-ko-1 (every translation is the line's `ref`) carry planted `replaced` records: line 5 (the name 海) under both-names
and both, line 1 (the term 合宿) under both only. The classes must come out N = {5}, T = {1}, everything else U. A planted defect (the
hint arm renders 海 wrongly on line 5) must show up in class N only, the names-kept and the probe counts of U must not move, and the judge
tally must split by class; a sequence none of whose requests was rewritten counts as identical to hint (and is excluded from the evidence).
With `--neuter` the classes are pooled (every line untouched), no sequence counts as identical, and this test must FAIL: run-all.sh runs it that
way, or the test would pass on an analysis that pools what it must keep apart."""
import importlib.util
import json
import os
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)
_spec = importlib.util.spec_from_file_location("both_bench", os.path.join(BENCH, "both_bench.py"))
B = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(B)
S = B.S
SID = "chat-ja-ko-1"


def make_run(path, replaced=None, wrong_line=None):
    seq = S.load_corpus(BENCH)[0][SID]
    translations = {str(l["id"]): l["ref"] for l in seq["lines"]}
    if wrong_line:
        translations[str(wrong_line)] = translations[str(wrong_line)].replace("카이", "우미")
    requests = [{"n": 1, "items": [l["id"]], "replaced": [r for r in (replaced or []) if r["id"] == l["id"]] if replaced is not None else None}
                for l in seq["lines"]]
    if replaced is None:
        for r in requests:
            del r["replaced"]
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, SID + ".json"), "w", encoding="utf-8") as f:
        json.dump({"id": SID, "condition": "M", "translations": translations, "requests": requests}, f, ensure_ascii=False)
    with open(os.path.join(path, "meta.json"), "w") as f:
        json.dump({"condition": "M", "engine": "fake", "model": "fake", "jobs": 1}, f)


NAME = {"id": 5, "text": "宿は카이が取ってくれるんだよね?", "spans": [["海", "카이"]]}
TERM = {"id": 1, "text": "みんな、今週末の엠티どうする?", "spans": [["合宿", "엠티"]]}


class Classes(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        make_run(os.path.join(t, "hint"), replaced=None, wrong_line=5)
        make_run(os.path.join(t, "both-names"), replaced=[NAME])
        make_run(os.path.join(t, "both"), replaced=[NAME, TERM])
        self.runs = {a: S.load_run(os.path.join(t, a)) for a in ("hint", "both-names", "both")}
        self.seqs, self.mems = B.load_named(BENCH, "memory-named")
        self.classes, self.notes = B.classes_of(self.runs["both-names"], self.runs["both"], self.seqs)

    def tearDown(self):
        self.tmp.cleanup()

    def test_the_lines_split_into_names_terms_and_untouched(self):
        cls = self.classes[SID]
        self.assertEqual([i for i, c in cls.items() if c == "N"], [5])
        self.assertEqual([i for i, c in cls.items() if c == "T"], [1])
        self.assertEqual(sum(c == "U" for c in cls.values()), len(cls) - 2)
        self.assertEqual(self.notes, [])

    def test_a_planted_wrong_name_shows_in_class_n_only(self):
        hint = B.measure(self.runs["hint"], self.seqs, self.mems, self.classes)
        good = B.measure(self.runs["both-names"], self.seqs, self.mems, self.classes)
        self.assertEqual(hint["N"]["lines"], 1)
        self.assertLess(hint["N"]["ent"][0], good["N"]["ent"][0])      # 海 is not kept on line 5 in the hint arm
        self.assertLess(hint["N"]["probes"][0], good["N"]["probes"][0])  # p08 fails there
        for c in ("T", "U"):
            self.assertEqual(hint[c], good[c], c)                       # nothing else moved

    def test_the_paired_comparison_counts_the_flip_in_its_class(self):
        pr = B.paired(self.runs["hint"], self.runs["both-names"], self.seqs, self.mems, self.classes)
        self.assertEqual((pr["N"]["a_only"], pr["N"]["b_only"], pr["N"]["same"], pr["N"]["lines"]), (0, 1, 0, 1))
        self.assertEqual((pr["U"]["a_only"], pr["U"]["b_only"]), (0, 0))
        self.assertEqual(pr["U"]["same"], pr["U"]["lines"])

    def test_a_sequence_with_no_rewritten_line_is_identical_to_hint_and_one_with_a_rewrite_is_not(self):
        self.assertEqual(B.identical_sequences(self.runs["hint"], self.runs["both-names"]), set())   # line 5 was rewritten
        t = self.tmp.name
        make_run(os.path.join(t, "both-none"), replaced=[])
        make_run(os.path.join(t, "hint-none"), replaced=[])
        self.assertEqual(B.identical_sequences(S.load_run(os.path.join(t, "hint-none")), S.load_run(os.path.join(t, "both-none"))), {SID})

    def test_the_judge_tally_splits_by_class(self):
        key = {"a": "M", "b": "M", "identical": 0, "items": {
            "item-0001": {"seq": SID, "line": 5, "kind": "real", "a_text": "x", "b_text": "y"},
            "item-0002": {"seq": SID, "line": 7, "kind": "real", "a_text": "x", "b_text": "y"},
            "item-0003": {"seq": SID, "line": 7, "kind": "calibration", "a_text": "x", "b_text": "x"}}}
        verdicts = [{"id": "item-0001.1", "better": "2"}, {"id": "item-0001.2", "better": "1"},   # B (the arm) wins in both orders
                    {"id": "item-0002.1", "better": "tie"}, {"id": "item-0002.2", "better": "tie"},
                    {"id": "item-0003.1", "better": "tie"}, {"id": "item-0003.2", "better": "tie"}]
        for c, want in (("N", (0, 1, 0)), ("U", (0, 0, 1))):
            sub = {**key, "items": {k: v for k, v in key["items"].items()
                                    if v["kind"] == "calibration" or self.classes[SID][v["line"]] == c}}
            t = B.J.tally(sub, verdicts)
            self.assertEqual((t["a"], t["b"], t["tie"]), want, c)
            self.assertTrue(t["calibration_ok"])


if __name__ == "__main__":
    if "--neuter" in sys.argv:
        sys.argv.remove("--neuter")
        B.POOL = True
        B.SAME_OFF = True
    unittest.main()
