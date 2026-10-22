# film3: a short clip for 1.1.5, a script fixes a real translation defect, live in the app
Round film3 (2026-10-21). Content: our method paper (`tools/paper-own/mwoyeo-method`) plus one added subsection; engine Apple en -> ko; the lens in Preview over a paragraph.
Evidence and board live in /tmp/film3 (evidence-paper.md, board.md); the furigana case of Phase 1 is kept in evidence.md.

| path | what |
|---|---|
| `paper/` | `threats.tex` (subsection 6.6, our paragraphs) and `build.sh` (builds the paper with it into /tmp/film3/paper-build; the paper's own files are not written) |
| `terms/` | the term fix: `probe.py` (Apple on 23 terms in natural sentences; `probe-*.json`), `script.js` (the 5-entry `after`), `script-section.js` (10 entries), `check-sites.py` (every replacement site over what the app translated: particle, partial word, sense; FAIL-first fixtures in `fixtures/`), `count-terms.py` (terms wrong / occurrences, raw vs script) |
| `edit/` | `locate.swift` (Vision's box of a span on a frame: marks are placed from it), `caption.swift` (caption pill and end card PNGs, the lead's words), `edit.py` (takes + plan -> 1920x1080 film and 720p proxy), `selftest.sh` (FAIL-first: a span that is not read stops the edit) |
| `live/` | the takes: `record-paper.sh before|after|ui` (the paper in Preview with a lens, scratch ids, whole-screen capture at 60 fps; waits by condition for the lens's Korean via `hangul.swift`; refuses or marks a take unusable when another process's window lies over the frame, `foreign.js`; env PDF, SCROLL, REGION, FRAME, QUIET), `ax.sh` + `ax.applescript` (Accessibility steps, no event synthesis: action, press, pressafter, presslast, set, type, bar, scroll, move, wait, dump), `takes-manifest.py` (moments in take seconds), `take-compare.py` (is a box unchanged under the lens, shift-tolerant, with a prose control), `a8-screen.sh` + `a8-score.py` + `a8-boxes.py` + `a8-rescreen.sh` (offline screening of equation windows of the paper: kept rows, drawn equation rows, debris, cuts) |
| `stage/`, `sequence/`, `make_stage.py`, `script-profile.json`, `live/record.sh` and its helpers | the game variant of Phase 1 (film 2's stage with furigana in brackets; `record.sh` = film2's recorder on the 1.1.5 settings shape, Apple engine, reader-ready gate); kept as a record, not used by the paper clip |

The film itself is built by round film3-motion in `motion/` (A7); `edit/` is the first, cut-only edit and is not extended.
