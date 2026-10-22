#!/bin/bash
# A8 screening: cut a box (pt) of a page of the paper PDF at 192 dpi, render it through the app (en -> ko, Apple), keep <name>.png / -out.png / .out / .err in $D for a8-score.py.
# usage: BIN=<app binary> D=<out dir> a8-screen.sh <name> <page> <x_pt> <y_pt> <w_pt> <h_pt>        (a window of the lens's size is ~250 x 110..175 pt of a column)
# Scratch ids (pool4 = this round's), no network, no key. Run one at a time; Bash sandbox off.
set -u
N=${1:?name}; P=${2:?page}; X=${3:?x}; Y=${4:?y}; W=${5:?w}; H=${6:?h}
BIN=${BIN:?BIN=<app binary>}; D=${D:-/tmp/film3/a8}; PDF=${PDF:-/tmp/film3/paper-build/main.pdf}; S=2.6667
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd); mkdir -p "$D"
px() { python3 -c "print(round($1 * $S))"; }
pdftoppm -f "$P" -l "$P" -r 192 -x "$(px "$X")" -y "$(px "$Y")" -W "$(px "$W")" -H "$(px "$H")" -png -singlefile "$PDF" "$D/$N" || exit 2
echo '{"sourceLanguage":"en","targetLanguage":"ko","checksForUpdates":false}' > "$D/settings.json"
MWOYEO_TRACE=1 MWOYEO_MEMORY_SECRETS=1 MWOYEO_DEFAULTS_SUITE=film3.render MWOYEO_SETTINGS_FILE="$D/settings.json" "$REPO/tools/ane-env.sh" run pool -- "$BIN" --render "$D/$N.png" "$D/$N-out.png" \
    --src en --tgt ko --scale 2 --warm --max-wait 300 > "$D/$N.out" 2> "$D/$N.err" < /dev/null
echo "$N rc=$?" >> "$D/screen.rc"
