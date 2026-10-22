#!/bin/bash
# one live run under the shared screen lock (retried every 60 s). usage: run-live.sh <label> <cold|warm> [drive.py args...]
L=$1; M=$2; shift 2
OUT=/tmp/r117/first117/data/runs/$L
mkdir -p $OUT
while true; do
  lockf -t 0 /tmp/r117/screen.lock python3 -I /tmp/r117/first117/drive.py --label $L --mode $M --out $OUT "$@" > $OUT/drive.log 2>&1
  rc=$?
  [ $rc -ne 75 ] && break
  sleep 60
done
echo "rc=$rc" > $OUT/rc
