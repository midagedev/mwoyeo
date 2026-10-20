#!/usr/bin/env python3
"""Rewrite a fixed read the way the app now cuts its words: a Latin run inside a CJK word is one word.

The H2 / H3 reads are fixed inputs. Their ocr.jsonl holds, per line, the words Vision gave for the text of that line: the
offsets of the word in the line's text (characters, not bytes: a CJK character's word covers one character), its box and its text.
The app used to split a word that holds a CJK character into its single characters, so a URL, a path or an identifier inside a
ja / zh line reached the keep rules as one letter per box (Shared/VisionExec.swift, wordRanges; the keep recall for URLs on H3
was 0.04 of 1841 words). The app now keeps the Latin runs of such a word together and splits only the CJK characters. This
script rewrites the reads of a dir so the rules see what the app sees now: the consecutive single-character words of a line
that touch in the text become one word, the union of their boxes. Nothing else changes: the pictures are linked, the html and the
other files are copied, the text of the lines is not touched.

  usage: resegment.py <read dir> <out dir>     rewrite the reads of a dir into another one
         resegment.py --words <text>            the words of a text, one a line (the app's new wordRanges)
         resegment.py --labels <in> <out>       a labels file whose blocks' words are merged the same way (the judge pipeline
                                                aligns the truth's words with the read's words by position: they must be one list)
"""
import json
import os
import shutil
import sys

# isCJK (Shared/VisionExec.swift:170): the same ranges, so the same characters are CJK here.
CJK_RANGES = ((0x3040, 0x30FF), (0x3400, 0x9FFF), (0xF900, 0xFAFF), (0xFF00, 0xFFEF), (0x3000, 0x303F))
# Character.isWhitespace (Unicode White_Space), the set Swift splits on.
WHITESPACE = set("\t\n\v\f\r \x85\xa0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200a"
                 "\u2028\u2029\u202f\u205f\u3000")


def is_cjk(ch):
    """True when any of the character's scalars is in a CJK range (isCJK, Shared/VisionExec.swift:170)."""
    for cp in [ord(c) for c in ch]:
        for lo, hi in CJK_RANGES:
            if lo <= cp <= hi:
                return True
    return False


def words_of(text):
    """The words of a text the way the app cuts them now (wordRanges, Shared/VisionExec.swift:154): a word ends at a space; a
    word that holds a CJK character is cut into its CJK characters and its Latin runs."""
    out = []
    i = 0
    while i < len(text):
        if text[i] in WHITESPACE:
            i += 1
            continue
        j = i
        while j < len(text) and text[j] not in WHITESPACE:
            j += 1
        token = text[i:j]
        if any(is_cjk(c) for c in token):
            run = ""
            for c in token:
                if is_cjk(c):
                    if run:
                        out.append(run)
                        run = ""
                    out.append(c)
                else:
                    run += c
            if run:
                out.append(run)
        else:
            out.append(token)
        i = j
    return out


def merge_words(text, words, stats):
    """The words of one line rewritten the way the app cuts them now: the consecutive single-character words whose characters
    are not CJK and that touch in the text (no space between) become one word, the union of their boxes. Everything else is
    left as it is."""
    out = []
    i = 0
    while i < len(words):
        w = words[i]
        if len(w) < 7:
            out.append(w)
            i += 1
            continue
        chunk = text[w[0]:w[1]]
        if len(chunk) != 1 or is_cjk(chunk):
            out.append(w)
            i += 1
            continue
        group, j = [w], i + 1
        while j < len(words):
            nxt = words[j]
            if len(nxt) < 7:
                break
            c = text[nxt[0]:nxt[1]]
            if len(c) != 1 or is_cjk(c):
                break
            if nxt[0] != group[-1][1]:
                stats["gaps"] += 1        # a character Vision gave no box for: the run cannot be rebuilt whole
                break
            group.append(nxt)
            j += 1
        if len(group) == 1:
            out.append(w)
            i += 1
            continue
        left = min(g[2] for g in group)
        top = min(g[3] for g in group)
        right = max(g[2] + g[4] for g in group)
        bottom = max(g[3] + g[5] for g in group)
        out.append([group[0][0], group[-1][1], left, top, right - left, bottom - top,
                    "".join(text[g[0]:g[1]] for g in group)])
        stats["merged"] += len(group) - 1
        i = j
    return out


def rewrite_line(obj, stats):
    """The words of every line of one read rewritten."""
    for read in ("vn", "doc"):
        for block in obj.get(read) or []:
            if "w" in block and "t" in block:
                block["w"] = merge_words(block["t"], block["w"], stats)
                stats["lines"] += 1
    return obj


