# The first lens: one click, fitted to the text (1.1.7 design and measurement)

Round first117, 2026-10-22. Design and measurement only; no product code. The lead moves this into `docs/design/first-lens.md`.
Built on fit117's column estimator (`ColumnFit`, worktree `mwoyeo-wt-fit117`, not landed). Everything measured on this Mac with a **Release** build of
main `5272f82` (exported with `git archive` to `tools/first-lens/src`, built to `/tmp/latin-runs/dd-first117`), a scratch bundle id
(`dev.midagedev.mwoyeo.cold1792626787950b`), scratch settings and defaults suite, `MWOYEO_MEMORY_SECRETS=1`. Data: `tools/first-lens/data/`, tools:
`tools/first-lens/{drive.py,probe/,tools/}` (section 12).

User, in their words: "원클릭 렌즈 … 내가 이야기한게 1번이긴 하구나 이거 결국 최초 렌즈 추가 경험을 올려주고 싶어".

**Machine state, said once.** The 1-minute load average was 135 to 280 during the live runs (4 rounds' benches on the same Neural Engine and CPUs; 48 to 69 only
in the picker loop at the end). Every row below says which load it was taken under. The rule "gates run under natural load" holds; the consequence is that
translation and window-server terms swing by 3x to 10x between runs, so every number is a median of 3 or more with its range, and a number I could not
make stable says so.

## 0. Verdict

1. **The first lens is already fast where recognition is concerned and slow where translation is concerned.** From the click to the lens on screen: 0.18 s
   (warm, n=6), 0.39 s (cold, n=3). From the lens to the first read: 1.1 s warm, 2.7 s cold. From the lens to the first Korean: **3.5 s warm, 9.0 s cold**
   (cold range 3.2 to 37 s), of which the first translation batch is 1.6 s warm / 6.1 s cold. On a **cold install a Latin page gets its Korean at 29 to 31 s after
   launch with the first lens placed at 20 s, long before the text model is compiled (67 s)**: the `.fast` rung reads it. Only a **CJK source** waits for the
   compile: no reader for **122.6 s** (236 reads failed "preparing", `vision-reads --src ja`, n=1).
2. **The default ghost cuts text.** The 560 x 320 box that follows the pointer has an edge through a text block at **95 % of the pointer positions inside a
   column** (top edge 70 %, bottom edge 71 %; 43,287 positions on 8 paper pages). A fitted target that starts at a paragraph and ends at one cuts a block
   at 2.8 % (the p4 table page; 0 % on the other 7).
3. **One-click design**: when the picker opens, one read of the display under the pointer (0.30 to 0.44 s median, the same host path a lens uses) gives blocks;
   `ColumnFit` makes columns; `LensTarget.choose` turns a pointer position into a lens rect (column width x whole paragraphs, 0.6 to 1.3 us, 3 to 33 us to build);
   the picker shows it as the ghost's replacement, a click places it, a drag, ⌥ and the keyboard behave as today. No column (chat, game, subtitles): today's ghost,
   byte for byte. No new first-run step; two onboarding sentences change.
4. **Warm-up already runs at every launch and already contains ProgramCheck.** Measured: the check costs **+0.48 s** in the Lines warm-up of a new build (0.49 -> 0.97 s;
   +0.4 CPU-s), finished 2.2 to 6.3 s after launch. The backlog's "~3 s" was not reproduced (it was a loaded one-shot `--render` racing a compile). What shortens the
   first Korean is not the check: it is **(a)** starting the cold compile before the translator prewarm and the inpainter load (the compile started 1.2 / 4.3 / 9.7 s after launch in the three cold runs: -4.3 s median of a 136 s cold start), **(b)** warming
   the translation session of the language under the pointer when the picker opens (low-latency first batch **2.07 s -> 0.23 s**; the default high-fidelity batch does not
   change: 7.2 -> 6.7/8.0 s), **(c)** a product decision for the lead: a low-latency first answer, high fidelity refining (section 3.4).
5. **The picker's drawing must leave CoreGraphics before the preview moves.** One full-display redraw of the picker's look costs **15.7 ms** (median, 3024 x 1964 px,
   load 38): a whole frame at 60 Hz, two at 120 Hz. A hover preview that redraws that on every mouseMoved cannot "follow with at most one frame of lag". Layers
   (a hole path and a stroke path animate in microseconds) are part of the design, not a polish item.
6. **Privacy sentence.** Onboarding says "Mwoyeo reads only what is under a lens". The picker's map reads the whole display once per picker open (on this Mac, never stored,
   never sent). The sentence is already loose (a lens captures 30 to 40 % beyond itself: `Overscan`), and fit117's probe reads a display-wide band. Section 5 gives the sentence that stays true.

## 1. The journey today, measured

Cold = a fresh id with its three e5rt cache dirs removed, `ane-env.sh run cold` (the lease), n=3 (`runs/cold1-3`); the first lens is placed 20 s after the app starts.
Warm = the same id with caches (`runs/warm1-3`, and `runs/new1-3` where the `programs-verified` mark was removed = a new build, lens at 6 s), n=6, load 135 to 220.
The hot key was ⌃⌥⌘J, not ⌃⌥L (the user's own Mwoyeo and other rounds' apps hold ⌃⌥L; a Carbon hot key is a Carbon hot key). Times are medians (min to max).

| # | Step | What the user sees | What they must know | Cold, load 180 to 280 | Warm, load 135 to 220 | Owner today |
|---|---|---|---|---|---|---|
| 1 | launch -> onboarding window | menu bar icon, then a 600 pt window: a looping demo (a chat, a lens gliding over it, Korean under it) and three cards | nothing | 4.2 s (1.3 to 10.3) | 2.1 s (0.87 to 5.3, 12 launches) | `AppModel.swift:233-241` (the window waits for `translator.prewarm` and `Inpainter.load`) |
| 2 | Screen Recording | card 1 "Allow" (default button); the system sheet, System Settings opens; the card turns green by a 1 s timer; "You may have to reopen Mwoyeo after allowing it" | to click Allow and maybe reopen | **not measured** (human; my process chain inherits the grant: `CGPreflightScreenCaptureAccess` = true) | same | `AppModel.requestPermission`, `OnboardingView.swift:28-34` |
| 3 | ⌃⌥L -> picker windows up | the screen dims (0.32 black), a hint pill "Drag an area or click · ⌥ pins to the screen · esc to cancel", the 560 x 320 ghost under the pointer | that a click or a drag places the lens | **1.3 s median (0.32 to 8.9; 6 presses)** | **0.07 s calm (loop, n=14, load 48 to 69); 0.21 s median over 41 presses (14 at load 48 to 69, 27 at 135 to 220); 29 % of the 41 took 1.8 to 5.8 s** | `AppModel.addRegion` -> `RegionPicker.pick` |
| 4 | pointer moves | the ghost follows, continuously; a window under it gets an accent outline | nothing | - | - | `PickerView.draw` (CoreGraphics, every `needsDisplay`) |
| 5 | click -> picker gone | the dim goes | - | 0.20 s (0.13 to 0.26) | 0.12 s (0.11 to 0.15) | `PickerView.mouseUp` -> `finish` |
| 6 | click -> lens windows on screen | the lens ring, the name tag "Auto -> 한국어" | nothing | 0.39 s (0.31 to 0.53) | 0.18 s (0.14 to 0.24) | `AppModel.startSession` -> `RegionSession.start` |
| 7 | lens -> first read done | the source text still shown | nothing | 2.7 s (1.0 to 3.7) | 1.1 s (0.95 to 1.17) | `RegionPipeline`; cold reads on the `.fast` rung (13 to 19 blocks, 0.45 s) |
| 8 | first read -> first Korean | Korean replaces the text | nothing | first translation batch 6.1 s (1.8 to 11.1) | 1.6 s (1.2 to 2.2) | `TranslationService` (default engine: high fidelity) |
| 9 | **lens -> first Korean** | | | **9.0 s (3.2 to 37)**; from launch 31.5 s (29.1 to 60.1) | **3.5 s (2.9 to 4.2)** | |
| 10 | a second lens, same run | | | picker 0.75 s (0.32 to 8.9), lens 0.48 s | picker 0.24 s (0.13 to 2.9), lens 0.16 s | |
| 11 | the cold compile (the "preparing" period) | Latin: nothing, Korean arrives via `.fast`; CJK: the pill "Preparing text recognition — first time only" for **122.6 s** | for CJK, to wait | Lines (rev3) done at 71.1 / 67.6 / 78.6 s; Docs at **136.2 / 134.3 / 209.8 s**; `vision-reads` en: text model 60.0 s, docs 119.9 s; ja: text model 122.6 s, docs 183.0 s | - | `RecognitionHost.warmUp`, `SwiftVisionGate` |
| 12 | ProgramCheck | nothing | - | inside step 11 (it is the first read of a cold cache) | Lines warm-up 0.49 s (0.47 to 0.51, verified mark) vs **0.97 s** (0.86 to 1.09, mark removed), n=3 each; finished 2.2 to 6.3 s after launch | `ReaderWorker.verifyPrograms` (first Lines job of the process) |

