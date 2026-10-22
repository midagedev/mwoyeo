# Lens shapes: the one-click lens changes shape with the content under the pointer (1.1.7 design and measurement)

Round shapes117, 2026-10-22. Core `LensShape.swift` (pure, new) with its tests, the demo stage, and the seam for `LensTarget` (a new file and a
five-line patch, section 6). Built on the one-click picker of `docs/design/first-lens.md` (`LensTarget`, round oneclick117) and fit117's `ColumnFit`.
Measured on this Mac, Release (`swiftc -O`), on the picker's own reads of 53 pictures (45 non-paper bench scenes, two of which, vertical text and manga balloons, the picker's read finds no blocks in; the 7 paper
pages; the stage; `tools/first-lens/data/shapes/`).

User, in their words (2026-10-22, after the first one-click take): "원클릭 화면에 요소가 하나뿐이다 보니까 인상적이지 않네. 뭔가 다양한 형태의 콘텐츠를
마우스로 훑으면서 렌즈 모양이 바뀌는 걸 만들고 싶은데". This is the release film's hero shot and a product feature: every shape is what a click really places,
and each is the right lens for reading that content.

## 0. Verdict

1. **One pure function and one enum.** `LensShape.choose(blocks:pointer:bounds:held:)` turns the blocks the picker already has into a lens for content that has
   no reading column. `LensShape.Kind` has five cases (`table`, `thread`, `dialog`, `subtitles`, `group`); a new kind of content is a new case with its recogniser
   and its rect in `region(of:)`, nothing else. No new read, no new setting, no new UI string, no telemetry. Geometry only: boxes, line counts, the pointer, the
   bounds. The column rule (`LensTarget.choose`) stays first and unchanged; a pointer over nothing recognisable keeps today's ghost.
2. **Every rect is whole blocks and never cuts one.** 91,642 pointer positions within 40 pt of a block, 53 scenes: 0.00 % of the rects cut a block, 0 reversals
   under +-2 pt jitter with the hold (the same walk with the hold removed: 592,143), 0.37 to 8.0 us per choice, 0 to 45 us to build the map once per picker open.
3. **What it gains.** Target positions (the pointer gets a fitted lens instead of the ghost): chat 27 % -> 95 %, docs/web 20 % -> 87 %, games 0 % -> 79 %,
   code 15 % -> 81 %, papers 50 % -> 99 %, subtitles 0 % -> 91 %, the stage 34 % -> 100 % (column rule alone, then the seam; section 5).
4. **The seam is where it can go wrong, and it did.** A bare `column ?? shape` flickers: 117,177 reversals over the 53 scenes. The column rule alone has 115,951
   of its own (its outer edge and its gutter have no hold; section 6.3). The seam of section 6 (each owner lets go of the pointer only 8 pt beyond where it would
   take it, in both directions, and between two columns) has **0**.
5. **The demo.** `tools/first-lens/stage/index.html`: one 1512 x 945 pt page with ten kinds of content side by side, our own words and drawings only. The
   planned pointer path (`path.json`, 6.5 s, six kinds: heading + lede, article column, chat thread, table, subtitle, game dialog) passes each one cleanly,
   0 frames with a cut; a 720p30 prototype of the outline gliding along it is `/tmp/r117/shapes117/sweep-proto.mp4`.
6. **Open** (section 7): eleven entries (false claims and misses) on the 53 scenes, all mild (a footer or a HUD line taken for a subtitle, an algorithm listing taken for a
   chat, a table missing an off-grid header cell, a chat of one-line bubbles that gets a lens per bubble). None cuts text; none is fixed by a number I could
   not defend on other scenes.

## 1. Owners (one each)

| what | owner | state |
|---|---|---|
| the reading column's rect, the anchor, the budget, the glide | `LensTarget` (oneclick117, hero2 integrates) | unchanged |
| the rect for content that is not a reading column | **`LensShape`** (new, Core, pure) | this round |
| which of the two answers a pointer, and how they hand it over | `LensTarget+Shapes.swift` (the seam) | this round, section 6 |
| the blocks (box + line count) | the picker's one read (`ColumnFit.Block`; `LensShape.Block` has the same two fields) | unchanged |
| the click, the drag, the lens it places | the picker (`target.rect`) | unchanged: a shape is a `Target` with a rect |

## 2. What every kind shares

1. **The anchor.** The block with the best signed distance to the pointer (depth inside, less the distance outside); none farther than `reach` = 40 pt.
   A shape is a function of the anchor block, never of where the pointer is inside it: the outline steps from one content to the next, it does not follow the hand.
