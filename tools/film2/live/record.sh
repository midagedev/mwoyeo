#!/bin/bash
# Records the real app in use on this Mac's screen: our RPG stage stepping through film-ja-ko-1 in a Chrome window (player.html), a
# Mwoyeo lens over its name plate and dialogue box translating live, ja -> ko, with Ollama gemma3:4b added as an OpenAI-compatible
# engine (http://localhost:11434/v1, thinking off). One part per call; Bash sandbox off (screen capture, the app, Chrome):
#   record.sh before                         no memory               -> $OUT/before-live.{mp4,jsonl,events.jsonl,settings.json,count.txt,settle.txt}
#   record.sh after <settings.json> [name]   the memory: the first appProfiles item of <settings.json> (e.g. ../plates/settings/after-hand.json,
#                                            or the memory Claude wrote), its bundleID set to com.google.Chrome (the app in front; the
#                                            profile is found by it), written into the running app's settings file once its lens reads
#                                            (the app re-reads the file within a second), then the same lines -> $OUT/<name>.* (after-live-hand)
#   record.sh log [<log.jsonl>]              that translation log (default: before-live's) opened in TextEdit, scrolled once -> $OUT/log-live.mp4
#   record.sh mcp [name]                     the memory through MCP: the app (BIN default the --mcp build, dd-main1) on its own settings file
#                                            ($OUT/s/settings.json: agentConnection on, exportFolder $OUT/s/export holding before-live's log, no
#                                            profile) shows IDS' first line and keeps it until Claude's set_memory lands in that file (run the
#                                            claude-take rig once `record: ready for Claude` prints), REDRAW s more, then IDS -> $OUT/<name>.*
#                                            (after-live; <name>.memory.jsonl: the log after the memory landed)
# Every part starts its own app, Chrome window and recording and quits them (pids in $OUT/runs/<name>/pids; nothing else is signalled).
# Pacing: a line goes once the app's log read it and the lens stayed unchanged HOLD s since (serve.py tails the log and reads the lens's
# inside from ffmpeg), never before DWELL s, never after MOST s; PACE=0 gives every line DWELL s instead.
# ENV: BIN (the app; a newer build: BIN=<…>/Mwoyeo.app/Contents/MacOS/Mwoyeo), DWELL (4), HOLD (2), MOST (30), PACE (1), LEAD (s of the
#      empty box first, 3), TAIL (4), FROM/TO (line ids, 1/36; a trial: TO=5), STAGE (the page under tools/, film2/stage2/game.html),
#      PARK (1: the pointer is moved to the bottom left for the take and back after; this macOS draws it into the capture),
#      SIZE (its CSS side: stage2 1280, stage1 960), STEPS (self: the page steps itself, stage2; swap: two frames), SCENE (stage2: still, the scene moves only as a line comes in, or live), ALIGN (where the stage square sits across the screen: right, center, left), SCROLL (s, the log part: 6), LENS (the lens over the stage, CSS px x,y,w,h: name plate + box), OUT (/tmp/film2/live), MBPS (16)
# The app runs with MWOYEO_SETTINGS_FILE=$OUT/settings.json (the one scratch settings file of every part), MWOYEO_DEFAULTS_SUITE=film2.live,
# MWOYEO_MEMORY_SECRETS=1, MWOYEO_TRACE=1, under tools/ane-env.sh run pool. The translation log is the app's own (savesTranscripts, jsonl,
# exportFolder $OUT/runs/<name>/export). FAILURE MODES IT BLOCKS: a recording of the user's real app or settings (every call of the app
# goes through `app` with the scratch env); a part whose memory never reached the app (the written file must pass --check-settings and the
# lens must be reading before it is written); a line changed before the lens translated it and settled (serve.py paces by the log;
# settle.py checks each line's time on screen after its translation and after the lens's last change).
set -u
HERE=$(cd "$(dirname "$0")" && pwd); TOOLS=$(cd "$HERE/../.." && pwd); REPO=$(cd "$TOOLS/.." && pwd)
BIN_DEFAULT=/tmp/latin-runs/dd-sch/Build/Products/Debug/Mwoyeo.app/Contents/MacOS/Mwoyeo
OUT=${OUT:-/tmp/film2/live}; DWELL=${DWELL:-4}; HOLD=${HOLD:-2}; MOST=${MOST:-30}; PACE=${PACE:-1}; LEAD=${LEAD:-3}; TAIL=${TAIL:-4}; FROM=${FROM:-1}; TO=${TO:-36}; MBPS=${MBPS:-16}
# The stage and its geometry (CSS px of the stage at SIZE): stage2's panel x 48..1232 y 988..1232 with its name tag on the top edge
# (y 960..1016), inside the 72 u the scene keeps still around the panel; stage1's plate and box.
STAGE=${STAGE:-film2/stage2/game.html}; ALIGN=${ALIGN:-right}
case $STAGE in
    *stage2/*) SIZE=${SIZE:-1280}; LENS=${LENS:-36,940,1208,304}; STEPS=${STEPS:-self}; SCENE=${SCENE:-still} ;;
    *) SIZE=${SIZE:-960}; LENS=${LENS:-24,690,912,246}; STEPS=${STEPS:-swap}; SCENE=live ;;
esac
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"; PROFILE=$OUT/chrome; FRONT=com.google.Chrome
SETTINGS=$OUT/settings.json; SUITE=film2.live; EXPORT=""; AGENT=false; ENGINE_ID=6F1A2B3C-4D5E-4F60-8A9B-0C1D2E3F4A5B
# KIND=anthropic (MODEL, default claude-haiku-5-5): an added Anthropic engine, its key to the app as MWOYEO_ENGINE_KEY from ANTHROPIC_API_KEY,
# in memory only; KIND=deepl: DeepL Free with context on and its instructions from the memory, the key from DEEPL_API_KEY;
# the default is Ollama gemma3:4b as an OpenAI-compatible engine.
case ${KIND:-ollama} in
    anthropic) MODEL=${MODEL:-claude-haiku-5-5}
               ENGINE='{"kind": "anthropic", "name": "Claude '"$MODEL"'", "baseURL": "'"${BASEURL:-https://api.anthropic.com}"'", "model": "'"$MODEL"'", "thinking": "off"}'
               export MWOYEO_ENGINE_KEY="${ANTHROPIC_API_KEY:?KIND=anthropic needs ANTHROPIC_API_KEY}" ;;
    deepl) ENGINE='{"kind": "deepL", "name": "DeepL", "baseURL": "https://api-free.deepl.com", "context": {"enabled": true, "deepLInstructions": true}}'
           export MWOYEO_ENGINE_KEY="${DEEPL_API_KEY:?KIND=deepl needs DEEPL_API_KEY}" ;;
    *) ENGINE='{"kind": "openAICompatible", "name": "Ollama gemma3:4b", "baseURL": "http://localhost:11434/v1", "model": "gemma3:4b", "thinking": "off"}' ;;
esac
usage() { sed -n '5,15p' "$0" >&2; exit 2; }
part=${1:-}; MEM=""
case $part in
    before) NAME=${NAME:-before-live} ;;
    after) MEM=${2:-}; [ -s "$MEM" ] || usage; MEM=$(cd "$(dirname "$MEM")" && pwd)/$(basename "$MEM"); NAME=${3:-after-live-hand} ;;
    log) LOG=${2:-$OUT/before-live.jsonl}; [ -s "$LOG" ] || { echo "record: no log $LOG" >&2; exit 2; }; NAME=log-live ;;
    mcp) NAME=${2:-after-live}; SETTINGS=$OUT/s/settings.json; EXPORT=$OUT/s/export; AGENT=true
         BIN_DEFAULT=/tmp/latin-runs/dd-main1/Build/Products/Debug/Mwoyeo.app/Contents/MacOS/Mwoyeo
         IDS=${IDS:-2,7,9,12,13,14,17,19,22,28,29,30,31,34,2}; REDRAW=${REDRAW:-12} ;;
    *) usage ;;
esac
BIN=${BIN:-$BIN_DEFAULT}
[ -x "$BIN" ] || { echo "record: no app at $BIN" >&2; exit 2; }
RUN=$OUT/runs/$NAME; rm -rf "$RUN"; mkdir -p "$RUN"; PIDS=$RUN/pids; EV=$RUN/events.jsonl; : > "$PIDS"; : > "$EV"
export MWOYEO_SETTINGS_FILE=$SETTINGS MWOYEO_DEFAULTS_SUITE=$SUITE MWOYEO_MEMORY_SECRETS=1
app() { "$BIN" "$@" < /dev/null; }                      # every call of the app carries the scratch env above
note() { python3 -I -c 'import json, sys, time; print(json.dumps({"t": round(time.time(), 3), "k": sys.argv[1], "v": sys.argv[2]}, ensure_ascii=False))' "$1" "${2:-}" >> "$EV"; echo "record: $1 ${2:-}"; }
started() { echo "$1 $2" >> "$PIDS"; }
stop() {   # <name> [signal]: signal every pid this run recorded under <name>, wait for each to go (10 s)
    local p
    for p in $(awk -v n="$1" '$1 == n {print $2}' "$PIDS"); do
        kill -"${2:-TERM}" "$p" 2>/dev/null || continue
        for _ in $(seq 1 100); do kill -0 "$p" 2>/dev/null || continue 2; sleep 0.1; done
        echo "record: $1 ($p) did not quit in 10 s" >&2
    done
}
cleanup() {
    stop ffmpeg INT; stop watch; stop textedit; stop app; stop chrome; stop serve; unpark
    [ -s "$RUN/pointer-in.log" ] && echo "record: the pointer was inside the take $(wc -l < "$RUN/pointer-in.log" | tr -d ' ') times (see $RUN/pointer-in.log)" >&2
}
trap cleanup EXIT
trap 'exit 130' INT TERM
waitfor() {   # <seconds> <command…>: until the command succeeds, or fail
    local n=$(( $1 * 10 )); shift
    for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 0.1; done; return 1
}
front() { osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null; }

# The visible frame of the main display (points, top-left origin): the window fills it, so the lens's overscan reads only the game.
read -r VX VY VW VH < <(osascript -l JavaScript -e 'ObjC.import("AppKit"); var s = $.NSScreen.mainScreen, f = s.frame, v = s.visibleFrame;
  [v.origin.x, f.size.height - v.origin.y - v.size.height, v.size.width, v.size.height].join(" ")')
DEV=$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 | sed -n 's/.*\[\([0-9]*\)\] Capture screen 0.*/\1/p' | head -1)
[ -n "$DEV" ] || { echo "record: no 'Capture screen 0' among the avfoundation devices" >&2; exit 2; }

