#!/usr/bin/env bash
# Start the lease's generation detached from the calling ssh, so a dropped connection cannot end it mid-run.
# Run from the bloomery tree on the box (through tools/box.sh, which has already waited out the lease and the holds):
#   bash /root/musicgen/film2/lease-run.sh <run name> [gen.py flags…]
# From the bloomery tree on the Mac, with a remote directory of your own (so no other track's tree is replaced):
#   BLOOMERY_REMOTE='~/repo/bloomery-film2music' BLOOMERY_BOX_ENV='BLOOMERY_LEASE_CARD=docs/cards/musicgen-film2.card' \
#     tools/box.sh 'bash /root/musicgen/film2/lease-run.sh mwoyeo-film2-1 --device cuda --dit acestep-v15-xl-sft \
#       --lm acestep-5Hz-lm-4B --backend pt --steps 50 --shift 1.0 --batch 4 --seeds 8 --duration 64'
# Then wait on the sentinel /root/musicgen/out/mwoyeo-film2-1-lease.rc (read it over ssh; run.sh's own is mwoyeo-film2-1.rc
# beside the out/mwoyeo-film2-1/ directory), never on a process list, and rsync the directory back.
# lease-hold.sh takes the lease with docs/cards/musicgen-film2.card and runs film2/run.sh under it. The detached pid goes to
# out/<run>-lease.pid, lease-hold's exit code to out/<run>-lease.rc, its output to out/<run>-lease.log.
set -uo pipefail
RUN=${1:?run name}; shift
O=/root/musicgen/out; mkdir -p "$O"; rm -f "$O/$RUN-lease.rc"
setsid nohup bash -c 'bash tools/ref/lease-hold.sh --card docs/cards/musicgen-film2.card -- bash /root/musicgen/film2/run.sh "$@"
echo $? > "/root/musicgen/out/$1-lease.rc"' _ "$RUN" "$@" > "$O/$RUN-lease.log" 2>&1 < /dev/null &
echo $! > "$O/$RUN-lease.pid"
echo "lease-run: pid $(cat "$O/$RUN-lease.pid"), log $O/$RUN-lease.log"
