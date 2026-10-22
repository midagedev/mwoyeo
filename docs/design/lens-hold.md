# A lens resize holds what is drawn (1.1.7 design, round hold117)

User, 2026-10-22: "렌즈 크기 바꿀때 글자 사라지는거 고쳐, 우리 오버스캔하고 미리 그려두는거 아니었나? 화면이 바뀌지 않는 이상 앵커 잘 되어서 이전에 그려져 있어야 하는데 제품 결함이야."

## 0. Verdict

The overscan and the anchoring work: through a resize, `captureResized` keeps every block where it is on the page, and the overlay panel only moves its clip (`OverlayPanel.slide`). What blanks the text is the **re-read that follows** (the fast pass for the strips the resize uncovered, then the settled seamless pass). A re-read builds new `Block`s. A new block keeps the old one's translation only when its text is *identical*. Where the new reading differs (a paragraph cut by the capture edge now reads longer; the document reader groups the lines of a paragraph in one block where the fast reader made two) the new block has `translation == nil`, so no `image`, and `emit` leaves it out of the snapshot (`guard let img = b.image`). The panel removes its layer. The page's own text shows until the engine answers (0.1 s in the check's mock, 0.3 to 1 s with a real engine), then the Korean comes back. Nothing on the page changed.

## 1. Measured (check `resize-hold-checks`, build of main 3a2e86a + the check + one counter, 2026-10-22, machine under load)

Lens 420×290 on a still page of nine paragraphs, two of them wider than the lens, a mock engine that answers after 120 ms. The check drags the corner as `RegionFrameWindow.mouseDragged` does (`setRegion`, `onResize`, `onCommit`) and keeps every snapshot (`RegionSession.snapshotObserver`).

```
 23889 ms v7   blocks 7 in lens 7 texts 7 untranslated 0 kept 1.00 ink 91114→91114 lens 450×310  <- grow a little dropped
 38417 ms v8   blocks 2 in lens 2 texts 6 untranslated 4 kept 0.45 ink 91114→46379 lens 450×310     <- the settled re-read
 38621 ms v9   blocks 3 ... v10 4 ... v11 5 ... 38786 ms v12 blocks 6 untranslated 0               <- the engine answering, one block at a time
 53098 ms v14  blocks 3 in lens 3 texts 7 untranslated 4 kept 0.67 ink 132538→90533 lens 520×350  <- after "grow inside the margin"
```

The trace names the cause at v8: `blanked 4 drawn block(s): 'The lens reads the w' no translation ; 'When a page does not' no translation ; 'Every line of a para' no translation ; 'Some paragraphs run ' no translation`. At v8 the lens drew 2 of its 6 blocks, 45 % of what v7 had drawn; the overlay changed 49 % fewer pixels. Four blocks blank, 7 over the run (`overlay.blanked`). The 15 s between a drop and v8 is the machine's load (the pass took 10 s); the order of events is the same on a quiet one (film4 act 1, `app.err`: `fast: 5 new blocks (erased), 2 kept`, then `engine ← "The predic (tk, dk, Ck) wi" | …`: the cut lines read longer after the resize, and 618 ms later `translate ×3 cancelled` when the next resize changed them again).

### 1.1 On the screen, and in the film's raw take

Screen recording of the same run (`tools/lens-hold`, `screencapture -V`, 3024×1964, the lens crop that every step keeps; the share of the page's text pixels that are dark again): base build, 1 dip above 0.6 in the first lens's run, 142 ms (9 frames), depth 0.74 (the translated level is 0.39); fixed build (the final tree, 508 frames), 0 dips (level 0.46). The mock answers after 120 ms, so the dip is as long as the engine.

Addendum H2 corrected the film's luma claim (194→240 was the edit's dips to the stage colour). The raw take's own trace (`/tmp/film4/takes/t0r-oldway2/app.err`) still shows the effect, in blocks instead of luma: `fast: 5 new blocks (erased), 2 kept` at 1972190803062541, `engine ← "The predictor keel (tk, dk, Ck) with Ck t moving the content path from an event" | "1 = 16 ms, and the" | "application animates k that is on screen a"`, and the three renders at 1972192773746958 to 1972192842310833: three of the lens's seven blocks undrawn for 1.97 s (the engine's `translate ×3 2038 ms`). Three blocks of seven are a small part of the lens, which the full-frame luma and the ink share of the lens do not see.

The line: `RegionPipeline.swift` `seamlessPass` (`if let oi = matches[i], prior[oi].source == ocr.text { b.translation = prior[oi].translation }`) and the same line in `fastPass`; the drop is `emit`'s `guard let img = b.image`.

## 2. Target

1. A block that was drawn stays drawn until a block that stands where it stood is drawn: the old translation is shown, in the place of the new reading, until the new one is rendered.
2. Only while the page under it has not changed since it was read. The uncovered strips of a grown capture do not count as a change (they are new pixels, not different ones). A real change of the page (a subtitle, an edit) is read as before: no old translation over new text.
3. One block's reading may become several (the document reader merges the pieces the fast reader made): the new block shows the old pieces' translations in reading order. A reading that splits one block shows the old text in the piece that holds most of it.
4. Nothing leaves the pipeline as a translation that is not one: `BlockText.translation`, the transcript, Copy Translation and the screen reader's lines stay `nil` until the engine answered.
5. `overlay.blanked` (blocks drawn in one snapshot, still read, drawn by none now) stays 0 on a still page.
6. (addendum H4, fit117's take: a translated lens turned English when it was fitted, mid-drag and 1.4 s after the release) The same rules hold for a lens put at its new size in one move (Fit to Column and its Undo): the capture grows past the old reference, a paragraph cut at the old edge reads longer, and the translation of the cut one stays until the longer one has its own. The page under such a block is judged by the pixels the old reference had, not by the tiles the strip touches.
7. (addendum H5: Fit, Fit back, Auto Fit, settle after a move, hand resize) When a block that had Korean is read again for any of those, the Korean it had stays until the new reading's own Korean is drawn, and then swaps in place: no frame of the page's text under it, no frame with the old and the new drawn at once. Two rules besides the carry above. (a) A new block takes the identity of the old block it stands in the place of (the largest of those whose text it carries): the overlay panel dissolves one layer into its new image, where a block with an identity of its own is faded in while the old one fades out, and the page's text shows through both. (b) A new block that is only a piece of an old drawn block (0.8 or more of it lies inside, the page under the old block unchanged: the capture's edge cuts the text the lens has moved to) is not made; the old block stays as it is, with its translation, clipped by the lens.

## 2b. The second symptom (addendum H1, game117's film defect F8): a resize throws away the pass in flight

`captureResized` bumped `geometryEpoch`, and `finishPass` returned nil for every pass that had started before the bump (`guard start.epoch == geometryEpoch`), so its OCR, its erase and its blocks were dropped (`guard let moved = finishPass(...) else { return }`). A game lens that widens its overscan on a dialogue change (more than 20 % of the frame changed = motion) and narrows it again after 4 s of calm resizes twice per change, and each resize can discard a pass that takes 3 to 10 s on a loaded machine: the text read 1.6 s after the click lands on the screen 12 s later. Same owner (`captureResized`), same rule:

6. A capture resize over a page that did not change keeps what is drawn **and what is being read**: a pass that started from the old frame follows the resize like a move (the machinery that already carries a pass across a scroll or a lens recentre: `moves`, `Move.apply`, `Move.undo`, `finishPass`'s replay of the reference image), and only the newly covered area is read.
7. A capture that only shrank (the lens made smaller, the overscan narrowed after calm) has nothing newly covered: it is not read again. `captureResized` marks the page changed (`lastChange`, `seamlessDone = false`) only when `ChangeMap`'s reference has strips the new capture shows for the first time (`GrayImage.uncovered`); a game lens that widens its overscan on every change of dialogue and narrows it after four calm seconds used to read the whole frame twice per change (film4 F8: 16 seamless passes in 61 s, the same text re-rendered every 3 s).

## 3. Owners (one each)

| What | Owner | Change |
|---|---|---|
| which old text a re-read block shows meanwhile | `TranslationCarry` (Core, pure) | new: `assign(old:new:)` |
| whether the page under an old block changed | `Staleness` in `RegionPipeline` over `ChangeMap` | `FrameDiff.changeMap(from:to:ignoring:)` (Core: the strips a larger capture only now shows do not count, pixel by pixel), `Staleness.covered`, `Staleness.edited(_:step:)` |
| what a block draws while it waits | `Block.carried`, used by `renderMissing` | one field; `translation ?? carried` |
| which identity the new block has for the panel | `carryTranslations`: the new block takes `old[Carry.primary].id` | `Block.id` is a `var`; one layer dissolves in place (`render.inherited`) |
| a new block that is only a piece of a drawn one | `TranslationCarry.fragments` (Core, pure), applied in `carryTranslations` | the old block stays in `blocks`, the piece is not made (`render.pieces`) |
| what the panel gets | `emit` (unchanged: a block with an image is drawn) | counter `overlay.blanked`, trace line |
| what a resize does to a pass in flight | `captureResized` → `apply(Move)` with `Move.resized`; `finishPass` replays it on the reference image | `geometryEpoch`, `PassStart` and the callers' `else { return }` removed; counters `pass.rebased`, `pass.read` |
| whether a resize asks for a read | `captureResized` | `lastChange` / `seamlessDone` only when `uncovered` strips exist |
| when the read of a grow starts | `RegionSession.armResizeRead`, called when the resize ends and when the lens is dropped | the read waits for a lens that rests on its size; a jump (Fit) ends its resize before its drop, which finds the capture already there, so the drop arms too |

## 4. Gap table

| # | Target | Today | Gap |
|---|---|---|---|
| 1 | old translation stays until the new one is drawn | new block without a translation draws nothing | `Block.carried`, set in `fastPass` and `seamlessPass` from `TranslationCarry` |
| 2 | only while the page is unchanged | not asked | `Staleness.edited`, from the change map over the pixels the reference had (`covered`: `forcedDirty` ignored pixel by pixel). First form: tiles whose centre lay in a strip were left out; a tile that the strip cuts, with its centre on the old side, read as an edit of the page and the cut paragraph (the one that needs the carry) got none: Fit trace `3 old drawn block(s), 3 edited; 0 of 9 new carry` |
| 3 | merge and split | the matcher pairs one new block with one old one, the others vanish | `assign` by coverage of each old block by a new one (≥ 50 %), not by the matcher |
| 4 | never leaves as a translation | n/a | `carried` is read by `renderMissing` only |
| 5 | counted | no counter | `overlay.blanked`, trace `blanked n drawn block(s)` |
| 6b | a pass's old blocks are matched where the frame had them | `fastPass` matched blocks moved since the pass began against frame coordinates (a scroll, now a resize) | `inFrame(_:)` (the undo `seamlessPass` already did), used by both |
| 6 | a pass in flight survives a resize | thrown away by the epoch bump | `Move.resized` (new capture bounds, new gray canvas); `finishPass` reframes the reference and flags the uncovered strips as `captureResized` does for the live one |
| 7 | a capture that shrank is not read again | `lastChange = now; seamlessDone = false` on every resize: a settled whole-frame read of 3 to 10 s after each narrowing | only when the resize uncovered something (`strips`); check: the "shrink" step reads 0 passes (`pass.read`) |
| 8 | a Fit's grow is read | the read of a held grow was armed by the resize's end only while the lens was not dragging; a jump's resize ends before the drop, the drop found the capture already at its size and armed nothing (check: 0 passes after the Fit, the Undo came first) | `armResizeRead` in `lensDropped` as well |
| 9 | one layer per block through a re-read | a new block without a matcher pairing had a new `UUID`: its layer faded in while the old one faded out, the page's text showing through both (check: `swaps`, 1 of 21 snapshots) | `Carry.primary`: the new block takes the identity of the old one it stands in the place of |
| 10 | a cut paragraph keeps its Korean | the lens moves, the capture's edge cuts a title: the new block (the part still in the capture) read differently, had no translation, the old block went (check, move step: the page's text back at 1.00 under the title, trace `no new block holds half of: 'Reading text o' -158,278 921x76`) | `TranslationCarry.fragments`: 0.8 of the new block inside an unchanged drawn old one: the old stays, the piece is not made |

Deferred, reported: a block that the new reading does not find at all (its old block unmatched, nothing covering it) still goes with the pass, as before; the engine failing for good leaves the carried text on (it is a translation of what the page showed, and the page has not changed).

## 5. Gates

- Core: `TranslationCarryTests` (a longer reading, a changed page, merge in reading order, split, an old block taken once, and `ChangeMap.intersects(_:excluding:)`). FAIL-first against stubs: 5 of 8 fail.
- App: `resize-hold-checks` (in `check-logic`): grow a little, grow inside the margin, shrink, grow past the margin, shrink to the start. Every snapshot is composited over the page and compared with the one before: the page's own text (its dark pixels under each block the snapshot before drew) must not come back (`worstRestored`, limit 0.6: a drawn translation leaves 0.35 to 0.41 of it dark, the page's text showing is 1; the settled lens is the control, 0.41), the overlay changes at least 0.7 of the pixels it did, never zero blocks, and `overlay.blanked` stays 0. FAIL on the base (main 3a2e86a + the check + the two counters): the page's text is back at 1.00 under 4 blocks (v8, 2 of 6 blocks drawn), the overlay changes 0.51 of the pixels it did, `overlay.blanked` 4; PASS with the fix (0.41 in three runs of the final build, 0.94, 0).
  The first form of this gate asked that the pixels each block *changed* stay changed (worst >= 0.5). A translation that is replaced by the one the engine answers (the carried one is shown meanwhile) changes other pixels of its block, and that read 0.46 in one of six runs under load: a block that is still drawn. Replaced 2026-10-22 by the form above (the instrument of `tools/lens-hold/luma.py`, on the snapshots); the same run on the final build now reads 0.37 where the old form read 0.46.
- App, second part of the same check: the lens is resized while its first read is under way (`session.activity == .reading`): `pass.rebased` ≥ 1, `pass.discarded` 0 (a counter that only the base tree used for FAIL-first has: base `pass.rebased 0, pass.discarded 2`, fix `1, 0`), and the blocks of the first snapshot sit on the page's paragraphs in the new capture (the re-basing is right, not just present).
- App, third part: Fit to Column, its Undo (one jump each, `drag(steps: 1)`) and a move of the lens (the pill dragged 220 pt, `slide`) on a narrow lens (280 pt) whose capture ends inside the first column: the Fit and the move read what they uncovered (`pass.read` ≥ 1: a check that reads nothing proves nothing), no snapshot of the three brings the page's text back under a block drawn before (the same instrument as part one, counted in snapshots: `englishOver`), `overlay.blanked` 0, no snapshot swaps a drawn block for another standing over it (`swaps`, parts one and three: the panel would fade both at once), and the Undo reads nothing again. `MWOYEO_HOLD_TIMELINE=<file>` writes `<file>.fit` beside the timeline.
- FAIL-first of the third part and of the rules of §2 7 (2026-10-22, `MWOYEO_TRACE=1`, machine under load): the tree with the carry assignment stubbed out (`carryTranslations` returns at once) fails the page's text back at 1.00 (2 of 27 snapshots in part one, 2 of 19 in part three), `overlay.blanked` 7 and 4, the overlay changing 0.51 of its pixels; the base with the counters fails the same, `the Undo takes the lens back and nothing is read again (1 passes)`, `pass.rebased 0, 4 passes`. The tree before the identity rule: `swaps` 1 of 21 snapshots; before the piece rule: the move step has the page's text back at 1.00 under the old title (1 of 21 snapshots). Core: `FrameDiff.changeMap(ignoring:)` with the pixels not skipped fails `the pixels the reference had say it is not`.
- Recording: `tools/lens-hold/record.sh` and `luma.py` (dips: number, length, depth).
- Benches: unchanged (`uc`, `paper`): the pipeline's reads and requests do not change.

## 5b. Not done, reported

- A new reading that covers an old block by less than half in any one piece draws nothing for it. Seen in the Fit check's first geometry (a lens 420 wide, the second column cut at the capture's edge): the document reader read the wide capture's second column as two garbled pieces, one of them held 0.44 of the old block (`TranslationCarry.share` is 0.5) and the lines under it were in no new block at all: 145 ms of the page's text under the old block (the mock answers after 120 ms), then the translation. The carry keeps what a new block stands over; an old block that no new block stands over, or only partly, still goes (the "deferred" case below). Not fixed: it is the new reading that is wrong there, and keeping the old block beside a new one that overlaps it would draw two translations over each other.

