#!/bin/bash
# Stage 1 of the App Store screenshots: runs the real app once and keeps what it made in renders/ (committed: OCR and Apple
# Translation vary from run to run, so the pictures the frames show are kept, not remade). compose.sh builds the frames from
# renders/ alone.
#   usage: render.sh <Mwoyeo binary> [scene ... | menu]
#                                           (a build with --render and --capture-ui; the Bash sandbox off: Chrome, OCR, captures)
#          no scene named: everything, renders/ emptied first;
#          scenes named: only those are shot, cut and rendered again (the menu panel only when `menu` is named), every other
#          file in renders/ stays byte for byte, and RUN.txt gets a `rerun` line naming them
#   env:   SCRATCH=<dir>                    (default $TMPDIR/as-shots-render; emptied first)
# What it does, per scenes.json:
#   1. the demo pages (demo/*.html) at 2x in headless Chrome, and the pages of our own paper (tools/paper-own/mwoyeo-method) a
#      paper scene shows, at its px per pt;
#   2. the card each frame shows -> renders/<scene>.source.png, and the lens out of it -> the picture --render reads;
#   3. Mwoyeo --render on each lens picture -> renders/<scene>.<target>.png (and its stdout, the lines it read and wrote, .out);
#   4. the menu panel in English and Korean (--capture-ui menu-default, one scratch lens listed) -> renders/menu.<loc>.png;
#   5. renders/MANIFEST.tsv (bytes, sha256) and renders/RUN.txt (binary, Chrome, tree).
# Scratch settings only: MWOYEO_SETTINGS_FILE, MWOYEO_DEFAULTS_SUITE=as1.shots, in-memory secrets. The app's id is the one the binary
# was built with (nothing reads MWOYEO_APP_ID at run time); tools/ane-env.sh takes the Neural Engine lease when the binary's id has no compiled bundle yet.
set -uo pipefail
BIN=${1:?usage: render.sh <Mwoyeo binary> [scene ... | menu]}; shift
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd); ANE=$HERE/../../ane-env.sh
R=$HERE/renders; SCR=${SCRATCH:-${TMPDIR:-/tmp}/as-shots-render}
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PY="python3 -I $HERE/prep.py"
SUITE=as1.shots
SCENES=(); MENU=1
if [ $# -gt 0 ]; then
    MENU=0
    for a in "$@"; do if [ "$a" = menu ]; then MENU=1; else SCENES+=("$a"); fi; done
fi
ONLY=${SCENES[@]+"${SCENES[@]}"}            # empty: every scene
fail() { echo "render.sh: $*" >&2; exit 1; }
$PY pages $ONLY > /dev/null || fail "scenes.json"
rm -rf "$SCR"; mkdir -p "$SCR/src" "$SCR/ui" "$R"
if [ $# -eq 0 ]; then
    rm -f "$R"/*.png "$R"/*.out "$R"/MANIFEST.tsv "$R"/RUN.txt
else
    for id in $ONLY; do rm -f "$R/$id".*; done
    [ $MENU = 1 ] && rm -f "$R"/menu.*.png
fi
export MWOYEO_SETTINGS_FILE=$SCR/settings.json MWOYEO_DEFAULTS_SUITE=$SUITE MWOYEO_MEMORY_SECRETS=1
echo '{}' > "$SCR/settings.json"

if [ $# -eq 0 ] || [ -n "$ONLY" ]; then        # not `render.sh <bin> menu` alone
# 1. sources
$PY pages $ONLY > "$SCR/pages.tsv" || fail "scenes.json"
while IFS=$'\t' read -r id page w h budget; do
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-color-profile=srgb --force-device-scale-factor=2 \
        --window-size="$w,$h" --virtual-time-budget="$budget" --screenshot="$SCR/src/$id.png" "file://$REPO/demo/$page" \
        > "$SCR/chrome-$id.log" 2>&1 < /dev/null
    [ -s "$SCR/src/$id.png" ] || fail "Chrome made no picture of $page"
    echo "source $id: demo/$page at ${w}x$h"
done < "$SCR/pages.tsv"
$PY pdfs $ONLY > "$SCR/pdfs.tsv" || fail "scenes.json"
PAPER=
if [ -s "$SCR/pdfs.tsv" ]; then
    "$REPO/tools/paper-own/mwoyeo-method/build.sh" "$SCR/paper" > "$SCR/paper-build.log" 2>&1 || fail "paper build (see $SCR/paper-build.log)"
    swiftc -O "$REPO/tools/paper-bench/pdfpages.swift" -o "$SCR/pdfpages" 2> "$SCR/pdfpages.log" || fail "pdfpages build"
    PAPER=$(shasum -a 256 "$SCR/paper/main.pdf" | cut -d' ' -f1)
    while IFS=$'\t' read -r id pdfpage pdfscale; do
        mkdir -p "$SCR/paper/$id"
        "$SCR/pdfpages" "$SCR/paper/main.pdf" "$SCR/paper/$id" "$pdfscale" "$pdfpage" && cp "$SCR/paper/$id/p$pdfpage.png" "$SCR/src/$id.png" \
            || fail "paper page $pdfpage"
        echo "source $id: main.pdf ${PAPER:0:16} page $pdfpage at $pdfscale px/pt"
    done < "$SCR/pdfs.tsv"
fi

# 2. cards and lens pictures
$PY cards "$SCR" "$R" $ONLY || fail "cards"

# 3. renders, one at a time (one Neural Engine; a concurrent render changes the answer)
$PY renders $ONLY > "$SCR/renders.tsv"
while IFS=$'\t' read -r id src tgt; do
    t0=$(date +%s)
    "$ANE" run pool -- "$BIN" --render "$SCR/lens/$id.png" "$R/$id.$tgt.png" --src "$src" --tgt "$tgt" --scale 2 --warm --max-wait 240 \
        > "$R/$id.$tgt.out" 2> "$SCR/$id.$tgt.err" < /dev/null
    rc=$?
    texts=$(grep -o 'translate.texts=[0-9]*' "$R/$id.$tgt.out" | head -1 | cut -d= -f2)
    echo "render $id $src>$tgt rc=$rc texts=${texts:-0} $(( $(date +%s) - t0 ))s"
    [ $rc -eq 0 ] && [ -s "$R/$id.$tgt.png" ] || fail "--render $id $src>$tgt rc=$rc (see $SCR/$id.$tgt.err)"
    if [ "${texts:-0}" -eq 0 ]; then
        pgrep -x ANECompilerService > /dev/null && echo "render.sh: ANECompilerService is running (wait for it; never kill it)" >&2
        fail "$id $src>$tgt translated nothing"
    fi
done < "$SCR/renders.tsv"
fi

# 4. the menu panel: real UI, one scratch lens of the panel frame's size in the list
if [ $MENU = 1 ]; then
    for loc in en ko; do
        srcl=$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['panel']['source'][sys.argv[2]])" "$HERE/scenes.json" "$loc")
        printf '{"sourceLanguage":"%s","targetLanguage":"%s"}\n' "$srcl" "$loc" > "$SCR/ui/settings-$loc.json"
        defaults delete "$SUITE" > /dev/null 2>&1
        defaults write "$SUITE" regions -data "$($PY region "$loc")" || fail "seed the scratch lens"
        mkdir -p "$SCR/ui/$loc"
        MWOYEO_SETTINGS_FILE=$SCR/ui/settings-$loc.json "$ANE" run pool -- "$BIN" --capture-ui "$SCR/ui/$loc" menu-default -AppleLanguages "($loc)" \
            > "$SCR/ui/$loc.log" 2>&1 < /dev/null
        [ -s "$SCR/ui/$loc/menu-default.png" ] || fail "no menu capture ($loc)"
        $PY panel "$SCR/ui/$loc/menu-default.png" "$R/menu.$loc.png" "$(python3 -I -c "import json,sys; print(json.load(open(sys.argv[1]))['panel']['titlebar_px'])" "$HERE/scenes.json")" || fail "panel $loc"
    done
    defaults delete "$SUITE" > /dev/null 2>&1
fi

# 5. what made them
SHA=$(shasum -a 256 "$BIN" | cut -d' ' -f1)
if [ $# -eq 0 ]; then
    {
        echo "date      $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "binary    $BIN"
        echo "binary    sha256 $SHA"
        echo "app       $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$(dirname "$BIN")/../Info.plist" 2>/dev/null) ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$(dirname "$BIN")/../Info.plist" 2>/dev/null))"
        echo "tree      $(git -C "$REPO" rev-parse HEAD) (demo/ and tools/paper-own as committed there)"
        echo "chrome    $("$CHROME" --version 2>/dev/null)"
        echo "macOS     $(sw_vers -productVersion) $(uname -m)"
        echo "paper     main.pdf sha256 $PAPER"
    } > "$R/RUN.txt"
else
    echo "rerun     $(date -u +%Y-%m-%dT%H:%M:%SZ) $* : binary sha256 $SHA, tree $(git -C "$REPO" rev-parse HEAD), $("$CHROME" --version 2>/dev/null | sed 's/ *$//')${PAPER:+, main.pdf sha256 $PAPER}" >> "$R/RUN.txt"
fi
$PY manifest "$R"
echo "render.sh: done ($R)"
