#!/usr/bin/env python3
"""Every replacement site of a term script, over what the app translated. Run isolated:
  python3 -I check-sites.py <script.js> <dir of --render .out files | log.jsonl> [more ...] [--show]
The script (an `after(src, dst, ctx)` with a term table) runs in node on every (source block, Korean block) the app produced; each place where it changed the
Korean is a SITE: the old text, the new text and what stands after it. A site is BAD when
  particle   the new text is followed by a particle of the wrong form (consonant ending: 이 은 을 과; vowel ending: 가 는 를 와), e.g. 대조군가, 부호 검정는
  partial    the old text sat inside a longer word (a Hangul syllable before it, or after it that is not a particle, an ending or a space)
  sense      the source block does not hold the English term the Korean text stands for (기억 = memory in "the user memory", not recall)
Exit 1 when a site is BAD (the numbers are on the last line). FAILURE MODES IT BLOCKS: a term table that makes a wrong particle or edits a word it
only contained (`제어` inside `제어하다`), found by running the script on the whole paper, not on the paragraph it was written for.
`--show` prints every site, good or bad."""
import difflib
import json
import os
import re
import subprocess
import sys

HAN = re.compile(r"[가-힣]")
# The English the Korean old text stands for: a site whose source block does not hold it is a different sense of the Korean word (기억 = memory in
# "the user memory", not recall) and BAD. Keys are the start of an entry's old text.
SENSE = [("제어", r"control"), ("컨트롤", r"control"), ("사인", r"sign test"), ("땅의", r"ground truth"), ("기본 진실", r"ground truth"), ("정확성", r"precision"),
         ("기억", r"recall"), ("보류", r"held[- ]out|hold-?out")]
PARTICLES_C = "이은을과"      # after a consonant
PARTICLES_V = "가는를와"      # after a vowel
OKAY_AFTER = ("이며", "이다", "이고", "이라", "에서", "에게", "에는", "에도", "에", "의", "로", "으로", "도", "만", "를", "을", "은", "는", "가", "이", "와", "과",
              "입니다", "인", "이므로", "일", "이었", "였", "처럼", "보다", "까지", "부터", "라고", "라는", "이라는", "란", "이란", "나", "이나", "를", "야")


def pairs_of(path):
    """[(src, dst)] from a render .out (a source line, then `    → translation`), a directory of them, or a transcript .jsonl."""
    if os.path.isdir(path):
        return [p for f in sorted(os.listdir(path)) if f.endswith((".out", ".jsonl")) for p in pairs_of(os.path.join(path, f))]
    if path.endswith(".jsonl"):
        rows = [json.loads(l) for l in open(path, encoding="utf-8") if l.strip()]
        return [(r["original"], r["translation"]) for r in rows]
    lines = open(path, encoding="utf-8").read().split("\n")
    out, i = [], 0
    while i < len(lines):
        if lines[i].startswith("  ") and not lines[i].startswith("    →") and i + 1 < len(lines) and lines[i + 1].startswith("    →"):
            out.append((lines[i].strip(), lines[i + 1].strip()[2:].strip()))
            i += 2
        else:
            i += 1
    return out


def run_script(script, pairs):
    harness = ("const fs = require('fs'); const after = new Function(fs.readFileSync(process.argv[1], 'utf8') + '; return after')();\n"
               "const rows = JSON.parse(fs.readFileSync(0, 'utf8')); const ctx = {app: '', profile: 'x', source: 'en', target: 'ko'};\n"
               "console.log(JSON.stringify(rows.map(([s, d]) => after(s, d, ctx))));")
    r = subprocess.run(["node", "-e", harness, script], input=json.dumps(pairs, ensure_ascii=False), capture_output=True, encoding="utf-8")
    if r.returncode:
        sys.exit("check-sites: node failed: " + r.stderr[-600:])
    return json.loads(r.stdout)


def final_consonant(word):
    last = word.rstrip()[-1]
    return "가" <= last <= "힣" and (ord(last) - 0xAC00) % 28 != 0


def table_of(script):
    """The script's term table: [(old, new)] in order (every ["old", "new"] pair of the source)."""
    return re.findall(r"\[\s*\"([^\"]+)\"\s*,\s*\"([^\"]+)\"\s*\]", open(script, encoding="utf-8").read())


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show = "--show" in sys.argv
    script, sources = args[0], args[1:]
    pairs = [p for s in sources for p in pairs_of(s)]
    table = table_of(script)
    after = run_script(script, pairs)
    sites = bad = 0
    for (src, dst), shown in zip(pairs, after):
        cur = dst
        for old, new in table:                       # the script's own order and its own replacements, one site at a time
            at = cur.find(old)
            while at >= 0:
                flags = []
                before, right = cur[at - 1:at] if at else "", cur[at + len(old):at + len(old) + 4]
                if before and HAN.match(before):
                    flags.append("partial-left")
                if right and HAN.match(right[0]) and not any(right.startswith(k) for k in OKAY_AFTER) and not new_ends_with_particle(old, new):
                    flags.append("partial-right")
                nxt = cur[at + len(old):at + len(old) + 1]
                if nxt and nxt in PARTICLES_C + PARTICLES_V:
                    want = PARTICLES_C if final_consonant(new) else PARTICLES_V
                    if nxt not in want and not (nxt == "이" and cur[at + len(old):at + len(old) + 2] in ("이며", "이다", "이고", "이라")):
                        flags.append("particle")
                want_en = next((rx for key, rx in SENSE if old.startswith(key)), None)
                if want_en and not re.search(want_en, src, flags=re.I):
                    flags.append("sense")
                if new[-1:] in PARTICLES_C + PARTICLES_V and old[-1:] in PARTICLES_C + PARTICLES_V:
                    stem = new[:-1]
                    if new[-1] not in (PARTICLES_C if final_consonant(stem) else PARTICLES_V):
                        flags.append("particle-in-table")
                sites += 1
                bad += bool(flags)
                if flags or show:
                    print("%s%s  [%s -> %s]  ...%s|%s|%s...\n      src: %s" % ("BAD " if flags else "ok  ", ",".join(flags), old, new, cur[max(0, at - 12):at], old,
                                                                            right, src[:90]))
                cur = cur[:at] + new + cur[at + len(old):]
                at = cur.find(old, at + len(new))
        if cur != shown:
            sys.exit("check-sites: the script's output differs from the model of its table for: %s" % src[:80])
    print("check-sites: %d blocks, %d sites, %d bad" % (len(pairs), sites, bad))
    sys.exit(1 if bad else 0)


def new_ends_with_particle(old, new):
    """An entry that carries its particle (제어가 -> 대조군이): what follows it starts a new word."""
    return old[-1:] in PARTICLES_C + PARTICLES_V and new[-1:] in PARTICLES_C + PARTICLES_V


main()