serve() {   # the player's server (serve.py), on a free port; sets PORT. Arguments go to serve.py.
    PORT=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
    python3 -I "$HERE/serve.py" --root "$TOOLS" --port "$PORT" --events "$EV" --go "$RUN/go" "$@" > "$RUN/serve.log" 2>&1 &
    SERVE_PID=$!; started serve $SERVE_PID
    waitfor 5 curl -s -o /dev/null "http://127.0.0.1:$PORT/go" || { echo "record: the player's server did not start" >&2; exit 1; }
}

chrome() {   # <query>: the player in a Chrome app window over the visible frame, its own profile (never the user's); waits for its rect
    if [ -L "$PROFILE/SingletonLock" ] && kill -0 "$(readlink "$PROFILE/SingletonLock" | sed 's/.*-//')" 2>/dev/null; then
        echo "record: a Chrome on $PROFILE is still open (a part that did not finish); quit it first" >&2; exit 1
    fi
    mkdir -p "$PROFILE/Default"
    python3 -I - "$PROFILE/Default/Preferences" <<'PY'
import json, os, sys
p = sys.argv[1]
d = json.load(open(p)) if os.path.exists(p) else {}
d["translate"] = {"enabled": False}          # no "translate this page?" bubble over a Japanese page
json.dump(d, open(p, "w"))
PY
    "$CHROME" --user-data-dir="$PROFILE" --no-first-run --no-default-browser-check --hide-crash-restore-bubble \
        --app="http://127.0.0.1:$PORT/film2/live/player.html?$1" --window-position="$VX,$VY" --window-size="$VW,$VH" > "$RUN/chrome.log" 2>&1 &
    started chrome $!
}

