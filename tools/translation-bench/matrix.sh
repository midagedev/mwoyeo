#!/bin/sh
# One condition on one Ollama model, preserved with the machine state in the note: the load average, pageouts, swap and
# free memory at the start and the end of the run, and `ollama ps` (the CPU/GPU split of the loaded model).
#
#   [NOTE='...'] [KIND=smoke] matrix.sh <bench-run binary> <scratch dir> <engine file> <run name> <condition> [bench-run options...]
#
# KIND (default `model`) is the manifest kind: `smoke` for a run that is not a result by itself (a subset of the sequences taken
# for its latency only, such as the A/A repeats of runs/RESULTS-2026-10-19-t3-product-layout.md).
#
# A warm-up request loads the model first, so the load time is not in the first request's latency. The run is one job at a
# time (latency is a measured axis). The note's machine tag is what `summary.py` reads as the load caveat:
#   [machine load1m start=<x> end=<y> pageouts +<n> swapouts +<n> swap_used_mb start=<x> end=<y> free_pct start=<x> end=<y>]
# Exit codes: the runner's, 3 when runs/<run name> exists (a run is never overwritten), 2 for usage.
set -u
[ $# -ge 5 ] || { echo "usage: matrix.sh <bin> <scratch dir> <engine file> <run name> <condition> [bench-run options...]" >&2; exit 2; }
BIN="$1"; SCRATCH="$2"; ENGINE="$3"; NAME="$4"; COND="$5"; shift 5
cd "$(dirname "$0")" || exit 2
[ -e "runs/$NAME" ] && { echo "runs/$NAME exists; a run is never overwritten" >&2; exit 3; }
mkdir -p "$SCRATCH"
OUT="$SCRATCH/$NAME"
MODEL=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["model"])' "$ENGINE")

snap() {   # load1m pageouts swapouts swap_used_mb free_pct
  l=$(sysctl -n vm.loadavg | awk '{print $2}')
  v=$(vm_stat)
  po=$(echo "$v" | awk '/^Pageouts/ {gsub(/\./,"",$2); print $2}')
  so=$(echo "$v" | awk '/^Swapouts/ {gsub(/\./,"",$2); print $2}')
  su=$(sysctl -n vm.swapusage | sed -n 's/.*used = \([0-9.]*\)M.*/\1/p')
  fp=$(memory_pressure | sed -n 's/.*free percentage: \([0-9]*\)%.*/\1/p')
  echo "$l ${po:-0} ${so:-0} ${su:-0} ${fp:-0}"
}

# warm-up: load the model, one token
curl -s -o /dev/null -X POST http://127.0.0.1:11434/api/chat \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"stream\":false,\"options\":{\"num_predict\":1}}"

set -- $(snap) "$@"   # first five words: the start state; the rest: bench-run options
L0=$1; P0=$2; S0=$3; U0=$4; F0=$5; shift 5

MWOYEO_MEMORY_SECRETS=1 "$BIN" run --engine "$ENGINE" --condition "$COND" --out "$OUT" --root . --jobs 1 "$@" > "$OUT.log" 2>&1 &
PID=$!
echo $PID > "$OUT.pid"
wait $PID
RC=$?
echo $RC > "$OUT.rc"
[ $RC -eq 0 ] || { echo "bench-run rc=$RC, see $OUT.log" >&2; exit $RC; }

set -- $(snap) "$@"
L1=$1; P1=$2; S1=$3; U1=$4; F1=$5; shift 5
PS=$(ollama ps | awk -v m="$MODEL" 'NR>1 && $1==m {for (i = 2; i < NF; i++) if ($i ~ /%$/) { c = ""; for (j = i; j <= NF && $j != "" && ($j ~ /%$/ || $j ~ /^(GPU|CPU|CPU\/GPU)$/ || $j ~ /^[0-9]+%\//); j++) c = c (c ? " " : "") $j; print c "; ctx " $(j); exit } }')
TAG="[machine load1m start=$L0 end=$L1 pageouts +$((P1 - P0)) swapouts +$((S1 - S0)) swap_used_mb start=$U0 end=$U1 free_pct start=$F0 end=$F1 ollama_ps='$PS']"
NOTE="${NOTE:-}${NOTE:+ }$TAG"

python3 -I runs.py add "$OUT" --kind "${KIND:-model}" --engine "$ENGINE" --binary "$BIN" --env MWOYEO_MEMORY_SECRETS=1 \
  --command "MWOYEO_MEMORY_SECRETS=1 $BIN run --engine $ENGINE --condition $COND --out $OUT --root . --jobs 1 $*" \
  --note "$NOTE"
