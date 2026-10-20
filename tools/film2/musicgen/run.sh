#!/usr/bin/env bash
# The lease's command (rig-log release-034's run.sh for the Mwoyeo film 2): pin the RTX A6000 (PCI order, checked by name
# in gen.py), generate under a 30-minute bound, write OUTDIR.rc. Film 2's files live in /root/musicgen/film2/, so
# release-034's files beside them and film 1's in /root/musicgen/film/ stay as they were.
# Usage: bash /root/musicgen/film2/run.sh <run name> [gen.py flags…]
set -uo pipefail
R=/root/musicgen; F=$R/film2; RUN=${1:?run name}; shift
OUT=$R/out/$RUN; mkdir -p $OUT; rm -f $OUT.rc
idx=$(nvidia-smi --query-gpu=index,name --format=csv,noheader | awk -F', ' '$2 ~ /A6000/ {print $1}')
[ -n "$idx" ] || { echo "run.sh: no RTX A6000" >&2; echo 69 > $OUT.rc; exit 69; }
export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES=$idx HF_HOME=$R/hf HF_HUB_OFFLINE=1 TOKENIZERS_PARALLELISM=false
nvidia-smi --query-gpu=index,name,memory.used,power.limit --format=csv,noheader
cd $R/src
# One process (nvidia-smi's own loop), so the kill below ends it: a shell loop left its `sleep` holding the lease's
# descriptor for up to 5 s after the run.
nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader -i $idx -l 5 > $OUT/smi.log 2>&1 &
smi=$!
timeout --kill-after=10 1800 .venv/bin/python $F/gen.py $OUT --prompts $F/prompts.json "$@"
rc=$?
kill $smi 2>/dev/null
echo $rc > $OUT.rc
exit $rc
