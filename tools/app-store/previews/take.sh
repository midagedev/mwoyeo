#!/bin/zsh
# Real takes for the App Store previews: the demo chat in a Chrome --app window, a Mwoyeo lens on it, recorded with
# `screencapture -v` while drive.swift moves the lens, scrolls and presses ⌃⌥O (docs/HERO.md's recipe at 16:9).
#   take.sh app <ko|en>        start the app (scratch identity and settings) with one lens; it stays up across takes
#   take.sh shoot <ko|en> <n>  one take -> $WORK/takes/<lang>-<n>.mov and .log (the step times, the page's clock)
#   take.sh stop               quit what app/shoot started (by recorded pid) and delete the scratch preferences
# A take holds the screen lease /tmp/mwoyeo-screen.lock, and starts only when the Mac has been idle for 60 s (the input our
# previous take made excepted) and no other app's window is over the rect; it is thrown away when either happens during it
# (drive exits 3 or 4).
# Needs: the Bash sandbox off; a Release build of this tree with MWOYEO_APP_ID=dev.midagedev.mwoyeo.preview in $DD;
# the terminal's Screen Recording and Accessibility permissions; the ja->ko and ko->en translation packs.
set -u
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/../../.." && pwd)
WORK=${WORK:-/tmp/as4}
DD=${DD:-$WORK/dd}
APP=$DD/Build/Products/Release/Mwoyeo.app/Contents/MacOS/Mwoyeo
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SUITE=as4.preview
DRIVE=$WORK/bin/drive
mkdir -p "$WORK/pids" "$WORK/takes" "$WORK/scratch" "$WORK/bin"
# (built when missing too: zsh's -nt is false when the second file does not exist)
{ [ -x "$DRIVE" ] && [ ! "$HERE/drive.swift" -nt "$DRIVE" ]; } || { swiftc -O "$HERE/drive.swift" -o "$DRIVE" || exit 1; }

# Geometry, global points (top-left origin), for a 1512x982 pt screen with the Dock showing below y 923. A window, not full
# screen: a lens dragged over a full-screen page can be dropped into Split View (macOS shows its Drag Guide), which moves it.
# The chat's main column fills the recorded rect R (16:9, 2 px per pt: 1920x1080 as is); the lens sits on the bottom of
# the message log, where new messages land, over the text column, the original visible to its right and above it, the
# message box below it for the captions.
R=552,383,960,540                     # recorded rect
WIN_POS=240,355; WIN_SIZE=1272,568    # Chrome --app window: 28 pt title bar, page content at (240,383) 1272x540
LENS=592,591,490,250                  # 46 % of the frame's height; its bottom 6 pt above the end of the log (y 847)
TAG=(622 572)                         # the lens' name tag, where a hand grabs it to drag
TITLE=(1300 369)                      # the window's title bar: a click brings it to the front
PARK=(1400 250)                       # the pointer between beats: outside R
MARK=(1470 880)                       # the pointer flashes here 1 s before t = 0: cut.sh finds t = 0 in the video by it
EVERY=6                               # a new chat message every 6 s, landing 1.5 s after its tick: at 1 and 7 s, then while
                                      # the log is scrolled back (13, 19, 25 s), where a message no longer moves it
HISTORY=(30 36)                       # messages already in the log (ko, en): room for three swipes back. The page's script
                                      # repeats every 16 messages and the one landing at 1 s is (history + 1) mod 16. ko: the
                                      # raid call. en: "나 갈래! 몇 시에 할까?", short in English too (the raid call's English is
                                      # drawn small to fit its short Korean line), and the swipes end on three short lines,
                                      # not on the sunset picture, for ⌃⌥O to turn over
SWIPES=("260 220 83" "260 220 200")   # the three swipes back (ko, en), in points. ko's last one is short: at 200 the lens
                                      # held mostly the sunset picture and a line cut by its bottom edge. After two swipes the
                                      # picture ends 124.5 pt and the patch link starts 376 pt below the rect's top; 83 more
                                      # puts both under the lens' borders (206-208, 458-460), with samwise's, Maya's and
                                      # junpark's messages whole inside it (measured on take ko-11)
LOCK=/tmp/mwoyeo-screen.lock          # the screen lease (mkdir to take it, rmdir to give it back)

case $1 in
app)
    L=$2
    [ -x "$APP" ] || { echo "no app at $APP"; exit 1; }
    if [ $L = ko ]; then SRC=ja; DST=ko; else SRC=ko; DST=en; fi
    defaults delete $SUITE >/dev/null 2>&1
    BLOB=$(printf '{"hasCompletedOnboarding":true,"sourceLanguage":"%s","targetLanguage":"%s"}' $SRC $DST | xxd -p | tr -d '\n')
    defaults write $SUITE settings -data $BLOB
    defaults write $SUITE settingsMirror -data $BLOB
    printf '{"sourceLanguage":"%s","targetLanguage":"%s"}\n' $SRC $DST > "$WORK/scratch/settings.json"
    MWOYEO_SETTINGS_FILE=$WORK/scratch/settings.json MWOYEO_DEFAULTS_SUITE=$SUITE MWOYEO_MEMORY_SECRETS=1 \
        "$APP" --add-region $LENS -AppleLanguages "($L)" > "$WORK/app-$L.log" 2>&1 &
    echo $! > "$WORK/pids/app"
    date +%s > "$WORK/pids/app.start"
    echo "app $L pid $(cat $WORK/pids/app)"
    ;;
