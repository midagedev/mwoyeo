#!/bin/bash
# The edit's own check on a take (any take of record-paper.sh): one clip joined to an end card by a dissolve, a mark under a span placed from Vision's box, a caption pill; PLACEHOLDER
# words only (the lead writes the real ones). Frames of it are written next to it.
#   selftest.sh <take.mp4> <clip start s> <frame s with the span> <span> [--missing]      --missing: the span is not on the frame: the edit must REFUSE (FAIL-first)
# The take's crop is the whole frame (the paper takes are recorded cropped: 2000:1124).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TAKE=${1:?take.mp4}; SS=${2:?clip start}; AT=${3:?frame second}; SPAN=${4:?span}; D=/tmp/film3/edit-selftest; mkdir -p "$D"
CROP=2000:1124:0:0
[ "${5:-}" = --missing ] && SPAN='없는말'
swiftc -O "$HERE/caption.swift" -o "$D/caption" 2> /dev/null
"$D/caption" pill "$D/pill.png" "(PLACEHOLDER) 캡션 자리" "PLACEHOLDER caption slot" || exit 1
"$D/caption" card "$D/card.png" "(PLACEHOLDER) 끝 카드" "PLACEHOLDER end line" "Mwoyeo 1.1.5" || exit 1
cat > "$D/plan.json" <<JSON
{"out": "$D/out/selftest", "fps": 30,
 "clips": [{"src": "$TAKE", "ss": $SS, "dur": 3.0, "crop": "$CROP"}, {"card": "$D/card.png", "dur": 1.5, "dissolve": 0.25}],
 "marks": [{"t": 0.4, "dur": 1.9, "src": "$TAKE", "at": $AT, "crop": "$CROP", "span": "$SPAN"}],
 "captions": [{"t": 0.2, "dur": 2.4, "png": "$D/pill.png", "x": 96, "y": 72}]}
JSON
python3 -I "$HERE/edit.py" "$D/plan.json" || exit 1
for t in 0.5 1.5 3.4; do ffmpeg -hide_banner -loglevel error -y -ss $t -i "$D/out/selftest.mp4" -frames:v 1 "$D/out/f-$t.png"; done
echo "selftest: frames in $D/out"