geometry() {   # from the player's rect: the lens (points) for --add-region, the crop (pixels) of the stage square, and the lens's inside
               # in that crop (pixels, inset 16 pt from the lens's edge so its glow is left out) with its quarter size, for the pacing feed
    python3 -I - "$EV" "$LENS" <<'PY'
import json, sys
rect = [json.loads(l) for l in open(sys.argv[1]) if '"rect"' in l][-1]
x, y, side, z = float(rect["x"]), float(rect["y"]), float(rect["side"]), float(rect["zoom"])
lx, ly, lw, lh = (float(v) for v in sys.argv[2].split(","))
even = lambda v: 2 * int(round(v))                 # whole points -> even pixels at 2x
L = (x + lx * z, y + ly * z, lw * z, lh * z)
cx, cy = even(x), even(y)
ix, iy = int(L[0] * 2 - cx + 32), int(L[1] * 2 - cy + 32)
iw, ih = int(L[2] * 2 - 64) // 8 * 8, int(L[3] * 2 - 64) // 8 * 8
print("%.1f,%.1f,%.1f,%.1f" % L, "%d:%d:%d:%d" % (even(side), even(side), cx, cy), "%d:%d:%d:%d" % (iw, ih, ix, iy), iw // 4, ih // 4)
PY
}

pointer() {   # where the mouse pointer is (points, top-left origin)
    osascript -l JavaScript -e 'ObjC.import("AppKit"); var p = $.NSEvent.mouseLocation; [Math.round(p.x), Math.round($.NSScreen.screens.objectAtIndex(0).frame.size.height - p.y)].join(",")'
}
pointer_clear() {   # whether the pointer is outside the crop (this macOS draws it into the capture: ffmpeg's -capture_cursor 0 is not applied)
    local px py; IFS=, read -r px py <<< "$(pointer)"
    IFS=: read -r cw ch cx cy <<< "$CROP"
    [ "$px" -lt $((cx / 2)) ] || [ "$px" -ge $(((cx + cw) / 2)) ] || [ "$py" -lt $((cy / 2)) ] || [ "$py" -ge $(((cy + ch) / 2)) ]
}

warp() { osascript -l JavaScript -e "ObjC.import('CoreGraphics'); \$.CGWarpMouseCursorPosition(\$.CGPointMake($1, $2))" > /dev/null; }
park() {     # the pointer to the bottom left, over this run's own window (not a hot corner, not the Dock); where it was is kept
    [ -s "$RUN/pointer" ] || pointer > "$RUN/pointer"
    warp 16 900
}
unpark() {   # the pointer back where park found it
    [ -s "$RUN/pointer" ] || return 0
    local x y; IFS=, read -r x y < "$RUN/pointer"; warp "$x" "$y"; rm -f "$RUN/pointer"
}

record() {   # starts ffmpeg on the crop (with a FEED, also the lens's inside, grey at 30 fps, into it); returns once frames are written
    [ "${PARK:-1}" = 1 ] && park
    pointer_clear || [ "${POINTER:-}" = ok ] || {
        echo "record: the mouse pointer is at $(pointer), inside the take ($CROP px); park it outside (POINTER=ok records anyway)" >&2; exit 1; }
    # Whether it came back while recording (someone used the mouse): every 0.5 s, its position when inside, for the report.
    ( while :; do pointer_clear || echo "$(date +%s) $(pointer)" >> "$RUN/pointer-in.log"; sleep 0.5; done ) & started watch $!
    local video=(-vf "crop=$CROP") feed=()
    if [ -n "${FEED:-}" ]; then
        video=(-filter_complex "[0:v]crop=$CROP,split=2[rec][in];[in]crop=$INSIDE,scale=$SW:$SH,fps=30,format=gray[g]" -map "[rec]")
        feed=(-map "[g]" -f rawvideo "$FEED")
    fi
    ffmpeg -hide_banner -loglevel info -nostats -nostdin -y -f avfoundation -capture_cursor 0 -capture_mouse_clicks 0 -framerate 60 \
        -pixel_format nv12 -i "$DEV:none" "${video[@]}" -fps_mode cfr -r 60 -c:v h264_videotoolbox -b:v "${MBPS}M" -pix_fmt yuv420p \
        -movflags +faststart "$RUN/$NAME.mp4" ${feed[@]+"${feed[@]}"} > "$RUN/ffmpeg.log" 2>&1 &
    started ffmpeg $!
    waitfor 15 sh -c 'test "$(stat -f %z "$1" 2>/dev/null || echo 0)" -gt 200000' - "$RUN/$NAME.mp4" \
        || { echo "record: ffmpeg writes no frames (Screen Recording?)" >&2; exit 1; }
    note rec "$CROP"
    # The video's first frame in epoch seconds: avfoundation stamps frames by the host clock (CLOCK_UPTIME_RAW; ffmpeg prints the
    # input's start), so settle.py places every page event in the video without guessing from the pixels.
    note rec0 "$(python3 -I -c 'import re, sys, time; s = float(re.search(r"start: ([0-9.]+)", open(sys.argv[1]).read()).group(1))
print("%.3f" % (s - time.clock_gettime(time.CLOCK_UPTIME_RAW) + time.time()))' "$RUN/ffmpeg.log")"
}

settings() {   # <profile json or empty>: the scratch settings file of this run, checked by the app
    python3 -I - "$SETTINGS" "$ENGINE_ID" "${EXPORT:-$RUN/export}" "$FRONT" "${1:-}" "$AGENT" "$ENGINE" <<'PY'
import json, sys
path, engine, export, front, mem, agent = sys.argv[1:7]
s = {"sourceLanguage": "ja", "targetLanguage": "ko",
     "engines": [dict(json.loads(sys.argv[7]), id=engine)],
     "customEngineID": engine, "checksForUpdates": False, "savesTranscripts": True, "exportFolder": export,
     "transcriptFormats": ["jsonl"], "shortcuts": {}, "appProfiles": []}
if agent == "true":
    s["agentConnection"] = True
if mem:
    profile = dict(json.load(open(mem, encoding="utf-8"))["appProfiles"][0])
    profile["bundleID"] = front
    s["appProfiles"] = [profile]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
    [ "$(app --check-settings "$SETTINGS.tmp")" = ok ] || { app --check-settings "$SETTINGS.tmp" >&2; exit 1; }
    mv "$SETTINGS.tmp" "$SETTINGS"
}

log_part() {
    serve; chrome "ctl=1&blank=1&align=$ALIGN"
    waitfor 15 grep -q '"rect"' "$EV" || { echo "record: the player never reported" >&2; exit 1; }
    read -r _ CROP _ < <(geometry)
    IFS=: read -r CW CH CX CY <<< "$CROP"
    WX=$((CX / 2)); WY=$((CY / 2)); WS=$((CW / 2))
    # TextEdit, fresh (no restored windows), its plain-text font (Menlo) at 18 pt for this run only (argument domain), the log as the app
    # wrote it.
    # Through LaunchServices: the sandboxed TextEdit crashes when its binary is started directly. It must not be running already (its
    # pid is then ours to quit).
    lsappinfo info -only pid -app com.apple.TextEdit | grep -q '[0-9]' && { echo "record: TextEdit is open; the log part opens its own" >&2; exit 1; }
    open -F -a TextEdit "$LOG" --args -NSFixedPitchFontSize 18
    waitfor 15 sh -c 'lsappinfo info -only pid -app com.apple.TextEdit | grep -q "[0-9]"' || { echo "record: TextEdit did not start" >&2; exit 1; }
    TE=$(lsappinfo info -only pid -app com.apple.TextEdit | tr -dc 0-9); started textedit "$TE"
    waitfor 15 sh -c "osascript -e 'tell application \"System Events\" to get name of window 1 of (first process whose unix id is $TE)' > /dev/null 2>&1" \
        || { echo "record: TextEdit shows no window" >&2; exit 1; }
    osascript -e "tell application \"System Events\" to tell (first process whose unix id is $TE)
        set frontmost to true
        set position of window 1 to {$WX, $WY}
        set size of window 1 to {$WS, $WS}
    end tell" > /dev/null
    sleep 1; record; sleep 2
    # Scrolled once through, top to bottom, by the window's own vertical scroll bar (an accessibility value, 0..1): 300 steps on a clock,
    # SCROLL s in all (a set takes 20-45 ms, so a step waits only for its time; the time it took is noted).
    note scroll start
    osascript -e "use framework \"Foundation\"
    use scripting additions
    tell application \"System Events\" to tell (first process whose unix id is $TE)
        set bar to (first scroll bar of scroll area 1 of window 1 whose value of attribute \"AXOrientation\" is \"AXVerticalOrientation\")
    end tell
    set t0 to current application's NSDate's timeIntervalSinceReferenceDate()
    repeat with i from 0 to 300
        set wait to t0 + i * ${SCROLL:-6} / 300 - (current application's NSDate's timeIntervalSinceReferenceDate())
        if wait > 0 then delay wait
        tell application \"System Events\" to set value of bar to i / 300
    end repeat
    tell application \"System Events\" to return (value of bar as text) & \" in \" & ((round (((current application's NSDate's timeIntervalSinceReferenceDate()) - t0) * 10)) / 10) & \" s\"
    " > "$RUN/scroll.log" 2>&1 || { echo "record: scrolling failed: $(cat "$RUN/scroll.log")" >&2; }
    note scroll "end at $(cat "$RUN/scroll.log")"
    sleep 2; stop ffmpeg INT; stop watch
    osascript -e 'tell application id "com.apple.TextEdit" to quit saving no' > /dev/null 2>&1; stop textedit; stop chrome
    cp "$RUN/$NAME.mp4" "$OUT/$NAME.mp4"
    echo "record: $OUT/$NAME.mp4 ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/$NAME.mp4") s) from $LOG"
    exit 0
}

