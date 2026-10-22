"""Which entries of the app's translation log read a given stage line, for serve.py (pacing) and settle.py (the check).
The log writes a line once it first has a usable translation (Core TranscriptRecorder; the merger holds it 3 s for a fuller reading,
App/Support/LensExport.swift), possibly in parts when OCR splits a wrapped line. A line counts as translated once the parts read so
far cover COVER of its text; a name plate (an entry that reads a speaker's name) never counts, though names occur inside lines."""
import datetime
import difflib
import json
import os
import re

SEQUENCE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sequence", "film3-ja-ko.json")   # film 3: the lines as the stage prints them (furigana in brackets)
COVER = 0.8


def squash(s):
    return re.sub(r"[\W_]+", "", s or "")


def load(path=SEQUENCE):
    """({line id: text}, {speaker names, squashed})."""
    seq = json.load(open(path, encoding="utf-8"))
    return {l["id"]: l["text"] for l in seq["lines"]}, {squash(l["speaker"]) for l in seq["lines"] if l.get("speaker")}


def epoch(iso):
    return datetime.datetime.fromisoformat(iso).timestamp()


def read_of(original, text):
    """The positions of `text` (squashed) the entry reads; none when it reads less than 70 % of itself from `text`."""
    a, b = squash(original), squash(text)
    if not a or not b:
        return set()
    blocks = difflib.SequenceMatcher(None, a, b, autojunk=False).get_matching_blocks()
    if sum(m.size for m in blocks) < 0.7 * len(a):
        return set()
    return {j for m in blocks for j in range(m.b, m.b + m.size)}


def coverage(originals, text, speakers):
    """The share of `text` the given entries' originals read together, name plates left out."""
    b = squash(text)
    if not b:
        return 0.0
    seen = set()
    for o in originals:
        if squash(o) not in speakers:
            seen |= read_of(o, text)
    return len(seen) / len(b)
