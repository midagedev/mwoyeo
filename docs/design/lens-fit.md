# Lens fit: snap, Fit to Column, Auto Fit (1.1.7 design)

Round fit117, 2026-10-22: design and measurement (sections 0 to 15); round fit117impl, the same day: as built (section 16).
Source of every number: `tools/lens-fit/data/*.txt` (run `tools/lens-fit/probe/run-all.sh`, section 13).

User, in their words: "논문 같은거 볼때 단에 맞춰서 렌즈 영역이 자동 확장되거나 하게 만들고 싶거든 ... 뭔가 스냅같은걸 주고 싶기도 하고".

## 0. Verdict

The lead's three-part shape (snap, Fit to Column, Auto Fit) holds. Six things change because of what the code and the data say:

| # | Lead's proposal | What the evidence says | Design |
|---|---|---|---|
| 1 | Snap while dragging, edges pulled live | A lens is moved by the window server (`performDrag`, `RegionFrameWindow.swift:482-487`); the code says why: a per-event `setFrame` made the lens "fall behind and jump". The app gets no mouse events during a move, and a `setFrame` inside the display link would fight the window server's own position. A resize (bottom-right corner) is app-driven and can snap live. | Move: a **guide line + alignment haptic while dragging, the lens settles onto the edge when you let go** (macOS precedent: Sequoia window tiling shows a preview and snaps on release). Resize: live snap. |
| 2 | ⌘ turns snapping off | Verified: Keynote 6.6 help, shortcut table: "Turn off alignment guides while moving an object: Command-drag"; also "Command-drag (while resizing): disables alignment guides". | Keep ⌘. |
| 3 | Snap to column and paragraph edges | A paragraph edge is within 8 pt of 37 % of all y positions (28.9 to 44.1 % by page): the lens would catch on every third pixel. A column edge holds 5 to 18 %. | **x only in 1.1.7** (column edges). Paragraph (y) snap and "fit height" are dropped; gap table. |
| 4 | Column from the overscan / blocks | `OverlaySnapshot.texts` is the wrong input: its frame is the block's *patch* (`b.rect`, which carries the ring and the spare width to the right), and it lists only `startsParagraph` blocks, so the second piece of a paragraph that goes on in the next column is missing (`RegionPipeline.swift:1717-1722`). The estimator needs the line union ("core") of every block. | The pipeline ships `columns` in the snapshot, computed in `emit` from `blocks` (12 µs for 60 blocks). |
| 5 | Auto Fit reads the column from the overscan | At rest the capture holds the whole column for 0 % (lens 160 pt) to 81 % (320 pt) to 96 % (400 pt) of positions on our paper (column 325 pt), and on a zoomed Preview page (column 588 pt) for 0 % up to a 320 pt lens, 92 % at 600 pt. | An edge the capture cuts is **unknown, never guessed**; one **probe read** with a display-wide band (`Overscan.band`) finds it, then the lens fits. |
| 6 | Double-click the lens border | Fits macOS: double-clicking a window edge expands that side to the screen edge (secondary sources, section 11). | Double-click the ring (not the pill, not the resize corner) = Fit to Column; double-click again = Undo Fit (the Zoom button's toggle). |

## 1. What was measured

Instruments: `tools/paper-bench` outputs of build `dd-d14main` (main at the D14 landing) on our own paper (13 pages, `tools/paper-own/mwoyeo-method`); two real Preview screens from film3 (`/tmp/film3/screen1.png`, a frame of `takes/after-paper.mp4` at 1.5 s), rendered by the app's own headless pipeline (`run.sh`, scratch settings); ten real lens-cut captures (crops of bench pages cut where the app's overscan would cut them, rendered by the same pipeline); the 52 scenes of the use-case bench. Units: screen points. Estimator: section 5 (prototype `probe/columns.py`).

### 1.1 How accurately do column edges come out of the existing blocks

Truth: the PDF's own columns (PDF pt 54..297 and 315..558, from pdftotext's justified lines) and, for Preview, the screenshot's ink (`probe/inkcols.py`). Two independent paths.

| set | cells | found | left err | right err | width err |
|---|---|---|---|---|---|
| paper pages, two body columns | 26 (p13 has no prose) | **24** (every page with prose; 0 of 26 with a stub estimator) | mean +0.1, max 0.6 | mean +1.3, max 2.0 | mean +1.2, p90 2.1, max 2.1; 87 % within 2 pt, **100 % within 3 pt** |
| Preview shot A (tables, captions, two columns) | 2 | 2 | +0.8 / 0.0 | -0.5 / +0.5 | -1.2 / +0.5 |
| Preview shot B (prose) | 2 | 2 | +0.5 / +0.5 | +0.5 / +0.5 | 0.0 / 0.0 |

The right edge has a +1.3 pt bias (the block box is a little wider than the justified edge). No calibration constant: the fitted lens takes a pad (section 5.5) that swallows it. **The app check must assert ±3 pt on the width, not ±2**: three of 24 paper cells are above 2 (2.1).

### 1.2 Does the capture hold the whole column, and what does the estimator make of a cut capture

Lens positions every 20 pt (x) and 150 pt (y), height 250, on the eight prose pages (p2 p4 p6 p7 p8 p10 p11 p12); capture = `Overscan.rect` at rest / wide; the page's blocks cut to the capture. "Reference" = the estimate from the whole page (validated in 1.1). Columns of 325 pt (the page is 817 pt wide).

| lens W | positions | capture holds the column, rest | exact, rest | edge reported unknown, rest | wrong | none | capture holds it, wide | exact, wide |
|---|---|---|---|---|---|---|---|---|
| 160 | 1021 | 0 % | 0 % | 99 % | 0 % | 1 % | 73 % | 74 % |
| 240 | 833 | 57 % | 56 % | 43 % | 0 % | 1 % | 89 % | 89 % |
| 320 | 680 | 81 % | 80 % | 19 % | 0 % | 2 % | 97 % | 97 % |
| 400 | 516 | 96 % | 95 % | 4 % | 0 % | 1 % | 98 % | 98 % |
| 560 | 143 | 100 % | 99 % | 0 % | 0 % | 1 % | 100 % | 100 % |