How the Korean was detected: in the three cold runs by a pixel change of the lens interior (a ScreenCaptureKit one-shot, 0.2 s per frame); in the warm runs by the first
`translate xN` trace line after the lens appeared (the lens draws within 0.25 s of it; in cold1 the pixel change came 0.23 s earlier than the line because results draw
one by one). The pixel watcher made macOS ask "'bash' wants to bypass the window picker" once per run: I stopped it and moved to the trace (sections 11, report).

### 1.1 What the cold compile tells the design
- Both warm-up steps are serial and long (67 s + 67 s; the first install's wall is 136 to 210 s), and `ANECompilerService` takes one network at a time: **nothing here is shortened by
  tuning; it is shortened by starting earlier and by not waiting for it.** The product already does the second: Latin text is read by `.fast`; `LensHint.preparingRecognition` is on the pill.
- A Japanese first lens sees nothing but "Preparing text recognition — first time only" for two minutes. The pill does not say how long ("about 2 minutes"): improvement spot.
- The lens redraws when a better reader arrives: `seamless: document OCR` again at 71.5 s (rev3) and 137 s (Docs) in cold1, with `erase 7 blocks 3079 ms` at 74.8 s. A viewer sees the first
  Korean change twice in the first 2.3 minutes of a first launch. Judge in playback (not mine to judge here).
- The first translation call is the largest term of a cold first Korean (6.1 s of 9.0), and it is not the compile: it is the hf decode under load (section 3.3).

## 2. The picker's map: what a read of the display costs

### 2.1 Read latency (`probe/rmsum.py`, `data/rm-summary.txt`; headless `--render` of a 3024 x 1964 px screen, fake engine (no translation), warm id, load 90 to 276)

| picture (full display unless said) | lines + grouper (`vn`) | document layout (`swift`) | blocks |
|---|---|---|---|
| paper page in a window (p01, own paper) | **300 ms** (229 to 336) | 334 ms (289 to 427); Docs read 303 | 9 / 12 |
| real Preview page (film3 shot B, Korean chrome, dock) | **363 ms** (353 to 537) | **2396 ms** (2369 to 2524): Docs `suspect`, rerouted to Lines after its patience | 14 |
| chat (Slack-like, c01) | **312 ms** (282 to 369) | 410 ms (348 to 471) | 6 / 13 |
| web article (own HTML, Chrome headless) | **354 ms** (353 to 428) | 435 ms (363 to 541) | 17 / 14 |
| web crop 560 x 320 pt (a lens) | - | 357 ms (325 to 496) | 3 |
| web crop 800 x 600 pt | - | **2432 ms** (rerouted, as Preview) | 7 |

- **A full display reads in 0.30 to 0.44 s, not slower than a lens-sized crop (0.36 s)**: the cost is not area. Two pictures took 2.4 s on the document path in 3 of 3 runs
  because the Docs service answered after its patience (`reader: docs state=suspect`, `rerouted=1`) at load 250; on the lines path they took 0.36 s. fit117's own run of Preview shot A
  (lower load) read 607 ms on Docs. **Docs latency is load-sensitive, the lines path is not**: the picker asks for the host's `automatic` plan with a patience of its own (below) and takes whatever answers first.
- The blocks of the lines path find the paper columns at the auto path's edges within 2.0 to 3.5 pt (`data/vn-vs-auto.txt`: p2 ±2.5, p4 ±2.8, p6 ±3.0, p7 ±3.5, p10 ±3.2, p11 ±2.0, p12 ±2.5)
  but make more stacks (table cells that group into several lines), so the target rule needs a **minimum column width of 160 pt** (a table column or sidebar is not a reading column). With it, the web-article
  and paper scenes claim what fit117 measured (`data/hover-scenes.txt`: papers 5 of 7, chat 1 of 5, docs/web 1 of 8, games 0 of 8, subtitles 0 of 9, code 0 of 12; Preview shots 66 % and 70 % of positions).
- **What the picker shows before the map returns: nothing, not the ghost** (picktarget117, 2026-10-23; it was today's ghost until the film4 take t1-hero). The ghost is the window's content, not the page: in Preview at 100 % it stood over the dark margin, up to 190 pt left of the page, for the 532 ms of the read, then glided into the first target (take frames 7.05 to 7.25 s). The app's own reads, 8 of them in the film4 takes, are 511, 523, 532, 581, 610, 614, 653 and 714 ms (the headless bench above: 0.30 to 0.44 s; 2.4 s when the Docs path was rerouted). The ghost shows after `LensTarget.ghostGrace` = 0.8 s of reading (the slowest of the 8 plus 12 %, short of the rerouted 2.4 s), and at once where the read gave nothing or there is no reader. A click before the map arrives places the default lens (never blocks).

### 2.2 Lookup and build cost (`probe/lookup.swift`, `data/lookup.txt`; swiftc -O, Apple Silicon, load 190)

| blocks on the display | map build (columns + members), median of 200 | `choose` per mouseMoved (random pointer, held anchor) |
|---|---|---|
| 16 | 2.6 us | 0.56 us |
| 72 | 4.7 us | 0.90 us |
| 240 | 10.8 us | 1.28 us |
| 960 | 32.8 us | 1.14 us |

A frame is 16,700 us (8,300 at 120 Hz): the geometry is below 0.01 % of it. **Not a term.** What is a term is drawing (section 4.4).

### 2.3 What the rule does on real block data (`probe/hover.py`, `data/hover-paper.txt`, `data/hover-scenes.txt`; 8 prose pages, grid 10 pt, 43,287 positions inside a column)
- A target exists at **100 %** of those positions (97 % on p12, 99 % on p6), median height 242 to 528 pt, width 338 pt (the column + 12 pt of pad).
- Today's ghost cuts a block at an edge at **95 %** (87 to 100 % by page); the target's edges: **2.8 %** (p4's overlapping table "column"; 0 % on the other pages).
- **Stability.** Walking the pointer down each of 22 columns: 7 to 25 target changes per column (one per paragraph), no flicker. With 2 pt of pointer jitter at each of the block boundaries
  (200 samples per boundary): **0 reversals with the hysteresis (5 on one column), 107 to 1253 without it on 20 of the 22 columns** (the FAIL-first for the Core test, `data/hover-paper.txt`).

## 3. Warm-up: where, what it costs, what it buys

### 3.1 Where it runs today and what a launch costs (launch only, no lens, warm cache, 20 s, `runs/noop*`, `noopn*`, load 53 to 124)
| | Lines warm-up | Docs warm-up | CPU-s of the Lines service | Docs service | app process |
|---|---|---|---|---|---|
| verified mark (n=3) | 0.49 s (0.47 to 0.51) | 0.55 s (0.51 to 0.58) | 0.35 | 0.35 to 0.38 | **8.8 to 10.5 s** |
| new build, mark removed (n=3) | **0.97 s** (0.86 to 1.09) | 0.50 s (0.50 to 0.58) | **0.74 to 0.79** | 0.35 to 0.38 | 8.3 to 11.6 s |
They finish 2.2 to 6.3 s after the process start because they start after `translator.prewarm()` and `Inpainter.load()` (`AppModel.swift:233-241`). **A login launch therefore costs the readers ~0.7 CPU-s
(~1.15 with a new build) and about one second of Neural Engine; the app process itself spends 9 to 12 CPU-s in its first 20 s**, which is 10x the warm-up (improvement spot; I did not profile it).
Neural Engine energy cannot be measured without `powermetrics` (sudo); the evidence is the count of executions (two reads of the drawn probe, ~1 s).

### 3.2 Placement (answers to the spec's three candidates)
| candidate | what it buys | cost | decision |
|---|---|---|---|
| app launch (today) | the cold compile starts at once; verified caches cost ~1 s | at a login launch ~0.7 CPU-s, ~1 s ANE | **stays**; it is not a "warm-up without a user action" in the harmful sense: with a verified cache it is two 0.5 s reads, and the cold compile only happens after an install or an update the user started. No new login work. |
| launch, **before** prewarm and inpaint | -4.3 s median (1.2 to 9.7 s, load-dependent) of the 136 s cold wall (the compile is what the first CJK lens waits for) | none | **do** (`warmUpVision` first; it is a detached utility task) |
| onboarding's last step | nothing: the warm-up is already running | - | no |
| picker open | (a) the map read (this design); (b) `translator.prewarm` for the **detected language of the text under the pointer** (low-latency first batch 2.07 -> 0.23 s); (c) a `purpose` the host schedules after running lenses | one read (0.3 to 0.4 s) + one tiny translation per open; none at launch or login | **do** (a) and (b) |
| ProgramCheck "moved to warm-up" | nothing more: **it is already the first job of the Lines service, i.e. of the launch warm-up** | +0.48 s once per new build | already true; close the backlog item with this measurement. The only "preparing" a user can still meet is a lens placed in the first 2 to 6 s of a launch (a restored lens at launch queues behind it: ≤ 1 s). |

### 3.3 The first translation (`probe/trwarm.swift`, `data/trwarm.txt`; fresh process per run, 5 rounds interleaved, load 220 to 235)
| first batch of 3 lines, median (5 runs) | none warmed | ja->ko session warmed (what `prewarm` does for source "auto") | en->ko session warmed |
|---|---|---|---|
| low latency (the pack path) | 2067 ms | 962 ms | **229 ms** (153 to 370) |
| high fidelity (the default engine) | 7165 ms (6481 to 8993) | 6671 ms | 7955 ms |
`TranslationService.prewarm` (line 298) warms **ja** when the source is Detect. Warming the right pair is worth 9x on the low-latency path and nothing on the default high-fidelity path: its time is decode, not session
creation. So: the picker's language warm-up is cheap and right, but the first Korean of a default lens is bounded by the engine (1.2 to 11 s at this load; the code comment's own worst case is 4.2 s for 3 lines).

### 3.4 For the lead to decide (it changes the default path)
Where the Apple pack is installed, answer the first batch with the low-latency strategy (0.2 to 2 s) and let high fidelity replace it: the first Korean arrives in about a third of the time and the quality
arrives behind it. This is the single largest lever on "effortless" and it changes the default translation path, so it needs a no-regression gate and your decision. Not in this design's scope.

## 4. The design

### 4.1 What the preview outlines (rule, `LensTarget.choose`; prototype `probe/hover.py`, Swift timing `probe/lookup.swift`)
Inputs: the pointer (picker view coordinates), a `Map` (columns from `ColumnFit.columns` of the display's blocks; **every** block, one-line headings and captions too, is a member of the column whose x range holds it), the display or window bounds, the held anchor.

1. **Column**: the one whose range `[left - 6 - 12, right + 6 + 12]` holds `pointer.x` (nearest when two do: the gutter goes to the nearer column within 12 pt of its padded edge, else nil). A column narrower than **160 pt** is not one.
2. **Anchor block**: the member with the best signed distance (depth inside, minus distance outside). The held anchor stays until another beats it by **8 pt** (no flicker at a gap's midpoint). Farther than 40 pt from every member: nil.
3. **Extent**: from the anchor's top down over following members while the gap to the previous one is at most 44 pt (a figure or a full-width element ends it), until the height reaches `H = clamp(560 x 320 / width, 160, 560)` (a read costs about what the default lens costs: column 338 pt -> 530 pt tall; Preview column 600 pt -> 300 pt); a block that crosses `H` stays when at least half of it is inside. Short of room below (display, window content below its 28 pt title bar) it grows upward by whole members. At least two lines and 40 pt tall, else nil.
4. **Width**: `column.left - 6` to `column.right + 6` (`ColumnFit.fitted`'s pad), clamped to the display and the window; aligned to 1/scale.
   **Bounds (picktarget117, A2)**: what a target may cover is the content of the window under the pointer (`LensTarget.targetBounds`: the frame below its title bar). With the pointer over no window of a display that has windows (the Dock, the menu bar, the desktop) there is no target: the Dock's labels are blocks of the map and the ones whose x lies in a page's column are its members, so with the display as the clamp a hop of the skinland117 take stretched the spotlight below Preview's window (bottom at y 891) over the Dock to y 968. With no window list at all (no permission, the checks) the display is the clamp, as before.
5. nil anywhere: **today's ghost** (`PickerView.clickLens(at:)`), unchanged. Chat, games, subtitles, code, a pointer over a figure or a margin. What the ghost can know is the display, the window list (each window's frame; the top 28 pt of a window taller than 120 pt are its title bar, `content(of:on:)`) and the pointer; the toolbar, a sidebar, a page's margin are only in the picture, which is the read. So it is never drawn while the read is young (4.2).

The target depends on the anchor block and the column, never on the pointer's y inside the block: the outline does not move while the pointer reads along a paragraph; it steps when the pointer crosses into the next.

### 4.2 Look and motion (no new look core)
- The preview is the picker's own ghost drawing (punched hole in the 0.32 dim, accent stroke 3 pt, radius 10, the same label "Follows Preview · ⌥ pins to the screen"): a fitted target and the default ghost differ only in rect. Stroke at **0.85 alpha** while it is a preview; full alpha is the placed lens's ring (not the picker's).
- Moving between targets: a **0.12 s** critically damped morph (`FitMotion`'s settle from fit117, one spring owner), `Reduce Motion` (`Motion.shared.reduced`): none, the rect jumps. A change of mind in mid-morph retargets from the current rect. Ghost <-> target: same morph.
- **Follow**: the target is recomputed on every `mouseMoved` (≤ 1.3 us); the visible rect is the morph's. The decision lags the pointer by zero frames; the glide is the 0.12 s on purpose.
- **The first outline (picktarget117, `LensTarget.preview`, `Glide.appear`)**: while the read is young (`ghostGrace` 0.8 s) the spotlight is nothing: the dim and the hint only. The first target, or the ghost where the read gave nothing, opens from the pointer: a 20 pt square (twice the outline's 10 pt radius) centred on the pointer, moved inside the rect it opens to (the gutter's slack puts the pointer up to 12 pt outside a target), growing to the rect on the glide's own spring (`quick` of the motion contract 3.5: 0.267 s, 90 % at 130 ms), every frame inside the rect. The hole, stroke and label move as one. Under Reduce Motion it is at the rect at once. A pointer that left the display and came back, and the end of a drag, open the same way. No reader or a read that gave nothing: the ghost at once (nothing is to be waited for).

### 4.3 What a click, a drag, ⌥, the keyboard and VoiceOver do
| input | today | with the target |
|---|---|---|
| click (no drag, < 24 x 12 pt) | `clickLens(at:)` default box, centred on the click | the target's rect when there is one, else the box; window = hovered window unless ⌥ |
| ⌥ held | pins to the screen | unchanged; the preview still shows (the lens just does not follow a window) |
| drag ≥ 4 pt | the user's rectangle | unchanged; the preview goes away at the first drag event |
| Return with the pointer over a target | engages the keyboard lens in the middle of the screen | **places the target** (the keyboard equivalent of the click); with no target on screen: unchanged |
| arrows, ⇧ resize, ⌥ fine, Esc | keyboard lens | unchanged |
| VoiceOver / Switch Control on | the keyboard lens is there from the start | unchanged: place it, then **Fit to Column** (fit117's lens-menu row and VO custom action) gives the same lens. Parity = the same outcome by a second route, not a second picker mode |
| click before the map returns | default box | default box (the click never waits) |

### 4.4 Drawing and threads (the term that matters)
- `PickerView.draw` redraws the whole display bitmap per `needsDisplay`: **15.7 ms median** (`probe/drawcost.swift`, 3024 x 1964, load 38); a `sample` of the app during a loaded picker open shows 0.54 s of the main thread in `CABackingStoreUpdate`/`argb32_mark`. Required for the preview: **layers** — a dim layer, one `CAShapeLayer` with an even-odd hole path, one stroke layer; the morph is a `CABasicAnimation` on `path` (0.12 s; none under Reduce Motion). The label pill and the hint pill stay views.
- The map is read **off the main actor**: one-shot capture of the display (`RegionCapturer`: `SCScreenshotManager` with `excludingApplications: [this app]`, the filter a lens uses, so the picker's dim and our own windows are not in it), `TextRecognizer.blocks(plan: .automatic)`, `ColumnFit.columns`, build `Map`; only the finished `Map` crosses to the main actor. A new `WorkerJob.Purpose.picker` between `lens` and `image` (the scheduling order is the enum's order: a running lens is never starved by a picker; the picker is ahead of an image window and warm-up).
- Lifecycle (one table, no ifs elsewhere): `opened` -> capture + read (display under the pointer first; another display's map when the pointer first enters it) -> `ready(Map)` | `none` (no column, no reader, no permission, timeout 4 s) -> `closed` (cancel the read; drop the map; nothing is kept). A map never outlives its picker; the picker holds no image after the read.
- Language: the lines of the read give the dominant language (`NLLanguageRecognizer`, already used in `TextRecognizer.swift` and `TranslationService.swift`); the translator prewarms that pair (`TranslationService.prewarm(source:)`, one tiny request).

### 4.5 Failure modes
| situation | what happens |
|---|---|
| no Screen Recording grant | `addRegion` already stops at the onboarding: no picker, no map |
| pointer over chat / game / subtitles / terminal | `choose` nil: the ghost; 1 false claim among the 42 non-paper scenes of the bench (the long Discord message: a 772 pt "column", 6 blocks; the target is a lens over the messages; the 3-column magazine is a true claim) |
| two columns, pointer in the gutter | nearer column within 12 pt, else the ghost |
| a figure, a table | members break at gaps > 44 pt; a table's narrow stacks are < 160 pt: the ghost |
| CJK page (one block per line) | no column (2 of 7 paper scenes): the ghost; fit117's v2 candidate |
| the first minutes of a cold install, Japanese source | no reader for 2 min: no map: the ghost; the lens will say "Preparing …" as today |
| Docs service slow | `automatic` plan: whichever answers (lines path 0.3 s); patience 4 s, then no map |
| content changes between the read and the click (a video) | the target is a rect on the old picture; the placed lens reads the real one; Auto Fit (fit117) corrects if the user enabled it |
| two displays | one map per display, read when the pointer first enters it; targets clamp to their display |
| the window under the pointer is not the page (a floating panel) | `hovered` window rules as today (top-most layer-0 window); the target is clamped to its content |

## 5. First run: what onboarding says and shows

No new step, no nag. Three changes to what exists; everything else stays.
1. **The demo shows the gesture.** `LensDemo` (a chat, a lens gliding) gets one beat before the glide: a ring hugging one message, then the Korean. No new string (its sample strings exist).
2. **Card 3** (`OnboardingView.swift:41-43`), en:
   - today: "Press ⌃⌥L anywhere, then drag an area or click. The lens follows the window it lands on; hold ⌥ to pin it to the screen."
   - proposed: "Press ⌃⌥L anywhere, point at a paragraph and click, or drag an area. The lens fits the column and follows the window it lands on; hold ⌥ to pin it to the screen."
3. **Card 1, granted** (`OnboardingView.swift:30`), en, because of the map (section 0.6):
   - today: "Allowed. Mwoyeo reads only what is under a lens, and never stores or sends it."
   - proposed: "Allowed. Mwoyeo reads the screen only while you place a lens and under a lens, on this Mac, and never stores or sends it."
Picker strings: **unchanged** (the hint pill, the label, the accessibility help). The preview explains itself; zero new picker keys.
New or changed catalog keys (11 languages each; ko by the lead): the two sentences above (each is a new key, the old key goes). The "Try It Now" button stays disabled before the grant without saying why (audit finding 6): a one-line caption "Allow Screen Recording first" is an optional third key.
How the first lens gets its first Korean fastest: section 3.2 (compile first at launch; the language of the pointer's text warmed at picker open; Latin on `.fast`). Said honestly: for a CJK source on a first launch there is no faster route than the compile, and the pill should say "about 2 minutes".

## 6. Owners (one each, nothing duplicated)
| what | owner | file | change |
|---|---|---|---|
| where the columns are | `ColumnFit` (fit117) | Core `ColumnFit.swift` | reused as is; one added constant `minTargetWidth = 160` in the target, not in `ColumnFit` |
| pointer -> lens rect | **`LensTarget`** (new, pure, Core) | `Core/Sources/MwoyeoCore/LensTarget.swift` | `Map`, `choose(_:held:bounds:)`, the constants of 4.1; built from `ColumnFit.columns` and all blocks |
| the glide between targets | `FitMotion` (fit117's `LensGesture.swift`) | Core | reused (0.12 s settle) |
| one-shot display capture | `RegionCapturer` | `App/Capture/RegionCapturer.swift` | `static func snapshot(of:)`: same filter as the stream |
| the read, the scheduling | `TextRecognizer.blocks` + `RecognitionHost` | `App/Pipeline/TextRecognizer.swift`, `App/Reader/RecognitionHost.swift`, Core `ReaderHealth.swift` | new `WorkerJob.Purpose.picker` (new meaning = new case) |
| map lifecycle, drawing, input | `RegionPicker` / `PickerView` | `App/Overlay/RegionPicker.swift` | map state, layers for dim/hole/stroke, hover -> `choose`, mouseUp, Return, Reduce Motion |
| language warm-up at picker open | `TranslationService.prewarm` | `App/Pipeline/TranslationService.swift:290-302` | `prewarm(source:)` takes the detected language |
| warm-up order | `AppModel` | `App/Model/AppModel.swift:233-241` | `warmUpVision` before `translator.prewarm` |
| onboarding sentences, demo beat | `OnboardingView` | `App/UI/OnboardingView.swift` | strings and one `LensDemo` phase |
| trace / stats | `Trace`, `stats()` | `RegionPicker`, `RecognitionHost` | `picker: map n=… columns=… ms=…`, `picker.map.read`, `picker.target.hit`, `picker.click.target|ghost` |

## 7. Gates the implementation round must pass (every one FAIL-first; none waits on a wall clock: durations are injected)
1. **Core `LensTargetTests`** on the p10 fixture of fit117 (`ColumnFitFixtures`) and a drawn two-column page: target per pointer (rect = column ± 6 pad, top = anchor top ±0.5, bottom = a block's bottom), nil in the gutter and over a one-line heading alone, minimum width 160, height budget, window/display clamp with the title bar, bounds-short growth upward, **hysteresis: 0 reversals under ±2 pt jitter at every boundary** (FAIL-first: a stub without the 8 pt rule shows hundreds, `data/hover-paper.txt` has 107 to 1253), determinism (same anchor -> same rect for any y inside the block). Stub = `choose` returns nil: every case fails.
2. **Core: the default is untouched**: `choose` nil -> the click rect equals `clickLens(at:)` for 500 random pointers and windows (byte-for-byte; the default path).
3. **App check `picker-click-fit`** (check-logic, a `FakeCapture` display with a CoreText two-column page): hover then click yields a lens within **±3 pt** of the drawn column's edges (`width - 12`), top/bottom on block edges ±2 pt; on a chat page the lens rect is the default box; click before the map returns places the default box (the map is delivered by an injected continuation after the click).
4. **Time to first Korean, before/after**, `drive.py` promoted to `tools/first-lens/` (warm n=3 and cold n=3; the same medians as section 1 for steps 3, 6 and 9, reported with the load). Pass: no step is slower than its median here beyond the run's spread; the picker open is not slower (the map read is off the main actor: a gate that the main thread is free during a read — a fake map that never returns must leave the hint pill drawable).
5. **Layers**: a Core/App check that a morph of the preview triggers no `draw(_:)` of the full view (a counter on `PickerView.draw`: 0 during 30 simulated morph frames; FAIL-first: the current drawing path counts 30).
6. **AXPress / keyboard parity**: `PressChecks` entries for the picker: the accessibility value and help are unchanged; Return with the pointer over a target places the target; Return without one engages the keyboard lens (today's checks, `AccessibilityChecks.swift:654-677`, stay green); after keyboard placement `Fit to Column` (fit117's row) answers AXPress and yields the same rect as the click.
7. **Reduce Motion**: `Motion.shared.force(true)`: the preview jumps (0 animations), the click rect is identical.
8. **Cost gates**: `picker.map.read` = 1 per picker open and 0 at launch, at login and while no picker is open (counter); closing the picker cancels the read (the fake read sees the cancellation); no image retained after `closed` (a weak reference check).
9. Benches equal: the uc and paper benches `cmp` equal to a same-day base run (no pipeline change).
10. Strings: the two onboarding keys in 11 languages, `catalog-coverage.py` 0 problems.
11. **The first outline is no ghost (picktarget117)**: Core `LensTargetPreviewTests` (the take's columns and pointer path: no target leaves its column ± 6 pt, the page or the window's content; the take's 532 ms read shows nothing at every 120 Hz frame; the grace, the injected zero, the phases) and `LensTargetEntranceTests` (the opening from the pointer: 20 pt square, 90 % at 130 ms, every frame inside the target, gutter pointer, tiny rect, Reduce Motion, a change of mind); `LensTargetBoundsTests` (the skinland117 take: a pointer over the Dock gets no target and none stands outside the window; today's display clamp reached 962); App `picker-checks`: nothing while young, the recheck due, a click still the default lens, the ghost after the grace and at once with no reader or an empty read, the first target a square at the pointer that opens inside itself, Reduce Motion at once.

## 8. Gap table (target vs today)
| target | today | gap | size |
|---|---|---|---|
| a preview that hugs the text | a 560 x 320 ghost that cuts a block at 95 % of positions | `LensTarget`, map read, layers | Core ~160 lines + tests; picker ~200 lines |
| one-click fitted lens | click -> default box | `mouseUp` uses the target | ~20 lines |
| picker draws in layers | CoreGraphics full-display redraw per event (15.7 ms) | 3 layers + path animation | ~120 lines |
| map read with its own purpose | none | `Purpose.picker`, `RegionCapturer.snapshot` | ~60 lines |
| language warmed at picker open | warms `ja` | `prewarm(source:)` | ~15 lines |
| warm-up before prewarm | after | reorder | 2 lines |
| onboarding says how | "drag an area or click" | 2 strings, 1 demo beat | ~40 lines + strings |
| snap in the picker's drag (fit117's `ColumnFit.snap` on the map's `Targets`) | none | optional v2 | ~30 lines |
| paragraph height from lines (a block taller than H cut at a line) | blocks only | needs line rects in the snapshot (fit117's v2 too) | v2 |
| a "ll first, hf refines" first answer | hf only | section 3.4: decision | M |
| the pill says how long CJK preparing takes | "first time only" | copy + a measured estimate | S |

## 9. Three layers
1. **Structural closure.** One owner for "pointer -> lens rect" (`LensTarget`, Core, pure); columns stay `ColumnFit`'s; the glide stays `FitMotion`'s; the capture stays `RegionCapturer`'s; the read goes through the host with its own `Purpose`. The picker view only draws and forwards.
2. **Recurrence.** Gate 1 (the rule on measured block data, hysteresis FAIL-first), gate 2 (the default path untouched), gate 5 (no full redraw per frame), gate 8 (no read at launch), gate 4 (the time-to-first-Korean medians kept in `tools/first-lens`). The perceptual axes (how the outline feels while steps morph at 0.12 s) go to one opus vision round on a playback recording, not on stills.
3. **Debuggability.** Trace lines `picker: map n=<blocks> columns=<n> read=<ms>` and `picker: target <column> anchor=<i> rect=…`; stats counters above; the probes become `tools/first-lens/` (`drive.py`, `probe/*.py`, `lookup.swift`, `drawcost.swift`, `trwarm.swift`, `tools/{pagewin,post,watch}.swift`).

## 10. HIG and convention references
| claim | reference | status |
|---|---|---|
| point at the thing, click to take it: the system's own capture does it | Apple Support, "Take a screenshot on your Mac" (https://support.apple.com/en-us/102646): Command-Shift-4, Space: "The pointer changes to a camera icon." "To take the screenshot, click the window or menu to capture it." "To cancel taking the screenshot, press the Esc (Escape) key." | fetched, quoted; the page does not say the window is highlighted |
| ⌘ turns alignment guides off; the alignment haptic is for dragging into alignment | fit117's section 10 (Keynote 6.6 help; `NSHapticFeedbackManager.FeedbackPattern.alignment`) | fetched there |
| Reduce Motion: the glide is a jump | `Motion.shared.reduced` (project rule); Apple's Motion guideline | the HIG pages do not load through the fetch tool: **not verified** |
| keyboard and VoiceOver reach every outcome | `AccessibilityChecks.swift:654-677`, `PressChecks`, HIG Accessibility | project checks exist; HIG page not verified |

## 11. Open questions for the lead
1. Section 3.4: low latency first, high fidelity refines (changes the default path).
2. The privacy sentence (section 5.3): wording, and that the map reads the whole display once per picker open (never stored or sent).
3. Return with the pointer over a target places it: a change to "the keyboard path unchanged" in the spec; it only applies when a target is on screen.
4. The system dialogs: macOS asked "'bash' wants to bypass the window picker" about 7 times (one per live run of my ScreenCaptureKit watcher, launched through bash). They are stacked on the user's screen; I did not answer them, and my watcher no longer uses ScreenCaptureKit. The user has to answer or dismiss them. I also found another round's a11y sheet window inside my lens area during a locked step, so pixel detection can be contaminated on this shared screen.

## 12. Reproduce
`tools/first-lens/`: `build.sh` (Release, cold id); `run-live.sh <label> <cold|warm> [--key-after S --picker-loop N --rm-mark --no-key --no-frames --second]` (screen lock, lease) -> `drive.py` (page window, hot key, windows, trace, Korean); `series-{cold,warm,noop}.sh`, `cold-vr.sh` (`vision-reads`), `rm-one.sh` + `series-rm.sh` (read matrix), `series-vnpages.sh`; `probe/{hover,scenes,vncmp,rmsum,summ}.py`, `probe/{lookup,drawcost,trwarm}.swift`; `timeline.py <run>`. Outputs: `data/runs/<label>/{events.jsonl,summary.json,timeline.txt}`, `data/runs-summary.jsonl`, `data/vr/{ja,en}`, `data/rm*`, `data/hover-*.txt`, `data/lookup.txt`, `data/drawcost.txt`, `data/trwarm.txt`, `data/vn-vs-auto.txt`. `runs-v1/` holds the first warm series, discarded (saved lenses from an aborted run leaked into the defaults suite; the ScreenCaptureKit watcher's frames were 10 s apart under load).

## 13. First paint: low latency first, high fidelity replaces (round fast117, section 3.4 built behind a flag)

**Scope, said once.** Which model answers today is set by `TranslationService.wantedStrategies`: `auto` takes the language pack's low-latency model (ll) when the pair's pack is installed and Apple
Intelligence's high-fidelity model (hf) otherwise; `highFidelity` takes hf only. So hf is today's FINAL answer in exactly two cases: **(B)** `auto` on a Mac whose pack is not installed (the usual new Mac with
Apple Intelligence; there ll does not exist, so there is nothing to paint first) and **(C)** `engine: highFidelity` chosen by the person, with the pack installed. The flag works in (C) and says nothing in the others.
On a Mac with the pack and `auto` (case A) the final is ll already (p6, `auto`: batches of 3 lines 99 to 385 ms); the flag leaves it alone, so its final text is today's byte for byte.

**Target.** `fastFirstPaint` (settings.json, default false). A lens's first batch, while hf has not answered it: ll and hf start together; the ll text is painted as a provisional first paint of its block; each line is
replaced by its hf text when it lands (the block's existing 0.22 s cross-fade, same rect); a line whose hf text equals the provisional one is not repainted. The provisional text exists only on screen: it is not in
the block's translation, so the translation log, Copy and Save never hear it; the cache, the pace and the credit ledger keep hf's answers only. A failure of ll costs the first paint and nothing else; hf's failure,
deadline and retry are today's.

| target | today | gap | owner |
|---|---|---|---|
| a quick first paint of the first batch | hf only | `FirstPaint.run` (Core, pure: order, ll failure swallowed, ll cancelled when hf is done) | `TranslationService.translateGroup`, Apple branch |
| which groups get it | - | `FirstPaintPlan.decide` (Core table: flag, final is hf, pack installed, caller asked) | same |
| one place per source: none, provisional, final | a translation or nothing | `FirstPaintBook` (Core): late ll after hf dropped, equal text not repainted, how long it was shown | `RegionPipeline` (draws it) |
| the person's log never hears it | - | the provisional is not `Block.translation` (`BlockText` reads that) | `RegionPipeline` |
| the right pair warm | `prewarm` warms `ja` for `auto` | `prewarm(source:)` takes the language the last lens detected; warms ll too when the flag is on | `TranslationService.prewarm` |
| seeing what happened | - | `translate.first_paint_ms`, `first-paint:` trace lines, `--first-paint-log` in the harness | `RegionPipeline`, `SelfTest` |

### 13.1 What was built (the flag is off by default; `fastFirstPaint` in settings.json, `--first-paint` in the harness)
- **`FirstPaintPlan`** (Core): `wants(flag, asked, finalIsHighFidelity)` is what is known without asking the system; `decide(..., quickInstalled)` adds the pack. The only table of when a group is answered twice (16 rows, tested).
- **`FirstPaint.run`** (Core): the quick model and the final one start together; a quick failure is swallowed; the final model's failure is thrown as it would be alone; the quick model is cancelled when the final one is done; the answer is the final one's.
  Sequence (quick, then final) was built and measured beside it, and dropped: same first paint, final 0.0 to 0.5 s later, and the final model would wait for the quick one.
- **`FirstPaintBook`** (Core, held by `RegionPipeline`): per source none, quick, final; a quick text that lands after the final one is dropped; a final text equal to the shown one is `keep` (nothing is drawn again); it keeps when each landed, for the numbers.
- **`TranslationService.translateGroup`** (Apple branch): the plan, then `FirstPaint.run`. `translate(..., provisional:)` is heard only here (no rewrites, no context, no added engine). `installedSession(source:route:strategy:)` is the one place a model's session is made (the old `session` loop uses it).
  `prewarm(route:source:)` warms a lens's own pair when the lens is added (Apple only; a pair already warmed is left alone) and the quick model beside a high-fidelity final.
- **`RegionPipeline`**: `firstPaint` book, `firstPaintOpen` (until the first batch lands). A quick text is drawn through the block's ordinary render (`renderMissing` reads `translation ?? firstPaint.shown`) and appears with the block's fade; the translation replaces it through `receive`
  (the block's 0.22 s cross-fade, same rect). The quick text is never `Block.translation`, so the translation log, Copy and Save (`BlockText`) never hear it, and "waiting for translation" (the queue, the lens's wait, settle) is still `translation == nil`.
- **`groupBySource`** (`TranslationService`, one owner of the grouping that both translate paths had written out): the page's language is learned from all the lines of a call before any line is read (13.6). `prewarm(route:source:)` warms the language the page showed most (`pageLanguage`) before `ja`.
- **Seeing it**: trace `first paint '<line>' <ms>`, `first-paint ll|hf landed '<line>' <ms>`, `session ll|hf ready (<source>)` (after the group's `engine ←`), `service result`, `pipeline streamed|provisional|emit`; counters `translate.model.ll|hf`, `translate.first_paint`, `first_paint.kept|repainted|redrawn`; samples `first_paint_ms`, `provisional_shown_ms`
  in the harness's work line; `--first-paint-log` prints one `fp-line:` per drawn line (when drawn, when final, how long the quick text stayed, characters changed, `REFIT` when the text size or height moved) and `fp-summary:`.

### 13.2 Measured (this Mac: en > ko, the pack installed for both models; `--render` of our own pictures through the real service and pipeline; load average 8 to 170 in the runs, the config order rotated each repetition; n = 5 each)
`tr` is the time from the first batch being sent to the first Korean drawn. `read` (the harness reads the whole picture; a live lens reads its area, 1.1 s warm in section 1) is the same for every config and is not what the first paint moves.
Medians (min to max), ms:

| scene (first batch) | config | tr: first batch to first Korean | final lands (first batch to the first final text) | quick text on screen | lines changed by the final text | text refit |
|---|---|---|---|---|---|---|
| c01 chat (3 short lines) | `auto`, pack (today's default here: low latency is final) | 31 (30..52) | = tr | - | - | - |
| | high fidelity, today | 1449 (1293..2039) | 1449 | - | - | - |
| | high fidelity + first paint | **432** (54..1347) | 2231 (1820..2736) | 2023 | 10 of 15 (90 of 215 characters) | 0 of 15 |
| d06 web (3 short lines) | `auto`, pack | 40 (39..132) | = tr | - | - | - |
| | high fidelity, today | 1800 (1513..2565) | 1800 | - | - | - |
| | high fidelity + first paint | **78** (61..600) | 2609 (2120..3508) | 3671 | 5 of 15 (20 of 125) | 0 of 15 |
| p6 paper (2 long paragraph lines) | `auto`, pack | 286 (274..2877) | = tr | - | - | - |
| | high fidelity, today | 7848 (6719..8508) | 7848 | - | - | - |
| | high fidelity + first paint | **355** (331..1307) | 7477 (7256..8593) | 7489 | 10 of 10 (475 of 1230) | 5 of 10 |
Sessions not warmed (a fresh process without the launch warm-up): high fidelity today 2185 / 2542 / 7220; with the first paint the quick text lands in 2041 (536..8159) / 2140 (709..2778) / 7184 (418..7610): the quick model's own first batch is as slow as the final one's (and the quick text lost the race to the final text in 4 of 5 p6 runs, so nothing was painted first). **The first paint is worth what the quick model's warm-up is worth**: warm, 3 to 23 times earlier; cold, none.

**A fresh bundle id (cold e5rt caches, the render without `--warm`, so the first read runs on the `.fast` rung while the text model compiles) and no launch warm-up**, c01, n = 5 (the machine was at load average 68 to 253: my own benches and other rounds' ran beside it, so read these as "no gain visible", not as medians to quote):
high fidelity today `tr` 5137 ms (2872..9854), with the first paint 3869 ms (956..9505); the quick text was painted before the final one in 1 of 5 runs (4 of 5 times the final text was there first or at the same time). The first read took 4.7 to 38 s in these runs (the harness reads the whole picture).

**With the inpainting model on, as in the app** (`INPAINT=1`, c01 and p6, n = 5, load 37 to 183): high fidelity today 2498 ms (2080..3742) / 7137 ms (7085..7168); with the first paint 834 ms (61..3147) / 639 ms (362..2112). The erase is done before a quick text can be drawn (it needs the erased background), so a live lens is as early as the later of the two.
In a live take on p6 at a load average above 70 the 16-block erase took 6.2 s and the quick text (landed 1.2 s after the batch was sent) was drawn with the final one: the first paint is worth nothing where the erase is the slower term.
**Final text, flag off vs on** (`tools/first-paint/data/full*`, `full2`): complete p6 runs on the final build, hf off x 2 and the flag on x 2 (37 lines each, the flag painted 2 lines in each): 0 lines differ among them and from the base build's hf run. c01 (11 lines) and d06 (9 lines), off vs on: 0 differ. The whole-page variant (every batch painted; removed) on c01 and d06: 0 differ; its p6 runs did not complete at load 150 to 250 (the 11 s hf deadline), and the 19 lines they did translate equal the others.
Sequence (the two models one after the other), warm medians, `tr` / final lands: c01 47 / 2213, d06 45 / 3020, p6 293 / 7416 ms, against parallel 432 / 2231, 78 / 2609, 355 / 7477: no earlier first paint, so it was removed (rows in `data/warm-s1`).

### 13.3 What the replace looks like
- **Motion.** A line whose final text differs fades from the quick text to the final one in place (the block's existing `CATransition` 0.22 s on its `contents`); a line that was not drawn before appears with the block's fade-in; a line whose final text is the quick one is not drawn again.
- **Lines that change.** First batch, warm: c01 10 of 15 lines (18 of 43 characters changed per run), d06 5 of 15 (4 of 25), p6 10 of 10 (95 of 246: the two long lines; edit distances 89 and 6). Short names and labels often agree (kept: c01 5 of 15, d06 10 of 15, p6 0 of 10).
- **Does the line wrap differently?** Only a paragraph does: p6's long paragraph went from 27.0 to 25.8 px text and from 188 to 206 px of text height (+9.6 %) inside the same block rectangle (a refit the block renderer always does: it lays the translation out in the original's room). The block's rectangle and everything around it stay; nothing jumps. 5 of 10 painted lines on p6 refit, 0 of 30 on the short-line scenes. A viewer sees a paragraph of Korean change its words and reflow once, 7 s after it appeared.
- **How long the quick text stays**: the length of the final model's batch (median 2.0 s on c01, 3.7 s on d06, 7.5 s on p6): `shown` in the table.

### 13.4 For the lead
1. **The premise.** Today's final is high fidelity only for an explicit `engine: highFidelity` (C) and for a Mac whose pack is not installed (B, the usual new Mac with Apple Intelligence: `auto` falls to it). The flag can do nothing for B (no quick model exists there) and nothing for a Mac with the pack on `auto` (A: the final is the quick model already, 31 to 286 ms a batch here). **The slow first lens a new user meets is B, and the lever there is the pack, not this flag**: the first batch is 1.4 to 7.8 s at this load. (A pack is installed by the person, in Settings; the first lens could offer it. That is a product decision.)
2. **What the flag buys in C**: the first Korean 3 to 23 times sooner on the translation term (warm); the cost is that the final text lands 0 to 0.8 s later on a short first batch and the first batch's lines change under the reader (above). The final text is the same as without the flag (`tools/first-paint/check.sh`, and the complete p6, c01 and d06 runs: section 13.2).
3. **Recommendation (updated after the live takes, 13.8): leave `fastFirstPaint` off in 1.1.7** as the file-only setting it is. It acts only for an explicit `engine: highFidelity` with the pack installed, and in a live lens with the inpainting model on (the default) the quick text is drawn when the erase pass ends, which is when the final text can be drawn too (13.8): the take shows no swap. Turning it on later changes `AppSettings.fastFirstPaint = true`, its entry in `SettingsFile.writtenOnlyWhenSet` (a default of true is written when false) and the doc string of the key; the plan keeps A and B untouched, so no per-user subset is needed. Revisit when the erase pass stops holding the pipeline (13.8, last point) and the picker warms the page's language.
4. **The warm-up is the other half.** Without a warm quick model the first paint is not earlier (table above). `prewarm(route:source:)` warms a lens's own pair when the lens is added and the quick model beside a high-fidelity final; for `auto` the language is still `ja` at launch. Warming the language the picker finds is first117's `prewarm(source: detected)`: one call at picker open.
5. **A live lens is as early as the later of the erase and the quick model** (13.2): the harness numbers above hold with the inpainting model on; a take at a load average above 70 did not show the swap because the erase took 6.2 s. The playback verdict wants a quiet machine.
6. **The 1.6 s of a default lens's first batch is not session creation or the model (13.6).** On a chat page it is two lines the detector guessed alone as Spanish and French; fixed in the owner. That is worth more than this flag on the default path (1.7 s on c01), and it changes `# general`'s text.

### 13.5 Reproduce (`tools/first-paint/`; every launch goes through `app.sh`, which refuses without scratch settings, a `fast117.*` defaults suite and `MWOYEO_MEMORY_SECRETS=1`)
- `check.sh <binary> <picture> <out dir>`: the first paint end to end on a fake Apple (`MWOYEO_FAKE_ENGINE=first-paint:200:4000`), the real service, pipeline, book and transcript writer: setting off paints nothing and logs hf only; on paints the first batch only, keeps the equal lines, logs no quick text, ends on the same final text. Five stubs of the code
  (the quick text in `BlockText`, equal lines drawn again, the setting ignored, every batch painted, the quick text as the answer) each fail it.
- `series.sh <build> <out> <reps> <scenes> <configs>` (`p6,c01,d06`; `auto-w`, `hf-off-w|c`, `hf-par-w|c`: `w` = the launch warm-up first, `c` = none), `summ.py <out>`: the timing tables above; `NOWARM=1 COLDID=<id>`: the cold id (an app built with that bundle id; never a pool id).
- `check-groups.sh <binary> <picture> <out dir>` (the fake Apple, Detect): the first engine call of c01 holds "# general", "Priya Shah" and the English line together. The base build fails it (the first call is "# general" alone).
- `INPAINT=1 series.sh ...`: the app's inpainting model on; `autod-n|j|e`: the `auto` engine with the source on Detect and no / the launch (`ja`) / the `en` warm-up. The raw runs of every table are in `tools/first-paint/data/` (`*.summary.txt` are `summ.py` of them; `*.groups` the `engine ←` / `session` lines of the Detect runs).
- `run-render.sh` (one render; `STAMP=1` stamps every stderr line with the uptime) and `timeline.py <run>`: where a first batch's time went, from the engine call to each model's lines and the pipeline's snapshots.
- `probe/penalty.swift`: does the quick model slow the final one? One process, models warm, four arms in rotation (alone, together, quick first, a used model); on three long lines the medians were 5.2 s alone (two runs at 11 and 12 s), 5.7 s together, 4.7 s quick first, 4.5 s after (n = 6, load 50): no penalty outside the noise there; in the app the short first batches landed 0.3 to 0.8 s later (above).
- `rec.py <build> <p6|c01> <on|off> <out>` (under `lockf /tmp/r117/screen.lock`): a live take of a lens over the page, `screencapture -v`, cropped to 720p30.
- `rec.py ... --source en --no-inpaint` (a take with the pair warmed at launch, a stand-in for the picker's detected-language warm-up of first117; without the inpainting model); `swap.py <out.mp4> <label>=<off take>,<on take>[,<seconds>] ...`: the playback sheet (off and on side by side, one timer from the click, 720p30) of the takes; the click is found from the picture (the first Korean line is the trace's first `pipeline provisional|streamed`), because a recording on a loaded machine does not keep the driver's clock.
- Harness switches: `--first-paint` (the setting), `--first-paint-log` (the probe, and the translation log fed as the app feeds it), `--prewarm` (the launch warm-up of the translation session first).

### 13.6 Where the first batch of an `auto` lens with the pack goes (the lead's question: 1.6 s warm / 6.1 s cold in section 1; round fast117, 2026-10-22)
The engine on `auto` with the pack is the low-latency model already (31 to 286 ms a batch with the source set to English), so the 1.6 s is not the model. Source on Detect (what a lens has by default), headless `--render`, stamped traces (`data/detect-before/*.groups`), n = 5, load 8 to 123:

| first batch (ms from the batch sent to the first Korean) | none warmed (n) | the launch warm-up, `ja` for Detect (j) | the `en` pair warmed (e) |
|---|---|---|---|
| c01 chat, before | 1799 (1740..2649) | 1724 (1666..2350) | 1788 (1674..1967) |
| c01 chat, after `groupBySource` | **148** (118..546) | 411 (205..422) | **48** (41..492) |
| d06 web, before / after | 131 / 143 | 397 / 414 | 43 / 51 |
| p6 paper, before / after | 364 / 385 | 651 / 629 | 271 / 283 |

- **Where the c01 time went (before).** The first call of the lens is three lines. Each was read alone: `# general` as Spanish, `Priya Shah` as French, `Morning all! ...` as English. Three groups, in that order: `engine ← "# general"`, `session hf ready (es)` 40 ms later, the answer 1.7 s later; then the same for the French name (0.6 s); then the English line on the low-latency model in 30 ms. A guess with no pack falls to high fidelity (`wantedStrategies`), and the groups run one after the other. Session creation was 0 to 57 ms in every group and nothing queued behind the reads: the time is two groups of high fidelity before the English one. A line the detector is unsure of already took the page's language when one was known (`sourceLanguage`: `p < 0.75 || count < 12`), but the page's language came from the long lines of the same call, which were counted after the short ones had been read.
- **The fix, in that owner.** `groupBySource` counts the call's confident long lines first, then reads every line (`learns: false`); both translate paths use it (they had the loop written out twice). c01's first call is one English group. d06 and p6 start with long lines: no change, as the table shows.
- **What changes in the text.** Only a line that was guessed alone and now reads in the page's language: c01 `# general` went from `# 일반적인` (Spanish to Korean, high fidelity) to `# 일반` (English to Korean). The other 10 lines of c01, d06's 9 and p6's 37 are byte-identical before and after (`data/detect-before` vs `data/detect-after`, runs that did not finish under load compared on the lines they did translate). This is the default path, so the lead decides whether it lands with this round.
- **Recurrence gate.** `tools/first-paint/check-groups.sh`: the first engine call of c01 on the fake Apple holds all three lines. The base build prints FAIL for the second and third line.
- **Warm language.** At launch `prewarm()` warms `ja` for Detect. For an English page that is worse than warming nothing (c01 411 vs 148 ms, d06 414 vs 143, p6 629 vs 385: +0.26 s), and the right pair is better than nothing by 0.1 s (48 / 51 / 283) at this load; at load 220 first117 measured 0.96 vs 0.23 s. `prewarm(route:source:)` now takes the language the page showed most (`pageLanguage`) before `ja`, so a second lens in a process warms the right pair; a picker that detects the language passes it (`source:`). Not done, the lead's call: remember the last page language across launches (one defaults key, no setting) so the launch warm-up of the first lens is right too.

### 13.7 The low-latency text against the high-fidelity text (data only; no default changes in this round)
The two models translate the same pictures; the quick text of the first paint is the low-latency one. Per scene, lines both models translated (5 runs each, both deterministic on c01 and d06): c01 9 of 11 lines differ, 55 of 283 characters (19 %); d06 5 of 9, 60 of 246 (24 %); p6's first batch (the two long paragraph lines) 95 of 246 characters (edit distances 89 and 6). Pairs, low latency then high fidelity:
- `Morning all! The release candidate is ready for testing.`: `여러분, 좋은 아침입니다! 릴리스 후보가 테스트를 위해 준비되었습니다.` / `여러분, 안녕하세요! 리리스 후보자가 테스트 준비가 완료되었습니다.`
- `New chip doubles battery life of laptops`: `새로운 칩이 노트북 배터리 수명을 두 배로 늘입니다` / `새 칩이 노트북 배터리 수명을 두 배로 늘린다`
- `Posted October 14, 2026 by Dana Cole`: `2026년 10월 14일에 다나 콜이 게시함` / `2026년 10월 14일 Dana Cole이 게시함`
- p6: `0.5 pt 해상도에서 이분할에 의해 발견됩니다.` / `0.5 pt의 해상도로 나눈 후 찾은 것이다.`
So "low latency first, high fidelity upgrade" on a Mac that has the pack (case A) would change a fifth to a quarter of the characters of a page after a short wait; neither text is a typo-free reference (high fidelity wrote `리리스` for the release). Kept as data; nothing is wired for case A.

### 13.8 The live takes and the final-build re-check (the successor round, 2026-10-22 evening; build `fast117f` of 14:47, after the last source edit)
- **Final text, final build, complete runs** (`data/full3`: the setting off x 2 and on x 2 per scene): c01 (11 lines), d06 (9), p6 (36): 0 lines differ between any two of the four runs. The first paint drew 3, 3 and 2 lines (c01 repainted 2 of 3, 18 of 43 characters; d06 1 of 3, 4 of 25; p6 2 of 2, 95 of 246). `check.sh` 10 PASS and `check-groups.sh` 3 PASS on the same binary.
- **Live takes** (`rec.py`, `screencapture -v`, 720p30 crop; load average 10 to 240 because other rounds ran beside; the sheet `/tmp/r117/fast117/swap.mp4`; times from the driver's events and the app's trace). Seconds after the click that placed the lens:
  | take | today: first Korean drawn | first paint on: first Korean drawn | the final text drawn (hf landed) |
  |---|---|---|---|
  | c01, no inpainting model, source `en` (the pair warm) | 9.5 | **5.5** (the batch was sent at 5.4) | 9.8 (7.9 to 9.3) |
  | p6, no inpainting model, Detect | 19.1 | **10.5** (batch sent at 10.2) | 19.3 (17.8 to 18.9) |
  | p6, inpainting model on (as in the app), Detect | 22.8 | 23.1 (the quick text landed at 14.1, the batch was sent at 12.6) | 23.1 (22.5 to 23.6) |
  | c01, inpainting model on, Detect | 16.1 | 14.9: no quick text (the quick model's session was cold: it had not answered when hf did) | 14.9 (10.3 to 11.8) |
  The seconds before the batch is sent (4 to 12 here: OCR 1.4 to 4.6 s, the fast erase 3 to 11 s at this load) are the read, which the flag does not touch. The quick text stayed on screen 4.3 s (c01) and 8.9 s (p6) before the final text replaced it.
- **Why the inpainting take shows no swap.** A text that lands is drawn by the pipeline actor, and the seamless pass (`RegionPipeline.swift:991`: the erase loop, then `blocks = next`) runs on that actor in one piece (4.2 to 7.3 s with the inpainting model here). In the p6 take the quick text landed at 14.1 s and was drawn at 23.1 s, when the pass ended; the final text, which landed 8 s after the quick one, was drawn in the same second. Without the inpainting model the pass is shorter and began after the quick text was drawn, so the swap shows (rows 1 and 2). Today's final text waits for the pass in the same way.
- **What this means for the flag**: a live lens draws its first Korean at the later of the erase pass and the model's answer, so the flag brings the first Korean forward only by what hf takes beyond the erase pass: 4.0 s (c01) and 8.6 s (p6) with the inpainting model off, 0 s with it on at this load (rows above); and only for an explicit high-fidelity engine (13.4, 1). The default-path win of this round is 13.6 (the first batch of a default lens, 1.8 s to 0.15 s on c01).
- **Not done, and why**: letting a landed text draw on the fast-erased background while the seamless erase runs (a yield point per block, or the erase pass moved off the actor) would move every first Korean, flag or not, by up to the erase time; it is a change of the pipeline's concurrency, outside this round's owner. The picker-open `prewarm(source: detected)` (13.4, 4) is first117's.
