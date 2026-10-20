#!/bin/bash
# The one command that renders every stage plate through the real app for a given settings file.
#   usage: render.sh <settings.json> <out-name> [id ...]      all 36 lines without ids; -> out/<out-name>/L<id>.{png,out,err,rc}
# What it does, per line, exactly as the product would be run on a screenshot of that stage:
#   Mwoyeo --render out/stage/L<id>.png out/<out-name>/L<id>.png --src ja --tgt ko --scale 2.25 --warm --max-wait 240
#          --profile-app dev.midagedev.film.lumiere --lens-app dev.midagedev.film.lumiere --lens-category public.app-category.role-playing-games
#          --engine-config <engine.json> --transcript out/<out-name>/log/L<id> --transcript-formats jsonl
# the engine being Ollama gemma3:4b as an added OpenAI-compatible engine (context off, the default), the app in front being the stage's own
# bundle ID, and the profile of that app the one in <settings.json> (none in the "before"). A pass-through (tap.py) sits between the app and
# Ollama only to keep every request and reply under out/<out-name>/requests/; it changes nothing the engine sees.
# Afterwards: out/<out-name>/log.jsonl = the 36 transcripts (one process per plate, so one file each) joined in line order; out/<out-name>/summary.txt.
# ENV: STAGE_DIR (the stage PNGs, default out/stage), BIN (the built app), MODEL (gemma3:4b), UPSTREAM (http://127.0.0.1:11434), APP (the stage's bundle ID), ANE_ENV (the lease wrapper of the
#      main tree), SCRATCH. Needs the Bash sandbox off (Vision, the Neural Engine). A new bundle ID compiles for 60-180 s on its first run.
# The app is run with MWOYEO_APP_ID=dev.midagedev.mwoyeo.film (the id it was built with), MWOYEO_DEFAULTS_SUITE=film2.plates, MWOYEO_MEMORY_SECRETS=1.
set -u
SETTINGS=${1:?usage: render.sh <settings.json> <out-name> [id ...]}; NAME=${2:?usage: render.sh <settings.json> <out-name> [id ...]}; shift 2
HERE=$(cd "$(dirname "$0")" && pwd); SETTINGS=$(cd "$(dirname "$SETTINGS")" && pwd)/$(basename "$SETTINGS")
BIN=${BIN:-/tmp/latin-runs/dd-film2/Build/Products/Debug/Mwoyeo.app/Contents/MacOS/Mwoyeo}
ANE_ENV=${ANE_ENV:-/Users/hckim/repo/mwoyeo/tools/ane-env.sh}
MODEL=${MODEL:-gemma3:4b}; UPSTREAM=${UPSTREAM:-http://127.0.0.1:11434}; APP=${APP:-dev.midagedev.film.lumiere}
SCR=${SCRATCH:-/tmp/film2/plates}; OUT=$HERE/out/$NAME; STAGE=${STAGE_DIR:-$HERE/out/stage}
ids=("$@"); [ ${#ids[@]} -gt 0 ] || ids=($(seq 1 36))
[ -x "$BIN" ] || { echo "render: no app at $BIN" >&2; exit 2; }
for id in "${ids[@]}"; do [ -s "$STAGE/L$id.png" ] || { echo "render: $STAGE/L$id.png missing (run ../stage/shoot.sh)" >&2; exit 2; }; done
mkdir -p "$OUT" "$SCR"; rm -rf "$OUT/requests" "$OUT/log"

export MWOYEO_APP_ID=dev.midagedev.mwoyeo.film MWOYEO_SETTINGS_FILE=$SETTINGS MWOYEO_DEFAULTS_SUITE=film2.plates MWOYEO_MEMORY_SECRETS=1
export MWOYEO_TRACE=1     # the .err keeps what OCR read (ocr-block), which blocks are kept as labels (items:) and what the engine was sent (engine <-)

PORT=$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I "$HERE/tap.py" --upstream "$UPSTREAM" --dump "$OUT/requests" --port "$PORT" > "$OUT/tap.log" 2>&1 &
echo $! > "$OUT/tap.pid"
stop_tap() { kill "$(cat "$OUT/tap.pid")" 2>/dev/null; }
trap stop_tap EXIT
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$PORT/v1/models" && break; sleep 0.1; done
cat > "$OUT/engine.json" <<JSON
{"mwoyeoEngine": 1, "engine": {"name": "Ollama $MODEL", "kind": "openAICompatible", "baseURL": "http://127.0.0.1:$PORT/v1", "model": "$MODEL", "thinking": "off"}}
JSON

for id in "${ids[@]}"; do
    "$ANE_ENV" run pool -- "$BIN" --render "$STAGE/L$id.png" "$OUT/L$id.png" --src ja --tgt ko --scale 2.25 --warm --max-wait 240 \
        --profile-app "$APP" --lens-app "$APP" --lens-category public.app-category.role-playing-games \
        --engine-config "$OUT/engine.json" --transcript "$OUT/log/L$id" --transcript-formats jsonl \
        > "$OUT/L$id.out" 2> "$OUT/L$id.err" < /dev/null
    echo "$?" > "$OUT/L$id.rc"
done

: > "$OUT/log.jsonl"
for id in "${ids[@]}"; do cat "$OUT"/log/L$id/*.jsonl >> "$OUT/log.jsonl" 2>/dev/null; done
ok=0; for id in "${ids[@]}"; do [ "$(cat "$OUT/L$id.rc")" = 0 ] && ok=$((ok + 1)); done
{
    echo "render $NAME: $ok of ${#ids[@]} rc 0; settings $SETTINGS; model $MODEL; app $APP"
    echo "requests kept: $(ls "$OUT/requests" 2>/dev/null | grep -c request.json); log.jsonl lines: $(wc -l < "$OUT/log.jsonl" | tr -d ' ')"
    echo "log lines with app=$APP: $(grep -c "\"app\":\"$APP\"" "$OUT/log.jsonl")"
} | tee "$OUT/summary.txt"
python3 -I "$HERE/verify.py" "$SETTINGS" "$OUT" --app "$APP" | tee -a "$OUT/summary.txt"
verified=${PIPESTATUS[0]}
[ "$ok" = "${#ids[@]}" ] && [ "$verified" = 0 ]
