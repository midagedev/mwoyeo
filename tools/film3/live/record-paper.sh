#!/bin/bash
# Film 3 (paper clip): the real app in use on this Mac's screen: our method paper (page 10 of the paper built by ../paper/build.sh) in Preview, a Mwoyeo lens over its
# paragraph "Controls and noise." translating live, en -> ko, with the Apple engine. One part per call; Bash sandbox off (screen capture, the app, Preview, Accessibility):
#   record-paper.sh ui                           the Script editor of the lens's Memory sheet, by Accessibility only (ui_steps below)   -> $OUT/ui-paper.*
#   record-paper.sh before                       no script          -> $OUT/before-paper.{mp4,jsonl,events.jsonl,settings.json,count.txt}
#   record-paper.sh after <settings.json> [name] the script: the first `profiles` item of <settings.json> (a profile with `script`), its `when` set to Preview, is in the
#                                                scratch settings from the start (a take never meets the script service's first start)      -> $OUT/<name>.*  (after-paper)
# Preview is the person's app: it is started with `open -F` for our window only, our window is closed by quitting it when it was not running before, and the pid of everything we
# start is written to $OUT/runs/<name>/pids (nothing else is signalled). Window placement and scrolling are Accessibility attribute writes (no mouse or keyboard events).
# Sequence of a take: Preview shows the paragraph (page scrolled by AX); ffmpeg starts; 2 s later the app starts with the lens over the paragraph; the reader's first answer is
# waited for (its seconds are cut in the edit); SEC s later the page is scrolled away (the cue closes and the log writes its entries), ffmpeg stops. $OUT/<name>.events.jsonl
# has the times (epoch s) of preview, rec0 (the first frame), lens (the app started), ready (the reader answered), away.
# ENV: BIN (the app: the FILM GO build, MWOYEO_APP_ID dev.midagedev.mwoyeo.pool4), PDF (default /tmp/film3/paper-build/page10.pdf: page 10 alone, `pdfseparate -f 10 -l 10`), SCROLL (Preview's scroll bar value 0..1 that brings the paragraph under the lens, 1.0), OUT (/tmp/film3/live-paper),
#      REGION (the lens, points: 770,382,600,270), CROP (px of the 3024x1964 capture, default none = the whole screen: the motion round crops), FRAME (pt x:y:w:h the pointer and foreign checks look at: 500:250:1000:562), SEC (30), PARK (1), MBPS (16), SEC (the most to wait for the Korean to settle, 120), HOLD (s the settled lens is held, 8), MINKO (Hangul characters that count as translated, 100), QUIET
# QUIET (s, default 0): wait up to this long (retry every 3 s) for no other process's window to lie over the frame (foreign.js: windows in front of the Preview window, not mine); exit 3 when one still does, or when one appeared during the take
# FAILURE MODES IT BLOCKS: a take with another process's window over the frame (the release gates and other rounds run GUI apps here with the SAME bundle id pool4: a lsappinfo check cannot tell them from this app; a settings window was seen at the left edge of a take); a recording of the user's real app or settings (every call of the app carries the scratch env); a take whose script never reached the app (the written file must
# pass --check-settings); the pointer inside the frame (it is parked outside; a take with it inside is refused); a lens that was not reading when the page was scrolled in (the reader's
# first answer is waited for in the app's own log).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOOLS=$(cd "$HERE/../.." && pwd); REPO=$(cd "$TOOLS/.." && pwd)
OUT=${OUT:-/tmp/film3/live-paper}; SEC=${SEC:-120}; HOLD=${HOLD:-8}; SCROLL=${SCROLL:-1.0}; MINKO=${MINKO:-100}; MBPS=${MBPS:-40}; REGION=${REGION:-770,382,600,270}; CROP=${CROP:-}; FRAME=${FRAME:-500:250:1000:562}
PDF=${PDF:-/tmp/film3/paper-build/page10.pdf}; BIN=${BIN:?BIN=<the app binary of the build to film>}
part=${1:-}; MEM=""
case $part in
    before) NAME=${NAME:-before-paper} ;;
    after) MEM=${2:-}; [ -s "$MEM" ] || { sed -n '3,6p' "$0" >&2; exit 2; }; MEM=$(cd "$(dirname "$MEM")" && pwd)/$(basename "$MEM"); NAME=${3:-after-paper} ;;
    ui) NAME=${NAME:-ui-paper}; FRAME=${FRAME_UI:-0:33:1512:858} ;;
    *) sed -n '3,6p' "$0" >&2; exit 2 ;;