- **Wrong = 0 %**: the estimator never returned a silently wrong edge; where the capture ends inside the column, the edge sits within 2.5 pt of the capture edge and is flagged *unknown* (`part-unk`). That flag is the safety property the design stands on.
- 23 % (lens 160) to 39 % (400) of lens positions, and 72 % at 560, have no single column under them (across the gutter, across both columns): `under` returns nil, and the menu row is disabled. Not a failure; it is the answer "ambiguous".
- Zoomed Preview (column 588 pt, display 1512 x 982; `data/eval6.txt`): capture holds the column at rest for 0 % (lens 240 and 320), 11 % (400), 66 % (480), 92 % (600), 100 % (800); wide: 0, 10, 27, 78, 100, 100 %. A lens narrower than about 0.62 of the column cannot see its far edge: the capture must grow (the probe, 5.4).
- Page 1 (title, wide abstract above the columns) and the table pages 3 5 9 13 have the same shape with lower exact rates, because the column under a lens in a wide-abstract band is the abstract (580 pt), which a 320 pt lens's capture cannot hold (`data/sim1.txt`).
- **Real vs simulated cut captures** (`data/eval2.txt`): 10 real renders; every one agrees with the simulation to 0.5 pt, including the unknown-edge flag (p10B: left edge = capture edge 90 pt, true 72). Across the gutter (p10C), across both columns (p10D), over a full-width table (p3T), over a diagram (p3F), over a listing page (p9A): `none` in the render and in the simulation.
- **film3's Preview take** (lens 770,382,600,270 on the right column 777.5..1365.5; display 1512 x 982): capture at rest x 552..1512 holds the column; Fit to Column would move the lens +7.5 pt on the left, -4.5 pt on the right, before the pad.

### 1.3 What is claimed where there is no column

Use-case bench (`data/eval4.txt`): chat 1 of 5 scenes claims a column (the long Discord message, 2 blocks, 4 lines, ragged), documents/UI 1 of 11 (the 3-column magazine: correct), games 0 of 8, code/terminal/docs 0 of 12, slides/subtitles 0 of 9, paper scenes 5 of 7 (the two CJK scenes read one block per line: no multi-line evidence, so no column). One false claim in 25 non-paper scenes; none in games; no claim on subtitles.

Sensitivity (`data/eval7.txt`): body columns found stay 23 to 24 of 26 for tol 3..10, split 16..40, support 3..6, min lines 1..3; claims on the use-case bench move 5..9 of 52 with the support (3 at support 6, 9 at support 3). Constants were set before looking (6, 24, 2, 4) and not tuned to these data.

### 1.4 Latency

Swift port timed with `swiftc -O` (`probe/swift/ColumnFitProbe.swift`, Apple Silicon): `columns` 4.2 µs (12 blocks), 12.3 µs (60), 31.7 µs (200), 161 µs (1000); the per-frame nearest-target lookup 0.02 µs. A frame is 16.7 ms (8.3 ms at 120 Hz): the geometry costs under 0.1 % of it. What costs is applying a frame (a window-server round trip, the reason move is not live) and the read: a lens-sized document read measured 320 ms (Docs service) and 586 ms (OCR, 21 blocks) in `cut-out/p10A.err`. So: **precompute on every snapshot (12 µs), look up per frame (nanoseconds), never read during a drag.**

### 1.5 How sticky is a snap

Share of one axis within the 8 pt reach of a target (`data/eval5.txt`): x, column edges: 10.8 to 18.3 % on paper pages (3 columns a page counting the wide box), 5.0 to 6.2 % on the Preview shot (2 columns); y, paragraph edges (blocks of 2 or more lines): 37.0 % (min 28.9, max 44.1). That is the reason for deciding 3.

## 2. Target behaviour

**Snap (on by default, setting `lensSnap`).** The lens's left edge pulls to a column's left edge, its right edge to a column's right edge (left to left, right to right), pad included (6 pt), within a reach of 8 pt (enter), left again beyond 12 pt (hysteresis, so a guide does not flicker). The closer of the two edges wins; the other follows. ⌘ held: no snapping at all, no guide, no haptic.
- Resize (corner drag): the right edge is pulled live in `mouseDragged` (where `LiveSnap` shows it: instant, or a taper with a dwell capture, section 16 item 16); the guide shows; the haptic is `NSAlignmentFeedbackFilter` (events exist here).
- Move (drag by the ring or the pill): the lens moves with the pointer, free. When an edge is within reach, the **guide** (a 1 pt line, accent colour, at the column's edge, along the column's height) appears and `NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)` fires once, on entering. On release the lens glides to the aligned position (at most 8 pt, 120 ms ease-out; at once under Reduce Motion). Without a Force Touch trackpad the haptic does nothing; the guide is the signal.
- No column known (chat, game, nothing read yet): no guide, no pull. Nothing changes from today.

**Fit to Column.** Width becomes the column's, height and top stay: new x range = `column.left - pad ... column.right + pad`, clamped to the lens's display (and its window, for a window lens). Reached by: the lens menu row; double-click on the ring; VoiceOver custom action; an optional shortcut action `fitLens` (unassigned, section 8). One undo step: the old rect is kept until the next drag, resize or close; menu row and a second double-click say "Undo Fit". The pill flashes "Fitted to column" (1.5 s). No column under the lens: the menu row is disabled with a tooltip; a double-click flashes "No column here" (never silent).
Edge unknown (the capture cuts the column): **probe** (5.4), then fit; the pill shows the busy state meanwhile; if the column runs off the display, the lens takes the display edge and the pill says "The column runs off the screen".

**Auto Fit (per lens, off by default; setting `lensAutoFit` only chooses the default of new lenses).** After a read settles, if the column under the lens is cut by the lens's left or right edge, the lens grows to the column once, with a short spring. It never shrinks, never moves while content scrolls or the user drags, acts at most once per settle, stays inside the display and window, and a manual resize turns it off for that lens (the pill says "Auto Fit off" once). State machine in section 7.

What a fit does not do: change the lens's height or top; follow a column that scrolls sideways; invent a column from one-line blocks.

## 3. Geometry source (the lead's question)

| source | coordinates | latency | covers | use |
|---|---|---|---|---|
| `columns` in the newest snapshot (new field, 5.1) | capture-local points + `snapshot.origin` = global Quartz | 0: main-actor read of `lastSnapshot` (`RegionSession.swift:688`), 12 µs to build in `emit` | the capture: lens ± 30 % (rest) or ± 40 % (wide) per side, 80..240 / 160..320 pt floors and caps (`Overscan.swift:17`) | snap targets, Fit, Auto Fit evidence. Primary. |
| the overscan itself | the same | the same | the same | what makes a column visible at all (1.2) |
| a probe read: capture = `Overscan.band` (display width x lens band) for one read | same snapshot path | one read: 0.3 to 0.6 s warm (document read 320 ms, OCR 586 ms on a 480 x 410 capture; a 1512 x 600 band is about 3x the area: an estimate of 1.5 s, not measured) | the whole display width at the lens's rows | only when an edge is unknown, only on Fit / Auto Fit, never during a drag |
| `texts` / `OverlayBlock.frame` | | | | **not used**: patch rects with spare width; second flow pieces missing |

Vertical scrolling does not move a column's x edges, so a snapshot's `columns` stay valid under a scroll; a zoom, a window resize or a sideways scroll changes them and the next snapshot replaces them. A snapshot that does not hold the lens, or is older than the last motion of the *content* (`LensFit.contentMovedAt`: the pipeline's motion handler and scroll reports, not the lens's own drags), is not trusted for a fit (the row is disabled for that moment, the double-click says "Reading..."). The design said `lastMotion`; a click on the ring or a drag inside the capture sets that too, and a still page then sends no newer snapshot, so the row would have stayed disabled (found by the live double-click test, section 16).

