#!/bin/bash
# FAIL-first check of resegment.py: the app's new wordRanges (a Latin run inside a CJK word is one word) and the rewrite of a read
# that holds the old segmentation (one box per character where a CJK word holds a URL).
#   usage: test_resegment.sh
# Run it before resegment.py exists (the FAIL lines) and after it (the PASS lines).
HERE=$(cd "$(dirname "$0")" && pwd)
RESEG=$HERE/resegment.py
PY=${PY:-python3}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0

check() { # name, expected, got
  if [ -z "$3" ]; then echo "FAIL $1: nothing came back"; fail=1; return; fi
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1: wanted [$2], got [$3]"; fail=1; fi
}

if [ ! -f "$RESEG" ]; then
  echo "FAIL resegment.py is missing ($RESEG): nothing to check"
  echo "FAIL the words of a CJK word with a Latin run"
  echo "FAIL the words of a line without CJK"
  echo "FAIL the words of a CJK line"
  echo "FAIL a read is rewritten: the URL of a CJK line is one word, its box the union of the characters'"
  exit 1
fi

words() { "$PY" -B -I "$RESEG" --words "$1"; }

check "the words of a CJK word with a Latin run" \
  "$(printf '詳\n細\nは\nhttps://example.com/a\nを\n参\n照')" \
  "$(words '詳細はhttps://example.com/aを参照')"
check "the words of a line without CJK" \
  "$(printf 'let\ntotal\n=\n2')" \
  "$(words 'let total = 2')"
check "the words of a CJK line" \
  "$(printf '日\n本\n語')" \
  "$(words '日本語')"

# A read that holds the old segmentation: one box per character of a CJK word that holds a URL.
python3 - "$T" <<'PY'
import json, os, sys
T = sys.argv[1]
os.makedirs(f"{T}/src")
text = "詳細はhttps://example.com/aを参照"
b = text.encode("utf-8")
words, x, i = [], 0, 0
for ch in text:
    words.append([x, x + 1, float(i), 0.0, 1.0, 10.0, ch])   # the offsets are characters, not bytes
    x += 1
    i += 1
line = {"r": [0.0, 0.0, 30.0, 10.0], "n": 1, "t": text, "w": words}
with open(f"{T}/src/x.ocr.jsonl", "w", encoding="utf-8") as f:
    f.write(json.dumps({"image": "x", "size": [30, 10], "vn": [line], "doc": []}, separators=(",", ":"), ensure_ascii=False) + "\n")
open(f"{T}/src/x.png", "w").write("picture")
open(f"{T}/src/x.html", "w").write("<html></html>")
# the words the rewrite must give: the URL is one word, its box the union of the 19 characters'
url = [w for w in words if w[0] >= 3 and w[0] < 3 + len("https://example.com/a")]
expect = [["詳", 0.0, 0.0, 1.0, 10.0], ["細", 1.0, 0.0, 1.0, 10.0], ["は", 2.0, 0.0, 1.0, 10.0],
          ["https://example.com/a", float(url[0][2]), 0.0, float(len(url)), 10.0],
          ["を", 24.0, 0.0, 1.0, 10.0], ["参", 25.0, 0.0, 1.0, 10.0], ["照", 26.0, 0.0, 1.0, 10.0]]
with open(f"{T}/expect.txt", "w", encoding="utf-8") as f:
    for t, x, y, w, h in expect:
        f.write(f"{t}|{x}|{y}|{w}|{h}\n")
PY

"$PY" -B -I "$RESEG" "$T/src" "$T/dst" > "$T/reseg.out" 2>&1
check "a read is rewritten: the URL of a CJK line is one word, its box the union of the characters'" \
  "$(cat "$T/expect.txt")" \
  "$("$PY" -B -I - "$T/dst/x.ocr.jsonl" <<'PY'
import json, sys
line = json.loads(open(sys.argv[1], encoding="utf-8").read().strip())["vn"][0]
for w in line["w"]:
    print(f"{w[6]}|{w[2]}|{w[3]}|{w[4]}|{w[5]}")
PY
)"
check "the picture of the new read is a link to the old one" "yes" \
  "$([ -L "$T/dst/x.png" ] && echo yes || echo no)"
check "the html of the new read is a copy" "<html></html>" \
  "$(cat "$T/dst/x.html" 2>/dev/null)"
check "the text of the line is not touched" "詳細はhttps://example.com/aを参照" \
  "$("$PY" -B -I - "$T/dst/x.ocr.jsonl" <<'PY'
import json, sys
print(json.loads(open(sys.argv[1], encoding="utf-8").read().strip())["vn"][0]["t"])
PY
)"
exit $fail
