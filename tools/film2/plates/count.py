#!/usr/bin/env python3
"""How many names and terms of the memory the real renders carry in one Korean form, before and after.
Run it isolated: `python3 -I count.py [--detail] [--json FILE] <out dir>...`   (the dirs render.sh wrote: out/before out/after-hand ...)

The renders' outputs are the `->` lines of each L<id>.out (the blocks the app translated: the dialogue, and the name plate when the
app translated it). Each dir becomes a run of the translation bench's sequence `film-ja-ko-1`, and the counting is the bench's own, imported
from tools/translation-bench/film_consistency.py (`measure`, `print_table`, `print_detail`: for every name and term of the memory,
over the lines whose text holds it, the distinct Korean renderings; 1 = consistent; `canonical` = every line carries the memory's form).
What differs from a bench run, and is printed beside the table:
  - the engine read the OCR text of the plate, not the sequence's text: `ocr` lists the lines whose dialogue block differs from the sequence
    text and which key characters were lost (a key whose characters were lost cannot come out in the memory's form);
  - a line's translation is its blocks except the speaker's plate, in reading order; the plate is counted apart (`plates`): the speaker
    names as the plates show them, distinct renderings per speaker."""
import argparse
import difflib
import importlib.util
import json
import os
import re
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.normpath(os.path.join(HERE, "..", "..", "translation-bench"))
SEQ_ID = "film-ja-ko-1"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FC = load("film_consistency", os.path.join(BENCH, "film_consistency.py"))
S = FC.S


def blocks_of(path):
    """[(source, translation)] of one .out in order: `  <source>` followed by `    -> <translation>` (a kept block has a third line)."""
    out, src = [], None
    for raw in open(path, encoding="utf-8").read().split("\n"):
        if raw.startswith("    → "):
            if src is not None:
                out.append((src, raw[len("    → "):]))
            src = None
        elif raw.startswith("  ") and not raw.startswith("    "):
            src = raw[2:]
    return out


def squash(s):
    return "".join(s.split())


def run_of(directory, seq):
    """A bench-shaped run from a render dir, and the per-line facts the table cannot show."""
    translations, plates, ocr, missing = {}, {}, {}, []
    for line in seq["lines"]:
        p = os.path.join(directory, "L%d.out" % line["id"])
        if not os.path.exists(p):
            missing.append(line["id"])
            continue
        speaker = line.get("speaker")
        body = []
        for src, tr in blocks_of(p):
            if speaker and squash(src) == squash(speaker):
                plates[line["id"]] = tr
            else:
                body.append((src, tr))
        translations[str(line["id"])] = " ".join(tr for _, tr in body)
        if body:
            read = "".join(src for src, _ in body)
            if squash(read) != squash(line["text"]):
                ocr[line["id"]] = read
    # The engine the render used, from the engine.json render.sh wrote beside the plates.
    try:
        with open(os.path.join(directory, "engine.json"), encoding="utf-8") as f:
            engine = json.load(f)["engine"]["name"]
    except (OSError, ValueError, KeyError):
        engine = "?"
    meta = {"engine": engine, "condition": os.path.basename(os.path.normpath(directory))}
    return {"path": directory, "meta": meta, "outs": {SEQ_ID: {"id": SEQ_ID, "translations": translations}}}, plates, ocr, missing


def lost_keys(seq, mem, ocr):
    """Per OCR-damaged line: the keys of the memory that the line's text holds and the OCR text does not."""
    out = {}
    for lid, read in ocr.items():
        text = next(l["text"] for l in seq["lines"] if l["id"] == lid)
        gone = [src for _, src in FC.keys_of(seq, mem) if src in text and src not in read]
        out[lid] = gone
    return out


def plate_forms(seq, plates):
    """Speaker name -> {rendering: count} of the plates the app translated."""
    speakers = {l["id"]: l["speaker"] for l in seq["lines"] if l.get("speaker")}
    forms = {}
    for lid, tr in plates.items():
        forms.setdefault(speakers[lid], {}).setdefault(tr, 0)
        forms[speakers[lid]][tr] += 1
    return forms


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dirs", nargs="+", help="render dirs (out/before, out/after-hand, ...)")
    ap.add_argument("--detail", action="store_true", help="list the renderings found per name and term")
    ap.add_argument("--json", help="write the numbers here")
    args = ap.parse_args(argv)
    seqs, mems = S.load_corpus(BENCH)
    seq, mem = seqs[SEQ_ID], mems[SEQ_ID]
    rows, report = [], []
    for d in args.dirs:
        run, plates, ocr, missing = run_of(d, seq)
        if missing:
            print("%s: no .out for lines %s" % (d, missing), file=sys.stderr)
            return 2
        row = FC.measure(run, seq, mem)
        rows.append(row)
        report.append({"dir": d, "plates": plate_forms(seq, plates), "ocr": {str(k): v for k, v in ocr.items()},
                       "lost": {str(k): v for k, v in lost_keys(seq, mem, ocr).items() if v}})
    keys = []
    for r in rows:
        keys += [k for k in r["keys"] if k not in keys]
    FC.print_table(rows, keys, sys.stdout)
    for r, rep in zip(rows, report):
        got, total = r["canonical"]
        print("\n%s: %d of %d keys in the memory's form on every line; ocr: %d of %d dialogue blocks differ from the sequence text; keys lost by OCR: %s" % (
            r["run"], got, total, len(rep["ocr"]), len(seq["lines"]),
            ", ".join("L%s %s" % (k, "/".join(v)) for k, v in rep["lost"].items()) or "none"))
        if rep["plates"]:
            print("  plates the app translated: " + "; ".join(
                "%s -> %s" % (sp, ", ".join("%s x%d" % (f, n) for f, n in sorted(fs.items(), key=lambda fn: (-fn[1], fn[0]))))
                for sp, fs in rep["plates"].items()))
        else:
            print("  plates the app translated: none")
    if args.detail:
        FC.print_detail(rows, sys.stdout)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({"runs": rows, "report": report}, f, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
