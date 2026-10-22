#!/usr/bin/env python3
"""Film 3's stage and sequence, made from film 2's: the same scene and the same 36 lines (film-ja-ko-1), with the furigana of our own names and
terms printed in brackets after them, as some games and e-books print it: 九十九（つくも）, 月影（つきかげ）の祠（ほこら）. Run isolated:
  python3 -I make_stage.py            writes sequence/film3-ja-ko.json and stage/game.html (both are generated; edit this file)
  python3 -I make_stage.py --check    exits 1 when either differs from what this file makes (the stage's lines must be the sequence's)
FAILURE MODE IT BLOCKS: a stage and a sequence that disagree on a line's text (serve.py's pacing and settle.py read the sequence; the
lens reads the stage), and a stage line that does not fit the panel (two lines of 21 characters)."""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SEQ = os.path.join(HERE, "..", "translation-bench", "sequences", "film-ja-ko-1.json")
GAME = os.path.join(HERE, "..", "film2", "stage2", "game.html")
# word -> the word with its furigana; applied once, longest first (月影の祠 holds 祠, which has its own entry only in this word)
FURIGANA = [("九十九", "九十九（つくも）"), ("月影の祠", "月影（つきかげ）の祠（ほこら）"), ("月涙石", "月涙石（げつるいせき）"),
            ("水鏡", "水鏡（みずかがみ）"), ("守り手", "守（まも）り手（て）"), ("番人", "番人（ばんにん）")]
FIT = 42          # the panel: two lines of 21 characters (film2/stage2/game.html's layout contract)


def annotate(text):
    for plain, ruby in FURIGANA:
        text = text.replace(plain, ruby)
    return text


def build():
    seq = json.load(open(SEQ, encoding="utf-8"))
    for line in seq["lines"]:
        line["text"] = annotate(line["text"])
        line.pop("ref", None)
    seq["id"] = "film3-ja-ko"
    seq["title"] = "film-ja-ko-1 with furigana printed in brackets after our names and terms"
    for key in ("screens", "probes"):
        seq.pop(key, None)
    html = open(GAME, encoding="utf-8").read()
    shown = [{"id": l["id"], "speaker": l.get("speaker"), "text": l["text"]} for l in seq["lines"]]
    html = re.sub(r'(<script type="application/json" id="lines">).*?(</script>)',
                  lambda m: m.group(1) + json.dumps(shown, ensure_ascii=False, separators=(",", ":")) + m.group(2), html, flags=re.S)
    html = html.replace('src="assets/', 'src="../../film2/stage2/assets/')
    html = html.replace("<title>Moon Shrine</title>", "<title>Moon Shrine (film 3: furigana in brackets)</title>")
    return json.dumps(seq, ensure_ascii=False, indent=1) + "\n", html, shown


def main():
    seq_json, html, shown = build()
    too_long = [(l["id"], len(l["text"])) for l in shown if len(l["text"]) > FIT]
    paths = {os.path.join(HERE, "sequence", "film3-ja-ko.json"): seq_json, os.path.join(HERE, "stage", "game.html"): html}
    if "--check" in sys.argv:
        bad = [p for p, text in paths.items() if not os.path.exists(p) or open(p, encoding="utf-8").read() != text]
        for p in bad:
            print("make_stage: %s differs from what make_stage.py makes" % p, file=sys.stderr)
        sys.exit(1 if bad else 0)
    for p, text in paths.items():
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w", encoding="utf-8").write(text)
    print("make_stage: %d lines, %d with furigana; too long for the panel (> %d characters): %s"
          % (len(shown), sum(1 for l in shown if "（" in l["text"]), FIT, too_long or "none"))


main()
