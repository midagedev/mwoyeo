#!/usr/bin/env python3
"""How many names and terms of the memory a live recording carries in one Korean form, counted from the app's own translation log.
Run it isolated: `python3 -I count-live.py [--detail] [--json FILE] [--events EV.jsonl] <log.jsonl> [<log.jsonl> --events EV ...]`
(record.sh writes $OUT/<part>.jsonl, the log the app wrote while the lens read the stage, and <part>.events.jsonl, when each line was on screen).

The counting is the plates' (../plates/count.py, which imports the bench's film_consistency.py): each log becomes a run of the sequence
film-ja-ko-1, and for every name and term of the memory, over the lines whose text holds it, the distinct Korean renderings are counted
(1 = consistent; canonical = every line carries the memory's form). What is live-only:
  - a log line belongs to the stage line on screen at its time, or one of the two before it, whichever text it reads best (the player's
    `line` events); without events, to the next line of the sequence whose text it matches best, in order;
  - an entry whose original is the speaker's name is that line's name plate (counted apart: `plates`); the app logs a plate again only
    once it was gone 10 s (Core TranscriptRecorder.gap), and it translates an identical plate from its cache, so plates repeat;
  - the dialogue of a line is its other entries, in log order; `ocr` lists lines whose logged original differs from the sequence text."""
import argparse
import datetime
import difflib
import importlib.util
import json
import os
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


PLATES = load("plates_count", os.path.join(HERE, "..", "plates", "count.py"))
FC, S, SEQ_ID, squash = PLATES.FC, PLATES.S, PLATES.SEQ_ID, PLATES.squash
WATCH = ["九十九", "月涙石"]    # the two keys whose renderings the report lists line by line


def epoch(iso):
    return datetime.datetime.fromisoformat(iso).timestamp()


def windows(events):
    """[(line id, start epoch, end epoch)] from the player's `line` events; id 0 is the empty box."""
    shown = [(int(e["id"]), int(e["ms"]) / 1000.0) for e in events if e.get("k") == "line"]
    out = []
    for (lid, start), nxt in zip(shown, shown[1:] + [(None, float("inf"))]):
        if lid:
            out.append((lid, start, nxt[1]))
    return out


def similar(a, b):
    return difflib.SequenceMatcher(None, squash(a), squash(b)).ratio()


def assign(entries, seq, events):
    """line id -> [entry] in log order."""
    by_line = {l["id"]: [] for l in seq["lines"]}
    if events:
        # The line on screen at the entry's time, or one of the two before it: the log writes a line once it first has a usable
        # translation, which can come after the next line showed (a slow engine). Of those, the one whose text the entry reads best.
        spans = windows(events)
        text = {l["id"]: l for l in seq["lines"]}
        for e in entries:
            t = epoch(e["time"])
            at = next((k for k, (lid, a, b) in enumerate(spans) if a - 0.05 <= t < b), None)
            if at is None:
                continue
            near = [spans[k][0] for k in range(max(0, at - 2), at + 1)]
            best = max(reversed(near), key=lambda lid: max(similar(e["original"], text[lid]["text"]),
                                                           similar(e["original"], text[lid].get("speaker") or "")))
            by_line[best].append(e)
        return by_line
    order = [l for l in seq["lines"]]
    i = 0
    for e in entries:
        best = max(range(i, min(i + 4, len(order))), key=lambda j: max(similar(e["original"], order[j]["text"]),
                                                                       similar(e["original"], order[j].get("speaker") or "")), default=None)
        if best is None:
            break
        by_line[order[best]["id"]].append(e)
        i = best
    return by_line


