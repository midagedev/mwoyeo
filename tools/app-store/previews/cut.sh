#!/bin/zsh
# A real take (take.sh) -> the App Store preview: out/<lang>.mp4, 1920x1080, 30 fps, H.264 High 4.0 at a constant 11 Mbit/s
# (Apple's target: 10-12; a still screen alone would encode at ~4), a silent stereo AAC track at a constant 256 kbit/s, 48 kHz
# (Apple's spec; its previews need an audio track), the four captions laid over, and out/<lang>.poster
# (the poster frame's time code). Also $WORK/<lang>.proxy.mp4 (1280x720, 30 fps) to judge the motion by, and the
# per-second frame changes of each beat (motion.py), which fails when a beat stands still too long.
#   cut.sh <ko|en> <take.mov> <poster s> [from-to ...]
# Every time is the take's story time (take.sh's timeline: t = 0 is the first frame of the uncut preview). Each from-to is
# cut out, and the captions and the poster move with the cuts. The video is the take's pixels as they are (960x540 pt at
# 2 px per pt), nothing changed inside; t = 0 is found by the pointer flash take.sh makes 1 s before it.
#
# What to cut, read off the take (motion.py's frames, a 6 fps step-through): an autoplaying, muted preview must not stand
# still. (1) Between the first message's translation and the second message, nothing moves for ~4 s: cut from a frame after
# the lens settles to a frame of the same state just before the second message (or before a re-render that follows), so
# the join cannot be seen. (2) After the drag the parked lens drops its translation and shows the original while it reads
# again (0.5-1 s, under the drag's caption): cut from the last translated frame to the frame the swipe starts or the
# translation is back. This hides that real re-read time; the drag's caption ends at the cut and the scroll's begins.
# The shipped cuts: ko take ko-12 (as4b): 0.8 2.6-5.88 11.52-12.34; en take en-2 (as4): 2.45 2.6-5.87 11.52-12.34.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${WORK:-/tmp/as4}
L=$1; TAKE=$2; POSTER=$3; shift 3; CUTS=("$@")
LEN=27
OUT=$HERE/out; mkdir -p "$OUT" "$WORK/cap"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# 1. t = 0: the pointer flash (take.sh's MARK, at px (1836, 994) of the take) begins 1.0 s before it (env T0=<s> overrides)
[ -n "${T0:-}" ] || T0=$(ffmpeg -v error -i "$TAKE" -vf "crop=96:106:1824:974,fps=120,format=gray" -f rawvideo - | python3 -c "
import sys, numpy as np
a = np.frombuffer(sys.stdin.buffer.read(), np.uint8).reshape(-1, 106, 96).astype(float)
d = np.abs(a - a[0]).mean(axis=(1, 2))
hit = np.nonzero(d > 4)[0]
if not len(hit): sys.exit('no pointer flash in the take')
print(f'{hit[0] / 120 + 1.0:.3f}')")
echo "t0 in the take: $T0 s"

# 2. the captions, each on a transparent frame (caption.html), in the lead's words (captions.json)
for i in 0 1 2 3; do
    T=$(python3 -c "import json, sys, urllib.parse; print(urllib.parse.quote(json.load(open('$HERE/captions.json'))['$L'][$i]))")
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 --default-background-color=00000000 \
        --window-size=1920,1080 --screenshot="$WORK/cap/$L-$i.png" "file://$HERE/caption.html?lang=$L&t=$T" > /dev/null 2>&1 < /dev/null
    [ -s "$WORK/cap/$L-$i.png" ] || { echo "no caption $i"; exit 1; }
done

# 3. the cut. Beats (story seconds, take.sh's timeline): 0-8.3 a message lands (1 s; another at 7 s, its translation
# in by 8.2 in ja->ko), 8.3-12 the lens dragged up and back (pressed at 8.4, back at 11.5), 12-20.5 three swipes back
# (12.2, 14.7, 17.1), 20.5-27 ⌃⌥O at 21.0 and 24.2. The captions span those beats; a caption edge inside a cut moves to
# the cut, the next caption starts 0.1 s after the last ends, and each fades in and out over 0.25 s. Prints the filter's pieces: the length, the beats and the poster in output seconds.
# Inputs: 0 the take, 1 the silent audio, 2-5 the captions.
PLAN=$(python3 - $LEN $POSTER "${CUTS[@]}" <<'EOF'
import sys
length, poster = float(sys.argv[1]), float(sys.argv[2])
cuts = sorted(tuple(map(float, c.split('-'))) for c in sys.argv[3:])
assert all(0 < a < b < length for a, b in cuts), 'cuts are from-to inside the take'
def out(t):                                       # story seconds -> output seconds
    return t - sum(min(max(t - a, 0), b - a) for a, b in cuts)
caps = [(0.3, 8.25), (8.35, 11.9), (12.0, 20.4), (20.6, length)]
spans = []
for s, e in caps:
    s, e = out(s), out(e)
    if spans: s = max(s, spans[-1][1] + 0.1)
    spans.append((round(s, 3), round(e, 3)))
total = round(out(length), 3)
keep = '+'.join(f'between(t,{a},{b})' for a, b in cuts)
sel = f"select='not({keep})'," if cuts else ''
vf = f"[0:v]fps=30,{sel}setpts=N/(30*TB),scale=1920:1080:flags=lanczos,setsar=1[v]"
for i, (s, e) in enumerate(spans, 1):
    vf += f";[{i + 1}]format=rgba,fade=in:st={s}:d=0.25:alpha=1,fade=out:st={round(e - 0.25, 3)}:d=0.25:alpha=1[c{i}]"
last = 'v'
for i, (s, e) in enumerate(spans, 1):
    nxt = 'out' if i == len(spans) else f'o{i}'
    vf += f";[{last}][c{i}]overlay=0:0:enable='between(t,{s},{e})'{',format=yuv420p' if nxt == 'out' else ''}[{nxt}]"
    last = nxt
frame = round(out(poster) * 30)
print(total)
print(vf)
print(','.join(str(x) for x in [0] + [s for s, _ in spans[1:]] + [total]))
print(f'00:00:{frame // 30:02d}:{frame % 30:02d}')
print(f'cuts {" ".join(f"{a}-{b}" for a, b in cuts) or "none"} -> {total} s; captions (output s) '
      + ' '.join(f'{s}-{e}' for s, e in spans) + f'; poster story {poster} s = output {frame / 30:.3f} s')
EOF
)
OUTLEN=${${(f)PLAN}[1]}; FILTER=${${(f)PLAN}[2]}; BEATS=${${(f)PLAN}[3]}; POSTER_TC=${${(f)PLAN}[4]}
echo ${${(f)PLAN}[5]}
ffmpeg -v error -y -ss $T0 -t $LEN -i "$TAKE" \
    -f lavfi -t $OUTLEN -i "anullsrc=channel_layout=stereo:sample_rate=48000" \
    $(for i in 0 1 2 3; do echo -loop 1 -framerate 30 -t $OUTLEN -i "$WORK/cap/$L-$i.png"; done) \
    -filter_complex "$FILTER" \
    -map "[out]" -map 1:a -t $OUTLEN -r 30 \
    -c:v libx264 -profile:v high -level:v 4.0 -preset slow -b:v 11M -minrate 11M -maxrate 11M -bufsize 11M -x264-params nal-hrd=cbr -g 60 \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -c:a aac_at -aac_at_mode cbr -b:a 256k -ar 48000 -ac 2 -movflags +faststart "$OUT/$L.mp4"
echo $POSTER_TC > "$OUT/$L.poster"

# 4. the proxy the motion is judged by, and its numbers per beat (the stills each beat may hold: motion.py)
ffmpeg -v error -y -i "$OUT/$L.mp4" -vf "scale=1280:720:flags=bicubic" -r 30 -c:v libx264 -crf 20 -an "$WORK/$L.proxy.mp4"
python3 "$HERE/motion.py" "$WORK/$L.proxy.mp4" --beats $BEATS
echo "$OUT/$L.mp4 (poster $(cat $OUT/$L.poster))"
