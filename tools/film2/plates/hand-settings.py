#!/usr/bin/env python3
"""The memory of a translation-bench sequence as an app profile in a settings.json: `python3 -I hand-settings.py [--bundle ID] <memory.json> <out settings.json>`
It is the bench's own conversion (BenchKit `Conditions.swift` `note`, `card` and `rows`) written as the settings file the app reads:
the profile's note is the memory's document fields joined by "; ", each entity is a `person` row (gender m/f/n, role as the row's note, reading,
who it speaks to and how: 반말 casual, 해요체 polite, 합쇼체 formal), each term a `term` row. The profile's name is the memory's window app.
The film's final "after" settings are written by Claude's own pass over the translation log; this is the hand-made preview of them."""
import argparse
import json
import sys

REGISTER = {"반말": "casual", "해요체": "polite", "합쇼체": "formal"}
GENDER = {"male": "m", "female": "f", "nonbinary": "n"}


def profile(mem, bundle):
    doc = mem.get("document") or {}
    win = mem.get("window") or {}
    entries = []
    for e in mem.get("entities", []):
        row = {"src": e["name"], "dst": e.get("dst") or e["name"], "kind": "person"}
        if e.get("gender") in GENDER:
            row["gender"] = GENDER[e["gender"]]
        if e.get("role"):
            row["note"] = e["role"]
        if e.get("reading"):
            row["reading"] = e["reading"]
        to = [{"to": k, "register": REGISTER[v]} for k, v in sorted(e.get("speaks_to", {}).items(), key=lambda kv: [ord(c) for c in kv[0]])
              if v in REGISTER]
        if to:
            row["addressing"] = to
        entries.append(row)
    entries += [{"src": t["src"], "dst": t["dst"], "kind": "term"} for t in mem.get("terms", [])]
    return {"bundleID": bundle, "appName": win.get("app") or bundle, "source": "ja", "target": "ko",
            "note": "; ".join(x for x in (doc.get("title"), doc.get("domain"), doc.get("summary")) if x), "entries": entries}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bundle", default="dev.midagedev.film.lumiere")
    ap.add_argument("memory")
    ap.add_argument("out")
    a = ap.parse_args()
    mem = json.load(open(a.memory, encoding="utf-8"))
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump({"appProfiles": [profile(mem, a.bundle)]}, f, ensure_ascii=False, indent=2)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
