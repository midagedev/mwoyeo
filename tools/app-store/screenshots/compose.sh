#!/bin/bash
# Stage 2 of the App Store screenshots: out/ko/01..06.png and out/en/01..05.png (2880 x 1800, RGB, sRGB) from renders/ only, then
# check.py (format, truth pixel for pixel, the paper's formulas, captions, coverage, cap height, frame count, and its own FAIL-first
# self-test).
# Two runs give the same bytes. out/ is gitignored; render.sh makes renders/ (committed).
#   usage: compose.sh                       (the Bash sandbox off: headless Chrome)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); OUT=$HERE/out
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -s "$HERE/renders/MANIFEST.tsv" ] || { echo "compose.sh: no renders/ (run render.sh first)" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT/.work/raw"
python3 -I "$HERE/compose.py" html "$OUT" || exit 1
for f in "$OUT"/.work/html/*.html; do
    n=$(basename "$f" .html)
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-color-profile=srgb --force-device-scale-factor=2 \
        --window-size=1440,900 --screenshot="$OUT/.work/raw/$n.png" "file://$f" > "$OUT/.work/raw/$n.log" 2>&1 < /dev/null
    [ -s "$OUT/.work/raw/$n.png" ] || { echo "compose.sh: Chrome made no picture of $n" >&2; exit 1; }
done
python3 -I "$HERE/compose.py" finish "$OUT" || exit 1
python3 -I "$HERE/check.py" "$OUT"
