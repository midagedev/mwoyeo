# film2 live: the real app on screen, translating our game as it plays
The stage (`../stage2/game.html`, unchanged; `STAGE=film2/stage/scene.html` for stage1) steps through film-ja-ko-1's 36 lines in a Chrome
app window (`player.html`, `serve.py`); a Mwoyeo lens over its panel and name tag translates live, ja -> ko, Ollama gemma3:4b as an
OpenAI-compatible engine (thinking off); ffmpeg records the stage square at 60 fps, 2x. A line goes once the app's log has its translation,
1 s has passed since (AFTER) and the lens has been still 2 s (HOLD); never before 4 s, at most 30 s (`python3 -I serve.py --self-test`;
FAIL-first `--cover 0`, `--hold 0`, `--after 0`). The scene moves only for 1 s as each line comes in (SCENE=still, the page's manual clock).

## Re-record (Bash sandbox off; Ollama up; the screen free; disk >= 8 GiB for tools/ane-env.sh)
- `./record.sh before` -> `/tmp/film2/live/before-live.mp4` + `.jsonl` (the app's own log), `.events.jsonl`, `.settings.json`, `.count.txt`, `.settle.txt`.
- `./record.sh log` -> `log-live.mp4`: before-live's log in TextEdit (Menlo 18), scrolled once through in 6 s (SCROLL) by its scroll bar.
- `./record.sh after <settings.json> [name]` -> `<name>.*` (default after-live-hand): the app starts with no memory; once its lens reads,
  the first `appProfiles` item of <settings.json> (bundleID set to com.google.Chrome, the app in front) goes into the settings file the app
  runs on (`/tmp/film2/live/settings.json`; applied within a second), then the 36 lines play. A newer build:
  `BIN=<…>/Mwoyeo.app/Contents/MacOS/Mwoyeo ./record.sh after <memory settings.json> after-live-claude`.
- Trial: `OUT=/tmp/film2/live/trial-out TO=5 ./record.sh before`. Knobs: DWELL HOLD MOST PACE LEAD TAIL, STAGE SIZE LENS STEPS SCENE, ALIGN
  (right: clear of other apps' windows at the left), PARK (1: the pointer goes bottom-left for the take and back; this macOS draws it
  into the capture whatever -capture_cursor says; record.sh refuses a take with the pointer inside and logs it if it comes back).
- Counts: `python3 -I count-live.py --events A.events.jsonl --events B.events.jsonl A.jsonl B.jsonl [--detail]` (../plates/count.py).
- Settle: `python3 -I settle.py <part>.mp4 <part>.events.jsonl --log <part>.jsonl --per-line`: per line, when the log had its translation
  and how long the line stayed after it and after the lens's last change; exit 1 under 1.5 s or never translated.

## The lens, and what the app does that shapes the takes
- `Mwoyeo --add-region x,y,w,h` (App/Model/AppModel.swift) pins the lens from the player's rect. Scratch ids only: MWOYEO_SETTINGS_FILE=
  /tmp/film2/live/settings.json, MWOYEO_DEFAULTS_SUITE=film2.live (hasCompletedOnboarding is in its `settings` blob), MWOYEO_MEMORY_SECRETS=1.
- The lens reads ~240 pt left/right and ~80 pt above/below itself (App/Model/RegionSession.swift:8): the window fills the visible frame in
  the stage's night colour. A moving scene in that band (stage2 above y 916 u) keeps the app re-reading: 18 s a line instead of 10.
- It keeps its last picture over the box until it reads again (a new line shows up to ~1 s late); an identical plate comes from the cache.
- The log writes a line once it first has a usable translation, a plate again only after it was gone 10 s (Core TranscriptRecorder.gap).