## 4. Owners (single owner each; nothing duplicated)

| what | owner | file | change |
|---|---|---|---|
| column geometry: `columns`, `under`, `fitted`, snap lookup, Auto Fit decision table | **Core `ColumnFit`**, pure, points | new `Core/Sources/MwoyeoCore/ColumnFit.swift` | new. `ColumnEdge.right(of:among:)` (`BlockLayout.swift:191`) stays: it answers "how far may this translation spill", a per-block question with another rule (overlap 0.5 of the narrower, furthest right). A shared-fixture test pins that both agree on a paper page. |
| a capture edge cuts a line | `CaptureEdge` (`BlockLayout.swift:289`) | same file | add `touchesSide(_ edge:, in bounds:)` with the same 4 px tolerance (2 pt at 2x; the simulation used 2.5 pt) |
| capture for a probe | `Overscan` (`Overscan.swift`) | same file | add `static func band(around lens:, display:) -> CGRect` (display-wide, vertical margins as at rest, 2 pt grid); the session uses it as the wanted rect while `probing`, through the existing `.resize` plan |
| columns in the snapshot | `RegionPipeline.emit` (`:1717`) | App/Pipeline/RegionPipeline.swift | one line: `ColumnFit.columns(blocks.map { (core: lineUnion($0) / s, lines: $0.lines.count) })` (`lineUnion` is the `core` the `drawn` list already builds at `:1730`); new field `OverlaySnapshot.columns: [ColumnFit.Column]` (capture-local points) and the capture rect already known by `origin` + size. Uses **all** `blocks`, cores (union of lines), never `rect`. |
| snap targets during a drag, state of the guide, the settle rect | `RegionSession` (`lensMoved` `:945`, `lensResized` `:978`, `lensDropped` `:986`) | App/Model/RegionSession.swift | session caches `columnsGlobal` per snapshot version; asks `ColumnFit.snap`; tells the chrome and the panel |
| the lens frame and its animation | `RegionFrameWindow` (`setRegion` `:72`, `FrameChromeView.mouseDown` `:471`, `followMove` `:493`, `mouseDragged` `:521`) | App/Overlay/RegionFrameWindow.swift | double-click in `mouseDown` (`event.clickCount == 2`, zone `.move`, not the pill, not the corner); live snap of the right edge in `mouseDragged`; the display-link animation (`animate(to:)`) that calls the existing `onResize`/`onMove` per frame and `onCommit` at the end, so the capture and the panel follow exactly as in a manual resize |
| the guide line | `OverlayPanel` | App/Overlay/OverlayPanel.swift | the panel already covers the lens's whole display, ignores the mouse and sits below the lens window (`.statusBar` vs `+1`): the guide is one layer in its host view (`showGuides`/`hideGuides`). **No new window.** |
| lens-level option | `RegionConfig.autoFit` | App/Model/Settings.swift (`:457`, `init(from:)` `:481`) | `var autoFit = false`, decoded with `decodeIfPresent` like `profilePin`; set from `settings.lensAutoFit` when a lens is made |
| global options | `AppSettings` | Settings.swift `:207`, CodingKeys `:350`, encode `:372`, decode `:424` | `lensSnap = true`, `lensAutoFit = false` |
| menu | `RegionSession.contextMenu` (`:789`) | RegionSession.swift | two rows, 9 |
| haptics | one helper `AlignmentHaptic` (App/Support) | new | `enter()` for the move case; `NSAlignmentFeedbackFilter` for the resize case |
| trace and stats | `Trace`, `stats()` | RegionPipeline, RegionSession | 12 |

game117 edits `RegionFrameWindow.swift` and `RegionSession`: this work starts after it lands (spec).

## 5. The algorithm (`ColumnFit`, points)

### 5.1 `columns(_ blocks: [(core: CGRect, lines: Int)]) -> [Column]`
A `Column` is `left, right, top, bottom, blocks, lines`.
1. Evidence: blocks of at least `minLines = 2` lines. A heading, a caption line, a table cell is one line and says nothing about a column.
2. Stack: sort by left; a block joins the stack while its left is within `tol = 6` pt of the previous one's.
3. Split the stack by right edge where sorted rights jump by more than `split = 24` pt (a full-width paragraph sharing the left edge of a half-width column).
4. A column: `left` = median left, `right` = max right, `top/bottom` = union of its blocks, support = sum of lines, at least `minSupport = 4`.
No indent absorption: tried (stacks inset from a bigger one with the same right edge folded in): page-level spurious columns 11 to 6, but exact fell 80 to 76 % and wrong rose 0 to 2 % at lens 320 on a clipped capture, so it was removed (an indented listing alone in a clipped capture is then taken as the column; without the rule it stays a rival and the answer is `none`).

### 5.2 `under(_ lens: CGRect, in columns) -> Column?`
Candidates touch the lens vertically. Share = (lens width inside the column) / lens width (the lens's, not the column's: a column cut by the capture is narrower than it is; normalising by the column inflated rivals and made 23 % of cut cases `none`). Return the best if its share is at least `need = 0.4` and every rival's share is at most `rival = 0.5` of it; else nil.

### 5.3 Unknown edges
A column edge within 2 pt of a capture edge that is not a display edge is `unknown`: `Column.leftKnown/rightKnown`. A display edge counts as known (the page ends there) except where the display clamps a fit.

### 5.4 Fit and probe
`fitted(lens, column, display, window?, pad = 6, scale)` returns the new lens rect: x range as in section 2, clamped to display ∩ window, aligned to 1/scale pt (0.5 on Retina, 1 on 1x), y and height unchanged; nil when the change is under 2 pt (nothing to do). An unknown edge returns `.probe(side)`: the session sets `probing`, the capture goes to `Overscan.band` for one read, the next snapshot with `version >` the probe's gives known edges (or the display edge), then `fitted` again; one probe per request, never nested.

### 5.5 Pad
Pad = 6 pt (the ring is stroked on the region edge, its grab band is 10 pt wide, and the OCR box is within 1.3 pt of the text on the right): the text stays clear of the ring and of glyphs cut at the edge. Not tuned; the vision verdict in the implementation round may move it. The ±3 pt gate is on `lens.width - 2 * pad` against the true column.

### 5.6 `snap(edges, targets, state) -> Snap?`
Inputs: lens edges (`minX`, `maxX`), `targets` = `[left - pad]` for lefts, `[right + pad]` for rights, the previous `Snap?` (for hysteresis), `bypass: Bool` (⌘). Output: the offset to apply and which target (for the guide), or nil. Reach 8 in, 12 out; the smaller |offset| of the two edges wins, a tie goes to the left edge.

## 6. Drag integration in detail

