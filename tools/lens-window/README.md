# tools/lens-window

What a lens shows of a block that crosses one of its edges (round edges117, docs/design/recognition.md §16.2).

- `sweep.py`: the number behind `LensWindow.minShares`. Render the paper bench with `MWOYEO_LENS_SWEEP=1` (`MWOYEO_LENS_SWEEP=1 tools/paper-bench/run.sh <binary> <out> p1 p2 ...`),
  then `python3 -I tools/lens-window/sweep.py <out>`: for each share of a block's source text width (100 % to 10 %) how many blocks the fitter can still lay a translation out
  in above its smallest size, for all blocks, for the paragraphs, and by the lines of the source. `--selftest` is its FAIL-first (a block that stops reading at 0.4 must say so).
- `sweep.py --ink [--ink-share 2|5|10]`: the number behind `LensWindow.wholeInset` (round edges117b, film4 F16). The same run (`MWOYEO_LENS_SWEEP=1`) also writes one `ink` line per line of
  each translation at the full width: where the line's ink stands in its box, and how deep into the box (a share of its height, from the top edge and from the bottom edge) an edge has
  cut 0, 2, 5 and 10 % of the ink (`LensSweep.ink`: the pixels that differ from the line's background, over the rows the line owns). `--ink` prints the distribution over the lines
  and the depth that at most 10 % of the lines have cut more than the share by (the default share is 10 %). Feed it the pages only (`p1.err` .. `p13.err`): a crop repeats a page's lines.
- The rule is `Core/Sources/MwoyeoCore/LensWindow.swift` (unit tests `LensWindowTests`); the app's gate is `lens-window-checks` (also a part of `check-logic`): the renderer's
  window and line boxes, the overlay's mask on a layer tree, and a real pipeline on a two-column page. `MWOYEO_LENS_WINDOW=off` turns the rule off for measuring against: the same
  run then draws every block as it stands (the checks FAIL on it, which is their FAIL-first).
- In the trace (`MWOYEO_TRACE=1`): `lens settled: …` when a settle laid blocks out again or left them out, `lens edges: …` after each snapshot (the lines the lens meets, how many it
  cuts and how many of those it shows, the fragments it draws), `render … lens window a..b` for a block laid out in the part the lens covers, and `reach: …` when the capture grows to
  the column of a paragraph it cut. Counters: `layout.visible_width`, `layout.share_hidden`, `layout.settled`, `overlay.line_masked`, `lens.reach`.
- `take-report.py <take dir>`: the numbers a live take leaves in its `app.err`, at each of its stills: the last `lens edges` / `lens rows` (the lines that stand on the lens's top and bottom edge, their
  overhang in shares of their height and what `LensWindow.shown` makes of each) / `pipeline emit` / `lens columns` line, the `fit:` / `reach:` / `lens planned` marks with their take second, and
  the blocks drawn at the capture's right edge (the translations of a cut column). `MWOYEO_TRACE=1` is on in the takes.
