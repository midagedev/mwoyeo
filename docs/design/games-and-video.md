# Games and video: ignored regions, recent lines, a moving scene beside the text (1.1.7)

Status: design, 2026-10-22, round game117. Ledger: docs/IDEAS.md "Games, video and chat"; docs/ROADMAP.md 1.1.5 D, carried to 1.1.7.
A lens with none of the new options set behaves as it did: no region is ignored, no line is kept, and a lens that has no text in
it yet reads every change as before.

## 1. Ignore a region inside a lens

Target: a HUD, a name tag or a timer inside a lens is not read, not translated and not drawn over. The person drags a rectangle
inside the lens ("Ignore Region…" in the lens menu); the rectangle is kept with the lens in lens units, so it follows a move and a
resize; "Clear Ignored Regions" takes them all away. Outlines show while the lens is hovered or being edited, never at rest.

| Piece | Today | Target | Owner |
|---|---|---|---|
| Where the picture reaches the reader | `RegionPipeline.ingest` takes the frame whole; `TextRecognizer.blocks` / `.lines` read `frame.image` in the fast and the seamless pass | one mask, two places that share one geometry (`RegionPipeline.ignoredAreas`): `ingest` makes the change-detection gray flat in the regions (`GrayImage.filled`), and both passes read `readingImage(frame)`, the picture with the regions painted in the colour around them (`RGBAImage.filled`, a two-pixel ring; a mask that cannot be made fails the pass, never reads the real picture). Erase and appearance still sample the real picture, so a patch beside a region is true to the screen | `RegionPipeline.ingest`, `.readingImage` |
| Geometry | none | `IgnoredRegions` (Core): a drag in global points → `UnitRect` (0…1 of the lens); `UnitRect` → capture pixels for the lens now and the capture's origin and scale; → gray pixels | Core `IgnoredRegions.swift` |
| Motion inside a region | a ticking timer re-reads its rows every second | the gray is flat there, so a region never changes a pixel and never wakes a read | same mask |
| Saved with the lens | `RegionConfig` holds rect, anchor, name, `profilePin` | `RegionConfig.ignored: [UnitRect]` (at most 12), persisted through `onConfigChange` like the pin | `RegionConfig`, `AppModel.startSession` |
| The regions change, or the lens moves over them | – | `remask()`: the newest frame's gray is made again from the gray as captured (`rawGray`), so the tiles that went flat (or real) differ from what the blocks describe and the next pass reads those rows; a block of text that was in a region is replaced by what the reader finds now, none | `RegionPipeline.setIgnored`, `setVisible` |
| Pick | none | `RegionMarker` (a window over the lens's screen, the lens punched out, drag, Esc or a right click cancels; arrow keys, ⇧ resizes, Return places, for no pointer, through `KeyboardLens(bounds:size:minimum:)` with the lens as bounds) | `App/Overlay/RegionMarker.swift` |
| Outlines, and nothing drawn over a region | none | the overlay panel (click-through; the lens window is not, and a drawn hatch would eat the clicks that go to the game): a view of its own draws the hatch and the edge while the pointer is over the lens or a region is being marked, and the clip of the translations gets the regions cut out of it (even-odd), so no block is drawn over one whatever its layout did. A lens with no region keeps the plain clip | `OverlayPanel`, `IgnoredOutlinesView` |
| Shortcut | none | `HotKeyAction.ignoreRegion`, no default | `HotKeys` |

## 2. Keep the last few translated lines on screen

Target: with "Keep Recent Lines" on (a lens option, off by default), a line that leaves the lens stays in a small stack, newest
nearest the lens, up to `recentLineCount` (a setting, 1…8, default 3), fading by age.

Placement, decided by readability: **just outside the lens** (below it, above it when the screen has no room). Inside the bottom
edge the stack would lie on the text a game or a chat has there (a visual novel's box and a chat's newest message are at the bottom
of the lens), hiding the very line being read. Outside it covers only what the person did not put a lens on. The cost: a second small
window (`RecentLinesPanel`), click-through, that follows the lens.

| Piece | Today | Target | Owner |
|---|---|---|---|
| What changed | `TranscriptRecorder` turns snapshots into entries (first usable translation of a line) for the transcript writer, only under `savesTranscripts` | the lens runs a recorder of its own on the same `LensText.observed` feed; `RecentLines` (Core) reads its `.entry` events and the lines in the lens now. Nothing re-detects a change | Core `RecentLines.swift`, `RegionSession.received` |
| What the stack holds | – | lines whose source is not in the lens now, newest first, a fragment of a line folded into the fuller reading (`TranscriptMerger.related`), at most N | `RecentLines.stack` |
| Fading | – | `RecentLines.opacity(rank:count:)`: 1.0 for the newest, 0.6 for the Nth (0.45 read about 2.2:1 on light, vision 10-22) | same |
| Option | – | `RegionConfig.keepsRecent`, lens menu "Keep Recent Lines" (checkmark), `HotKeyAction.keepRecentLines`, no default; the number is the setting `recentLineCount` (file only, 1…8, default 3; the Appearance tab's Restore Defaults sets it back) | `RegionSession.contextMenu`, `AppSettings` |
| Cleared when | – | the languages or engine change, the option is turned off, the lens closes. Show Original only takes the stack off the screen (it is a peek, and a peek must not cost the history) | session |

## 3. A moving scene beside the text does not slow translation

Measured (film2-live, 2026-10): a game's moving background in the band above the text box made the lens re-read the scene about
three times as often (frame latency median 3.7 s against 1.2 s).

Cause, from the code. `RegionPipeline.ingest` takes every changed tile as a change: it sets `lastChange` and clears `seamlessDone`,
adds the tile to `unexplained`, and a change over 20 % of the capture counts as motion for the queue (`noteMotionFrame`). `dirtyRect`
then makes one box of all changed tiles (the band, the gap, and the text box when it changed too), so each frame of the scene is one
fast read of the band and a line change is read as one very large box. The reader serves one read at a time: the text waits behind
the band.

| Piece | Today | Target | Owner |
|---|---|---|---|
| Which change counts | any tile | a tile inside a box of the last read grown by one tile counts now; a tile away from the boxes is held until it has been still for `hold` (0.4 s): new text appears once and stays, a scene keeps changing. A held tile that rests is read like an uncovered strip (`forcedDirty`) | Core `ReadWatch` |
| No text known | every change counts | every change counts (nothing to weigh against) | `ReadWatch` |
| Scroll, a capture that grew | every change counts | unchanged: every change counts, the blocks move with the content | `ingest` passes `boxes: nil` |
| Motion for the queue | `ratio > 0.2` | `ratio > 0.2` and the text's own tiles changed | `ingest` |
| The look again | `churn.coolsIn` wakes a still pass | the first held tile's rest wakes it too (`ReadWatch.wake`); a tile that rests is handed to `forcedDirty` (`noteRested`), because the reference moves on to the frame of the last read, which had the tile as it was while it moved. `lastChange` is a frame's time and stays as it is: the first version set it to the clock, the pass then ended with `seamlessDone` false (`lastChange > frame.time`) and read the same still frame again and again (found by `GameChecks`, 2026-10-22). A rest is judged when a run starts and not between its passes: a pass holds the actor for longer than `hold`, the frames that came in meanwhile are not counted when it ends, and a tile of a scene that never stops would rest on the stamp of a frame from before the pass, so every pass was followed by a read of the scene (found by `BandProbe` with frames fed as a capture feeds them: 100 passes for 9 line changes, latency median 0.8 s against 0.4 s with the weighing off; `GameChecks.movingBandDuringAPass`) | `run()` |
| The clock of a rest | the wall clock when a run starts: a run was taken to come after the frames that waited behind the last pass | the time the frames counted reach (`ReadWatch.Inbox.seen`): `ingest` hands a frame in off the actor and `take` counts it (or drops it); while frames wait, no tile is judged still past the capture time of the oldest of them, and with none waiting it is the clock (a still scene sends no frames). The rest judgment, the wake and the staleness all read it. On the wall clock a run asked for during the drain judged after the frames before it were counted, more than `hold` after the stamp of the newest it had, when the drain took longer than the hold or the feed paused before the pass ended, and read the scene (`GameChecks.movingBandDuringAPass` failed 7 of 20 under load, round bandflake, 2026-10-22). The trace says `rest held back: N frames wait…` and counts `watch.rest_waits` (round gamelag117) | Core `ReadWatch.Inbox`, `RegionPipeline.ingest`/`take`/`noteRested` |
| A read ends | the reference is the frame read | `didRead(area, frameTime:)` lets go of the held tiles inside the area read whose last change is not newer than the frame read; a tile that changed after it stays held (the frames that came in during the read moved the scene on, and without this every read of a moving scene was followed by another) | `fastPass`, `seamlessPass` |
| Measuring | – | `--capture-ui <dir> band-probe` feeds a 900×360 lens (a band of moving cells over 31 % of it, a line of text that changes every 3 s) at 8 frames a second, each frame in a task of its own, and prints the latency of every change and the passes it took; `MWOYEO_READ_SCOPE=off` (not in the App Store build) turns the weighing off, so one binary shows before and after; the trace says `(N tiles away from the text held)` per frame and counts `watch.held_frame` and `watch.rested` | `DebugSwitch`, `Trace` |

Trade-off, stated: a new line of text that appears away from every known box while a scene keeps moving **in the same tiles** waits
until that area is still. Text that appears in a still part of the capture is read 0.4 s later than before. Text in or beside a known
box is read as fast as before. What this does not fix: a scene that moves **under** the text (a video behind a subtitle) changes the text's own
tiles, which count as they did; only `Churn` (the same tile changing again and again) takes those out. Gates: `ReadWatchTests` (Core, synthetic frames, a fake clock) and `GameChecks.movingBand` (the pipeline with real reads: twelve frames of a moving scene make no read, the text changing in the thirteenth is read; FAILs with `MWOYEO_READ_SCOPE=off`). `GameChecks.movingBandDuringAPass` holds a pass for longer than the hold while the scene goes on; its set-up has a pause of more than the hold in the scene before it (a machine slow to ingest makes one by itself, load 100+: the rest of the first frames is read, the scene goes on, and it is read again), and it waits until no tile is held (`RegionPipeline.holdsTiles`) before it counts, since `debugState().busy` is false between a read and the timer that reads what rests next.

## 4. The marker's focus (film4 F12)

After a drag, the marker gave the previous app no focus back: the game stayed inactive and the first click into it only activated it and was lost (film4 takes t4r-game, t4r-game2: the first
dialogue click after the drag did not advance the scene). The marker ended in three ways and only the key paths returned the focus.

| Piece | Before | Now | Owner |
|---|---|---|---|
| The marker ends | the app that was in front got its focus back only after a key | whichever way it ends (drag, key, Esc, right click) in the one `finish`; the system calls (`frontmost`, `refocus`) are replaceable for the check | `RegionMarker` |

Gate: `GameChecks.markerFocus` (a drag, Esc and the keys each give the app that was in front its focus back; Finder stands for it), seen to FAIL on the code before.

The lens that lags a changed line (film4 F8) is not this round's: it is on main too (a resize of the capture throws away the pass that began before it, `RegionPipeline.captureResized`/`finishPass`) and belongs to
round hold117; the handover with the trace and a first fix is `/tmp/r117/game117-F8-handover.md`.

## 5. The marker's hint pills avoid the lens (gamepill, 2026-10-22)

The two hint pills ("Drag over what the lens should not read", "Arrow keys move …") were drawn at the screen's middle at a fixed distance from its top, whatever the lens was: opus vision on the
game117 shots found the arrow-keys pill over the lens's top-right ring by ~9 pt, and a lens near the top or the right of the screen is where they always collide.

Target (contract): a pill never overlaps the lens frame (ring included, and the room of its name tag), stays fully inside the screen's visible frame (menu bar and Dock excluded), and the two
keep their order (the drag hint above the arrow-keys one) with 8 pt between them. Above the lens when the pair fits there, else below it, else beside it (right, then left); when no side has room
(a lens that fills the visible frame) they sit just inside the top of it, the one place the contract cannot hold.

| Piece | Before | Now | Owner |
|---|---|---|---|
| Where the pills go | `MarkerView.draw`: `bounds.maxY - 120` and `- 164`, centred on the screen | `MarkerHints.place(pills:lens:visible:clearance:)`, a pure function of the sizes, the lens and the visible frame; `MarkerView.hintFrames` is its one call | `Core/MarkerHints.swift`, `RegionMarker` |
| Clearance | none | `RegionFrameWindow.tabExtra` (40 pt: the ring, its glow and the name tag, which sits above or below by setting) on every side | `RegionMarker` |
| The arrow-keys pill appears | it was placed on its own | both pills are always placed, one pair, so the drag hint does not move when the second appears | `MarkerView.hintFrames` |
| The shot | `GameShots` cut the pills at the capture's edge and showed the real desktop around the stage | the capture is the lens and the pills with 20 pt around (16 asked; the ring and its glow count as the lens), over a stage that covers all of it; light and dark | `GameShots` |

Gates: `MarkerHintsTests` (Core: a centred lens, near the top, near the right edge, full height, a lens that fills the screen, and a sweep of 2 120 lenses up to 1000 × 600), `GameChecks.markerHints` (the view's
frames for a lens at the top right of this Mac's screen), seen to FAIL on the fixed placement.