Move (window-server drag, `RegionFrameWindow.swift:482-487`): `followMove` already runs once per display frame and knows the lens rect (`r`). Add: `session.snapTarget(for: r)` (a lookup) and, on change, `panel.showGuide(...)` + haptic. On `finishDrag` (`:537`) the session settles through the same `animate(to:)` as Fit. ⌘: `NSEvent.modifierFlags.contains(.command)` is read per frame (the class property, not an event). A guide shown at the moment ⌘ goes down is taken down.
Resize (`mouseDragged`, `:521`): the new right edge `startRegion.minX + width` is passed through `snap`; the unsnapped width is what the haptic filter gets as `defaultX`, the snapped one as `alignedX`.
Hit rule for double-click: `mouseDown` already routes the close and mode buttons, the actionable hint and the pill; the remaining `.move` zone is the ring. The first click starts `performDrag` as now; the second arrives with `clickCount == 2`. **Risk to check in the implementation round**: that `clickCount` is 2 after a `performDrag` that ended with no movement (the window server takes the mouse-up). If not, take the double-click from `followMove`'s button-up path (two quick button-ups within `NSEvent.doubleClickInterval`, no movement).
Multiple displays: `onScreen` (`:511`) already keeps a drag on its starting display and the capture cannot span displays, so targets come from the lens's display only; the guide is drawn in that display's `OverlayPanel`; a fit is clamped to `DisplayLayout.display(showing:)`. Retina: all values are points; the 8 pt reach is 16 device pixels on 2x, 8 on 1x (same physical distance on every Mac screen at default scaling).

## 7. Auto Fit state machine

States per lens: `off`, `armed`, `probing(side)`, `fitting`, `held(column)`.

| from | event | guard (one table row each; no other `if`) | action | to |
|---|---|---|---|---|
| `off` | menu toggle on / lens made with `autoFit` | | | `armed` |
| any | menu toggle off | | | `off` |
| `armed` | `settled` (activity becomes `.idle`; `lastMotion` older than 1.0 s; `!dragging`; the lens is on screen and not paused; snapshot `version` newer than the last evaluated) | `under(lens)` exists and `cut(lens, column)`: the column reaches beyond the lens by more than 4 pt on a side where the lens intersects a multi-line block of it | grow target = union(lens, column ± pad) clamped to display ∩ window | `fitting` |
| `armed` | `settled` | same, but the cut side's edge is unknown | `probing` | `probing(side)` |
| `armed` | `settled` | the change is under 6 pt, or the target is wider than 2.0 x the lens, or a side is a display edge already | trace `autofit skipped: <reason>` | `armed` |
| `probing` | next snapshot after the probe | edge known (or the display edge) | as the `fitting` row | `fitting` |
| `probing` | 1.5 s without a snapshot, or a drag / resize / hide / close | | restore the capture (`fitCapture(allowResize: true)`) | `armed` |
| `fitting` | animation done | | `onCommit` (follow window, persist `config.rect`, capture refit); remember `lastFit = (left, right)` | `held` |
| `fitting` | user drag starts | | stop the animation where it is | `armed` |
| `held` | `settled` with `under(lens)` = the same column (left and right within 12 pt of `lastFit`) | | nothing: this is the "at most once per settle, never again for the same column" row | `held` |
| `held` | the lens dropped on another column, or the column's edges moved more than 12 pt | | | `armed` |
| any except `off` | **manual resize** (`lensResized`) | | `config.autoFit = false`, persist, flash "Auto Fit off" once, announce to VoiceOver | `off` |
| any | Fit to Column by hand | | same animation, `lastFit` set, state unchanged | same |

Never shrinks: the grow target is `union`, so a lens wider than its column stays (no row shrinks). Never moves while content scrolls: `lastMotion`. A manual drag (move) does not turn Auto Fit off: it re-arms it on the new place.

## 8. Settings

Two keys, file + schema + strict validation like `lensTabPosition` (`SettingsFile.swift:50` columns, `:90` rows; `Settings.swift:207`, `:350`, `:372`, `:424`; `docs/settings-for-agents.md`; `RestoreDefaultsSheet.swift:49`, `:79`; `SettingsFileChecks.swift:763` defaults table):

| key | kind | default | tab / nature | doc string |
|---|---|---|---|---|
| `lensSnap` | `.bool` | `true` | `(.appearance, .preference)` | "Snap a lens to the text columns under it: while you drag or resize it, a guide shows when an edge is within 8 points of a column's edge, and the lens lands on it when you let go. Hold ⌘ while dragging to place a lens freely." |
| `lensAutoFit` | `.bool` | `false` | `(.appearance, .preference)` | "Lenses you add start with Auto Fit on: after a read settles, a lens that cuts the text of its column at the left or right edge grows to the column once. It never makes a lens smaller. Each lens keeps its own choice, in its menu." |