shoot)
    L=$2; N=$3
    if [ $L = ko ]; then PAGE=ja; HIST=${HISTORY[1]}; SW=(${=SWIPES[1]}); else PAGE=ko; HIST=${HISTORY[2]}; SW=(${=SWIPES[2]}); fi
    APID=$(cat "$WORK/pids/app"); kill -0 $APID || { echo "app not running"; exit 1; }
    OUT=$WORK/takes/$L-$N
    # 0. the screen lease the rounds that put windows on the screen share (held for one take, about a minute)
    until mkdir $LOCK 2>/dev/null; do sleep 15; done
    trap "rmdir $LOCK 2>/dev/null" EXIT
    # 1. the Mac is idle: 60 s without input, or the last input was our own previous take's
    IDLE=$($DRIVE idle)
    LAST=$(cat "$WORK/pids/laststamp" 2>/dev/null || echo 0)
    OURS=$(python3 -c "import time; print(int(abs(($IDLE) - (time.time() - $LAST)) < 2))")
    if python3 -c "import sys; sys.exit(0 if $IDLE >= 60 else 1)"; then :
    elif [ $OURS = 1 ]; then echo "idle $IDLE s since our own last input"
    else echo "busy: idle $IDLE s"; exit 5; fi
    # 2. a fresh page (its timers start at load: the page's clock)
    rm -rf "$WORK/chrome"
    "$CHROME" --user-data-dir="$WORK/chrome" --no-first-run --no-default-browser-check --disable-features=Translate,TranslateUI \
        --app="file://$REPO/demo/chat.html?lang=$PAGE&every=$EVERY&history=$HIST" \
        --window-position=$WIN_POS --window-size=$WIN_SIZE > "$WORK/chrome.log" 2>&1 &
    CPID=$!; echo $CPID > "$WORK/pids/chrome"
    PAGE_T=$($DRIVE window $CPID "#general" 20)
    [ -n "$PAGE_T" ] || { echo "no chat window"; kill $CPID; exit 1; }
    $DRIVE run $R $APID $CPID -- "0 click ${TITLE[1]} ${TITLE[2]}" "0.3 point ${PARK[1]} ${PARK[2]} 0.3" "0.7 end" > /dev/null
    $DRIVE clear $R $APID $CPID || { echo "the rect is not clear"; kill $CPID; exit 4; }
    # 3. t = 0: 1 s before a message lands, at least 9 s after the page loaded (the lens has read it all by then)
    T0=$(python3 -c "
import time
page = $PAGE_T; t = page + 1.5 - 1.0
while t < time.time() + 9: t += $EVERY
print(f'{t:.3f}')")
    SECS=$(python3 -c "import math, time; print(math.ceil($T0 - time.time()) + 30)")
    rm -f "$OUT.mov"
    screencapture -v -C -V $SECS -R $R "$OUT.mov" > "$OUT.capture.log" 2>&1 &
    SPID=$!; echo $SPID > "$WORK/pids/capture"
    # the story in output seconds (cut.sh: t = 0 is the first frame); messages land at 1 and 7 s at the bottom of the log.
    # The drag starts once the 7 s message is translated, up and back in one press (a pause at the top lets the read-ahead
    # margins narrow, and the way back then shows the original for a moment); the first swipe is under way before 13 s, so
    # that message lands below.
    # Every swipe goes back (content moving down): a swipe toward the end of the log drags the message box's translation,
    # read ahead below the lens, up into it for a moment (a lens defect, reported), so the take never does that.
    LX=${${(s:,:)LENS}[1]}; LY=${${(s:,:)LENS}[2]}
    DRIVE_T0=$T0 DRIVE_STAMP=$WORK/pids/laststamp $DRIVE run $R $APID $CPID $SPID -- \
        "-1.5 warp ${PARK[1]} ${PARK[2]}" "-1.0 warp ${MARK[1]} ${MARK[2]}" "-0.5 warp ${PARK[1]} ${PARK[2]}" \
        "7.4 point ${TAG[1]} ${TAG[2]} 0.8" "8.3 drag ${TAG[1]} ${TAG[2]} 0 -130 1.5 0 130 1.4" \
        "11.6 point $(( LX + 360 )) $(( LY + 140 )) 0.5" "12.2 swipe $(( LX + 360 )) $(( LY + 140 )) ${SW[1]} 0.9" \
        "14.7 swipe $(( LX + 360 )) $(( LY + 140 )) ${SW[2]} 0.9" "17.1 swipe $(( LX + 360 )) $(( LY + 140 )) ${SW[3]} 0.9" \
        "18.9 point ${PARK[1]} ${PARK[2]} 0.7" "21.0 key ctrl+opt+o" "24.2 key ctrl+opt+o" "27.6 end" > "$OUT.log"
    RC=$?
    [ $RC = 0 ] || kill -INT $SPID 2>/dev/null      # a spoiled take: stop recording now
    while kill -0 $SPID 2>/dev/null; do sleep 0.5; done
    kill $CPID 2>/dev/null
    printf 'page %s\nt0 %s\nrc %s\n' $PAGE_T $T0 $RC >> "$OUT.log"
    python3 - "$OUT.capture.log" <<'EOF' >> "$OUT.log"
import os, sys
print('capture-log', open(sys.argv[1]).read().strip().replace('\n', ' | '))
EOF
    echo "take $OUT: drive rc $RC"; grep -E "touched|intruder|clean" "$OUT.log"
    exit $RC
    ;;
stop)
    for f in capture chrome app; do
        [ -f "$WORK/pids/$f" ] && kill $(cat "$WORK/pids/$f") 2>/dev/null && echo "stopped $f $(cat $WORK/pids/$f)"
        rm -f "$WORK/pids/$f"
    done
    defaults delete $SUITE >/dev/null 2>&1 && echo "deleted defaults $SUITE"
    ;;
*)
    sed -n 2,8p "$0"; exit 2 ;;
esac
