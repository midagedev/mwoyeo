# tools/lens-window

What a lens shows of a block that crosses one of its edges (round edges117, docs/design/recognition.md §16.2).

- `sweep.py`: the number behind `LensWindow.minShares`. Render the paper bench with `MWOYEO_LENS_SWEEP=1` (`MWOYEO_LENS_SWEEP=1 tools/paper-bench/run.sh <binary> <out> p1 p2 ...`),
  then `python3 -I tools/lens-window/sweep.py <out>`: for each share of a block's source text width (100 % to 10 %) how many blocks the fitter can still lay a translation out
  in above its smallest size, for all blocks, for the paragraphs, and by the lines of the source. `--selftest` is its FAIL-first (a block that stops reading at 0.4 must say so).
- The rule is `Core/Sources/MwoyeoCore/LensWindow.swift` (unit tests `LensWindowTests`); the app's gate is `lens-window-checks` (also a part of `check-logic`): the renderer's
  window and line boxes, the overlay's mask on a layer tree, and a real pipeline on a two-column page. `MWOYEO_LENS_WINDOW=off` turns the rule off for measuring against: the same
  run then draws every block as it stands (the checks FAIL on it, which is their FAIL-first).
- In the trace (`MWOYEO_TRACE=1`): `lens settled: …` when a settle laid blocks out again or left them out, `lens edges: …` after each snapshot (the lines the lens meets, how many it
  cuts and how many of those it shows, the fragments it draws), `render … lens window a..b` for a block laid out in the part the lens covers, and `reach: …` when the capture grows to
  the column of a paragraph it cut. Counters: `layout.visible_width`, `layout.share_hidden`, `layout.settled`, `overlay.line_masked`, `lens.reach`.
