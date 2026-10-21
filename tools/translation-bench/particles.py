#!/usr/bin/env python3
"""Korean particle check for source rewriting (round both-bench, design names-and-context section 10).
Run it isolated: `python3 -I particles.py [--root DIR] [--json FILE] [--neuter] <run dir>...`

A run made with `bench-run run --apply both|both-names` records, per request, the item lines whose source got a row's target written
into it (`replaced`: id, rewritten text, `[matched, target]` spans). For each such line this script finds every written target in the
engine's output and looks at what follows it:

  particle  the particle written right after the target must fit the target's last syllable (batchim table below). The pairs are
            (after a final consonant, after a vowel): 은/는, 이/가, 을/를, 과/와, 아/야, 이랑/랑, 으로/로. After a final ㄹ the
            consonant form of 으로/로 is 로, every other pair takes its consonant form. A particle counts only when it stands directly
            after the target (no space) and is followed by a space, punctuation, the end of the line or a short second particle
            (요, 도, 만, 의, 에, ...): "소고과장님" is a name and a title, not 소고 + 과.
  kana      a kana right after a written target ("사쿠の肩を"): the engine kept the source's own particle or word next to the name
            instead of translating it, a failure mode only a source rewrite has (ko targets)
  one-char  a one-character Han row replaced inside a longer word (王 in 王様): the character next to the match in the SOURCE line is
            Han too (design section 10: a one-character source costs a hint row where a replacement breaks the word).

Only ko targets are checked for particles (other targets have no particles to break). `--neuter` switches the particle table off: the
unit test (tests/test_particles.py) must fail with it, or it would pass on a checker that finds nothing."""
import argparse
import importlib.util
import json
import os
import sys
import unicodedata

sys.dont_write_bytecode = True   # `-I` ignores PYTHONDONTWRITEBYTECODE; keep __pycache__ out of the tree
HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("score", os.path.join(HERE, "score.py"))
S = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(S)

# (form after a final consonant, form after a vowel). 으로/로 is special: after a final ㄹ it takes 로 like a vowel does.
PAIRS = [("은", "는"), ("이", "가"), ("을", "를"), ("과", "와"), ("아", "야"), ("이랑", "랑"), ("으로", "로")]
RIEUL = 8   # jongseong index of ㄹ
# what may follow a particle without it being the start of another word: a second particle ("와의", "로부터", "가요")
AFTER = ("요", "도", "만", "의", "서", "께", "처럼", "보다", "부터", "까지", "조차", "마저")
PUNCT = set(".,!?…:;'\"“”‘’()[]{}「」『』、。！？・~-—–")
NEUTER = False
# every written form with the pair it belongs to, longest first, so 이랑 is read before 이 and 으로 before 으
FORMS = sorted(((f, pair) for pair in PAIRS for f in pair), key=lambda fp: -len(fp[0]))


def hangul(ch):
    return 0xAC00 <= ord(ch) <= 0xD7A3


def final_of(text):
    """None when the last character is not a Hangul syllable; else 0 (vowel-final), RIEUL or the jongseong index."""
    t = unicodedata.normalize("NFC", text).rstrip()
    if not t or not hangul(t[-1]):
        return None
    return (ord(t[-1]) - 0xAC00) % 28


def boundary(rest):
    """Whether `rest` (what stands after a particle) ends the word: nothing, a space, punctuation, a non-Hangul character or a
    second particle."""
    if not rest or rest[0].isspace() or rest[0] in PUNCT or not hangul(rest[0]):
        return True
    return any(rest.startswith(a) for a in AFTER)


def right_form(pair, final):
    """The form of `pair` a target with this final takes."""
    with_consonant, with_vowel = pair
    if pair == ("으로", "로"):
        return with_vowel if final in (0, RIEUL) else with_consonant
    return with_vowel if final == 0 else with_consonant


def particles_after(output, target):
    """Every particle standing directly after `target` in `output`, right or wrong: [{"target", "found", "want", "ok", "at", "context"}]."""
    if NEUTER:
        return []
    out = unicodedata.normalize("NFC", output or "")
    tgt = unicodedata.normalize("NFC", target or "")
    final = final_of(tgt)
    if final is None:
        return []
    found_all = []
    start = 0
    while (i := out.find(tgt, start)) >= 0:
        start = i + len(tgt)
        rest = out[start:]
        found = next(((f, pair) for f, pair in FORMS if rest.startswith(f)), None)
        if found is None:
            continue
        form, pair = found
        if not boundary(rest[len(form):]):
            continue
        want = right_form(pair, final)
        found_all.append({"target": tgt, "found": form, "want": want, "ok": form == want, "at": i,
                          "context": out[max(0, i - 6):start + 6]})
    return found_all