def run_of(path, seq, events):
    entries = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
    by_line = assign(entries, seq, events)
    translations, plates, ocr, missing = {}, {}, {}, []
    for line in seq["lines"]:
        speaker, body = line.get("speaker"), []
        for e in by_line[line["id"]]:
            if speaker and similar(e["original"], speaker) >= 0.8:
                plates[line["id"]] = e["translation"]
            else:
                body.append(e)
        if not body:
            missing.append(line["id"])
        seen, parts = set(), []
        for e in body:
            if e["translation"] not in seen:
                seen.add(e["translation"])
                parts.append(e["translation"])
        translations[str(line["id"])] = " ".join(parts)
        read = "".join(e["original"] for e in body)
        if body and squash(read) != squash(line["text"]):
            ocr[line["id"]] = read
    engine = entries[0].get("engine", "?") if entries else "?"
    meta = {"engine": engine, "condition": os.path.splitext(os.path.basename(path))[0]}
    run = {"path": os.path.splitext(path)[0], "meta": meta, "outs": {SEQ_ID: {"id": SEQ_ID, "translations": translations}}}
    return run, plates, ocr, missing, len(entries)


def watched(run, seq, mem):
    """For each watched key: [(line id, the rendering found)] in line order."""
    out = {}
    for kind, src in FC.keys_of(seq, mem):
        if src not in WATCH:
            continue
        dst, accepted, wrong = FC.key_forms(seq, mem, kind, src)
        out[src] = [(l["id"], FC.rendering(S.translation_of(run, SEQ_ID, l["id"]), l["ref"], src, dst, accepted, wrong))
                    for l in seq["lines"] if src in l["text"]]
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("logs", nargs="+", help="the live jsonl logs (record.sh: $OUT/before-live.jsonl $OUT/after-live-hand.jsonl)")
    ap.add_argument("--events", action="append", default=[], help="the events file of each log, in the same order (optional)")
    ap.add_argument("--detail", action="store_true", help="list the renderings found per name and term")
    ap.add_argument("--json", help="write the numbers here")
    args = ap.parse_args(argv)
    if args.events and len(args.events) != len(args.logs):
        ap.error("give --events once per log, or not at all")
    seqs, mems = S.load_corpus(PLATES.BENCH)
    seq, mem = seqs[SEQ_ID], mems[SEQ_ID]
    rows, report = [], []
    for i, path in enumerate(args.logs):
        events = [json.loads(l) for l in open(args.events[i], encoding="utf-8")] if args.events else []
        run, plates, ocr, missing, n = run_of(path, seq, events)
        row = FC.measure(run, seq, mem)
        rows.append(row)
        report.append({"log": path, "entries": n, "missing": missing, "plates": PLATES.plate_forms(seq, plates),
                       "ocr": {str(k): v for k, v in ocr.items()},
                       "lost": {str(k): v for k, v in PLATES.lost_keys(seq, mem, ocr).items() if v},
                       "watched": watched(run, seq, mem)})
    keys = []
    for r in rows:
        keys += [k for k in r["keys"] if k not in keys]
    FC.print_table(rows, keys, sys.stdout)
    for r, rep in zip(rows, report):
        got, total = r["canonical"]
        print("\n%s: %d log entries; %d of %d keys in the memory's form on every line; lines with no dialogue entry: %s; ocr: %d of %d "
              "lines differ from the sequence text; keys lost by OCR: %s" % (
                  r["run"], rep["entries"], got, total, rep["missing"] or "none", len(rep["ocr"]), len(seq["lines"]),
                  ", ".join("L%s %s" % (k, "/".join(v)) for k, v in rep["lost"].items()) or "none"))
        print("  plates: " + ("; ".join(
            "%s -> %s" % (sp, ", ".join("%s x%d" % (f, n) for f, n in sorted(fs.items(), key=lambda fn: (-fn[1], fn[0]))))
            for sp, fs in rep["plates"].items()) or "none"))
        for src, found in rep["watched"].items():
            print("  %s: %s" % (src, ", ".join("L%d %s" % (lid, f or "-") for lid, f in found)))
    if args.detail:
        FC.print_detail(rows, sys.stdout)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump({"runs": rows, "report": report}, f, ensure_ascii=False, indent=1, default=list)
    return 0


if __name__ == "__main__":
    sys.exit(main())
