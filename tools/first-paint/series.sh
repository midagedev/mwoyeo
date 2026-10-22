#!/bin/bash
# fast117 timing series: scenes x configs x reps, rep-major, the config order rotated each rep (load drift is spread over the configs).
# usage: [MAXWAIT=40] [NOWARM=1] [INPAINT=1] [COLDID=<bundle id>] series.sh <build label> <outdir> <reps> <scene,scene,...> <config,config,...>
#   configs: auto-w|c, hf-off-w|c, hf-par-w|c  (hf: engine highFidelity; par: the setting on; w: the app's launch warm-up of the translation session
#            first, c: without it); autod-n|j|e: `auto` engine with the source on Detect, as a lens is added (n: no session warmed, j: the launch
#            warm-up, which is `ja` for Detect, e: the pair `en` warmed, what a picker's or an earlier lens's detected language warms: `--prewarm-source`).
#            data/ also holds hf-seq (the two models one after the other) and parevery (every batch asks for a first paint) rows: they ran on an
#            experiment binary whose switches were removed after the measurement (design first-lens §13.2), so they are not configs here.
#   INPAINT=1  the inpainting model erases the old text, as in the app (the series run `--no-inpaint`: the erase is not what they measure)
#   NOWARM=1  no `--warm` (the render does not wait for the text model: the cold read on the `.fast` rung)
#   COLDID=<id>  the three e5rt cache dirs of that scratch bundle id are removed before every run (the app copy must carry that id; never a pool id)
HERE=$(cd "$(dirname "$0")" && pwd)
W=$1; OUT=$2; REPS=$3; SCENES=$4; CONFIGS=$5
mkdir -p $OUT
scene_png() { case $1 in p6) echo /tmp/paper-quality/pages-own/p6.png;; c01) echo /tmp/latin-runs/pngs/c01-slack-en.png;; d06) echo /tmp/latin-runs/pngs/d06-webpage-en.png;; esac; }
IFS=, read -ra CS <<< "$CONFIGS"; IFS=, read -ra SS <<< "$SCENES"
for ((r=1; r<=REPS; r++)); do
  for scene in "${SS[@]}"; do
    n=${#CS[@]}
    for ((k=0; k<n; k++)); do
      cfg=${CS[$(( (k + r) % n ))]}
      o=$OUT/$scene-$cfg-$r
      [ -s $o.out ] && continue
      src=en; case $cfg in autod-*) src=auto;; esac
      args=(--src $src --tgt ko --scale 2 --max-wait ${MAXWAIT:-40} --first-paint-log); [ -z "$NOWARM" ] && args+=(--warm); [ -z "$INPAINT" ] && args+=(--no-inpaint)
      env=()
      case $cfg in
        auto-*) ;;
        hf-off-*) args+=(--engine highFidelity);;
        hf-par-*) args+=(--engine highFidelity --first-paint);;
      esac
      case $cfg in *-w|autod-j) args+=(--prewarm);; autod-e) args+=(--prewarm-source en);; esac
      if [ -n "$COLDID" ]; then for sfx in "" .reader.lines .reader.docs; do rm -rf "$HOME/Library/Caches/$COLDID$sfx"; done; fi
      env "${env[@]}" $HERE/run-render.sh $W $(scene_png $scene) $o "${args[@]}"
    done
  done
done
echo done > $OUT/DONE
