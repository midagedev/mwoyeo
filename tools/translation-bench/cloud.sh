#!/bin/sh
# One condition on one cloud engine (Anthropic, OpenAI-compatible or DeepL), preserved with the load average in the note.
#
#   [NOTE='...'] cloud.sh <bench-run binary> <scratch dir> <engine file> <run name> <condition> [bench-run options...]
#
# The engine file's `keyEnv` variable must already be in the environment (a file never holds a key and a key is never printed).
# One job at a time (latency is a measured axis). Cloud latency is the network plus the service's load, so repeat condition A once
# under a second run name and let latency.py's A/A spread decide what a delta means. Exit codes: the runner's, 3 when runs/<run name>
# exists (a run is never overwritten), 2 for usage. Cost: the run's `cost estimate` line in score.py's output (prices.json).
set -u
[ $# -ge 5 ] || { echo "usage: cloud.sh <bin> <scratch dir> <engine file> <run name> <condition> [bench-run options...]" >&2; exit 2; }
BIN="$1"; SCRATCH="$2"; ENGINE="$3"; NAME="$4"; COND="$5"; shift 5
cd "$(dirname "$0")" || exit 2
[ -e "runs/$NAME" ] && { echo "runs/$NAME exists; a run is never overwritten" >&2; exit 3; }
mkdir -p "$SCRATCH"
OUT="$SCRATCH/$NAME"
L0=$(sysctl -n vm.loadavg | awk '{print $2}')
MWOYEO_MEMORY_SECRETS=1 "$BIN" run --engine "$ENGINE" --condition "$COND" --out "$OUT" --root . --jobs 1 "$@" > "$OUT.log" 2>&1 &
PID=$!
echo $PID > "$OUT.pid"
wait $PID
RC=$?
echo $RC > "$OUT.rc"
[ $RC -eq 0 ] || { echo "bench-run rc=$RC, see $OUT.log" >&2; exit $RC; }
L1=$(sysctl -n vm.loadavg | awk '{print $2}')
NOTE="${NOTE:-}${NOTE:+ }[machine load1m start=$L0 end=$L1; cloud engine, latency includes the network]"
python3 -I runs.py add "$OUT" --kind model --engine "$ENGINE" --binary "$BIN" --env MWOYEO_MEMORY_SECRETS=1 \
  --command "MWOYEO_MEMORY_SECRETS=1 $BIN run --engine $ENGINE --condition $COND --out $OUT --root . --jobs 1 $*" \
  --note "$NOTE"