esac
[ -x "$BIN" ] || { echo "record-paper: no app at $BIN" >&2; exit 2; }
[ -s "$PDF" ] || { echo "record-paper: no pdf $PDF (../paper/build.sh, then pdfseparate -f 10 -l 10)" >&2; exit 2; }
RUN=$OUT/runs/$NAME; rm -rf "$RUN"; mkdir -p "$RUN/export"; PIDS=$RUN/pids; EV=$RUN/events.jsonl; : > "$PIDS"; : > "$EV"
export MWOYEO_SETTINGS_FILE=$RUN/settings.json MWOYEO_DEFAULTS_SUITE=film3.paper MWOYEO_MEMORY_SECRETS=1
app() { "$BIN" "$@" < /dev/null; }
note() { python3 -I -c 'import json, sys, time; print(json.dumps({"t": round(time.time(), 3), "k": sys.argv[1], "v": sys.argv[2]}, ensure_ascii=False))' "$1" "${2:-}" >> "$EV"; echo "record-paper: $1 ${2:-}"; }
started() { echo "$1 $2" >> "$PIDS"; }
stop() { local p; for p in $(awk -v n="$1" '$1 == n {print $2}' "$PIDS"); do kill -"${2:-TERM}" "$p" 2>/dev/null || continue
         for _ in $(seq 1 100); do kill -0 "$p" 2>/dev/null || continue 2; sleep 0.1; done; echo "record-paper: $1 ($p) did not quit in 10 s" >&2; done; }
PV_WAS=$(lsappinfo info -only pid -app com.apple.Preview | tr -dc 0-9)
if [ -n "$PV_WAS" ]; then   # a resident Preview with no window is fine (this take adds and closes its own window, and leaves the process); with windows it is someone's work
    n=$(osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PV_WAS) to return (count of windows) as text")
    [ "${n:-1}" = 0 ] || { echo "record-paper: Preview is already running with $n window(s) (pid $PV_WAS); quit them first: this take opens its own" >&2; exit 1; }
fi
PVNAME=$(basename "$PDF" .pdf)
unpark() { [ -s "$RUN/pointer" ] || return 0; local x y; IFS=, read -r x y < "$RUN/pointer"; warp "$x" "$y"; rm -f "$RUN/pointer"; }
warp() { osascript -l JavaScript -e "ObjC.import('CoreGraphics'); \$.CGWarpMouseCursorPosition(\$.CGPointMake($1, $2))" > /dev/null; }
pointer() { osascript -l JavaScript -e 'ObjC.import("AppKit"); var p = $.NSEvent.mouseLocation; [Math.round(p.x), Math.round($.NSScreen.screens.objectAtIndex(0).frame.size.height - p.y)].join(",")'; }
pv_close() { if [ -z "$PV_WAS" ]; then osascript -e 'tell application id "com.apple.Preview" to quit' > /dev/null 2>&1
             else osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PV_WAS)
                    repeat with w in windows
                      if name of w contains \"$PVNAME\" then perform action \"AXPress\" of (first button of w whose subrole is \"AXCloseButton\")
                    end repeat
                  end tell" > /dev/null 2>&1; fi; }
cleanup() { stop ffmpeg INT; stop watch; stop app; pv_close; unpark
            [ -s "$RUN/pointer-in.log" ] && echo "record-paper: the pointer was inside the take (see $RUN/pointer-in.log)" >&2; }