2. **The hold** (section 4.1 of first-lens.md, extended). A new anchor must beat the held one by `switchBy` = 8 pt; the held shape is let go only 8 pt beyond
   `reach` from every block it holds, and never while the pointer is inside its outline (the white space between a table's cells is still the table). A held
   anchor that gives no shape (a lone label) comes second: the label is as good as empty space and the held shape stays over it.
3. **Whole blocks.** Every rect is the union of its member blocks plus `pad` = 6 pt on every side (the same pad as `ColumnFit`'s), inside `bounds`. `settled`
   then moves any edge that would cut another block off it (the side that keeps the most area; a block that overlaps the members is taken in whole); a rect
   that still cannot hold its members whole is nil. At least 80 x 40 pt (the lens's resize floor), on the pixel grid. A block is cut when an edge reaches
   into it by more than `cutSlack` = 2 pt (the measure of the gates; a box is a little wider than its glyphs).
4. **The height budget** is `LensTarget`'s: 560 x 320 over the shape's width, within 160 and 560 pt. A group taller than that is windowed as a column is:
   from the anchor's top down over whole blocks (a block that crosses the budget stays when half of it fits), then up while short of 0.6 of it.
5. **Order and determinism.** Kinds are tried in `allCases` order: the first that recognises the content wins (strong evidence first, `group` last).
   A pure function of (blocks, pointer, bounds, held); the order of the read does not matter (a test reverses it).
6. **Lines.** The read gives a block's box and its line count; lines are spread evenly over the box at a pitch of 1.35 x the glyph height (`Block.em`).
7. **Content is what lies in `bounds`** (shapestab, section 13). The read is of the display; the hovered window's content is `bounds`. A block outside it (the title bar,
   the menu bar, the window beside) is not content: `choose` builds the recognisers' map from the blocks that overlap `bounds` by more than `cutSlack` both ways
   (`Map.within`, the same map when all do) and gives the answer's anchor in the read's own indices.

## 3. The kinds

### 3.1 Content -> kind

| content | kind | what a click places | why it is the right lens |
|---|---|---|---|
| prose column paragraph | (`LensTarget`, today) | the column's width, whole paragraphs from the one under the pointer | a reader reads down a column |
| chat thread (bubbles, or names over messages) | `thread` | the pane's width, whole messages, with their names and times | a reply makes sense only beside the message it answers; the pane is the unit |
| table (cells in lanes, three rows or more) | `table` | every lane, whole rows, its title | a row's cells translate together; a column of numbers alone reads as nothing |
| game / visual-novel dialog box | `dialog` | the speaker's name and the lines, widened to leave room for the text still being typed | the box is set before the text finishes; a lens fitted to the first words clips the rest |
| subtitle band over a picture | `subtitles` | a band centred on the lines, wider and one line taller | the next subtitle arrives where this one stands; it must fit without a new click |
| list with its title, code block with its lead-in sentence, a sidebar note or card, a popup, a heading with its lede, a figure's caption (two lines or more) | `group` | the blocks that stand together apart from the rest, whole | the group is the thing the author set apart |
| CJK page whose read is one block per line | `group` (or the column rule where it finds a column) | the stacked lines that belong together | a block per line is not a reading unit; the stack is |
| a lone label, a one-line caption, a button, empty space | nothing: today's ghost | the default box, byte for byte | there is nothing to fit |

### 3.2 How each is recognised (geometry only) and what rect it gives

| kind | recognised from | rect | notes |
|---|---|---|---|
| `table` | The anchor's line and the lines beside it on its row (middles within 0.4 of the shorter height), each at least 1.5 ems from the next, are the lanes; the anchor's lane followed down and up within 3 ems gives the rows; another lane stays when it has a cell on 0.6 of them and at least 0.6 of its lines down them stand on a row (a text column beside the table has its own rhythm and meets a row now and then). At least 3 rows with a cell in another lane, the one-line cells alike in height down a lane (within 1.7 of the median; a merged block's lines have no height of their own), at least 0.6 of the blocks one line. A title line of the same group just above, within the table's width, is a member; a pointer on the title aims at the table. | the lanes x the rows, with the title | a page or a chat beside the table meets its rows now and then, which is why a lane needs 0.6 of them, not all |
| `thread` | A message is a block of 4 lines or fewer that is not a name or a time (one line, 4 ems wide at most, or 0.8 of the messages' size). The message under the pointer (or nearest the name or time under it) keeps to an edge of the pane with others. The messages of one thread are set alike (glyph height within 1.7 of the anchor's: a heading is no message). Two-sided: the other side's messages keep to the opposite edge, two messages or more on each side (bubbles). One-sided: three messages of two lines or more keep to its left edge with ragged right edges (a name over a message). The thread is the lanes' messages one after another within 4.5 ems, ended by a gap of twice the usual one; its pane holds nothing else but names and times. | the pane: the messages with their names and times, windowed by the budget | both sides are tried, nearest first |
| `dialog` | A name (one line, 8 ems at most, no taller than 1.25 x the body) at the body's left edge or a little inside it, within 0.85 em above a body of one to four lines set large (16 pt or more) and 10 ems wide or more; nothing under the body within an em. The name is the nearest block that pairs, not the nearest block above. A read that merged the name into the body's block (one block, its first line `head` the name) is split at that line and judged the same. A doc's heading is a paragraph's space (0.94 to 1.26 ems) above its text, a speaker's name 0.58 to 0.74. | the name and the body, widened to 28 ems from the body's left edge (no wider than the mirror of its left margin in the bounds: the box is centred) and three body lines tall | the room is for the line being typed out |
| `subtitles` | One to three lines in blocks stacked within 0.8 em, middles within an em, set large (16 pt or more), in the lower half of the bounds; no text of like size (0.6 or more of it) within 3 ems of them. A player's controls and a menu's small print may be near; a page's lone line stands a paragraph's space from the next, a subtitle on its picture 6 ems or more. | centred on the lines, 2 ems wider each side (at least 18 ems wide), two lines tall from the last line up | |
| `group` | `Map.group`: blocks of one connected part, two stacked with their x ranges overlapping and the gap at most 1.2 ems (of the larger), or on one row with at most 1.5 ems between; two lines or more in all. | the group's union, windowed by the budget | the fallback: whatever stands together |

## 4. Target and gap

| target | today (first-lens.md 4.5) | gap | size |
|---|---|---|---|
| chat, game, subtitles, table, code, list, sidebar, popup under the pointer get a fitted lens | the 560 x 320 ghost | `LensShape` + the seam | Core 586 lines (521 at shapes117, 65 for section 13) + 327 + 206 test lines + 384 of fixtures; seam 39 lines + 5 patch lines |
| no flicker between the owners | (one owner) | the seam's hold, both ways, and between columns | in the seam |
| a stage that shows it | one element on screen | `tools/first-lens/stage/` | page 174 lines |

## 5. Measurements

Probe: `tools/first-lens/shapes/main.swift` (`measure.sh` runs it), blocks from `tools/first-lens/data/shapes/` (the picker's vn read of each picture: the lines
path with `ParagraphGrouper`, screen points = bench px / 2). A position counts when a block is within 40 pt of it ("near"; grid 10 pt). **Target%** is the
share of near positions that get a lens instead of the ghost. Reversals: the pointer walks every 10 pt row and column at 1 pt steps with the held choice; at
every change of choice 200 jittered positions within +-2 pt are chosen in turn; every A, B, A counts. "no hold" is the same walk with the held choice dropped (the control).

### 5.1 Per category (weighted by near positions)

| category | scenes | near positions | target %, column rule alone | target %, with the seam | column | table | thread | dialog | subtitles | group |
|---|---|---|---|---|---|---|---|---|---|---|
| chat | 5 | 8930 | 27 | 95 | 27 | 0 | 58 | 0 | 0 | 10 |
| docs-web | 11 | 11813 | 20 | 87 | 20 | 18 | 0 | 0 | 3 | 47 |
| games | 8 | 11162 | 0 | 79 | 0 | 12 | 0 | 21 | 22 | 23 |
| code | 12 | 26533 | 15 | 81 | 15 | 3 | 3 | 0 | 0 | 59 |
| papers | 7 | 15280 | 50 | 99 | 50 | 0 | 0 | 0 | 0 | 48 |
| subtitles | 9 | 9963 | 0 | 91 | 0 | 0 | 0 | 0 | 89 | 2 |
| stage | 1 | 7961 | 34 | 100 | 34 | 14 | 13 | 7 | 7 | 24 |
| **all** | 53 | 91642 | 21 | 88 | | | | | | |

All 53 scenes: 91,642 near positions; cut 0.00 %; reversals with the seam 0, with the bare chain `column ?? shape` 117,177, with the column rule alone 115,951,
LensShape alone 0 (without the hold 592,143 under the `nohold` mutant). Cost, `swiftc -O`, one choice: 0.37 to 8.0 us (the stage, 46 blocks, is the largest);
the map, once per picker open: 0 to 45 us (shapes) and 0 to 9 us (columns).

### 5.2 Per scene (`data/shapes/seam.txt`)

Kinds are the share of near positions by the kind that answered (column = the column rule). rev = reversals with the hold, then without.

| scene | category | blocks | near | target % (column alone -> seam) | column | table | thread | dialog | subs | group | cut % | rev (hold / no hold) | us |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| c01-slack-en | chat | 7 | 2237 | 24 -> 97 | 24 | 0 | 72 | 0 | 0 | 0 | 0.0 | 0 / 5300 | 2.41 |
| c02-kakao-ko | chat | 15 | 1712 | 0 -> 100 | 0 | 0 | 100 | 0 | 0 | 0 | 0.0 | 0 / 4980 | 4.98 |
| c03-line-mixed | chat | 13 | 1841 | 0 -> 100 | 0 | 0 | 100 | 0 | 0 | 0 | 0.0 | 0 / 4699 | 4.50 |
| c04-discord-longmsg-en | chat | 4 | 1863 | 99 -> 100 | 99 | 0 | 1 | 0 | 0 | 0 | 0.0 | 0 / 1296 | 0.34 |
| c05-wechat-zh | chat | 10 | 1277 | 0 -> 67 | 0 | 0 | 0 | 0 | 0 | 67 | 0.0 | 0 / 5451 | 3.63 |
| d01-spec-table-en | docs-web | 12 | 1160 | 0 -> 92 | 0 | 66 | 0 | 0 | 0 | 27 | 0.0 | 0 / 3239 | 5.56 |
| d02-timetable-ja | docs-web | 18 | 1181 | 0 -> 69 | 0 | 69 | 0 | 0 | 0 | 0 | 0.0 | 0 / 3714 | 4.77 |
| d03-magazine-3col-en | docs-web | 8 | 2325 | 81 -> 100 | 81 | 0 | 0 | 0 | 0 | 19 | 0.0 | 0 / 2294 | 1.14 |
| d04-lists-ko | docs-web | 8 | 1025 | 0 -> 100 | 0 | 0 | 0 | 0 | 0 | 100 | 0.0 | 0 / 484 | 3.99 |
| d05-settings-ja | docs-web | 10 | 997 | 0 -> 52 | 0 | 52 | 0 | 0 | 0 | 0 | 0.0 | 0 / 2015 | 3.09 |
| d06-webpage-en | docs-web | 6 | 2150 | 20 -> 87 | 20 | 0 | 0 | 0 | 0 | 67 | 0.0 | 0 / 4978 | 3.18 |
| d07-slide-zh | docs-web | 5 | 1736 | 0 -> 100 | 0 | 0 | 0 | 0 | 20 | 80 | 0.0 | 0 / 5935 | 3.08 |
| d08-tategaki-ja | docs-web | 0 | 0 | 0 -> 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.0 | 0 / 0 | 0.00 |
| d09-manga-balloons-ja | docs-web | 0 | 0 | 0 -> 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.0 | 0 / 0 | 0.00 |
| d10-terminal-en | docs-web | 3 | 303 | 0 -> 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.0 | 0 / 0 | 1.74 |
| d11-code-ko-comments | docs-web | 3 | 936 | 0 -> 96 | 0 | 0 | 0 | 0 | 0 | 96 | 0.0 | 0 / 1661 | 2.15 |
| g01-vn-dialogue-ja | games | 2 | 1080 | 0 -> 100 | 0 | 0 | 0 | 100 | 0 | 0 | 0.0 | 0 / 3976 | 1.47 |
| g02-vn-dialogue-en | games | 2 | 1301 | 0 -> 100 | 0 | 0 | 0 | 100 | 0 | 0 | 0.0 | 0 / 4878 | 1.45 |
| g03-rpg-inventory-ja | games | 18 | 2137 | 0 -> 88 | 0 | 65 | 0 | 0 | 23 | 0 | 0.0 | 0 / 7083 | 5.22 |
| g04-item-popup-en | games | 5 | 1516 | 0 -> 100 | 0 | 0 | 0 | 0 | 0 | 100 | 0.0 | 0 / 4240 | 3.20 |
| g05-battle-hud-ko | games | 4 | 1402 | 0 -> 50 | 0 | 0 | 0 | 0 | 50 | 0 | 0.0 | 0 / 3942 | 2.24 |
| g06-tutorial-popup-en | games | 3 | 1032 | 0 -> 100 | 0 | 0 | 0 | 0 | 0 | 100 | 0.0 | 0 / 3984 | 2.35 |
| g07-pixel-font-en | games | 4 | 1405 | 0 -> 19 | 0 | 0 | 0 | 0 | 19 | 0 | 0.0 | 0 / 1796 | 2.19 |
| g08-vn-choice-zh | games | 3 | 1289 | 0 -> 77 | 0 | 0 | 0 | 0 | 77 | 0 | 0.0 | 0 / 3742 | 1.65 |
| k01-readme-en | code | 11 | 3426 | 0 -> 70 | 0 | 0 | 0 | 0 | 0 | 70 | 0.0 | 0 / 10626 | 4.32 |
| k02-readme-ko | code | 10 | 2854 | 19 -> 88 | 19 | 0 | 0 | 0 | 0 | 69 | 0.0 | 0 / 8980 | 2.98 |
| k03-stackoverflow-ja | code | 10 | 2153 | 0 -> 100 | 0 | 0 | 0 | 0 | 0 | 100 | 0.0 | 0 / 1980 | 4.12 |
| k04-stackoverflow-en | code | 9 | 2405 | 22 -> 66 | 22 | 0 | 0 | 0 | 0 | 44 | 0.0 | 0 / 5126 | 3.45 |
| k05-terminal-zh | code | 6 | 1269 | 91 -> 100 | 91 | 0 | 0 | 0 | 0 | 9 | 0.0 | 0 / 2380 | 0.58 |
| k06-ide-diff-ko | code | 22 | 1778 | 37 -> 95 | 37 | 26 | 0 | 0 | 0 | 31 | 0.0 | 0 / 5617 | 3.96 |
| k07-algorithm-en | code | 13 | 2505 | 10 -> 84 | 10 | 0 | 37 | 0 | 0 | 37 | 0.0 | 0 / 6651 | 4.60 |
| k08-algorithm-zh | code | 14 | 1830 | 0 -> 84 | 0 | 0 | 0 | 0 | 0 | 84 | 0.0 | 0 / 2087 | 5.53 |
| k09-git-release-en | code | 7 | 2824 | 32 -> 91 | 32 | 0 | 0 | 0 | 0 | 59 | 0.0 | 0 / 4662 | 1.94 |
| k10-shortcuts-ko | code | 12 | 1643 | 0 -> 67 | 0 | 21 | 0 | 0 | 0 | 47 | 0.0 | 0 / 5941 | 4.14 |
| k11-traceback-ja | code | 10 | 1871 | 0 -> 100 | 0 | 0 | 0 | 0 | 0 | 100 | 0.0 | 0 / 2238 | 4.03 |
| k12-docker-zh | code | 8 | 1975 | 0 -> 34 | 0 | 0 | 0 | 0 | 0 | 34 | 0.0 | 0 / 2504 | 2.94 |
| p01-paper-en-2col | papers | 10 | 2863 | 65 -> 100 | 65 | 0 | 0 | 0 | 0 | 35 | 0.0 | 0 / 5713 | 2.17 |
| p02-paper-fig-table | papers | 20 | 1969 | 95 -> 100 | 95 | 1 | 0 | 0 | 0 | 3 | 0.0 | 0 / 5641 | 0.82 |
| p03-paper-references | papers | 8 | 2015 | 0 -> 100 | 0 | 0 | 0 | 0 | 0 | 100 | 0.0 | 0 / 5583 | 3.67 |
| p04-thesis-en | papers | 5 | 2108 | 81 -> 90 | 81 | 0 | 0 | 0 | 0 | 8 | 0.0 | 0 / 4770 | 0.81 |
| p05-paper-ja | papers | 6 | 2380 | 34 -> 100 | 34 | 0 | 0 | 0 | 0 | 66 | 0.0 | 0 / 5510 | 2.85 |
| p06-paper-zh | papers | 7 | 2033 | 34 -> 100 | 34 | 0 | 0 | 0 | 0 | 66 | 0.0 | 0 / 5327 | 2.60 |
| p07-paper-ko | papers | 5 | 1912 | 36 -> 100 | 36 | 0 | 0 | 0 | 0 | 64 | 0.0 | 0 / 5451 | 2.31 |
| s01-sub-ja-bright-2line | subtitles | 1 | 828 | 0 -> 100 | 0 | 0 | 0 | 0 | 100 | 0 | 0.0 | 0 / 3068 | 1.40 |
| s02-sub-en-dark-1line | subtitles | 1 | 1042 | 0 -> 100 | 0 | 0 | 0 | 0 | 100 | 0 | 0.0 | 0 / 4747 | 1.39 |
| s03-sub-ko-busy-2line | subtitles | 1 | 921 | 0 -> 100 | 0 | 0 | 0 | 0 | 100 | 0 | 0.0 | 0 / 3078 | 1.67 |
| s04-sub-zh-boxed-2line | subtitles | 1 | 1135 | 0 -> 100 | 0 | 0 | 0 | 0 | 100 | 0 | 0.0 | 0 / 3898 | 1.37 |
| s05-sub-plus-sign-top | subtitles | 3 | 1613 | 0 -> 60 | 0 | 0 | 0 | 0 | 60 | 0 | 0.0 | 0 / 3498 | 1.91 |
| s06-player-controls | subtitles | 4 | 1523 | 0 -> 86 | 0 | 0 | 0 | 0 | 70 | 16 | 0.0 | 0 / 4683 | 2.30 |
| s07-karaoke-ja | subtitles | 2 | 1248 | 0 -> 100 | 0 | 0 | 0 | 0 | 100 | 0 | 0.0 | 0 / 4329 | 1.76 |
| s08-sub-en-busy-outline | subtitles | 1 | 859 | 0 -> 100 | 0 | 0 | 0 | 0 | 100 | 0 | 0.0 | 0 / 3753 | 1.38 |
| s09-sub-ko-bright-1line | subtitles | 1 | 794 | 0 -> 100 | 0 | 0 | 0 | 0 | 100 | 0 | 0.0 | 0 / 3539 | 1.32 |
| stage | stage | 46 | 7961 | 34 -> 100 | 34 | 14 | 13 | 7 | 7 | 24 | 0.0 | 0 / 22587 | 7.92 |

## 6. The seam

### 6.1 Signature

New file `Core/Sources/MwoyeoCore/LensTarget+Shapes.swift` (`tools/first-lens/shapes/seam/`), and `LensTarget.Target` gains one stored property
(`tools/first-lens/shapes/seam/LensTarget.patch`, 5 lines):

```swift
public var shape: LensShape.Shape?          // nil for a column target; with `column` -1 and the shape's own anchor for a shape
public init(rect: CGRect, column: Int, anchor: Int, shape: LensShape.Shape? = nil)

extension LensTarget {
    public typealias Fallback = (_ pointer: CGPoint, _ held: LensShape.Shape?) -> LensShape.Shape?
    public static func choose(_ map: Map, pointer: CGPoint, held: Target? = nil, bounds: CGRect, scale: CGFloat = 2, fallback: Fallback) -> Target?
}
```

The picker builds `LensShape.Map(blocks: blocks.map(LensShape.Block.init))` where it builds `LensTarget.Map`, and calls
`LensTarget.choose(map, pointer: q, held: target, bounds: b) { p, h in LensShape.choose(shapeMap, pointer: p, bounds: b, held: h) }`. The existing `choose`
(no `fallback`) is untouched: the default path is byte for byte what it was, and a call without `fallback` cannot reach the new code. The trace prints
`target.shape?.kind` where it printed `column`. Nothing else in the picker changes: a shape is a `Target` with a rect.

### 6.2 The rule (one owner for the hand-over)

The column rule takes the pointer where it has a target. Each owner lets go of it only `switchBy` = 8 pt beyond where it would take it:

| held | the column rule at p | result |
|---|---|---|
| nothing | a target | the column |
| nothing | none | the shape at p, or the ghost |
| a column | a target of the same column | the column (the rule's own anchor hold) |
| a column | none, or another column | the held column while the rule would still take any of the 8 points `switchBy` around p in that column; else as for nothing |
| a shape | a target, and the rule takes all 8 points around p | the column (it holds the pointer 8 pt deep) |
| a shape | otherwise | the shape (`LensShape`'s own hold), or the column when the shape lets go |

A pointer jittering +-2 pt across any edge stays on the side it was on: the band is 16 pt wide, the jitter 4. The corners matter: a pointer off a column's
corner is 8 pt from it only along both axes (the first version probed the four side middles and left 56 reversals at corners).

### 6.3 What it measured

| chain | reversals over 53 scenes, 91,642 positions |
|---|---|
| the column rule alone (today's `choose`) | 115,951 (the outer edge ghost <-> column, the gutter column <-> column) |
| the bare chain `column ?? shape` | 117,177 |
| **the seam** | **0** |
| `LensShape` alone, with / without its hold | 0 / 592,143 |

The first row is a finding outside this round's assignment: the column rule's own edge and gutter flicker under jitter; the seam's hold removes it only when a
`fallback` is passed. Applying the same hold to the default path changes the default path; it needs the lead's decision and a no-regression gate (section 11).

## 7. False claims and misses (open; every rect is whole blocks, none cuts text)

A false claim is a shape a reader would call wrong. Rects are in the picture's screen points (x0 y0 x1 y1).

| scene | what | rect | size of the problem |
|---|---|---|---|
| d07-slide-zh | the slide's footer line is taken for a subtitle | 25 448 385 502.5 | the lens is a band around one line: harmless, wrong label |
| g05-battle-hud-ko | the menu strip and the HUD stats box are taken for subtitles | 5.5 437 385.5 498.5; 500.5 342.5 953 447.5 | bands around the text, wider than it |
| g07-pixel-font-en | the copyright line | 285.5 443.5 674.5 506.5 | as d07 |
| g03-rpg-inventory-ja | an item's description line is a subtitle (the table itself is right) | 3.5 399.5 500.5 476.5 | benign: a lens around that line is what a reader wants |
| k07-algorithm-en | an algorithm listing (left-aligned lines, ragged) is taken for a one-sided chat thread | 49 34 812.5 245 | the lens covers the intro and the listing: wrong unit, nothing cut |
| d01-spec-table-en | the table rect leaves out the off-grid header cell "Pro" (centred over a column whose values are left-aligned) | 0.5 45 626 216.5 | a lane with a cell on one row only fails the 0.6 lane share |
| c05-wechat-zh | a chat of one-line bubbles with their times gets a lens per bubble, not a thread (a time 4.2 ems wide is not "small") | per bubble | a miss: the lens is smaller than the unit |
| d03-magazine-3col-en | headline, byline and three columns are one group: 835 pt wide | 32 26.5 867 255 | a miss: wanted the heading with its lede |
| c01-slack-en | a three-line message gets the column rule's narrow column (61.5 120.5 377 201), the other messages the thread: mixed | | the order of the owners (section 11, question 1) |
| g08-vn-choice-zh | the read merged the speaker's name into the body (one two-line block "小雪你真的…"); the dialog is taken for a subtitle band; the rect is right | 9.5 362.5 722 447 | a read artefact; closed where the picker hands over the first line's box (`Block.head`, section 13.7); the bench fixture has no first lines, so it stays |
| k06-ide-diff-ko | the file list and the editor pane (line numbers | code) are one table | 6.5 40 650.5 231.5 | two panes read as lanes |

## 8. The stage

`tools/first-lens/stage/index.html`: one page, 1512 x 945 pt at 1x, pure HTML and CSS, system fonts, opens from `file://` in Safari; all content is ours
(paragraphs from our own paper, `tools/paper-own`; a chat of our own words; a code block of our own commands; a table of our own timings; a drawing; a
subtitle over a drawn sky; a game dialog of our own words; a list; a sidebar note). No third-party text, brand, logo or imitation of a real product's UI.
`path.json` plans the pointer path: the pointer rests `dwell` s at each of six points and takes `move` s (smoothstep) to the next; every point is on content (a
point in white space is held only by the hold, and a fresh pointer there gets the ghost). `shapes sweep` runs the choice along it, one line per 30 fps frame
(`data/shapes/sweep.txt`): kinds in order `group`, `column` (oneclick's rect), `thread`, `table`, `subtitles`, `dialog`; 0 frames with a cut. The
prototype animation draws the picker's preview (0.32 dim with a punched hole, accent ring) gliding by the critically damped spring of `LensTarget.Glide`
(omega 30, 8/30 s); the kind tag is a review aid, not product UI.

Self-verification of the frames: each rect starts on a block's top less 6 pt and ends on a block's bottom plus 6 pt; the thread's rect includes every bubble and
time of the pane; the table's includes the title and every lane; the subtitle band is centred on its two lines with a line's room above; the dialog box has
room to its right for the text still being typed. The article column in the frames is oneclick117's rect (vertical pad 0: hero2's O3b).

## 9. Gates

Every one FAIL-first (`tools/first-lens/shapes/mutants.sh`, `.../seam/check.sh`; each runs on a scratch copy and fails when a mutated line moves).

| gate | what | FAIL-first |
|---|---|---|
| `LensShapeTests` (Core, 19 tests) | one synthetic layout per kind with the exact rect; a doc's heading over a paragraph is no dialog; a page's lone line is no subtitle; two rows are no table; the hold; reach and let-go; the 53 scenes: never cut, inside bounds, at least the floor, the kinds each must (and must not) claim, 0 reversals; the stage's stops; the read's order does not matter | stub, `no-hysteresis`, `cut-a-block-allowed`, `heading-is-dialog`, `page-line-is-subtitle`, `no-pad`, `reach-unbounded`, `label-takes-held-lens`, `table-without-min-rows` |
| `LensShapeStabilityTests` (Core, 9 tests, shapestab) | the film stage's five stops on seven reads of it (`LensShapeHeroScenes`: hero2o's five reads one point apart, the zoom case, the live take): each its kind, its rect inside its panel; the stage moved 0..7 pt down, 0..3 across, at 1 and 0.888 (320 placements); every edge of every read off a point in 32 ways; a name merged into its lines still a dialog with the same lens, a three-line subtitle still a subtitle; a table with a column of cells beside it in another window; a dialog with a block ending above its body in another column; a heading over a chat; `explain` | on main's `LensShape` (scratch copy, `Block.head`, `Map.within` and `explain` stubbed): 8 of 9 fail, 422 issues (section 13.6); `content-not-scoped`, `messages-not-alike`, `dialog-nearest-above-only`, `merged-name-not-split`, `lane-without-precision`, `lane-spread-tight`, `merged-lines-judged-by-height`, `name-of-any-width` |
| `LensSeamTests` (5 tests) | a shape where the column has none; a fallback that finds nothing changes nothing; each owner lets go only 8 pt beyond; no flicker at the edge, at a shape, at a gutter | `no-deep-test`, `no-release`, `no-hold-between-columns`, `shape-hold-forgotten`, `column-held-over-shape`; the test's own `plain` chain flickers |
| the measure (`measure.sh`) | the numbers of section 5 on the picker's own reads | `--mutant nohold` |

## 10. Three layers

1. **Structural closure.** One owner for "content -> shape" (`LensShape`, `Kind`), one for the hand-over (the seam). A new content kind is a case and a row,
   nothing else; nothing outside a kind's recogniser decides what content is.
2. **Recurrence prevention.** The tests above on the picker's own reads (fixtures generated by `tofix.py` from `data/shapes/`), with named mutants; the measure
   is repeatable and its data is kept. The perceptual axes (how the outline feels while it morphs between shapes) go to one opus vision round on a playback
   recording, not on stills.
3. **Debuggability.** `shapes at <scenes> <scene> x y ...` prints the choice at each point with the held choice carried along (no debugger attach); `shapes
   grid` and `sheet.py` draw every position's kind and rect over the picture; `--why` prints each reversal with its jittered positions. In the app, the picker's
   trace line carries the shape's kind (section 6.1).

Section 13 adds three more, for the stability of a kind: (1) the owners are `Map.within` (what is content), `alike` (what is set alike), the dialog's `pair` over
the nearest *pairing* block, and the lane rule's rows and precision; (2) `LensShapeStabilityTests` and its eight named mutants; (3) `LensShape.explain` prints, for
a pointer, the blocks inside `bounds`, the anchor, and what each kind gave in the order they are tried, the last line the choice; `tools/first-lens/shapes/stability`
(on `LensShape.swift` alone) runs the hero's reads, the shift and jitter sweeps, the per-scene flip count, the grid diff, the cost, and `why` / `at` with `explain`.

## 11. Open questions for the lead

1. **Order of the owners.** The column rule is first; where it takes a few lines of a chat (c01: 24 % of positions) the user sees a narrow column in one place and
   the whole pane in another. Putting `thread` and `table` before the column would make chats and tables consistent, at the cost of letting a strong shape
   preempt the column on a page that has both (a paper's table: 1 % of p02). I kept the column first: it is the proven default.
2. **The default path's edge flicker.** The column rule alone has 115,951 reversals on these scenes (ghost <-> column at its edge, column <-> column at a gutter
   narrower than twice the slack). The seam's hold fixes it when a fallback is passed; applying it with no fallback changes the default path (needs a
   no-regression gate).
3. **`LensShape.pad`** is 6 here because `ColumnFit` is not in this tree; in the integrated tree it can read `ColumnFit.pad`, and `LensShape.Block` can become
   `ColumnFit.Block`.
4. **False claims** of section 7: the subtitles kind cannot tell a footer from a subtitle by geometry; a "centred in the frame" test would be wrong for a video in
   a page. The honest fix is a second signal (colour contrast or an outline), which the picker does not have.

## 12. Reproduce

```
cd tools/keep-labels && swift build -c release --product snap && swift build -c release --product ocrdump   # picture and read
snap tools/first-lens/stage/index.html stage.png 1512 945; ocrdump stage.ocr.jsonl en stage.png              # the stage's read
python3 tools/first-lens/shapes/tofix.py Core/Tests/MwoyeoCoreTests/LensShapeScenes.swift                  # fixtures from data/shapes/
python3 tools/first-lens/shapes/herofix.py Core/Tests/MwoyeoCoreTests/LensShapeHeroScenes.swift            # the film stage's reads (section 13)
swiftc -O -o /tmp/stability tools/first-lens/shapes/stability/main.swift Core/Sources/MwoyeoCore/LensShape.swift   # the probe of section 13 (modes in its header)
cd Core && swift test --filter LensShape                                                                    # 28 tests (19 + 9)
tools/first-lens/shapes/mutants.sh                                                                           # FAIL-first, scratch copy
tools/first-lens/shapes/seam/check.sh <tree with LensTarget.swift>                                           # the seam: tests and mutants
COLUMN=<seam sources> tools/first-lens/shapes/measure.sh                                                     # section 5, data/shapes/*.txt
python3 tools/first-lens/shapes/proto.py data/shapes/sweep.txt stage.png sweep-proto.mp4                      # the prototype animation
```

## 13. A kind must not change with a point of the read (shapestab, 1.1.7, 2026-10-22)

The film's hero is the lens changing shape as the pointer sweeps varied content. hero2o found that the kind of a stop changed when the stage was read again
a point lower (hero.html pasted into the screen frame `dy` = 0..3 pt below, read by Vision each time; the zoom case at 0.888; the live take). The same flips
would show on any screen: the cause is in the recognisers, not the stage. Reads, stops and the sim are in `tools/first-lens/data/shapes/hero/` (`herofix.py`
makes `LensShapeHeroScenes.swift` from them); a stop is a stage point (heading 240,64; chat 770,176; table 1236,140; subtitle 1240,492; dialog 1180,754 in
hero.html, 850 in index.html), the pointer 61 pt lower plus `dy`, the zoom case scaled by 0.888. Reproduced exactly: heading thread/group/thread/ghost,
table wide/ok/ok/ok, dialog ok/ok/ok/subtitles over hc0..hc3.

### 13.1 What each flip was (every one traced to the guard that decided it)

| flip | cause | owner | closed by |
|---|---|---|---|
| heading -> `thread` (38,61 904 x 151: the article's heading and paragraph, the chat's bubbles, and the window's title text) | the thread took the heading as a message: its em (29 pt) set the lane tolerance (1.5 em = 44 pt), the gap (4.5 em) and the neighbourhood (20 em = 580 pt), so the left lane held the article, the right the chat; and `webwin`, `Lens shapes` (the title bar, y < 61, outside the window's content) counted as messages | `thread`, and what `choose` hands the recognisers | `Map.within(bounds)`; the thread's messages are set alike (`alike`, `laneSpread`) |
| table -> a table 38..1467 wide | the anchor's row held a line of the article 540 pt to the left: its lane met 3 of the table's 5 rows by chance, and the share needed was 0.6 (3 of 5), so a point of read decided it | `lanes` | a lane needs its lines down the rows to stand on a row too (0.6 of them): the article's lane has 3 of 7 |
| table -> `group` (live take: only the first lane, 232 pt) | the read merged the first lane's three cells into one 3-line block, whose modelled glyph height (68.1 / 3.7 = 18.4 pt) is the box over the leading, not a glyph; against the lane's 11 and 13.2 pt cells it broke the 1.4 spread | `lanes` | a lane is judged by its one-line cells |
| table -> `group` / ghost under 1 pt of noise (hc1, hc2, zc) | the 1.4 spread is inside the natural variation of box heights: digits 11 pt, words with descenders 17.8 pt in one lane (ratio 1.45 to 1.6 with a point of noise) | `laneSpread` | 1.7, section 13.4 |
| dialog -> `group` (1 pt of noise, h0: 53 of 1000) | `above()` took the nearest block above the body, then tested it: a list item of the next panel ended 0.5 pt above the name's limit and was taken for the name | `dialog` | the name is the nearest block that *pairs* |
| dialog -> `subtitles` (hc3, zc, live) | the read merged "Mira" into its lines: one 3-line block, which is what a 3-line subtitle is by its box (the name sits on the box's pitch, so even the line pitch is uniform) | `Block` (what the read gives) | `Block.head`, the first line's box, 13.6 |
| heading -> ghost (hc3) | Vision lost the paragraph under the heading (it has the last line only); a heading alone is no group | the read | pinned as the ghost in the test (`readLostText`) |

### 13.2 Target and gap

| target | today (before) | gap | owner |
|---|---|---|---|
| a recogniser takes the blocks that belong with the anchor and no others | `lanes`, `thread`, `dialog` take any block that passes a geometric test, wherever it stands | what stands in `bounds`; what is set alike; a lane's lines stand on its rows; the name is a block that pairs | `Map.within`, `alike`, `lanes`, `dialog` |
| a kind does not change with a point of the read | thresholds sat at the edge of the measure: 3 of 5 against 0.6, a ratio of 1.45 against 1.4, 0.5 pt of 17.8 | the measured quantity gets room: the lane's lines, 1.7, the pairing block | `lanes`, `laneSpread` |
| a read that merged the name is read as the unmerged one | geometry cannot tell it from a three-line subtitle | `Block.head`, split at the first line and judged by `pair` | `dialog`, the picker's seam |
| the reason for a kind can be read | nothing | `LensShape.explain` | `LensShape` |

### 13.3 The panel boundary: what I measured instead of a gutter width

The brief asked for a vertical gutter wider than some X across the rows. Measured on the reads, no X separates a panel's gutter from a table's own: the film stage's
panels are 52 and 66 pt apart (41 and 53 at 0.888), the two columns of p02 22 pt; across the rows of a true table the free x gaps between lanes are 35 and 42 (the
stage), 90 and 113 (d01), 44 to 163 (d02), 385 (d05), 71 and 131 (g03), 142 (the k06 pane pair, which is no table). Both ranges cover each other. What separates them is
not the width of the gap but whether the content on its two sides is one thing, so the boundary is stated as what belongs with the anchor, at four owners: content is
what is in `bounds` (a window is the first panel boundary the system draws); a lane's lines down the rows are cells on those rows; a thread's messages are alike;
a dialog's name is a block that pairs with the body. None adds a number: they reuse `cutSlack`, `laneShare`, `laneSpread` and `pair`.

### 13.4 The margin

`laneSpread` 1.4 -> 1.7 (the same ratio now decides `alike` for the thread). In the film stage's table lanes the box heights run from 10.2 to 18.1 pt (digits to
descenders), so a lane's cells are 1.42 to 1.6 apart with a point of noise; a heading stands 1.8 to 2.2 over the text (29.1 against 16.1 and 13.2 in h0; one read,
hc3, 1.7). 1.7 is between. Over the 53 scenes (10 pt grid, 288,602 positions) it changes d01 only (13.5), and of the values tried (1.4, 1.5, 1.6, 1.7, 1.8, 2.0) 1.7 and
1.8 flip no table in the seven reads at +-2 pt of noise (at +-2 pt 1.4 flips the table 20 to 85 times in 1000 on five of the reads, 1.6 up to 8), and 2.0 lets the heading back into the thread.

### 13.5 The gates

`LensShapeStabilityTests`, section 9. The kinds in the hero's five reads, the panel each rect stays in, and the sweeps: 320 placements (dy 0..7, dx 0..3, scale 1 and
0.888), 32 jitters of 1 pt on every edge of every read (7 reads x 32 x 5 stops), the merged name, and one synthetic test per rule. `mutants.sh` takes each rule out in
turn.

### 13.6 Measured

Hero reads, kind before -> after (`h0`..`live`, five stops):

| read | heading | thread | table | subtitles | dialog |
|---|---|---|---|---|---|
| h0, hc0 | thread -> group | thread | table 38,147 1429 x 365 -> 996,125 471 x 151 | subtitles | dialog |
| hc1 | group | thread | table | subtitles | dialog |
| hc2 | thread -> group | thread | table | subtitles | dialog |
| hc3 | ghost (the read lost the paragraph) | thread | table | subtitles | subtitles -> dialog |
| zc | group | thread | table | subtitles | subtitles -> dialog |
| live | group | thread | group -> table | subtitles | subtitles -> dialog |

Wrong answers of 1000 (200 jitters x 5 stops) per read at +-1 pt on every edge, before -> after: h0 158 -> 0, hc1 73 -> 0, hc2 201 -> 0, hc3 400 -> 200 (the lost
paragraph), zc 211 -> 0, live 466 -> 0; at +-1.5 pt after: 2, 2, 1, 200, 0, 0; the 320 placements of h0 (dy 0..7, dx 0..3, 1 and 0.888): 64 wrong -> 0.
Over the 53 scenes, the kind at every block's centre with +-1 pt on every edge (24 jitters, 10,008 trials): 446 -> 431 flips; the offenders left are in section 13.8.

The 53 scenes keep their kinds, position by position: of 288,602 positions on a 10 pt grid 308 change (d01-spec-table-en: `group` -> `table`, the title's and the first
column's anchors now get the same table the other anchors of that table get: its table share of near positions 66 % -> 92 %, group 27 % -> 0 %); 0 change their rect;
no other scene changes by a position (per-scene histograms before and after: the report of this round; `stability grid` makes the two grids to diff). `measure.sh`, the same tool, over the same 91,642 near
positions, LensShape alone: claim 88.3 % -> 88.3 %, cut 0.00 % -> 0.00 %, reversals with the hold 0 -> 0 (without it 592,143 -> 592,683); d01 is the one row that
moves (`data/shapes/hero/measure-alone-{before,after}.txt`). The stage's planned path (`sweep.txt`, 196 frames): identical, kinds in the same order, 0 frames with a cut. The seam's rows (`seam`, `plain`, `column`) were
measured here on the hero tree's `LensTarget` (the shapes117 seam tree is gone): 78.3 %, 88.4 %, 20.8 % claim, identical before and after, so they do not move with this
change; they are not the 88 % of section 5, which is the older column rule's.
Cost: `choose` 7 -> 8 us on the stage when every block is inside `bounds`; 36 us when some are not (the scoped map is built per call: 46 blocks; its linking now stops at
the first block out of reach, which took the build from 53 to 36 us), a pointer move at 120 Hz spends 0.4 % of a core on it.

### 13.7 The first line's box (`Block.head`) and the picker's seam

`LensShape.Block` gained `head: CGRect?`, the box of the block's first line, nil by default (every existing call and the bench fixtures are unchanged). The dialog splits
a block with a `head` at that line (`split`: the name is the head, the body the rest, its lines spread over the rest of the box) and judges the pair with `pair`: a
three-line subtitle's first line is as wide as the others, so it is no name (`threeLineSubtitleIsNoDialog`). The picker has the box: the vn read's block holds its
lines. The wiring is two lines in the seam that is applied after this: `ColumnFit.Block` gets `head: CGRect? = nil`, the picker sets it from the block's first line (in
the same points as `core`) where it builds `LensTarget.Map(read:)`, and `LensShape.Block.init(_ b: ColumnFit.Block)` passes it (`self.init(core: b.core, lines: b.lines,
head: b.head)`). Without it the merged read stays a subtitle, as before.

### 13.8 Open (outside this round; the first needs a decision)

- p02-paper-fig-table: a bar chart's three labels paired with a column of text lines through a text column's own lines (711 positions, `table` 43..813 wide, across both
  columns). It is one lane of paragraph lines against another (the two columns of a page set at one pitch) and no geometric rule of this section tells it from a table
  with wrapped cells; the cell share counted in lines would, but loses d01, k06 and the right-hand table of p02 (2,318 positions). Unchanged by this round.
- The table's title aims at the table only within `stackGap` (1.2 em) of its first row: the stage's title is 18.4 pt above its row against a limit of 18.48 (a 0.08 pt
  margin; +-1 pt of noise flips it, `stage` 17 of 1104). Widening to 1.5 em adds table claims in d05 (45), k06 (75), p02 (3): needs a look at each.
- Flips left over the 53 scenes at +-1 pt (24 jitters per block centre): c05-wechat 110 of 240 (a chat of four one-line bubbles),
  k04 42, k10 36, k09 27, k12 25, k02 22 (group <-> ghost), d03 17 (thread -> dialog on a magazine), d05 18 (table -> ghost); none traced. `explain` prints
  the ladder of each in a few lines.
- hc3's heading: the read lost the paragraph; nothing to recover.