def rewrite_dir(src, dst):
    """The reads of src copied into dst with their words rewritten: the pictures are linked, the html and the other files are
    copied as they are."""
    os.makedirs(dst, exist_ok=True)
    stats = {"merged": 0, "gaps": 0, "lines": 0}
    for name in sorted(os.listdir(src)):
        s, d = os.path.join(src, name), os.path.join(dst, name)
        if os.path.isdir(s):
            continue
        if name.endswith(".png"):
            if os.path.lexists(d):
                os.remove(d)
            os.symlink(os.path.abspath(s), d)
        elif name.endswith(".ocr.jsonl"):
            out = []
            with open(s, encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    out.append(json.dumps(rewrite_line(json.loads(line), stats), separators=(",", ":"), ensure_ascii=False))
            with open(d, "w", encoding="utf-8") as f:
                f.write("\n".join(out) + "\n")
        else:
            shutil.copy2(s, d)
    return stats


def merge_label_words(text, words, stats):
    """The words of one labelled block rewritten the way the app cuts them now: the consecutive single-character words whose
    characters are not CJK and that touch in the text become one word (the class, the reason and the tag of the first word win).
    The block's counts and its uncertain word indices are rewritten with them."""
    out, index = [], []
    i = 0
    while i < len(words):
        w = words[i]
        chunk = text[w[0]:w[1]]
        if len(chunk) != 1 or is_cjk(chunk):
            out.append(list(w))
            index.append([i])
            i += 1
            continue
        group, j = [w], i + 1
        while j < len(words):
            nxt = words[j]
            c = text[nxt[0]:nxt[1]]
            if len(c) != 1 or is_cjk(c):
                break
            if nxt[0] != group[-1][1]:
                stats["gaps"] += 1
                break
            group.append(nxt)
            j += 1
        if len(group) == 1:
            out.append(list(w))
            index.append([i])
            i += 1
            continue
        if len({(g[2], g[3], g[4]) for g in group}) > 1:
            stats["mixed"] += 1           # the merged words do not agree on their class: the first one wins
        out.append([group[0][0], group[-1][1], group[0][2], group[0][3], group[0][4],
                    "".join(text[g[0]:g[1]] for g in group), group[0][6]])
        index.append(list(range(i, j)))
        stats["merged"] += len(group) - 1
        i = j
    return out, index


def recount(rec, words):
    """The counts of a labelled block rewritten for its new words (label.py's emit_block)."""
    n = {"keep": 0, "translate": 0, "either": 0, "none": 0}
    reasons = {}
    for w in words:
        k = w[2] if w[2] in n else "none"
        n[k] += 1
        if w[2] == "keep" and w[3]:
            reasons[w[3]] = reasons.get(w[3], 0) + 1
    st = dict(rec.get("stats") or {})
    st.update(n)
    st["reasons"] = dict(sorted(reasons.items()))
    rec["stats"] = st
    cls = "none"
    if n["keep"] and not n["translate"] and not n["either"]:
        cls = "keep"
    elif n["translate"] and not n["keep"] and not n["either"]:
        cls = "translate"
    elif n["either"] and not n["keep"] and not n["translate"]:
        cls = "either"
    elif n["keep"] and (n["translate"] or n["either"]):
        cls = "mixed"
    rec["keep"] = cls
    rec["reason"] = max(reasons.items(), key=lambda kv: kv[1])[0] if reasons else ""


def rewrite_labels(src, dst, stats):
    """A labels file rewritten the way the app cuts its words now: every block's words are merged the same way the read's words
    are, so the truth's words and the read's words stay one list (the judge pipeline aligns them by position)."""
    out = []
    with open(src, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("kind") == "block" and rec.get("words"):
                words, index = merge_label_words(rec.get("text", ""), rec["words"], stats)
                rec["words"] = words
                recount(rec, words)
                if rec.get("unc"):
                    rec["unc"] = sorted({index[k][0] for k in rec["unc"] if k < len(index)})
                stats["blocks"] += 1
            out.append(json.dumps(rec, separators=(",", ":"), ensure_ascii=False))
    with open(dst, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    return stats


def main(argv):
    if len(argv) == 3 and argv[1] == "--words":
        for w in words_of(argv[2]):
            print(w)
        return 0
    if len(argv) == 4 and argv[1] == "--labels":
        stats = rewrite_labels(argv[2], argv[3], {"merged": 0, "gaps": 0, "mixed": 0, "blocks": 0})
        print(f"resegment: {argv[2]} -> {argv[3]}: {stats['blocks']} blocks, {stats['merged']} characters merged into Latin runs, "
              f"{stats['gaps']} runs broken by a character Vision gave no box for, {stats['mixed']} merged words whose class did not agree")
        return 0
    if len(argv) == 3:
        stats = rewrite_dir(argv[1], argv[2])
        print(f"resegment: {argv[1]} -> {argv[2]}: {stats['lines']} lines, {stats['merged']} characters merged into Latin runs, "
              f"{stats['gaps']} runs broken by a character Vision gave no box for")
        return 0
    print(__doc__.strip())
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
