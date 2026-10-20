# Stage 2 art: how every image was made

All art on this page is ours: six images generated for it on 2026-10-20, plus the shader in `game.html`. No third-party art, sprite,
font file or text. There is no text in any image. The Japanese on screen is the system's Hiragino Sans.

## Generator

- Tool: the `agy` CLI (Google plan), `--model gemini-3.8-flash-high`, through its built-in `image-generator` subagent. The agy
  conversation store names that subagent's model as `gemini-3.1-flash-image`.
- Output: a 1024 × 1024 JPEG for every call.
- Seeds: the subagent does not take a seed or report one. The raw outputs are kept in `assets/src/` so the assets can be rebuilt
  exactly. A new call with the same prompt gives a different image.
- Call form: `agy -p "<wrapper + prompt>" --model gemini-3.8-flash-high --dangerously-skip-permissions --print-timeout 6m < /dev/null`.
  The run's cwd was a scratch dir, never the repo. The wrapper text asks the subagent to pass the prompt verbatim, to use the named
  input image where there is one, and to save the result at a fixed path.
- Tried first and refused: the Gemini API itself (`gemini-3-pro-image-preview`, `gemini-3.1-flash-image`, `gemini-2.5-flash-image`
  with the machine's `GEMINI_API_KEY`) returned HTTP 429 "free tier … limit: 0" for image models. grok's `image_gen` was not used
  (the user took grok out of rotation on 2026-10-20).

## The six images

Each prompt is in `prompts/` word for word. Raw files are in `assets/src/`.

| raw file | prompt | input image | what it is |
|---|---|---|---|
| `bg-1.jpg` | `prompts/bg.txt` | none | the night plate: the moon shrine, torii, steps, lanterns, mirror pool, pines, mist |
| `depth-1.jpg` | `prompts/depth.txt` | `bg-1.jpg` | its depth map (white near, black sky); edge correlation with the plate peaks at offset (0, 0) |
| `p-suzanne-1.jpg` | `prompts/p-suzanne.txt` | none | シュザンヌ, the canonical portrait: it sets the style of the others |
| `p-tsukumo-1.jpg` | `prompts/p-tsukumo.txt` | `p-suzanne-1.jpg` (style reference) | 九十九 |
| `p-herve-1.jpg` | `prompts/p-herve.txt` | `p-suzanne-1.jpg` (style reference) | エルヴェ |
| `p-haku-1.jpg` | `prompts/p-haku.txt` | `p-suzanne-1.jpg` (style reference) | ハク, a white fox spirit with a blue tail |

The portraits were drawn on a flat #00FF00 ground so they could be keyed. The three companion portraits were made from the first one
as a style reference, because independent calls drift. Each one took a single attempt. Nothing was regenerated or edited by hand.

## From raw to assets: `art.py` (deterministic)

`python3 -I art.py assets/src assets` writes:

- `plate.webp`: the plate at 2048² (Lanczos, unsharp mask 2.2 px / 60 %), WebP q90.
- `depth.png`: the depth map, near values dilated 2 px and then blurred 2 px. A moving edge then carries its own background with it.
- `p-<name>.webp`: each portrait keyed off the green, at 1200² with alpha. Alpha comes from the green excess. The key colour is
  un-mixed from the edge pixels. Any spill left is clamped only within 4 px of the background, so エルヴェ's green coat keeps its
  colour. The script exits 1 when a portrait keeps a green fringe (more than 0.5 % green-dominant opaque pixels) or loses its figure.
- `art.js`: the plate and the depth map as data URLs. WebGL cannot read an image file on a `file://` page, but it can read a data URL.

## What the shader adds (game.html, `#fs`)

All of this is procedural; there are no particle sprites or texture sheets.

- **Depth parallax.** A slow Lissajous camera drift and a slow push-in, moved per pixel by the depth map.
- **Sky.** Drifting cloud wisps, limited to the sky's depth.
- **Moon.** A breathing glow and soft rays.
- **Mist.** Two fbm layers: a valley band behind near objects, and a low band in front.
- **Motes.** A far set behind the pines and a near warm set, both twinkling.
- **Lights and water.** Lantern flicker, and a shimmer on the mirror pool.
- **Vignette.**

Under the dialogue panel, and 72 u around it, the scene is drawn at time 0. The glass blur under the text never moves.
