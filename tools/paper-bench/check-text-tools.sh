#!/bin/bash
# FAIL-first test of hyphens.py and names.py (round read117): each must fail on a render output that has what it counts and pass on one that has
# not. usage: check-text-tools.sh        exit 0 when both tools tell the two outputs apart
HERE=$(cd "$(dirname "$0")" && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir "$T/bad" "$T/good"
cat > "$T/bad/p1.out" <<'OUT'
  The size of the old text is read from the height of its glyphs, and there is noth-ing left to con-text.
    → 구 텍스트의 크기는 글리프의 높이에서 읽힙니다.
  Pass the depth to fitFontSize.
    → 깊이를 fitfontsize에 전달하세요.
OUT
cat > "$T/good/p1.out" <<'OUT'
  The size of the old text is read from the height of its glyphs, and there is nothing left to context, sequence-aligned.
    → 구 텍스트의 크기는 글리프의 높이에서 읽힙니다.
  Pass the depth to fitFontSize.
    → 깊이를 fitFontSize에 전달하세요.
OUT
rc=0
python3 -I "$HERE/hyphens.py" "$T/bad" > "$T/o" 2>&1 && { echo "FAIL: hyphens.py passed an output with broken words"; rc=1; } || echo "ok: hyphens.py fails on a broken word ($(cat "$T/o"))"
python3 -I "$HERE/hyphens.py" "$T/good" > "$T/o" 2>&1 && echo "ok: hyphens.py passes a joined output ($(cat "$T/o"))" || { echo "FAIL: hyphens.py failed a joined output"; rc=1; }
python3 -I "$HERE/names.py" "$T/bad" > "$T/o" 2>&1 && { echo "FAIL: names.py passed a recased name"; rc=1; } || echo "ok: names.py fails on a recased name ($(cat "$T/o"))"
python3 -I "$HERE/names.py" "$T/good" > "$T/o" 2>&1 && echo "ok: names.py passes a restored name ($(cat "$T/o"))" || { echo "FAIL: names.py failed a restored name"; rc=1; }
exit $rc