Settings view: two toggles in `AppearanceSettings > Lens`, after "Name tag position" (`SettingsView.swift:618`): "Snap to text columns" and "Auto Fit new lenses". Per-lens `RegionConfig.autoFit` is not in the file (a lens's own choice stays with the lens, as `profilePin`); agents set the default through `lensAutoFit` and read lens state from the trace.
Shortcut: an optional `HotKeyAction.fitLens` (`HotKeys.swift:45`), no default key, acts on the lens under the pointer, else the one used last. Listed in the gap table (not needed for 1.1.7).
Zero setup stays: the Apple default path is unchanged; snap is on but only draws a guide where a column was found; Auto Fit is off.

## 9. Menu rows and strings (en; ko is the lead's)

Lens menu (`contextMenu`, after the first separator, before "Save Lens Image"; a section of its own):

```
Show Original / Copy Original Text / Copy Translation / Read Aloud
-------------------------------------------------------------
Fit to Column          (title "Undo Fit" while the undo is held)
Auto Fit               (checkmark when on)
-------------------------------------------------------------
Save Lens Image
Profile ...
```
`Fit to Column` is disabled when no column is under the lens, with a tooltip as `Read Aloud` has one. `ActionItem` is the existing row type.

New keys (all 11 languages in `Localizable.xcstrings`, `catalog-coverage.py` → 0 problems):

| key (en) | use |
|---|---|
| `Fit to Column` | menu row; VoiceOver action |
| `Undo Fit` | menu row while the old rect is held |
| `Auto Fit` | menu row |
| `Fitted to column` | pill flash after a fit |
| `No column here` | double-click flash when no column is under the lens |
| `Move the lens over one column of text.` | tooltip of the disabled row |
| `Reading…` | double-click flash while the snapshot is stale |
| `The column runs off the screen` | flash |
| `Auto Fit off` | flash after a manual resize; VoiceOver announcement |
| `Snap to text columns` | Settings toggle |
| `Hold ⌘ while dragging to place a lens freely.` | Settings footer |
| `Auto Fit new lenses` | Settings toggle |


## 10. HIG and convention references

| claim | reference | status |
|---|---|---|
| ⌘ disables alignment guides while moving and resizing | Keynote 6.6 help, shortcut table (https://help.apple.com/keynote/mac/6.6/en.lproj/tanfde4a3e6d.html): "Turn off alignment guides while moving an object: Command-drag"; "Command-drag (while resizing): disables alignment guides" | fetched, quoted |
| the alignment haptic belongs to dragging an object into alignment, paired with a visible guide | `NSHapticFeedbackManager.FeedbackPattern.alignment` (https://developer.apple.com/documentation/appkit/nshapticfeedbackmanager/feedbackpattern): "in response to the alignment of an object the user is dragging around ... scaling an object to fit within specific dimensions, positioning an object at a preferred location" | fetched, quoted; "call only in response to user-initiated actions, ideally with visual feedback" is from the search summary of `perform(_:performanceTime:)` |
| haptic filtering for events | `NSAlignmentFeedbackFilter` (https://developer.apple.com/documentation/appkit/nsalignmentfeedbackfilter), macOS 10.11+: `update(with:)`, `alignmentFeedbackTokenForHorizontalMovement(in:previousX:alignedX:defaultX:)`, `performFeedback`; "if null is returned ... the cursor is moving too fast or the distance is not significant" | fetched. It needs events: usable for resize, not for the window-server move. |
| snap on release with a preview | macOS Sequoia window tiling: a preview while dragging, snap on release, a System Settings switch | secondary sources (MacMost, iBoysoft, Computerworld); not Apple's page |
| double-click an edge or corner expands that side to the screen edge; the green button toggles | MacMost "Mac Basics: Moving And Resizing Windows"; Eclectic Light "Window controls in Big Sur" | secondary |
| Reduce Motion | `Motion.shared.reduced` (`App/Support/Motion.swift`): the animation is a jump; Low Power Mode counts as Reduce Motion there (untrans117, 2026-10-23) | project rule |
| Apple HIG "Windows", "Drag and drop", "Motion" | the pages did not load through the fetch tool (client-rendered); **not verified this round** | open |

## 11. Failure modes

| situation | what happens | evidence |
|---|---|---|
| lens across the gutter or across both columns | `under` is nil: row disabled, double-click flashes, Auto Fit does nothing; snap still pulls to the nearest edge of any column | 1.2: 23 to 39 % of positions (72 % at 560 pt) |
| a figure, a diagram, a full-width table (one-line cells) | no multi-line evidence: no column, no fit | real renders p3T, p3F: none |
| lens over a listing or an indented block alone in the capture | a rival or the wrong left edge (1 to 2 % wrong when indent absorption was on; without it `none`) | 5.1 |
| a chat, a game, a subtitle bar, a terminal | no column, no guide, nothing changes; one false claim in 25 non-paper scenes (the long Discord message) | 1.3 |
| CJK page read one block per line | no column (2 of 7 paper scenes) | 1.3; v2 candidate below |
| ragged text (web, README) | right edge = the longest line seen, a lower bound; Fit may be a little narrow, Auto Fit only widens | not measured against truth; the bench scenes are short |
| capture cuts the column | the edge is unknown; probe, never a guess | 1.2: wrong = 0 % |
| column wider than the display | the display edge wins, flash says so | |
| two displays | targets and guide on the lens's display; a fit is clamped to it | `onScreen`, `DisplayLayout.display(showing:)` |
| Retina / 1x | points; aligned to 1/scale | |
| window lens (anchored) | the fit stays inside the anchor window; `lensDropped` re-follows (offset recomputed) | `RegionSession.swift:986` |
| content scrolls sideways or zooms after the read | snapshot older than `lastMotion`: not trusted; next snapshot replaces it | 3 |
| the capture cannot be read (no permission, off screen, paused) | no snapshot, no columns, no fit | |

## 12. Gates

All new checks show their FAIL-first line (a stub `ColumnFit` that returns no columns / never snaps / never fits) in the implementation round's report.

**Core tests** (`Core/Tests/MwoyeoCoreTests/ColumnFitTests.swift`, plain rects, no OCR):
1. `columns`: a fixture of the 12 multi-line block cores of paper page 10 (committed JSON, our own paper; the page has 35 blocks) gives two columns at the PDF's edges, left ±1, right ±2.5 (measured max 0.6 and 2.0); a stub returns none (FAIL-first).
2. one-line blocks claim nothing (a table's cells, headings, a subtitle bar).
3. a full-width paragraph sharing the left edge splits off by the right gap.
4. `under`: inside, wider than a column, narrower, across the gutter (nil), across both (nil), a cut column does not inflate a rival.
5. unknown edges: a column edge at a capture edge is unknown, at a display edge known (`CaptureEdge.touchesSide`).
6. `fitted`: grow, shrink, pad, display clamp, window clamp, 1/scale alignment, under 2 pt returns nil, unknown returns `.probe`.
7. `snap`: reach 8 in / 12 out (hysteresis), left to left and right to right only, closest wins, tie to left, ⌘ bypass returns nil.
8. Auto Fit table: every row of section 7 as a case (event, guard flags in, state out), including never-shrinks and skipped reasons.
9. `Overscan.band`: display width, vertical margins as at rest, 2 pt grid, inside the display.
10. `ColumnEdge.right(of:among:)` and `ColumnFit.columns` agree on the right edge of the page-10 fixture's body column.

**App checks** (check-logic, `FakeCapture` + a synthetic two-column page drawn with CoreText, so the truth is exact):
- `fit-to-column`: a lens 30 pt narrower than the column on each side; `fitToColumn()`; `lens.width - 2 * pad` equals the drawn column **±3 pt** (measured max 2.1 on paper, 1.2 on Preview; ±2 would flake), height and top unchanged, display clamp, then Undo restores the exact rect; a second fit toggles.
- `fit-none`: a chat page: nothing changes, the menu row is disabled.
- `auto-fit`: settle → the lens grows once → a second settle does nothing → a manual resize turns it off (`config.autoFit == false`, flash) → re-enable → a drag onto the other column re-arms it; the lens never shrinks.
- `fit-probe`: a lens at 0.3 of the column: first snapshot has an unknown edge, the capture is a band, the next snapshot fits.
- `snap-resize`: a resize drag passing the column edge snaps within 8 pt and releases at 12.
- `fit-reduce-motion`: with `Motion.shared.force(true)` the fit is one frame.
- settings: `lensSnap` and `lensAutoFit` round-trip, a wrong type is reported with the path and keeps the value (`SettingsFileChecks` table, `RestoreDefaultsSheet` labels, `catalog-coverage` 0 problems).
- The use-case and paper benches `cmp` equal to `uc-r3.score` / `paper-115.score`: the only pipeline change is a snapshot field and a trace line in `.err`.
- `tools/lens-fit/run-all.sh` re-derives the numbers of section 1 from the bench outputs; its FAIL-first (a stub estimator finds 0 of 26 columns; the truth shifted 10 pt finds 0 of 26) is in `data/failfirst.txt`.

## 13. Three layers

1. **Structural closure.** One owner for "where a column is": `ColumnFit` (Core, pure). The session owns the lens rect transitions, the frame window owns the animation and the gestures, the overlay panel owns the guide, `Overscan` owns capture shapes (one new `band`). No view code computes a column; no second place reads block rects for it.
2. **Recurrence.** The Core tests above plus the paper-page fixture and the `tools/lens-fit` re-derivation (so a reader change that moves block edges shows up as a column error, not as a surprised user). Perceptual axis: the 8 pt reach and the 6 pt pad were chosen against measured OCR edge error (≤ 2.1 pt) and stickiness (5 to 18 %), not by eye; the look of the guide gets one opus vision verdict in the implementation round.
3. **Debuggability.** Trace (stderr, `.err`): `columns: n=2 [72.5..398.0 blocks=6 lines=42 edges=known] ...` per snapshot; `fit: manual|auto column=72.5..398.0 lens=100..400 -> 66.5..404.0 steps=1`; `autofit skipped: <reason>`; `snap: edge=right target=404.0 offset=-3.5`. Stats counters: `lens.fit.manual`, `lens.fit.auto`, `lens.fit.probe`, `lens.fit.skipped.<reason>`, `lens.snap.enter`. The probes become `tools/lens-fit/` (`columns.py`, `eval1..7.py`, `sim1.py`, `eval2.py`, `mkcrops.py`, `run-all.sh`, `README.md`, results file dated), Swift port as the Core implementation's starting point (`probe/swift/ColumnFitProbe.swift`).

## 14. Gap table (target vs today) and what is deferred

| target | today | gap | size |
|---|---|---|---|
| column geometry in Core | `ColumnEdge.right` (per block), `ColumnBreak` (pieces) | new `ColumnFit.swift` | ~150 lines + tests |
| `columns` in the snapshot | `texts` (patch rects, startsParagraph only) | 1 line in `emit` + 1 field + trace | ~15 lines |
| probe band | `Overscan.rect/plan` only | `Overscan.band` + `probing` in `fitCapture` | ~30 lines |
| guide, haptic | none | `OverlayPanel` layer, `AlignmentHaptic` | ~80 lines |
| live snap on resize | corner resize clamps 80 x 40 only | `snap` in `mouseDragged` | ~20 lines |
| settle on release | `finishDrag` commits | `animate(to:)` + snap in `followMove` | ~60 lines |
| double-click, menu rows, VoiceOver action | none | `mouseDown`, `contextMenu`, `LensAccessElement` | ~50 lines |
| Auto Fit state | none | session state + table + `RegionConfig.autoFit` | ~90 lines |
| settings rows, schema, strings | none | 2 keys, 12 strings x 11 languages | ~60 lines + strings |
| shortcut `fitLens` | none | `HotKeyAction` case, handler | deferred (not needed to ship) |
| fit height / paragraph snap | none | **dropped for 1.1.7**: y targets hold 37 % of positions; a reading window's height is the user's choice | revisit with line-gap targets only if asked |
| left-edge resize | only the bottom-right corner resizes | out of scope; Fit moves the left edge | |
| CJK one-line-per-block pages | no column | v2: stacks of 3 or more blocks with at least 2 equal right edges (tol 2.5); not tested beyond two scenes | needs a line-level snapshot field |
| ragged right edge | lower bound | v2: a `sharp` flag from per-line flushness (needs line rects in the snapshot) | |
| a real lens drag test of "snap on release" feel | not done (screen is shared; product code is out of this round) | implementation round: one drag A/B on a live lens, vision verdict on the guide | |

Open questions for the lead: (1) the ±3 pt tolerance instead of ±2 (evidence 1.1); (2) whether `Fit to Column` may also be the default double-click on the pill (it is not proposed: the pill's click targets exist); (3) the optional `fitLens` shortcut.

## 15. Reproduce

`tools/lens-fit/probe/run-all.sh` writes `data/eval1.txt` (edge accuracy against the PDF), `eval1b.txt` (width), `eval2.txt` (real cut captures), `eval3.txt` (Preview shots and the film3 take), `eval4.txt` (use-case scenes), `eval5.txt` (stickiness), `eval6.txt` (zoomed Preview containment), `eval7.txt` (constants), `sim1.txt` (lens positions). Renders: `probe/run-pv.sh`, `probe/run-cut.sh` (headless, sandbox off, build `dd-d14main`, pool id `pool4`); inputs `pv-pages/`, `cut-pages/` (made by `probe/mkcrops.py`), outputs `pv-out/`, `cut-out/`.

## 16. As built (round fit117impl, 2026-10-22)

Everything of sections 2 to 9 is in; deferred as the design says: fit height, paragraph snap, CJK line-block pages, ragged right edges, the `fitLens` shortcut, left-edge resize.

| what | owner as built |
|---|---|
| columns, `under`, `fitted`, snap targets and `snap`, unknown edges (`marked`) | `Core/Sources/MwoyeoCore/ColumnFit.swift`, pure; the estimator is `probe/columns.py`, ported (median of an even count is the mean of the two middle lefts, as Python's) |
| Auto Fit's table (`step`, `evaluate`) | `Core/.../AutoFit.swift`: the states of section 7 and the events of its rows; every row is a test |
| the ring's double-click, the spring | `Core/.../LensGesture.swift`: `DoubleTap` (two releases that did not move within the system's double-click interval and 4 pt), `FitMotion` (a critically damped spring: 0.382 s a fit (response 0.30 s, the motion contract's, addendum A9), 0.25 s an Auto Fit, 0.12 s a settle, all from `LensMotion`; 0.3 % short of the target at its end, the last frame is the target) |
| probe capture | `Overscan.band`, `Overscan.plan(band:)`; `CaptureEdge.touchesSide` |
| columns in the snapshot | `RegionPipeline.emit`: `OverlaySnapshot.columns` (capture-local points) and `captureSize`; trace `columns: n=2 [72..398 blocks=6 lines=42]` |
| session | `RegionSession` extension (end of the file) over `LensFit` (`App/Model/LensFit.swift`): the snapshot's columns to screen points, the pull, the settle, Fit / Undo Fit, the probe, Auto Fit's carrying-out of an `AutoFit` action; hooks in `received`, `setActivity`, `lensMoved`, `lensResized`, `lensDropped`, `fitCapture`, `contextMenu`, `wireChrome` |
| gestures, animation | `RegionFrameWindow`: the tap on the ring in `followMove`'s release path, the live right-edge snap and the filtered haptic in `mouseDragged`, `animate(to:)` on a display link calling `onResize`/`onMove` per frame, VoiceOver's custom action |
| guide | `OverlayPanel`: a 1 pt accent-coloured layer-backed view above the clipped host view (the host's mask is the lens, the guide lies outside it); 0.1 s fade, none under Reduce Motion |
| tick | `AlignmentHaptic` |
| settings | `lensSnap`, `lensAutoFit` (`Settings.swift`, `SettingsFile.swift`, `RestoreDefaultsSheet.swift`, `RestorePlanChecks.swift`, `SettingsView.swift`); `RegionConfig.autoFit` per lens, set from `lensAutoFit` where a lens is made (`AppModel`) |

Decisions where the design was silent or the code said otherwise:

1. **Double-click detection.** `clickCount` is not used (the window server takes the second mouse-up of a `performDrag`): a release that did not move on the ring, twice within `NSEvent.doubleClickInterval`. A press that goes nowhere is not reported to the session as a move (`followMove` compares with `startRegion`): before, any click on the ring ran `lensMoved` once. A live test with posted mouse events (`--capture-ui <dir> lens-fit-click`, needs the accessibility grant) passes: the second click fits, the first does not.
2. **Freshness**: section 3, above.
3. **Unknown edge tolerance** is `ColumnFit.edgeTolerance` = 2.5 pt (the simulated value, `touchesSide(tolerance:)`), not the lines' 4 px.
4. **The fit is undoable after an Auto Fit too**: the menu row says Undo Fit; an unwanted growth is one click from gone.
5. **Auto Fit with one cut side at the bound** (a window lens at its window's edge) grows the other side; `skip(atEdge)` is when no cut side can move. `Skip.unknown`: a probe whose snapshot still has an unknown edge ends (never nested).
6. **Probe wait** is `LensFit.probeTimeout`, see decision 13 (the design's 1.5 s was an estimate; the lapse restores the capture and, for Fit to Column, flashes "Reading...").
7. **Snapshots out of order**: the session ignores a snapshot older than the newest (snapshots hop to the main actor one task each).
8. **A manual resize turns Auto Fit off; a move re-arms it** (`dragged`); the first frame of a hand's move or resize also drops the held undo, and ends a probe.
9. **VoiceOver's action** is added where the lens has a session (`onFit` set), after Show Original; its name is Undo Fit while the old rect is held.
10. **The tick on a move** plays once as an edge enters its reach (`lens.snap.enter` counts it); on a resize the system's `NSAlignmentFeedbackFilter` decides. No trackpad, no tick: the guide is the signal.

11. **An edge is known against what was read, not against the capture** (film4 F4 and F5, found live on the first build, 2026-10-22). The capture grows before its read does (`captureResized` emits at once, with the old blocks, which stop where the old read did), so a snapshot whose capture was wide but whose blocks were not re-read marked the column's cut edge *known*: the snap aimed at it (the right target stood 44 pt inside the column, no guide at the true edge) and the probe took that snapshot for its answer. The pipeline now keeps `readRect`, the part of the capture (capture-local points) the blocks were read from: the whole capture after a pass, moved with the capture and cut by it afterwards; `OverlaySnapshot.read` ships it; `ColumnFit.marked` and the probe's arrival test use it. The snap's targets are the known edges only (`Targets(columns:)`).
12. **A resize reads the band once, at its start (scout).** The capture does not follow a corner drag (`fitCapture(allowResize: false)`), so the right edge of a column 133 pt beyond the lens is never in what is read while the hand drags towards it, and with decision 11 the snap would have no target there. The first frame of a hand's resize, with a column near the lens whose right edge is unknown (`ColumnFit.unknownEdges`) and Snap on, makes the capture the band for one read (`Probe.Reason.scout`: no pill, no fit, no timeout); the band is the rect taken at that frame and kept while the lens grows (`Overscan.plan(band: CGRect?)`), and the drop ends it. This is the one read the design said never to start during a drag; the evidence says the snap needs it. Counted as `lens.fit.scout`.
13. **The probe waits longer** (`LensFit.probeTimeout`, 10 s; the design said 1.5 s, the first build 3 s): a band is three times a lens's area, and on a Mac with the Neural Engine busy one read took 8 s (film4 t2r-fit). The pill is busy meanwhile and a hand on the lens ends it.
14. **One table for the numbers of motion** (`LensMotion`, Core; addendum A3): fit, Auto Fit, settle, the guide's fade and opacity. `FitMotion` is the curve. The motion contract's values drop in as an edit of the table: `fit` is the contract's spring since addendum A9 (response 0.30 s, settles in 0.382 s; it was the design's 0.25 s); `autoFit` is its `calm` (response 0.50 s, 0.637 s) and `settle` its `quick` (response 2π/30 s, 0.267 s) since round skinland117 (2026-10-23, addendum A1; they were 0.25 s and 0.12 s). `LensTarget.glide`, the picker spotlight's hop, is `LensMotion.settle`.
15. **Feel gates** (addendum A2): `LensFeelTests` drives the session's own functions with synthetic paths and a fake clock: `ColumnFit.snap` with its previous snap and `ColumnFit.change` (the guide and the tick are the session's reading of it), `FitMotion` at 60 and 120 Hz, and `AutoFit.SettleGate` (the "once per settle, never while the page scrolls or a hand is on the lens" rule the session asks before `step` sees a `settled`).

16. **Where a resize shows its right edge while the guide is up: two feels, `LiveSnap` (Core), chosen in playback** (round snap117, 2026-10-23, addenda A1 and A2). The guide, the tick and the hysteresis are as designed (from 8 pt, kept to 12; `ColumnFit.snap` and the session's `evaluateSnap`). What stood here until 2026-10-23 was fit117's decision (feel, addendum A2, measured on the first live take, 10-22: the lens's right edge jumped 8.5 pt in the frame the pull took hold and 12.0 pt in the frame it let go, against the user's "never jumps under the hand"): the edge follows `ColumnFit.livePull`, on the target while the hand is within 4 pt of it (the plateau), tapering linearly to nothing at 12 pt, from the nearest target taken from 12 pt (`snap`'s `entry`), so it moves 0 to 1.5 pt for each point the hand moves; a resize let go while the guide is up glides the rest of the way onto the edge (`settleResized`, `LensMotion.settle`). The skinland117 take (48.50 to 50.10 s) showed what that leaves: a hand that holds 7 pt off has the guide up and the edge 4.5 pt off it for as long as it holds, and the edge lands only after the release (4.0 pt in 272 ms). The motion contract's 3.1 (written before that take) wants the capture instant. So both are built, `LiveSnap.Feel`, `MWOYEO_SNAP=instant|dwell` (not in the App Store build; `LiveSnap.standard` is the one a lens has):
    - `instant` (3.1): the edge is on the target in the very frame the guide comes up and under the hand again in the very frame it goes down (the corner steps up to 8 pt on the capture and 12 pt on the release; the skin's right edge is a spring behind it, so the ring's middle steps about half of that: `LensFeelTests.theRingTakesTheInstantJumpInTheSkinAndTheDwellGlideSmoothly`). A resize let go lands where it shows; nothing glides after the mouse-up.
    - `dwell` (A1): decision 16 as built while the hand moves; when it holds still (`LiveSnap.Dwell`: under 1.5 pt of motion for 0.15 s; a held hand sends no `mouseDragged`, so the lens window asks the session again each display frame of a resize) with the guide up, the edge glides onto the target during the drag (`LensMotion.settle`, from where it is), and goes back to the taper, from where it is, when the hand moves again. A let go while it still moves glides the rest as before.
    The tests drive both on a fake clock (`LensFeelTests`, `Drag`): decision 16's jump tests apply to `dwell`; `instant` has its own (the edge is the hand's or the target's and never between; the first frame of a second drag within reach is captured). The app's `fit-checks` run both through the session's own `snapResized`/`settleResized`. `tools/lens-fit/snap-capture.py` reads a take (`MWOYEO_TRACE=1`: `snap: live hand= edge= guide= capturing=` per frame) and prints, per drag, the frame the hand came within 8 pt, the frame the edge was on the target, the per-frame steps and what moved after the mouse-up.

What was run (numbers in the round's report, `/tmp/r117/fit117-REPORT.md`): Core tests (`ColumnFitTests`, `AutoFitTests`, `LensGestureTests`; FAIL-first on a stub, 22 guard mutants), the `fit-checks` of `check-logic` (46 lines; FAIL-first on a build whose `ColumnFit` and `AutoFit` are stubs: 23 of the first 43 lines FAILED), the live double-click, the paper and use-case benches against a same-day base, `lens-fit-shots` for the vision verdict. The app checks drive geometry (block cores at the true column edges plus the measured 1.3 pt right-edge bias, cut to the capture), not the reader: what the reader makes of a drawn page is the paper bench's (`columns:` in each `.err`) and `tools/lens-fit`'s.

| gap row of section 14 | now |
|---|---|
| column geometry in Core, `columns` in the snapshot, probe band | done |
| guide, haptic, live snap on resize, settle on release | done (the move's pull is a guide and a settle, as designed; a resize's edge is `LiveSnap`'s, item 16) |
| double-click, menu rows, VoiceOver action | done |
| Auto Fit state | done |
| settings rows, schema, strings | done (12 strings x 11 languages) |
| `fitLens` shortcut, fit height / paragraph snap, left-edge resize, CJK and ragged edges | not done, as the design defers them |
| a real drag A/B of "snap on release" feel | the guide and the fit are captured (`lens-fit-shots`) and a live take (`/tmp/r117/fit117-try/a2.mp4`); the drag's feel is the lead's to try |

## 17. The ring's outline: the membrane on the lens (round skinland117, 2026-10-23)

The motion contract's organic outline (section 9, the user's direction: "like an organism, a scene from an SF film"; the pick is direction 2, Membrane) is `LensSkin` in Core (round skin117): one spring per edge, so each straight edge bows by how far it is ahead of or behind the rigid frame, and settles on it. Round skinland117 wires it. The frame (the window, the capture, the 10 pt hit band, the pill) stays rigid and keeps its own springs; only the outline deforms, and text never does.

| what | owner |
|---|---|
| the bows, the caps (4 out, 8 in, 4 under the hand), the moments' rows (`LensSkin.choreography`), the path (4 arcs and 4 cubics, G1) | `Core/.../LensSkin.swift`, pure; `LensSkinTests` drive it on a fake clock |
| the lens window's skin: one `LensSkin` stepped on the display-link tick that moves the frame (a hand's resize, an animation, a commit, the tail after them; a move steps it with every edge held) | `FrameChromeView` in `RegionFrameWindow.swift`; `outline()` is the one reading of it |
| the ring and the glow masks | `FrameChromeView.drawOutline`: `outline.path(outset: 1)` in view coordinates, drawn again only when the outline, the region or the style changed (a move changes nothing of it, so the window server keeps its cached raster) |
| the translations' clip | `OverlayPanel`: the same `LensOutline` (`RegionSession.wireChrome`: `panel.outline` pulls `chrome.outline()` on every frame change, `chrome.onOutline` pushes when only the outline changed); a `CAShapeLayer` mask whose path is the outline at `outset: 0`; the ignored regions are cut out of the same shape |
| the picker's spotlight and one-click commit | `PickerView`: the hole and the stroke are `outline.path(outset: 0)` and `path(outset: 1.5)` of a skin stepped on the glide's clock (the hop); the default lens under the pointer is held; on a click `RegionPicker.Result.click` goes to `RegionSession.takeHold` and the new lens takes hold from its first frame (edges 8 pt out, closing, the side nearest the click first) while the dim goes in 0.20 s, the accent stroke in 0.10 s and the pill comes in in 0.20 s |

Which moment is a row, not an if: `FrameChromeView.animate(…moment:)` (the session passes `.fit`, `.undoFit`, `.autoFit`; a release's settle is `.drop`), `mouseDown` on the corner (`.cornerDrag`), `beginHold` (`.commit`), `PickerView.aimAt` (`.pickerHop`). `Trace.mark("skin: <moment> peak=<pt> rest=<ms>")` once when the outline has landed (a moment the next one cuts short, a resize let go as a drop, writes its line with `(cut by <moment>)`); `RegionFrameWindow.stats()` reads the bows and the same line.

What lands the outline exactly: `LensSkin.land()` when the skin is at rest (within 0.05 pt) so the ring is today's rounded rect itself and the display link stops. `RegionFrameWindow.setRegion` (a lens that followed its window, changed display or came up) puts the outline at rest on the frame; `driveRegion` is for the hand and the animations, which own the skin. Reduce Motion: the outline is the rigid ring and the commit's cross-fades are opacity only.

Gap table, contract section 6 and 9.5 against main before this round: spring of the settle 0.12 s → `quick` 0.267 s; Auto Fit 0.25 s → `calm` 0.637 s (tests re-pinned as equalities, `LensFeelTests`); ring `CGPath(roundedRect:)` → the outline; the clip `CALayer` with a continuous corner radius → the outline at `outset: 0` (one corner construction); the picker's rounded rect → the skin; the picker's whole-window 0.20 s fade → dim 0.20 s ease-out, accent 0.10 s linear; the lens's first frame → the commit and the pill's 0.20 s fade. Left as the contract says: the bows during a move (`LensSkin.moveBows`, off until the window-server measurement of section 9.5), the brackets style (rigid), the sweep mask (a rounded rect).

Gates: `LensSkinChecks` (`skin-checks`, and in check-logic): the ring and the clip are one outline 1 pt apart at rest, mid-Fit, after a hold and under Reduce Motion (FAIL-first: a rounded-rect clip is 5 pt off a bowed ring); each moment through the window against its row (Fit, Undo Fit, Auto Fit, the drop; FAIL-first: fit117's 0.12 s settle bows the 7 pt glide 3.18 pt against 1.62, and its 0.25 s Auto Fit is at rest in 183 ms against 562); a lens that was only restored does not take hold; a frame a gesture drives leaves the outline bowed and `setRegion` puts it at rest; the real display link plays a Fit. `PickerChecks`: the spotlight bows over a hop and is the rigid rect at the end, and under Reduce Motion it is the rigid rect; a picker opened over a resting pointer aims at it at once (`PickerView.open()` seeds `pointer` from the mouse location; film defect F22, addendum A2: before it the pointer was known only from a move).
