# Hero clips

One short loop per README language. Everything in them is the real app on a real screen; the page scrolls by
synthesized trackpad events, so a take can be repeated exactly.

| README | Chat (`demo/chat.html?lang=`) | Translated into | GIF |
|---|---|---|---|
| Korean | `ja` | Korean | `docs/media/hero.ko.gif` |
| English | `ko` | English | `docs/media/hero.en.gif` |
| Japanese | `ko` | Japanese | `docs/media/hero.ja.gif` |
| Simplified Chinese | `ko` | Simplified Chinese | `docs/media/hero.zh-CN.gif` |

## Shot list

A small lens (470×260 pt) in the middle of the chat, so the original stays visible around it. 688×720 pt crop
(exported 600 px wide), 20 s:

| Time | What happens | Caption |
|---|---|---|
| 0–3 s | Only the text under the lens is translated; everything around it is the original. | Only the text under the lens turns English, in place |
| 3–9 s | The lens is dragged up by its name tag, then back down a little. Whatever it passes over is translated live. | Drag the lens: what it passes over is translated |
| 9–16 s | Two trackpad swipes up under the lens. | Scroll, and the translation keeps up |
| 16 s– | ⌃⌥O: the ring turns grey and the original shows, then the translation again. | ⌃⌥O shows the original |

## Setting up

```bash
# The chat: content area 1000×1000 at (140, 96) — the --app title bar sits above it; no translate bubble
open -na "Google Chrome" --args --user-data-dir=/tmp/mwoyeo-demo --no-first-run \
  --disable-features=Translate,TranslateUI \
  --app="file://$PWD/demo/chat.html?lang=ko&every=6&history=16" \
  --window-position=140,68 --window-size=1000,1028

# Settings › Translate from must match the page, Translate to the README's language. For the non-Korean clips the
# app's own language matches too: defaults write dev.midagedev.mwoyeo AppleLanguages -array ja (delete it after).
# A small lens over the message log (global points, top-left origin). Launch the binary from a terminal that has
# Screen Recording permission, so a rebuilt ad-hoc app needs no new grant.
build/dd/Build/Products/Release/Mwoyeo.app/Contents/MacOS/Mwoyeo --add-region 490,526,470,260 &
```

`--add-region` stores the lens like any other; remove it from the menu afterwards.

## Before recording

1. **Warm up.** Wait about 18 s after launch: the first recognition loads models. Don't scroll yet; the history
   should be read for the first time on camera.
2. **Language pack** for the pair installed (System Settings › General › Language & Region › Translation Languages).
3. **Clean screen.** Nothing over the recorded rect (no dialogs or notifications); park the cursor outside it
   between moves.

## Recording and cutting

Screen recording captures Mwoyeo's overlays (only Mwoyeo's own capture leaves them out). `screencapture` won't
overwrite an existing file:

```bash
rm -f take.mov; screencapture -v -V 22 -R 452,166,688,720 take.mov
# t = 4.2 s: drag the name tag (530,509) up 300 pt over 1.6 s; t = 7.2 s: down 180 pt over 1.2 s
# t = 10.4 s and 13.4 s: swipe up 260 and 200 pt under the lens; t = 17.4 s and 19.4 s: ⌃⌥O
```

Captions are HTML pills (system font per language, 52 px on the 1376 px wide take) rendered to transparent PNGs
with headless Chrome, then laid over the bottom of the take:

```bash
ffmpeg -ss 1 -t 20 -i take.mov \
  -loop 1 -framerate 30 -t 20 -i cap0.png -loop 1 -framerate 30 -t 20 -i cap1.png \
  -loop 1 -framerate 30 -t 20 -i cap2.png -loop 1 -framerate 30 -t 20 -i cap3.png \
  -filter_complex "[0:v]fps=30,setpts=PTS-STARTPTS[v];\
[1]format=rgba,fade=in:st=0.3:d=0.3:alpha=1,fade=out:st=2.7:d=0.3:alpha=1[c0];\
[2]format=rgba,fade=in:st=3.1:d=0.3:alpha=1,fade=out:st=8.6:d=0.3:alpha=1[c1];\
[3]format=rgba,fade=in:st=9.0:d=0.3:alpha=1,fade=out:st=15.6:d=0.3:alpha=1[c2];\
[4]format=rgba,fade=in:st=16.0:d=0.3:alpha=1[c3];\
[v][c0]overlay=(W-w)/2:H-h-50:enable='between(t,0.3,3.0)'[a];[a][c1]overlay=(W-w)/2:H-h-50:enable='between(t,3.1,8.9)'[b];\
[b][c2]overlay=(W-w)/2:H-h-50:enable='between(t,9.0,15.9)'[c];[c][c3]overlay=(W-w)/2:H-h-50:enable='gte(t,16.0)',format=yuv420p" \
  -c:v libx264 -crf 16 cut.mp4
# README hero: the first 8.6 s of the GIF (lens up and back; a clean loop); the full take is hero.<lang>.full.gif
ffmpeg -i cut.mp4 -vf "fps=12,scale=600:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=sierra2_4a" \
  docs/media/hero.ko.gif
```

Keep each GIF under 10 MB.
