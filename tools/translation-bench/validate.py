#!/usr/bin/env python3
"""Checks the sequences and memories of the bench. Run it isolated: `python3 -I validate.py [--root DIR] [--only ID...]`.

It enforces the format in README.md ("Sequences, memories and probes") and the corpus gates of the spec: at least 12
sequences of 15-40 lines, at least 250 probes, at least 30 % of them decidable only from the memory. Every probe checks
itself: its `check` must pass on the line's hand-written `ref` and fail on its `bad` text; every line of a Korean
target whose speaker has a `speaks_to` level must have a `ref` at that level; evidence strings must sit on the side
the probe says (`memory` evidence in no line, `lines` evidence in a `need` line and not in the memory).
Exit 0 with no errors; the summary is printed either way."""
import argparse
import importlib.util
import json
import os
import sys

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("score", os.path.join(HERE, "score.py"))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

KINDS = {"chat", "subtitles", "game", "docs"}
TYPES = {"name", "pronoun", "speech_level", "term", "register"}
BY = {"memory", "lines", "none"}
LANGS = {"ja", "zh", "en", "ko"}
MEMORY_TOKEN_LIMIT = 150
MIN_SEQUENCES, MIN_PROBES, MIN_MEMORY_SHARE = 12, 250, 0.30


def validate_sequence(seq, mem, errors, warnings):
    sid = seq.get("id", "?")

    def err(msg):
        errors.append("%s: %s" % (sid, msg))

    def warn(msg):
        warnings.append("%s: %s" % (sid, msg))

    for k in ("id", "kind", "source", "target", "title", "lines", "screens", "probes"):
        if k not in seq:
            err("missing field %s" % k)
            return
    if seq["kind"] not in KINDS:
        err("kind %r not in %s" % (seq["kind"], sorted(KINDS)))
    if seq["source"] not in LANGS or seq["target"] not in LANGS or seq["source"] == seq["target"]:
        err("source/target must be two different codes of %s" % sorted(LANGS))
    lines = seq["lines"]
    if not 15 <= len(lines) <= 40:
        err("%d lines, want 15-40" % len(lines))
    ids = [l.get("id") for l in lines]
    if ids != list(range(1, len(lines) + 1)):
        err("line ids must be 1..n in order")
        return
    by_id = {l["id"]: l for l in lines}
    for l in lines:
        for k in ("text", "ref"):
            if not isinstance(l.get(k), str) or not l[k].strip():
                err("line %d has no %s" % (l["id"], k))
    noise = [l["id"] for l in lines if l.get("noise")]
    if not noise:
        err("no OCR-noise line (a line with a `noise` note: a cut word, a stray symbol)")

    # speakers and memory
    names = {e.get("name") for e in mem.get("entities", [])}
    speakers = {l["speaker"] for l in lines if l.get("speaker")}
    if seq["kind"] in ("chat", "game") and not speakers:
        err("a %s sequence needs speakers" % seq["kind"])
    for sp in speakers:
        if sp not in names:
            err("speaker %r is not an entity of the memory" % sp)
    for l in lines:
        if l.get("to") is not None and l["to"] not in names:
            err("line %d: `to` %r is not an entity" % (l["id"], l["to"]))
    if len(speakers) == 2 and seq["target"] == "ko":
        pass  # the other speaker is the default addressee; expected_level handles uniform levels only
    if mem:
        for e in mem.get("entities", []):
            for to, level in (e.get("speaks_to") or {}).items():
                if level not in S.LEVEL_CLASS:
                    err("entity %s speaks_to %s: %r is not one of %s" % (e["name"], to, level, sorted(S.LEVEL_CLASS)))
                if to not in names:
                    err("entity %s speaks_to unknown entity %s" % (e["name"], to))
        size = S.est_tokens(S.render_memory(mem))
        if size > MEMORY_TOKEN_LIMIT:
            err("memory renders to about %.0f tokens, limit %d" % (size, MEMORY_TOKEN_LIMIT))
    else:
        err("no memory file memory/%s.json" % sid)

    # screens: reading order, overlap allowed, new lines contiguous and in order
    seen_max = 0
    for i, scr in enumerate(seq["screens"]):
        if not scr or scr != sorted(set(scr)) or any(x not in by_id for x in scr):
            err("screen %d: ids must exist, ascend and not repeat" % (i + 1))
            continue
        new = [x for x in scr if x > seen_max]
        if new and new != list(range(seen_max + 1, seen_max + 1 + len(new))):
            err("screen %d: new lines %s do not continue after line %d" % (i + 1, new, seen_max))
        if not new:
            warn("screen %d shows no new line" % (i + 1))
        seen_max = max(seen_max, max(scr))
        if seq["kind"] in ("chat", "docs") and len(scr) > 12:
            warn("screen %d shows %d lines" % (i + 1, len(scr)))
    if seen_max != len(lines):
        err("screens do not cover every line (last shown %d of %d)" % (seen_max, len(lines)))

    # speech level of the refs
    judged = scored = 0
    for l in lines:
        exp = S.expected_level(seq, mem, l)
        if seq["target"] == "ko" and l.get("speaker"):
            ent = next((e for e in mem.get("entities", []) if e.get("name") == l["speaker"]), None)
            if ent and ent.get("speaks_to") and exp is None:
                err("line %d: the addressee's level is ambiguous; add `to` (speaks_to levels differ)" % l["id"])
        if not exp:
            continue
        judged += 1
        got = S.line_level(l["ref"])
        if got is None:
            continue
        scored += 1
        if got != exp:
            err("line %d: ref is %s, the speaker's level is %s: %s" % (l["id"], got, exp, l["ref"]))
    if judged and scored < 0.7 * judged:
        warn("only %d of %d ref lines have an ending the classifier can judge" % (scored, judged))

    # probes
    memtext = json.dumps(mem, ensure_ascii=False)
    pids = set()
    for p in seq["probes"]:
        pid = p.get("id", "?")

        def perr(msg, pid=pid):
            err("probe %s: %s" % (pid, msg))

        if pid in pids:
            perr("duplicate id")
        pids.add(pid)
        if p.get("type") not in TYPES:
            perr("type %r not in %s" % (p.get("type"), sorted(TYPES)))
        if p.get("by") not in BY:
            perr("by %r not in %s" % (p.get("by"), sorted(BY)))
            continue
        if p.get("line") not in by_id:
            perr("line %r does not exist" % p.get("line"))
            continue
        line = by_id[p["line"]]
        chk = p.get("check")
        if not isinstance(chk, dict) or not chk or set(chk) - S.CHECK_KEYS:
            perr("check must be a non-empty dict of %s" % sorted(S.CHECK_KEYS))
            continue
        if p["type"] == "speech_level":
            if seq["target"] != "ko":
                perr("speech_level probes need a Korean target")
            if set(chk) != {"level"} or chk["level"] not in ("hapsyo", "haeyo", "banmal"):
                perr("a speech_level check is exactly {level: hapsyo|haeyo|banmal}")
            exp = S.expected_level(seq, mem, line)
            if exp != chk.get("level"):
                perr("check level %s differs from the memory's level %s for that line" % (chk.get("level"), exp))
        if seq.get("speaker_visible", True) is False and p["type"] == "speech_level" and p["by"] == "memory":
            perr("speaker_visible is false: the memory cannot say who speaks, so it cannot decide a speech level")
        if p["type"] in ("name", "term", "register") and not p.get("key"):
            perr("name, term and register probes need a `key` (the entity or term they test)")
        if p["type"] in ("name", "term") and not (chk.get("none") or chk.get("none_w") or chk.get("nregex")):
            warn("probe %s has no explicit wrong form in none/none_w; carry-over cannot see its failures" % pid)
        if not S.check_probe(chk, line["ref"]):
            perr("check fails on the line's own ref: %s" % line["ref"])
        bad = p.get("bad")
        if bad is None and p.get("bad_sub"):
            frm, to = p["bad_sub"]
            if frm not in line["ref"]:
                perr("bad_sub %r is not in the ref" % frm)
            else:
                bad = line["ref"].replace(frm, to)
        if not isinstance(bad, str):
            perr("needs `bad` (a wrong rendering of the line) or `bad_sub` [from, to]")
        elif S.check_probe(chk, bad):
            perr("check passes on the bad text: %s" % bad)
        if S.check_probe(chk, line["text"]) and seq["source"] != seq["target"]:
            perr("check passes on the untranslated source text")
        if line.get("noise"):
            warn("probe %s sits on the noise line %d" % (pid, line["id"]))

        ev = p.get("evidence", [])
        if p["by"] == "none":
            if p.get("need") or p.get("mem") or ev:
                perr("by none takes no need/mem/evidence")
        elif p["by"] == "memory":
            if p.get("need"):
                perr("by memory takes no `need` lines")
            paths = p.get("mem") or []
            if not paths:
                perr("by memory needs `mem` paths")
            for path in paths:
                if S.resolve_memory_path(mem, path) in (None, ""):
                    perr("mem path %s does not resolve" % path)
            if not ev:
                perr("by memory needs `evidence` strings")
            for e in ev:
                if e not in memtext:
                    perr("evidence %r is not in the memory" % e)
                for l in lines:
                    if e in l["text"]:
                        perr("evidence %r also occurs in line %d, so the lines decide it" % (e, l["id"]))
                        break
        else:
            need = p.get("need") or []
            if not need or any(n not in by_id or n >= p["line"] for n in need):
                perr("by lines needs `need`: ids of earlier lines")
                continue
            if p.get("mem"):
                perr("by lines takes no `mem`")
            if not ev:
                perr("by lines needs `evidence` strings")
            for e in ev:
                if not any(e in by_id[n]["text"] for n in need):
                    perr("evidence %r is in none of the need lines %s" % (e, need))
                if e in memtext:
                    perr("evidence %r is also in the memory, so the memory decides it" % e)

    # keys used by one entity must exist
    return


