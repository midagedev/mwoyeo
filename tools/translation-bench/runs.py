#!/usr/bin/env python3
"""Preserves bench runs as content: `python3 -I runs.py add|verify|list`.

A run is the output of one `bench-run run` (one condition on one engine): `meta.json` plus one file per sequence. The
experiment data is the product of this bench, so every run that is worth a number goes to `runs/<name>/` with a
`MANIFEST.json` that says what produced it. **A run directory is never overwritten; a rerun gets a new name.**

  runs.py add <run dir> --command "<exact command line>" [--name N] [--engine engines/x.json] [--kind model|oracle|smoke]
                        [--binary PATH] [--env K=V ...] [--note TEXT]
      copies the run to runs/<name>/ (refuses when that exists), writes MANIFEST.json (source, engine config without
      keys, model name and digest, condition, date, command, score.py summary, file hashes)
  runs.py verify [runs/<name> ...]
      every run has a MANIFEST.json, its files hash as recorded, `score.py` reproduces the recorded summary from the
      copied files (scored against the corpus snapshot the run was preserved with, `runs/_corpus/<hash>/`, so a later
      edit of a sequence or probe cannot break an old run), and an oracle run scores 100 % of its probes. Exit 0 when
      all hold; a live corpus that moved on is a note, not a failure.
  runs.py list
      one line per preserved run (condition, engine, probes correct, date, kind)
  `--root DIR` (before the subcommand) works on another bench directory (the unit checks use a scratch copy).

Manifest layout is documented in README.md (section "Runs").
"""
import argparse
import contextlib
import datetime
import glob
import hashlib
import importlib.util
import io
import json
import os
import platform
import shutil
import subprocess
import sys
import urllib.request

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
MANIFEST_VERSION = 1
KINDS = ("model", "oracle", "smoke")
OLLAMA_TAGS = "http://127.0.0.1:11434/api/tags"
REQUIRED = ("manifest_version", "run", "kind", "note", "date", "seconds", "condition", "layout", "jobs", "batch_size",
            "command", "engine", "model", "source", "corpus", "score_summary", "score", "files")


def load_score():
    spec = importlib.util.spec_from_file_location("score", os.path.join(HERE, "score.py"))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_hash(files):
    """One digest over {relative path: sha256}: stable under file order, changes when any file or name changes."""
    h = hashlib.sha256()
    for rel in sorted(files):
        h.update(("%s\0%s\n" % (rel, files[rel])).encode("utf-8"))
    return h.hexdigest()


def runner_files(root):
    out = {}
    pkg = os.path.join(root, "runner")
    cands = [os.path.join(pkg, "Package.swift")] + sorted(glob.glob(os.path.join(pkg, "Sources", "**", "*.swift"), recursive=True))
    for p in cands:
        if os.path.exists(p):
            out[os.path.relpath(p, root)] = sha256_file(p)
    return out


def corpus_files(root):
    out = {}
    for sub in ("sequences", "memory"):
        for p in sorted(glob.glob(os.path.join(root, sub, "*.json"))):
            out[os.path.relpath(p, root)] = sha256_file(p)
    pr = os.path.join(root, "prices.json")
    if os.path.exists(pr):
        out["prices.json"] = sha256_file(pr)
    return out


def snapshot_corpus(root, files, digest):
    """Copy the corpus a run was scored against to runs/_corpus/<digest>/ once (content-addressed); returns its relpath."""
    rel = os.path.join("_corpus", digest[:16])
    dest = os.path.join(root, "runs", rel)
    if not os.path.isdir(dest):
        for f in files:
            os.makedirs(os.path.dirname(os.path.join(dest, f)), exist_ok=True)
            shutil.copy2(os.path.join(root, f), os.path.join(dest, f))
    return rel