- After a resize the fast pass reads the whole capture, not only the strips: `dirtyRect(for:)` widens every strip to full rows and unions them (a strip at the right edge, full height, is the whole frame: the film's trace says `fast: OCR 1316×636px` for a 1316-wide capture). Reading only the rows of the blocks that touch a strip plus the strips needs several regions per pass (`TextRecognizer.blocks(in:roi:)` takes one). About 60 lines and a bench run; nothing is blanked meanwhile.
- A pass that was re-based used to leave `seamlessDone` false (`lastChange` was the resize's time), so the settled whole-frame read ran again after it. Closed: a resize while a pass is in flight does not bump `lastChange`, `finishPass` sets `seamlessDone` when it rebases, and a shrink sets `seamlessDone` so a larger size queued ahead of it is not read. The session applies the capture as it is when the resize runs. A call that waited behind a pass applies nothing once a newer request exists. A grow does not start its read until the lens has settled on that size, so a shrink that arrives first is not followed by the larger size's read.

## 6. Three layers

1. Structural closure: the owner of "what is drawn where a block was" is the block itself (`carried`), decided in one Core function. No second place patches the overlay.
2. Recurrence: the check above; the counter in the trace of every run (`MWOYEO_TRACE=1`).
3. Debuggability: `overlay.blanked` counter and a `blanked …` trace line naming the block and whether it lacks a translation or an image; `MWOYEO_HOLD_TIMELINE=<file>` makes the check write its snapshot timeline.