def summarize(seqs, mems, out):
    probes = [(s, p) for s in seqs for p in s["probes"]]
    n = len(probes)
    print("sequences %d, lines %d, probes %d" % (len(seqs), sum(len(s["lines"]) for s in seqs), n), file=out)

    def count(keyf):
        d = {}
        for s, p in probes:
            d[keyf(s, p)] = d.get(keyf(s, p), 0) + 1
        return d

    for title, keyf in (("by type", lambda s, p: p["type"]), ("by evidence", lambda s, p: p["by"]),
                        ("by pair", lambda s, p: s["source"] + ">" + s["target"]), ("by kind", lambda s, p: s["kind"])):
        print("  %-12s %s" % (title, "  ".join("%s %d" % kv for kv in sorted(count(keyf).items()))), file=out)
    dist = {}
    for s, p in probes:
        d = S.probe_distance(s, p)
        if d is not None:
            b = S.distance_bucket(d)
            dist[b] = dist.get(b, 0) + 1
    print("  %-12s %s" % ("by distance", "  ".join("%s %d" % (name, dist.get(name, 0)) for _, _, name in S.DISTANCE_BUCKETS)),
          file=out)
    mem_n = sum(1 for _, p in probes if p["by"] == "memory")
    print("  memory-only share %.1f%% (%d of %d)" % (100.0 * mem_n / n if n else 0, mem_n, n), file=out)
    toks = [S.est_tokens(S.render_memory(mems[s["id"]])) for s in seqs if mems.get(s["id"])]
    if toks:
        print("  memory size  min %.0f max %.0f mean %.0f est tokens" % (min(toks), max(toks), sum(toks) / len(toks)),
              file=out)
    print("  %-30s %5s %6s %6s %6s %5s" % ("sequence", "lines", "probes", "memory", "lines", "none"), file=out)
    for s in seqs:
        c = count_by(s)
        print("  %-30s %5d %6d %6d %6d %5d" % (s["id"], len(s["lines"]), len(s["probes"]), c["memory"], c["lines"], c["none"]),
              file=out)


