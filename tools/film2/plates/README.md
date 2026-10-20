# film2 plates: an RPG stage of our own, translated by the real app

One plate per line of `tools/translation-bench/sequences/film-ja-ko-1.json` (36 lines): the line on a night scene as an RPG dialogue box
(`../stage/scene.html`, CSS only, system Hiragino), read and translated by the real app (`--render`, Vision, Ollama gemma3:4b as an added
OpenAI-compatible engine, context off), the stage's own bundle ID in front. Every Korean word the film shows comes from `out/<name>/L<id>.png`.

## Remake everything (Bash sandbox off for the app and Chrome)
1. Stage PNGs 2160x2160 (device scale 2.25 of a 960 px page): `../stage/shoot.sh` -> `out/stage/L1..L36.png`, `lines.txt` (lines each text
   needs; all <= 2). `../stage/check.sh` = the stage checks, each with its FAIL-first mutation; `../stage/contrast.py` = text vs panel (>= 7:1).
2. The app: `ANE_ID=dev.midagedev.mwoyeo.film /tmp/latin-runs/build-app.sh <this tree> film2` -> `/tmp/latin-runs/dd-film2` (never xcodebuild by hand).
3. Settings (`settings/`, the `settings.json` shape of App/Model/SettingsFile.swift): `before.json` is `{}` (no profile for the stage app); `after-hand.json`
   is the bench memory as that app's profile: `python3 -I hand-settings.py ../../translation-bench/memory/film-ja-ko-1.json <out.json>`. The film's final
   "after" is the memory Claude writes from `out/before/log.jsonl`. Check a file: `<Mwoyeo binary> --check-settings <file>` prints `ok`.
4. `./render.sh <settings.json> <out-name> [id ...]` -> `out/<out-name>/`: `L<id>.{png,out,err,rc}` (the .out `->` lines are the translation, the
   .err the trace: `ocr-block` = what OCR read, `items:` a `*` = kept as a name tag), `log/L<id>/*.jsonl` (the app's own translation log of that
   render) joined in line order into `log.jsonl`, `requests/NNNN.{request,reply}.json` (what the engine was sent and said), `summary.txt`.
   `render.sh` ends with `verify.py` (rc 0 everywhere; `app` in every log line; the note and every matching memory row in every request, or none
   without a profile). It wraps each run in `tools/ane-env.sh run pool --` of the main tree.
   `PLATE=tag ../stage/shoot.sh` shoots the variant with a gold plate text (out/stage-tag): the app keeps it as written, so the request holds the dialogue
   only; `STAGE_DIR=$PWD/out/stage-tag ./render.sh settings/before.json before-tag` renders it (passes before-tag, after-hand-tag exist).
5. `python3 -I count.py out/before out/after-hand [--detail]`: the bench's `film_consistency.py` counting over the renders, plus the OCR damage
   and the plates' renderings.

## Ids and env
App `dev.midagedev.mwoyeo.film` (MWOYEO_APP_ID, built in), MWOYEO_DEFAULTS_SUITE=film2.plates, MWOYEO_MEMORY_SECRETS=1, MWOYEO_TRACE=1 (render.sh).
The stage app: bundle `dev.midagedev.film.lumiere`, name 月涙譚, category `public.app-category.role-playing-games` (the card says "games").
Engine: `engine.json` written per run (name "Ollama gemma3:4b", base URL = `tap.py`, a pass-through that keeps every request and reply).

## Things the app does that shape the plates
- A name plate in another text colour than the dialogue is kept as written (name tag rule, Core/Sources/MwoyeoCore/Runs.swift:132); the stage
  gives it the dialogue's ink (`--plate-ink` in scene.html's `:root`), so the app translates it and the memory applies to it. Revert = one token:
  `--plate-ink: var(--gold)` (or `PLATE=tag` for a second set); then the request holds the dialogue only and the plate stays Japanese.
- OCR (rev3 lines) loses the glyph 祠 after 月影の in most lines (and 涙 once): the engine is sent text without the term, see `count.py` "keys lost by OCR".
- Line 26 is the sequence's noise line ("cut"): its text stops mid-sentence on the plate too.
- `--render` has no one-log-over-many-renders: each render is one process and writes its own jsonl; `render.sh` joins them (the times are each process's).
