#!/usr/bin/env python3
"""Visible defects in what the lens showed, counted from the app's own translation log (record.sh writes $OUT/<part>.jsonl). Run isolated:
  python3 -I count-script.py [--detail] <log.jsonl>        exit 1 when the log holds no entry with furigana in its original
An entry is DIALOGUE when its original holds furigana in brackets (（かな）); name plates and other entries are not counted. A dialogue entry
has a visible defect when its translation shows
  leak   a parenthesis or a kana (the furigana reached the Korean, or the engine kept a reading beside its word), or
  name   구십구, the engine's reading of the name 九十九 as the number 99 (the name is つくも, ツクモ; the Korean form 츠쿠모).
The numbers are the same two rules the evidence (/tmp/film3/evidence.md) uses; a line is counted once per log entry."""
import argparse
import json
import re
import sys

KANA = re.compile(r"[ぁ-ゖァ-ヿ]")
FURIGANA = re.compile(r"（[ぁ-ゖ]+）")


def defects(original, translation):
    leak = bool(re.search(r"[(（]", translation) or KANA.search(translation))
    name = "九十九" in original and "구십구" in translation
    return leak, name


def count(entries):
    rows = []
    for e in entries:
        if not FURIGANA.search(e.get("original", "")):
            continue
        leak, name = defects(e["original"], e.get("translation", ""))
        rows.append((e["original"], e.get("translation", ""), leak, name))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("log")
    ap.add_argument("--detail", action="store_true")
    opts = ap.parse_args()
    entries = [json.loads(l) for l in open(opts.log, encoding="utf-8") if l.strip()]
    rows = count(entries)
    n = len(rows)
    leak, name = sum(r[2] for r in rows), sum(r[3] for r in rows)
    either = sum(r[2] or r[3] for r in rows)
    print("count: %d dialogue entries with furigana; visible defect: leak %d, name 구십구 %d, either %d" % (n, leak, name, either))
    if opts.detail:
        for original, translation, l, nm in rows:
            print("  %s%s %s\n      -> %s" % ("L" if l else "-", "N" if nm else "-", original, translation))
    return 0 if n else 1


if __name__ == "__main__":
    sys.exit(main())