def run_cmd(args, cwd=None):
    try:
        r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=30)
        return r.stdout.strip() if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def iso_from_mtime(path):
    return datetime.datetime.fromtimestamp(os.path.getmtime(path), datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def modified_after(files, root, started):
    """Files whose mtime is later than the run's start: the tree may have changed while the run was going."""
    return sorted(rel for rel in files if iso_from_mtime(os.path.join(root, rel)) > started)


def scrub_engine(cfg):
    """The engine config as recorded: a key value never goes in (only `keyEnv`, the NAME of the variable, stays)."""
    return {k: v for k, v in cfg.items() if not ("key" in k.lower() and k.lower() != "keyenv")}


def ollama_model(cfg):
    """Name, digest and size of an Ollama model as `ollama list` shows it (the full digest from the same server)."""
    base = cfg.get("baseURL", "")
    if cfg.get("kind") != "openAICompatible" or not (base.startswith("http://127.0.0.1:11434") or base.startswith("http://localhost:11434")):
        return {"name": cfg.get("model"), "source": "not a local Ollama engine; digest not recorded"}
    try:
        with urllib.request.urlopen(OLLAMA_TAGS, timeout=10) as resp:
            tags = json.load(resp)
    except (OSError, ValueError):
        return {"name": cfg.get("model"), "source": "ollama /api/tags unreachable at preservation time; digest not recorded"}
    for m in tags.get("models", []):
        if m.get("name") == cfg.get("model") or m.get("model") == cfg.get("model"):
            d = m.get("digest", "")
            return {"name": m.get("name"), "digest": d, "ollama_list_id": d[:12], "size_bytes": m.get("size"),
                    "modified_at": m.get("modified_at"), "details": m.get("details"),
                    "source": "ollama /api/tags (the data behind `ollama list`) at preservation time"}
    return {"name": cfg.get("model"), "source": "model not in `ollama list` at preservation time; digest not recorded"}


def machine():
    return {"chip": run_cmd(["sysctl", "-n", "machdep.cpu.brand_string"]),
            "memory_bytes": int(run_cmd(["sysctl", "-n", "hw.memsize"]) or 0) or None,
            "macos": run_cmd(["sw_vers", "-productVersion"]), "kernel": platform.release(),
            "ollama": (run_cmd(["ollama", "--version"]) or "").replace("ollama version is ", "") or None}


def score_run(S, run_dir, root):
    """(summary lines, numbers) of one run by itself, exactly as `score.py <run dir>` prints and `--json` writes."""
    seqs, mems = S.load_corpus(root)
    s = S.summarize(S.load_run(run_dir), seqs, mems, S.load_prices(root))
    buf = io.StringIO()
    S.print_summary(s, buf)
    slim = {k: v for k, v in s.items() if k != "_probes"}
    numbers = json.loads(json.dumps(slim, ensure_ascii=False, default=lambda o: sorted(o) if isinstance(o, set) else o))
    return buf.getvalue().rstrip("\n").split("\n"), numbers


def run_files(run_dir):
    return {os.path.relpath(p, run_dir): sha256_file(p) for p in sorted(glob.glob(os.path.join(run_dir, "*.json")))
            if os.path.basename(p) != "MANIFEST.json"}


# ---------------------------------------------------------------------------------------------------------------------
# add

def cmd_add(args):
    S = load_score()
    root = args.root
    src = os.path.abspath(args.run_dir)
    meta_path = os.path.join(src, "meta.json")
    if not os.path.isfile(meta_path):
        print("error: %s has no meta.json (not a run directory)" % src, file=sys.stderr)
        return 2
    name = args.name or os.path.basename(src.rstrip("/"))
    dest = os.path.join(root, "runs", name)
    if os.path.exists(dest):
        print("error: runs/%s exists. A run is never overwritten; a rerun gets a new name (--name)." % name, file=sys.stderr)
        return 3
    meta = S.load_json(meta_path)
    started = meta.get("started", "")
    engine_cfg = {}
    if args.engine:
        engine_cfg = S.load_json(os.path.join(root, args.engine) if not os.path.isabs(args.engine) else args.engine)
    rf = runner_files(root)
    cf = corpus_files(root)
    git_head = run_cmd(["git", "-C", root, "rev-parse", "HEAD"]) or "unknown (not a git checkout)"
    dirty = run_cmd(["git", "-C", root, "status", "--porcelain", "--", "."])
    source = {
        "git_head": git_head,
        "tree": ("uncommitted tools/translation-bench tree" if dirty else "tools/translation-bench as committed at git_head"),
        "runner_sha256": tree_hash(rf), "runner_files": rf,
        "runner_files_modified_after_run_start": modified_after(rf, root, started) if started else None,
        "binary": None,
    }
    if args.binary:
        source["binary"] = {"path": args.binary, "sha256": sha256_file(args.binary), "mtime": iso_from_mtime(args.binary),
                            "note": "hash of the binary at preservation time"}
    digest = tree_hash(cf)
    corpus = {"sequences": len(glob.glob(os.path.join(root, "sequences", "*.json"))), "sha256": digest, "files": cf,
              "snapshot": snapshot_corpus(root, cf, digest),
              "files_modified_after_run_start": modified_after(cf, root, started) if started else None}
    env = dict(kv.split("=", 1) for kv in (args.env or []))

    # copy first (no overwrite: dest does not exist), then score the COPY, so the manifest describes what is stored
    os.makedirs(os.path.join(root, "runs"), exist_ok=True)
    shutil.copytree(src, dest, ignore=shutil.ignore_patterns("MANIFEST.json"))
    summary, numbers = score_run(S, dest, os.path.join(root, "runs", corpus["snapshot"]))
    corpus["probes"] = numbers["probes"]["n"]
    manifest = {
        "manifest_version": MANIFEST_VERSION, "run": name, "kind": args.kind,
        "note": args.note or "", "date": started, "seconds": meta.get("seconds"),
        "preserved": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "condition": meta.get("condition"), "layout": meta.get("layout"), "jobs": meta.get("jobs"),
        "batch_size": meta.get("batch_size"), "sequences": meta.get("sequences"),
        "command": args.command, "command_cwd": "tools/translation-bench", "env": env,
        "engine": {"config_file": args.engine, "config": scrub_engine(engine_cfg), "name": meta.get("engine"),
                   "kind": meta.get("kind")},
        "model": ollama_model(engine_cfg) if args.kind != "oracle" and engine_cfg else {"name": meta.get("model")},
        "machine": machine(),
        "source": source, "corpus": corpus,
        "score_summary": summary, "score": numbers,
        "files": run_files(dest),
    }
    with open(os.path.join(dest, "MANIFEST.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
        f.write("\n")
    print("preserved runs/%s (%d files, %s, %s)" % (name, len(manifest["files"]), manifest["condition"], args.kind))
    return 0


# ---------------------------------------------------------------------------------------------------------------------
# verify

def verify_run(S, run_dir, root):
    """(problems, notes) of one preserved run; no problems when the run is intact and its summary reproduces."""
    bad, notes = [], []
    mp = os.path.join(run_dir, "MANIFEST.json")
    if not os.path.isfile(mp):
        return ["no MANIFEST.json"], notes
    try:
        m = S.load_json(mp)
    except ValueError as e:
        return ["MANIFEST.json is not JSON: %s" % e], notes
    for k in REQUIRED:
        if k not in m:
            bad.append("manifest lacks %r" % k)
    if bad:
        return bad, notes
    if m["kind"] not in KINDS:
        bad.append("kind %r not in %s" % (m["kind"], KINDS))
    if m["run"] != os.path.basename(run_dir.rstrip("/")):
        bad.append("manifest names run %r but the directory is %r" % (m["run"], os.path.basename(run_dir.rstrip("/"))))
    if m["kind"] == "model" and not m["model"].get("digest") and "not a local Ollama" not in m["model"].get("source", ""):
        bad.append("model run without a model digest")
    if m["kind"] == "oracle" and "not model output" not in m["note"]:
        bad.append("oracle manifest must say it is a scorer self-check, not model output")
    if not m["command"]:
        bad.append("empty command")
    if not m["source"].get("git_head") or not m["source"].get("runner_sha256"):
        bad.append("source lacks git_head or runner_sha256")
    have = run_files(run_dir)
    for rel in sorted(set(have) | set(m["files"])):
        if rel not in have:
            bad.append("recorded file missing: %s" % rel)
        elif rel not in m["files"]:
            bad.append("file not in the manifest: %s" % rel)
        elif have[rel] != m["files"][rel]:
            bad.append("file changed since preservation: %s" % rel)
    snap = os.path.join(os.path.dirname(os.path.abspath(run_dir)), m["corpus"].get("snapshot") or "")
    if not m["corpus"].get("snapshot") or not os.path.isdir(snap):
        bad.append("corpus snapshot missing: %s" % m["corpus"].get("snapshot"))
        return bad, notes
    if tree_hash(corpus_files(snap)) != m["corpus"]["sha256"]:
        bad.append("corpus snapshot %s does not hash to the recorded corpus.sha256" % m["corpus"]["snapshot"])
        return bad, notes
    if tree_hash(corpus_files(root)) != m["corpus"]["sha256"]:
        notes.append("the live corpus differs from this run's; scored against %s" % m["corpus"]["snapshot"])
    summary, numbers = score_run(S, run_dir, snap)
    if summary != m["score_summary"]:
        diff = [(a, b) for a, b in zip(m["score_summary"], summary) if a != b][:2]
        bad.append("score.py summary differs from the manifest (the corpus snapshot is the recorded one, so the scorer "
                   "changed): %s" % diff)
    elif numbers != m["score"]:
        bad.append("score.py numbers differ from the manifest")
    if m["kind"] == "oracle" and numbers["probes"]["ok"] != numbers["probes"]["n"]:
        bad.append("oracle run scores %d of %d probes, not 100 %%" % (numbers["probes"]["ok"], numbers["probes"]["n"]))
    return bad, notes


def run_dirs(root, given):
    if given:
        return [os.path.abspath(g) for g in given]
    return sorted(p for p in glob.glob(os.path.join(root, "runs", "*"))
                  if os.path.isdir(p) and not os.path.basename(p).startswith("_"))


def cmd_verify(args):
    S = load_score()
    dirs = run_dirs(args.root, args.runs)
    if not dirs:
        print("runs: none preserved yet")
        return 0
    failed = 0
    for d in dirs:
        bad, notes = verify_run(S, d, args.root)
        print("%s  %s" % ("FAIL" if bad else "ok  ", os.path.basename(d)))
        for b in bad:
            print("      " + b)
        for n in notes:
            print("      note: " + n)
        failed += bool(bad)
    print("runs: %d checked, %d failed" % (len(dirs), failed))
    return 1 if failed else 0


# ---------------------------------------------------------------------------------------------------------------------
# list

def cmd_list(args):
    S = load_score()
    for d in run_dirs(args.root, None):
        mp = os.path.join(d, "MANIFEST.json")
        if not os.path.isfile(mp):
            print("%-22s NO MANIFEST" % os.path.basename(d))
            continue
        m = S.load_json(mp)
        p = m["score"]["probes"]
        print("%-22s %-6s %-9s %-18s probes %3d/%3d %-6s %s" % (
            m["run"], m["condition"], m["kind"], m["engine"].get("name"), p["ok"], p["n"],
            "%.1f%%" % (100.0 * p["ok"] / p["n"]) if p["n"] else "-", m["date"]))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=HERE, help="the bench directory (sequences/, memory/, runs/, prices.json)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add", help="preserve a run")
    a.add_argument("run_dir")
    a.add_argument("--name", help="runs/<name>; default: the run directory's name")
    a.add_argument("--command", required=True, help="the exact command line that produced the run")
    a.add_argument("--engine", help="the engine config file used (relative to the bench directory)")
    a.add_argument("--kind", choices=KINDS, default="model")
    a.add_argument("--binary", help="the bench-run binary that produced it (its hash is recorded)")
    a.add_argument("--env", action="append", help="K=V environment of the run (never a key)")
    a.add_argument("--note", help="what the run is, and anything a reader needs (load, caveats)")
    v = sub.add_parser("verify", help="check preserved runs")
    v.add_argument("runs", nargs="*")
    sub.add_parser("list", help="list preserved runs")
    args = ap.parse_args(argv)
    args.root = os.path.abspath(args.root)
    return {"add": cmd_add, "verify": cmd_verify, "list": cmd_list}[args.cmd](args)


if __name__ == "__main__":
    sys.exit(main())