def count_by(s):
    c = {"memory": 0, "lines": 0, "none": 0}
    for p in s["probes"]:
        c[p["by"]] = c.get(p["by"], 0) + 1
    return c


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", default=HERE)
    ap.add_argument("--only", nargs="*", help="check only these sequence ids and skip the corpus-wide gates")
    args = ap.parse_args(argv)
    seqs, mems = S.load_corpus(args.root)
    errors, warnings = [], []
    chosen = [s for sid, s in seqs.items() if not args.only or sid in args.only]
    for s in chosen:
        validate_sequence(s, mems.get(s["id"], {}), errors, warnings)
    summarize(chosen, mems, sys.stdout)
    if not args.only:
        probes = [p for s in chosen for p in s["probes"]]
        if len(chosen) < MIN_SEQUENCES:
            errors.append("corpus: %d sequences, want at least %d" % (len(chosen), MIN_SEQUENCES))
        if len(probes) < MIN_PROBES:
            errors.append("corpus: %d probes, want at least %d" % (len(probes), MIN_PROBES))
        mem_share = sum(1 for p in probes if p["by"] == "memory") / max(1, len(probes))
        if mem_share < MIN_MEMORY_SHARE:
            errors.append("corpus: memory-only probes are %.1f%%, want at least %.0f%%" % (100 * mem_share, 100 * MIN_MEMORY_SHARE))
        pairs = {(s["kind"], s["source"], s["target"]) for s in chosen}
        for want in (("chat", "ja", "ko"), ("chat", "zh", "ko"), ("chat", "en", "ko"), ("chat", "ko", "en"),
                     ("subtitles", "ja", "ko"), ("subtitles", "en", "ko"), ("game", "ja", "ko"), ("game", "zh", "en"),
                     ("docs", "en", "ko"), ("docs", "ja", "en")):
            if want not in pairs:
                errors.append("corpus: no %s sequence for %s>%s" % want)
    for w in warnings:
        print("warning:", w)
    for e in errors:
        print("ERROR:", e)
    print("validate: %d errors, %d warnings" % (len(errors), len(warnings)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
