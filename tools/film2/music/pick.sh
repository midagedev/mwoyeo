#!/usr/bin/env bash
# Copy the picked clip and its spare to PICKDIR (default /tmp/film2/music/pick) as FLAC and MP3, with their sha256.
# Usage: bash tools/film2/music/pick.sh RAWDIR CLIP SPARE [PICKDIR]      (CLIP, SPARE: stems such as koto-s1003)
set -euo pipefail
RAW=${1:?raw dir}; CLIP=${2:?clip}; SPARE=${3:?spare}; OUT=${4:-/tmp/film2/music/pick}
mkdir -p "$OUT"
for c in "$CLIP" "$SPARE"; do
  for e in flac mp3; do cp "$RAW/$c.$e" "$OUT/$c.$e"; done
done
( cd "$OUT" && shasum -a 256 "$CLIP".* "$SPARE".* | tee sha256.txt )
