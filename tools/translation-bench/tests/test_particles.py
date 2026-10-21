#!/usr/bin/env python3
"""Particle checker unit checks (round both-bench): `python3 -I tests/test_particles.py [--neuter]`.

A target written into a source line must keep its Korean particle right. The checks: one hand-broken line the checker catches
(a vowel-final name with the consonant form, a consonant-final one with the vowel form, a final ㄹ with 으로, ...), one correct line
each it passes, a name that merely starts like a particle ("소고과장님") it leaves alone, a one-character Han row inside a longer word,
and the same through `check_run` on a mini run record. With `--neuter` the particle table is switched off and this test must FAIL:
run-all.sh runs it that way and fails if it passes, or the test would pass on a checker that finds nothing."""
import importlib.util
import os
import sys
import unittest

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.dirname(HERE)
_spec = importlib.util.spec_from_file_location("particles", os.path.join(BENCH, "particles.py"))
P = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(P)


def found(output, target):
    return [(b["found"], b["want"]) for b in P.particle_breaks(output, target)]


class Particles(unittest.TestCase):
    def test_a_hand_broken_line_is_caught(self):
        # 펠 ends in ㄹ: the subject particle is 이, not 가
        self.assertEqual(found("펠가 먼저 말했다.", "펠"), [("가", "이")])

    def test_the_correct_line_passes(self):
        self.assertEqual(found("펠이 먼저 말했다.", "펠"), [])

    def test_every_pair_of_the_table_both_ways(self):
        cases = [  # (output, target, wrong form found, right form)
            ("카이은 갔다.", "카이", "은", "는"), ("쏜는 갔다.", "쏜", "는", "은"),
            ("카이이 갔다.", "카이", "이", "가"), ("쏜가 갔다.", "쏜", "가", "이"),
            ("카이을 봤다.", "카이", "을", "를"), ("쏜를 봤다.", "쏜", "를", "을"),
            ("소고과 함께 갔다.", "소고", "과", "와"), ("쏜와 함께 갔다.", "쏜", "와", "과"),
            ("카이아, 와.", "카이", "아", "야"), ("민야, 와.", "민", "야", "아"),
            ("카이이랑 갔다.", "카이", "이랑", "랑"), ("펠랑 갔다.", "펠", "랑", "이랑"),
            ("카이으로 갔다.", "카이", "으로", "로"), ("쏜로 갔다.", "쏜", "로", "으로"), ("펠으로 갔다.", "펠", "으로", "로"),
        ]
        for out, target, wrong, right in cases:
            self.assertEqual(found(out, target), [(wrong, right)], out)
        right_ones = [("카이는 갔다.", "카이"), ("쏜은 갔다.", "쏜"), ("카이가 갔다.", "카이"), ("쏜이 갔다.", "쏜"), ("카이를 봤다.", "카이"),
                      ("쏜을 봤다.", "쏜"), ("소고와 갔다.", "소고"), ("쏜과 갔다.", "쏜"), ("카이야, 와.", "카이"), ("민아, 와.", "민"),
                      ("카이랑 갔다.", "카이"), ("펠이랑 갔다.", "펠"), ("카이로 갔다.", "카이"), ("쏜으로 갔다.", "쏜"), ("펠로 갔다.", "펠")]
        for out, target in right_ones:
            self.assertEqual(found(out, target), [], out)

    def test_a_name_that_only_starts_like_a_particle_is_left_alone(self):
        self.assertEqual(found("소고과장님이 오셨다.", "소고"), [])
        self.assertEqual(found("카이은행에 갔다.", "카이"), [])
        self.assertEqual(found("카이 이름이 뭐야?", "카이"), [])   # a space ends the name
        self.assertEqual(found("카이가요", "카이"), [])           # a second particle after the right one
        self.assertEqual(found("카이은요", "카이"), [("은", "는")])   # ... and after the wrong one

    def test_a_target_that_is_not_hangul_has_no_particle_to_break(self):
        self.assertEqual(found("Seoyoon이 왔다.", "Seoyoon"), [])

    def test_every_occurrence_is_looked_at(self):
        self.assertEqual(found("펠가 말했고 펠이 웃었고 펠를 봤다.", "펠"), [("가", "이"), ("를", "을")])

    def test_a_kana_left_right_after_the_target_is_caught(self):
        self.assertEqual(P.kana_after("사쿠の肩을 잡았다.", "사쿠"), ["사쿠の肩을 잡았"])
        self.assertEqual(P.kana_after("텟사이 が 말했다.", "텟사이"), ["텟사이 が 말했다"])   # a space between does not hide it
        self.assertEqual(P.kana_after("사쿠는 어깨를 잡았다. 'の'", "사쿠"), [])
        self.assertEqual(P.kana_after("사쿠와 カイ", "사쿠"), [])                        # a kana later in the line is not next to the name

    def test_a_one_character_han_row_inside_a_longer_word(self):
        self.assertEqual(P.one_char_in_word("王様が来た", "王"), ["王様が来"])
        self.assertEqual(P.one_char_in_word("宿は海が取ってくれる", "海"), [])
        self.assertEqual(P.one_char_in_word("海外に行く", "海"), ["海外に行"])
        self.assertEqual(P.one_char_in_word("ユウが来た", "ユ"), [])   # kana is not Han
        self.assertEqual(P.one_char_in_word("王様が来た", "王様"), [])   # two characters are not this rule

    def test_check_run_reads_a_replaced_record(self):
        seqs = {"s": {"id": "s", "source": "ja", "target": "ko", "lines": [{"id": 1, "text": "王様がペルに会った", "ref": ""}]}}
        run = {"outs": {"s": {"translations": {"1": "왕이 펠가 만났다"}, "requests": [
            {"replaced": [{"id": 1, "text": "왕様が펠に会った", "spans": [["王", "왕"], ["ペル", "펠"]]}]}]}}}
        rows = P.check_run(run, seqs)
        self.assertEqual([(r["target"], [b["found"] for b in r["particle"]], bool(r["one_char"]), r["kept"]) for r in rows],
                         [("왕", [], True, True), ("펠", ["가"], False, True)])
        self.assertEqual([len(r["kana_after"]) for r in rows], [0, 0])


if __name__ == "__main__":
    if "--neuter" in sys.argv:
        sys.argv.remove("--neuter")
        P.NEUTER = True
    unittest.main()
