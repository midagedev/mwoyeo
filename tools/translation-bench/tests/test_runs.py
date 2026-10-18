#!/usr/bin/env python3
"""Run preservation checks: `python3 -I tests/test_runs.py`.

FAIL-first, each on a scratch bench directory built from the golden mini-sequence: a run is copied with a manifest and
verifies; a second `add` under the same name is refused and leaves the stored run untouched; and `verify` fails on a
run without a manifest, on a changed file, on a changed recorded summary, on a file the manifest does not know, on a
changed corpus snapshot and on an oracle run that does not score every probe; a live corpus that moved on does not break
an old run (it is scored against the snapshot it was preserved with). An engine config never keeps a key value."""
import contextlib
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


R = load("runs")


def runs_main(*argv):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = R.main(list(argv))
    return rc, out.getvalue(), err.getvalue()


class Preserve(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="tb-runs-")
        for d in ("sequences", "memory"):
            shutil.copytree(os.path.join(GOLDEN, d), os.path.join(self.root, d))
        shutil.copy(os.path.join(GOLDEN, "prices.json"), self.root)
        with open(os.path.join(self.root, "engine.json"), "w", encoding="utf-8") as f:
            json.dump({"name": "e", "kind": "openAICompatible", "baseURL": "https://example.invalid/v1", "model": "m",
                       "keyEnv": "SOME_KEY_VARIABLE", "apiKey": "sk-should-never-be-stored"}, f)
        self.src = os.path.join(self.root, "src-correct")
        shutil.copytree(os.path.join(GOLDEN, "runs", "correct"), self.src)

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def add(self, name="kept", kind="model", src=None, note="a unit-test run"):
        return runs_main("--root", self.root, "add", src or self.src, "--name", name, "--command", "bench-run run ...",
                         "--engine", "engine.json", "--kind", kind, "--note", note)

    def manifest(self, name="kept"):
        with open(os.path.join(self.root, "runs", name, "MANIFEST.json"), encoding="utf-8") as f:
            return json.load(f)

    def verify(self, *names):
        return runs_main("--root", self.root, "verify", *[os.path.join(self.root, "runs", n) for n in names])

    def test_add_writes_a_manifest_that_verifies(self):
        rc, out, err = self.add()
        self.assertEqual(rc, 0, err)
        m = self.manifest()
        for k in R.REQUIRED:
            self.assertIn(k, m)
        self.assertEqual(m["condition"], "correct")
        self.assertEqual(m["score"]["probes"]["n"], 8)
        self.assertEqual(m["files"].keys(), {"meta.json", "mini.json"})
        self.assertIn("8 correct", " ".join(m["score_summary"]))
        rc, out, _ = self.verify("kept")
        self.assertEqual(rc, 0, out)
        self.assertIn("ok    kept", out)

    def test_an_engine_config_never_keeps_a_key_value(self):
        self.add()
        with open(os.path.join(self.root, "runs", "kept", "MANIFEST.json"), encoding="utf-8") as f:
            text = f.read()
        self.assertNotIn("sk-should-never-be-stored", text)
        self.assertNotIn("apiKey", text)
        self.assertEqual(self.manifest()["engine"]["config"]["keyEnv"], "SOME_KEY_VARIABLE")

    def test_a_run_is_never_overwritten(self):
        self.assertEqual(self.add()[0], 0)
        before = self.manifest()
        # a different source under the same name: refused, the stored run is byte for byte what it was
        other = os.path.join(self.root, "src-other")
        shutil.copytree(os.path.join(GOLDEN, "runs", "swapped-name"), other)
        rc, out, err = self.add(src=other)
        print("FAIL-first: second add under the same name -> rc %d: %s" % (rc, err.strip()))
        self.assertEqual(rc, 3)
        self.assertIn("never overwritten", err)
        self.assertEqual(self.manifest(), before)
        self.assertEqual(self.verify("kept")[0], 0)
        # and the same source under a new name is a new run
        self.assertEqual(self.add(name="kept-2", src=other)[0], 0)
        self.assertEqual(self.manifest("kept-2")["score"]["probes"]["ok"], 6)

    def test_verify_fails_without_a_manifest(self):
        self.add()
        os.remove(os.path.join(self.root, "runs", "kept", "MANIFEST.json"))
        rc, out, _ = self.verify("kept")
        print("FAIL-first: " + out.strip().splitlines()[0] + " / " + out.strip().splitlines()[1].strip())
        self.assertEqual(rc, 1)
        self.assertIn("no MANIFEST.json", out)

    def test_verify_fails_on_a_changed_file(self):
        self.add()
        p = os.path.join(self.root, "runs", "kept", "mini.json")
        with open(p, encoding="utf-8") as f:
            s = f.read()
        with open(p, "w", encoding="utf-8") as f:
            f.write(s.replace("바다", "해양", 1) if "바다" in s else s + " ")
        rc, out, _ = self.verify("kept")
        self.assertEqual(rc, 1)
        self.assertIn("file changed since preservation: mini.json", out)

    def test_verify_fails_on_a_file_the_manifest_does_not_know(self):
        self.add()
        shutil.copy(os.path.join(self.root, "runs", "kept", "mini.json"), os.path.join(self.root, "runs", "kept", "extra.json"))
        rc, out, _ = self.verify("kept")
        self.assertEqual(rc, 1)
        self.assertIn("file not in the manifest: extra.json", out)

    def test_verify_fails_when_the_recorded_summary_does_not_reproduce(self):
        self.add()
        mp = os.path.join(self.root, "runs", "kept", "MANIFEST.json")
        m = self.manifest()
        m["score_summary"][1] = "probes 8: 7 correct = 87.5%"
        with open(mp, "w", encoding="utf-8") as f:
            json.dump(m, f, ensure_ascii=False)
        rc, out, _ = self.verify("kept")
        print("FAIL-first: " + [l for l in out.splitlines() if "differs" in l][0].strip()[:160])
        self.assertEqual(rc, 1)
        self.assertIn("score.py summary differs from the manifest", out)
        self.assertIn("the corpus snapshot is the recorded one", out)

    def test_a_run_is_scored_against_its_own_corpus_snapshot(self):
        self.add()
        snap = os.path.join(self.root, "runs", self.manifest()["corpus"]["snapshot"])
        self.assertTrue(os.path.isfile(os.path.join(snap, "sequences", "mini.json")))
        # the live corpus moves on (a probe dropped): the old run still reproduces, against its snapshot, and says so
        p = os.path.join(self.root, "sequences", "mini.json")
        with open(p, encoding="utf-8") as f:
            seq = json.load(f)
        seq["probes"] = seq["probes"][:-1]
        with open(p, "w", encoding="utf-8") as f:
            json.dump(seq, f, ensure_ascii=False)
        rc, out, _ = self.verify("kept")
        self.assertEqual(rc, 0, out)
        self.assertIn("note: the live corpus differs from this run's", out)
        # a second run under the new corpus gets its own snapshot; the old one is kept
        self.assertEqual(self.add(name="kept-new")[0], 0)
        self.assertNotEqual(self.manifest("kept-new")["corpus"]["snapshot"], self.manifest()["corpus"]["snapshot"])
        self.assertEqual(self.manifest("kept-new")["score"]["probes"]["n"], 7)
        self.assertEqual(self.manifest()["score"]["probes"]["n"], 8)
        self.assertEqual(self.verify("kept", "kept-new")[0], 0)

    def test_verify_fails_on_a_changed_corpus_snapshot(self):
        self.add()
        p = os.path.join(self.root, "runs", self.manifest()["corpus"]["snapshot"], "sequences", "mini.json")
        with open(p, encoding="utf-8") as f:
            seq = json.load(f)
        seq["probes"] = seq["probes"][:-1]
        with open(p, "w", encoding="utf-8") as f:
            json.dump(seq, f, ensure_ascii=False)
        rc, out, _ = self.verify("kept")
        print("FAIL-first: " + [l for l in out.splitlines() if "snapshot" in l][0].strip()[:120])
        self.assertEqual(rc, 1)
        self.assertIn("does not hash to the recorded corpus.sha256", out)

    def test_an_oracle_run_must_say_so_and_score_every_probe(self):
        rc, _, _ = self.add(name="o1", kind="oracle", note="not model output: a scorer self-check")
        self.assertEqual(rc, 0)
        rc, out, _ = self.verify("o1")
        self.assertEqual(rc, 0, out)   # the golden "correct" run scores 8 of 8
        other = os.path.join(self.root, "src-swapped")
        shutil.copytree(os.path.join(GOLDEN, "runs", "swapped-name"), other)
        self.assertEqual(self.add(name="o2", kind="oracle", src=other, note="not model output: a scorer self-check")[0], 0)
        rc, out, _ = self.verify("o2")
        print("FAIL-first: " + [l for l in out.splitlines() if "oracle" in l][0].strip())
        self.assertEqual(rc, 1)
        self.assertIn("oracle run scores 6 of 8 probes, not 100 %", out)
        self.assertEqual(self.add(name="o3", kind="oracle", note="a plain note")[0], 0)
        rc, out, _ = self.verify("o3")
        self.assertIn("must say it is a scorer self-check", out)

    def test_list_prints_one_line_per_run(self):
        self.add()
        rc, out, _ = runs_main("--root", self.root, "list")
        self.assertEqual(rc, 0)
        self.assertEqual(len(out.strip().splitlines()), 1)
        self.assertIn("probes   8/  8", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