def kana_after(output, target):
    """The contexts where a hiragana or katakana stands right after `target` in `output` (the source's own text left next to the name)."""
    if NEUTER:
        return []
    out = unicodedata.normalize("NFC", output or "")
    tgt = unicodedata.normalize("NFC", target or "")
    hits = []
    start = 0
    while tgt and (i := out.find(tgt, start)) >= 0:
        start = i + len(tgt)
        rest = out[start:].lstrip(" ")
        if rest and 0x3040 <= ord(rest[0]) <= 0x30FF:
            hits.append(out[max(0, i - 4):start + 6])
    return hits


def particle_breaks(output, target):
    """The wrong particles standing directly after `target` in `output` (`particles_after` without the right ones)."""
    return [b for b in particles_after(output, target) if not b["ok"]]


def is_han(ch):
    cp = ord(ch)
    return 0x4E00 <= cp <= 0x9FFF or 0x3400 <= cp <= 0x4DBF or 0xF900 <= cp <= 0xFAFF


def one_char_in_word(source, matched):
    """The contexts where a one-character Han `matched` stands next to another Han character in `source` (a longer word)."""
    if len(matched) != 1 or not is_han(matched):
        return []
    hits = []
    for i, ch in enumerate(source):
        if ch != matched:
            continue
        near = (source[i - 1] if i > 0 else "", source[i + 1] if i + 1 < len(source) else "")
        if any(c and is_han(c) for c in near):
            hits.append(source[max(0, i - 3):i + 4])
    return hits


def check_run(run, seqs, plan=None):
    """Every written target of a run's rewritten lines: a list of rows {seq, line, target, matched, particle: [breaks], one_char: [..]}.
    `plan` (another run of the same sequences) supplies the `replaced` records when `run` has none: the same targets looked for in a
    run that did not write them, which is what the rate of a run's own particle breaks is read against."""
    rows = []
    for sid, out in sorted(run["outs"].items()):
        seq = seqs.get(sid)
        if not seq:
            continue
        by_id = {l["id"]: l for l in seq["lines"]}
        source = (plan or run)["outs"].get(sid, out)
        for req in source["requests"]:
            for rep in req.get("replaced") or []:
                src = by_id[rep["id"]]["text"]
                tr = out["translations"].get(str(rep["id"]), "")
                for matched, target in rep["spans"]:
                    rows.append({
                        "seq": sid, "line": rep["id"], "matched": matched, "target": target, "output": tr,
                        "particle": particle_breaks(tr, target) if seq["target"] == "ko" else [],
                        "with_particle": len(particles_after(tr, target)) if seq["target"] == "ko" else 0,
                        "kana_after": kana_after(tr, target) if seq["target"] == "ko" else [],
                        "one_char": one_char_in_word(src, matched),
                        "kept": S.nfc(target).casefold() in S.nfc(tr).casefold()})
    return rows


def main(argv=None):
    global NEUTER
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", help="run directories made with --apply both or both-names")
    ap.add_argument("--root", default=HERE, help="the bench directory (sequences/)")
    ap.add_argument("--json", help="write the rows here")
    ap.add_argument("--neuter", action="store_true", help="switch the particle table off (the unit test must fail with it)")
    args = ap.parse_args(argv)
    NEUTER = args.neuter
    seqs, _ = S.load_corpus(args.root)
    result = {}
    for path in args.runs:
        run = S.load_run(path)
        rows = check_run(run, seqs)
        name = os.path.basename(os.path.normpath(path))
        result[name] = rows
        broken = [r for r in rows if r["particle"]]
        one = [r for r in rows if r["one_char"]]
        print("%s: %d written targets, %d kept in the output, %d particle breaks, %d kana left after a target, %d one-character rows inside a longer word"
              % (name, len(rows), sum(r["kept"] for r in rows), sum(len(r["particle"]) for r in rows), sum(len(r["kana_after"]) for r in rows), len(one)))
        for r in broken:
            for b in r["particle"]:
                print("  particle %s/%s line %d: %s + %s, wants %s  ...%s..." % (r["seq"], r["line"], r["line"], b["target"], b["found"], b["want"], b["context"]))
        for r in rows:
            for c in r["kana_after"]:
                print("  kana %s/%s: %s ...%s..." % (r["seq"], r["line"], r["target"], c))
        for r in one:
            print("  one-char %s/%s: %s -> %s inside %s" % (r["seq"], r["line"], r["matched"], r["target"], " | ".join(r["one_char"])))
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(result, f, ensure_ascii=False, indent=1)
    return 0


if __name__ == "__main__":
    sys.exit(main())
