#!/usr/bin/env python3
"""Did a render dir come out the way its settings say? `python3 -I verify.py <settings.json> <out dir> [--app BUNDLE_ID]`  Exit 1 when not.
Three things, each of which a past run got wrong (the render path once sent no memory at all, and wrote no app into the log):
  1. every L<id>.rc is 0;
  2. every line of log.jsonl carries `app` = the stage's bundle ID (the transcript knows which app was in front);
  3. the memory reached the engine's request, read from the kept requests/*.request.json:
     - the settings hold a profile for the app with a note: every request's system message has "User's note for this app: <note>", and
       every entry of the profile whose `src` is in the request's text has its row "<src> -> <dst>" in the user message;
     - the settings hold no profile for the app: no request has a note and none has a memory row."""
import argparse
import glob
import json
import os
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("settings")
    ap.add_argument("out")
    ap.add_argument("--app", default="dev.midagedev.film.lumiere")
    a = ap.parse_args()
    bad = []

    rcs = sorted(glob.glob(os.path.join(a.out, "L*.rc")), key=lambda p: int(os.path.basename(p)[1:-3]))
    nonzero = [os.path.basename(p)[:-3] for p in rcs if open(p).read().strip() != "0"]
    if nonzero:
        bad.append("rc not 0: %s" % nonzero)
    print("verify: %d renders, rc 0 in %d" % (len(rcs), len(rcs) - len(nonzero)))

    log = [json.loads(l) for l in open(os.path.join(a.out, "log.jsonl"), encoding="utf-8") if l.strip()]
    wrong = [i + 1 for i, row in enumerate(log) if row.get("app") != a.app]
    if wrong or not log:
        bad.append("log.jsonl: %d lines, app is not %s on lines %s" % (len(log), a.app, wrong[:10]))
    print("verify: log.jsonl %d lines, app=%s on %d" % (len(log), a.app, len(log) - len(wrong)))

    settings = json.load(open(a.settings, encoding="utf-8"))
    profile = next((p for p in settings.get("appProfiles", []) if p.get("bundleID") == a.app), None)
    note = (profile or {}).get("note") or ""
    entries = (profile or {}).get("entries", [])
    seen = with_note = with_rows = rows_expected = rows_found = 0
    for p in sorted(glob.glob(os.path.join(a.out, "requests", "*.request.json"))):
        body = json.load(open(p, encoding="utf-8"))
        system = next((m["content"] for m in body["messages"] if m["role"] == "system"), "")
        user = next((m["content"] for m in body["messages"] if m["role"] == "user"), "")
        try:
            asked = " ".join(t["text"] for t in json.loads(user)["translate"])
        except (ValueError, KeyError, TypeError):
            asked = user
        seen += 1
        with_note += ("User's note for this app: " in system)
        with_rows += ('"memory"' in user)
        for e in entries:
            if e["src"] in asked:
                rows_expected += 1
                rows_found += ("%s -> %s" % (e["src"], e["dst"]) in user)
    if profile and note:
        if with_note != seen:
            bad.append("%d of %d requests lack the note %r" % (seen - with_note, seen, note))
        if rows_found != rows_expected:
            bad.append("%d of %d memory rows are missing from the requests" % (rows_expected - rows_found, rows_expected))
    elif with_note or with_rows:
        bad.append("settings hold no profile for %s but %d requests carry a note and %d a memory" % (a.app, with_note, with_rows))
    print("verify: %d requests; note in %d, memory in %d; memory rows found %d of %d expected" % (seen, with_note, with_rows, rows_found, rows_expected))

    for b in bad:
        print("verify: FAIL " + b)
    print("verify: %s" % ("FAIL" if bad else "OK"))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