trap cleanup EXIT; trap 'exit 130' INT TERM
IFS=: read -r FX FY FW FH <<< "$FRAME"
fgn() { osascript -l JavaScript "$HERE/foreign.js" "${PV:-0}" "$(awk '$1 == "app" {print $2}' "$PIDS" | tail -1)" "$PVNAME" "$FX:$FY:$FW:$FH" 2> /dev/null; }
pointer_clear() { local px py; IFS=, read -r px py <<< "$(pointer)"; [ "$px" -lt "$FX" ] || [ "$px" -ge $((FX + FW)) ] || [ "$py" -lt "$FY" ] || [ "$py" -ge $((FY + FH)) ]; }
pv_ax() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PV)
    set frontmost to true
    set w to first window whose name contains \"$PVNAME\"
    set position of w to {0, 33}
    set size of w to {1512, 858}
  end tell" > /dev/null; }
pv_scroll() { osascript -e "tell application \"System Events\" to tell (first process whose unix id is $PV)
    set sa to scroll area 1 of splitter group 1 of (first window whose name contains \"$PVNAME\")
    set bar to (first scroll bar of sa whose value of attribute \"AXOrientation\" is \"AXVerticalOrientation\")
    set value of bar to $1
  end tell" > /dev/null; }

# the scratch settings of this run (en -> ko, Apple, the log on), the script profile when there is one; checked by the app
python3 -I - "$MWOYEO_SETTINGS_FILE" "$RUN/export" "$MEM" <<'PY'
import json, sys
path, export, mem = sys.argv[1:4]
s = {"sourceLanguage": "en", "targetLanguage": "ko", "checksForUpdates": False, "savesTranscripts": True, "exportFolder": export,
     "transcriptFormats": ["jsonl"], "shortcuts": {}, "profiles": []}
if mem:
    p = dict(json.load(open(mem, encoding="utf-8"))["profiles"][0])
    p["when"] = [{"app": "com.apple.Preview"}]
    s["profiles"] = [p]
json.dump(s, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
[ "$(app --check-settings "$MWOYEO_SETTINGS_FILE")" = ok ] || { app --check-settings "$MWOYEO_SETTINGS_FILE" >&2; exit 1; }
defaults delete film3.paper > /dev/null 2>&1; blob=$(printf '{"hasCompletedOnboarding":true}' | xxd -p | tr -d '\n')
defaults write film3.paper settings -data "$blob"; defaults write film3.paper settingsMirror -data "$blob"
DEV=$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | sed -n 's/.*\[\([0-9]*\)\] Capture screen 0.*/\1/p' | head -1)
[ -n "$DEV" ] || { echo "record-paper: no 'Capture screen 0' among the avfoundation devices" >&2; exit 2; }

open -F -a Preview "$PDF"
for _ in $(seq 1 60); do lsappinfo info -only pid -app com.apple.Preview | grep -q '[0-9]' && break; sleep 0.5; done
PV=$(lsappinfo info -only pid -app com.apple.Preview | tr -dc 0-9); [ -n "$PV" ] || { echo "record-paper: Preview did not start" >&2; exit 1; }
started preview "$PV"; sleep 2; pv_ax; pv_scroll "$SCROLL"; note preview "pid $PV window placed, page scrolled to $SCROLL"
quiet_end=$((SECONDS + ${QUIET:-0})); while [ -n "$(fgn)" ] && [ $SECONDS -lt $quiet_end ]; do sleep 3; done
[ -z "$(fgn)" ] || { echo "record-paper: another window is over the frame: $(fgn | head -2) (QUIET=<s> waits for it)" >&2; exit 3; }
reader_ready() { local end=$((SECONDS + $1)); while [ $SECONDS -lt $end ]; do
    kill -0 "$APP" 2>/dev/null || { echo "record-paper: the app quit: $(grep -v '^\[trace\]' "$RUN/app.err" | tail -2)" >&2; exit 1; }
    /usr/bin/log show --last 15m --predicate "processID == $APP" --style compact 2>/dev/null | grep -q 'reader answered role=lines' && return 0; sleep 1; done; return 1; }
[ "${PARK:-1}" = 1 ] && { pointer > "$RUN/pointer"; warp 16 900; }
pointer_clear || [ "${POINTER:-}" = ok ] || { echo "record-paper: the pointer is inside the take; park it outside (POINTER=ok records anyway)" >&2; exit 1; }
( while :; do pointer_clear || echo "$(date +%s) $(pointer)" >> "$RUN/pointer-in.log"; f=$(fgn); [ -z "$f" ] || echo "$(date +%s) $f" >> "$RUN/foreign.log"; sleep 0.5; done ) & started watch $!
# the page is at the paragraph before anything runs (a page scrolled under a lens is a different case: defects.md D5); the take starts before the lens is added, so the lens's
# first appearance and its first read are in it (the wait for the reader is cut in the edit)
ffmpeg -hide_banner -loglevel info -nostats -nostdin -y -f avfoundation -capture_cursor 0 -capture_mouse_clicks 0 -framerate 60 -pixel_format nv12 -i "$DEV:none" \
    ${CROP:+-vf crop=$CROP} -fps_mode cfr -r 60 -c:v h264_videotoolbox -b:v "${MBPS}M" -pix_fmt yuv420p -movflags +faststart "$RUN/$NAME.mp4" > "$RUN/ffmpeg.log" 2>&1 &
started ffmpeg $!
for _ in $(seq 1 150); do [ "$(stat -f %z "$RUN/$NAME.mp4" 2>/dev/null || echo 0)" -gt 200000 ] && break; sleep 0.1; done
[ "$(stat -f %z "$RUN/$NAME.mp4" 2>/dev/null || echo 0)" -gt 200000 ] || { echo "record-paper: ffmpeg writes no frames (Screen Recording?)" >&2; exit 1; }
note rec "${CROP:-the whole screen}"
note rec0 "$(python3 -I -c 'import re, sys, time; s = float(re.search(r"start: ([0-9.]+)", open(sys.argv[1]).read()).group(1))
print("%.3f" % (s - time.clock_gettime(time.CLOCK_UPTIME_RAW) + time.time()))' "$RUN/ffmpeg.log")"
sleep 2
MWOYEO_TRACE=1 "$REPO/tools/ane-env.sh" run pool -- "$BIN" --add-region "$REGION" > "$RUN/app.out" 2> "$RUN/app.err" < /dev/null &
APP=$!; started app $APP; note lens "$REGION"
reader_ready 900 || { echo "record-paper: the lens's reader never got ready (see $RUN/app.err)" >&2; exit 1; }
note ready "the reader answered"
# the lens's first translation comes ~20 s after the reader answered (defects.md D6): wait until Vision reads Hangul in the band and the count has stopped changing, then hold
mkdir -p "$OUT"; HANGUL=$OUT/hangul; [ "$HANGUL" -nt "$HERE/hangul.swift" ] || swiftc -O "$HERE/hangul.swift" -o "$HANGUL" || exit 2
band=$RUN/band.png
wait_korean() {   # until Vision reads >= MINKO Hangul in the lens band and the count has stopped changing for 3 samples
    local n=0 prev=-1 same=0 end=$((SECONDS + SEC))
    while [ $SECONDS -lt $end ]; do
        n=$(screencapture -x -R"$REGION" "$band" && "$HANGUL" "$band"); n=${n:-0}
        if [ "$n" -ge "$MINKO" ] && [ "$n" = "$prev" ]; then same=$((same + 1)); else same=0; fi; prev=$n; [ $same -ge 3 ] && break; sleep 1
    done
    [ $same -ge 3 ] || { echo "record-paper: the lens showed no settled Korean in ${SEC} s (last count $n, MINKO $MINKO)" >&2; return 1; }
    note korean "$n Hangul characters in the band, settled"
}
# beat 2 by Accessibility only (no mouse, no keys): every step is noted with its time; D12: the Test button answers AXPress but shows no Before/After rows
ui_steps() {
    local X="$HERE/ax.sh" A=$APP
    note step "lens menu"; "$X" action "$A" "번역 렌즈" "메뉴" > /dev/null || return 1; sleep 1.8
    note step "memory sheet"; "$X" press "$A" "미리보기 메모리" > /dev/null || return 1; "$X" wait "$A" "미리보기 메모리, " 15 > /dev/null || return 1; sleep 0.8
    "$X" move "$A" "=번역" 40 110 > /dev/null; note step "settings window moved clear of the lens"; sleep 1.2
    note step "customize"; "$X" press "$A" "사용하는 때, 언어, 문맥, 다시 쓰기" > /dev/null || return 1; sleep 1.5
    note step "scroll"; for v in 0.3 0.6 0.85 1.0; do "$X" bar "$A" "=번역" "$v" > /dev/null || return 1; sleep 0.4; done; sleep 0.8
    note step "script row"; "$X" press "$A" "꺼짐" > /dev/null || return 1; sleep 1.2; "$X" bar "$A" "=번역" 1.0 > /dev/null; sleep 0.9
    note step "typing starts"; "$X" type "$A" "스크립트 내용" "$REPO/tools/film3/terms/script.js" 4 0.06 > /dev/null || return 1; note step "typing ends"; sleep 1.0
    note step "run switch"; "$X" press "$A" "스위치" > /dev/null || return 1; sleep 1.2
    note step "test"; "$X" pressafter "$A" "시험할 줄" AXButton > /dev/null || return 1; sleep 3.0
    note step "done"; "$X" presslast "$A" "=번역" AXButton > /dev/null || return 1; sleep 1.5
    note step "settings window closed"; osascript -e "tell application \"System Events\" to tell (first process whose unix id is $A)
        repeat with w in windows
          if name of w is \"번역\" then perform action \"AXPress\" of (first button of w whose subrole is \"AXCloseButton\")
        end repeat
      end tell" > /dev/null 2>&1; sleep 1.2
    note step "the page is read again with the script"; pv_scroll 0.5; sleep 3; pv_scroll "$SCROLL"
}
wait_korean || exit 1
sleep "$HOLD"
if [ "$part" = ui ]; then ui_steps || { echo "record-paper: a UI step found nothing (see events)" >&2; exit 1; }; wait_korean || exit 1; sleep "$HOLD"; fi
pv_scroll 0.6; note away "the cue closes"; sleep 6
stop ffmpeg INT; stop watch
stop app; pv_close
cat "$RUN"/export/Transcripts/*.jsonl > "$OUT/$NAME.jsonl" 2>/dev/null
cp "$RUN/$NAME.mp4" "$OUT/$NAME.mp4"; cp "$EV" "$OUT/$NAME.events.jsonl"; cp "$MWOYEO_SETTINGS_FILE" "$OUT/$NAME.settings.json"
python3 -I "$REPO/tools/film3/terms/count-terms.py" "$HERE/../terms/script.js" /tmp/film3/xrender --log "$OUT/$NAME.jsonl" > "$OUT/$NAME.count.txt" 2>&1
echo "record-paper: $OUT/$NAME.mp4 ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/$NAME.mp4") s), log entries $(wc -l < "$OUT/$NAME.jsonl" | tr -d ' ')"
grep -E "^(all|control|sign)" "$OUT/$NAME.count.txt"
grep -q '"engine":"apple"' "$OUT/$NAME.jsonl" || { echo "record-paper: the log has no entry under the Apple engine" >&2; exit 1; }
[ ! -s "$RUN/foreign.log" ] || { echo "record-paper: another process had a window over the frame during the take ($(head -1 "$RUN/foreign.log")): not a usable take" >&2; exit 3; }
exit 0