take_part() {
if [ "$part" = mcp ]; then   # the memory part's own folder: before-live's log (as the app wrote it) where its settings point
    mkdir -p "$EXPORT/Transcripts" "$(dirname "$SETTINGS")"
    ls "$EXPORT/Transcripts"/*.jsonl > /dev/null 2>&1 || cp "$OUT/runs/before-live/export/Transcripts/"*.jsonl "$EXPORT/Transcripts/" \
        || { echo "record: no before-live log in $OUT/runs/before-live/export/Transcripts" >&2; exit 1; }
    ls "$EXPORT/Transcripts"/*.jsonl > "$RUN/logs-before"
fi
case ${KIND:-ollama} in anthropic|deepl) ;; *) curl -s --max-time 5 http://localhost:11434/api/tags | grep -q '"gemma3:4b"' || { echo "record: Ollama has no gemma3:4b at localhost:11434" >&2; exit 1; } ;; esac
settings ""
defaults delete "$SUITE" > /dev/null 2>&1
blob=$(printf '{"hasCompletedOnboarding":true}' | xxd -p | tr -d '\n')   # the onboarding is a preference, not a settings.json key
defaults write "$SUITE" settings -data "$blob"; defaults write "$SUITE" settingsMirror -data "$blob"
FEED=""
MEMWAIT=(); [ "$part" = mcp ] && MEMWAIT=(--memory "$SETTINGS" --bundle "$FRONT" --redraw "$REDRAW")
if [ "$PACE" = 1 ]; then FEED=$RUN/lens.gray; mkfifo "$FEED"
    serve --lens-feed "$FEED" --transcripts "${EXPORT:-$RUN/export}/Transcripts" --hold "$HOLD" --most "$MOST" ${MEMWAIT[@]+"${MEMWAIT[@]}"}
else serve; fi
chrome "ctl=1&pace=$PACE&align=$ALIGN&steps=$STEPS&scene=$SCENE&stage=$STAGE&size=$SIZE&dwell=$DWELL&lead=$LEAD&tail=$TAIL&from=$FROM&to=$TO${IDS:+&ids=$IDS}"
waitfor 15 grep -q '"rect"' "$EV" || { echo "record: the player never reported its rect" >&2; exit 1; }
read -r LENSRECT CROP INSIDE SW SH < <(geometry)
[ -n "$FEED" ] && echo "$SW $SH" > "$FEED.size"
note lens "$LENSRECT"
MWOYEO_TRACE=1 "$REPO/tools/ane-env.sh" run pool -- "$BIN" --add-region "$LENSRECT" > "$RUN/app.out" 2> "$RUN/app.err" < /dev/null &
APP=$!; started app $APP
# The lens is up once it has read the screen once (a cold Neural Engine compile can take minutes); an app that quit (ane-env's disk
# floor: exit 75) ends the part at once.
lens_reads() { kill -0 "$APP" 2>/dev/null || { echo "record: the app quit: $(grep -v '^\[trace\]' "$RUN/app.err" | tail -2)" >&2; exit 1; }
               grep -q 'fast: OCR [0-9]' "$RUN/app.err"; }
waitfor 400 lens_reads || { echo "record: the lens never read (see $RUN/app.err)" >&2; exit 1; }
note front "$(front)"
if [ -n "$MEM" ]; then
    sleep 2
    settings "$MEM"                       # the memory, into the same file, while the app runs
    note profile "$MEM"
    sleep 3                               # the app applies a saved file within a second
fi
record
touch "$RUN/go"; note go
[ "$part" = mcp ] && echo "record: ready for Claude: the memory goes into $SETTINGS (suite $SUITE); the first line waits for it" 
waitfor 3600 grep -q '"k": "end"' "$EV" || { echo "record: the player never ended" >&2; exit 1; }
note end "$(front)"
stop ffmpeg INT; stop watch; stop serve
sleep 4                                   # the log holds an entry 3 s for a fuller reading of its line
stop app; stop chrome
if [ "$part" = mcp ]; then   # this run's own log (the folder also holds before-live's), and the part of it after the memory landed
    for f in "$EXPORT/Transcripts"/*.jsonl; do grep -qxF "$f" "$RUN/logs-before" || cat "$f"; done > "$OUT/$NAME.jsonl"
    python3 -I - "$EV" "$OUT/$NAME.jsonl" > "$OUT/$NAME.memory.jsonl" <<'PY'
import datetime, json, sys
landed = next((e["t"] for e in map(json.loads, open(sys.argv[1], encoding="utf-8")) if e.get("k") == "memory"), None)
for line in open(sys.argv[2], encoding="utf-8"):
    if landed is not None and datetime.datetime.fromisoformat(json.loads(line)["time"]).timestamp() >= landed:
        sys.stdout.write(line)
PY
else cat "$RUN"/export/Transcripts/*.jsonl > "$OUT/$NAME.jsonl" 2>/dev/null; fi
cp "$RUN/$NAME.mp4" "$OUT/$NAME.mp4"; cp "$EV" "$OUT/$NAME.events.jsonl"; cp "$SETTINGS" "$OUT/$NAME.settings.json"
python3 -I "$HERE/settle.py" "$OUT/$NAME.mp4" "$OUT/$NAME.events.jsonl" --log "$OUT/$NAME.jsonl" --per-line > "$OUT/$NAME.settle.txt" 2>&1
settled=$?
if [ "$part" = mcp ]; then
    grep -q '"k": "memory"' "$EV" || { echo "record: the memory never landed in $SETTINGS" >&2; settled=1; }
    python3 -I "$HERE/count-live.py" --events "$OUT/before-live.events.jsonl" --events "$OUT/$NAME.events.jsonl" "$OUT/before-live.jsonl" \
        "$OUT/$NAME.memory.jsonl" > "$OUT/$NAME.count.txt" 2>&1
else python3 -I "$HERE/count-live.py" --events "$OUT/$NAME.events.jsonl" "$OUT/$NAME.jsonl" > "$OUT/$NAME.count.txt" 2>&1; fi
echo "record: $OUT/$NAME.mp4 ($(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT/$NAME.mp4") s), log lines $(wc -l < "$OUT/$NAME.jsonl" | tr -d ' ')"
grep -E '^(settle|log):' "$OUT/$NAME.settle.txt"
grep -q '"page"' "$OUT/$NAME.events.jsonl" && { echo "record: the stage showed another line than the player's (events: page)" >&2; exit 1; }
exit $settled
}

# The parts are functions called last: an error that aborts a command (bash goes on with the next one) then ends the script, never
# runs one part's steps in another.
if [ "$part" = log ]; then log_part; else take_part; fi
