# paper-own: our own test papers

The paper bench used to render arXiv 1706.03762, whose licence (arXiv non-exclusive) lets nothing of it be shown in public. From
2026-10-19 the bench's page source is a paper of ours: `mwoyeo-method/`, "Mwoyeo: In-Place Screen Translation that Keeps Up with the
Scroll", an arXiv-style two-column paper (Computer Modern, 13 pages with an appendix) about the method the code implements. Its
formulas, listings and tables are ours, so the pages can go into films and the README. Its facts must stay true of `main`.

| | |
|---|---|
| `mwoyeo-method/build.sh [out dir]` | cuts the listings from the sources by line range, then `tectonic` builds `main.pdf` (`brew install tectonic`; the first build downloads its TeX bundle). `SOURCE_DATE_EPOCH` is fixed to the commit the paper describes, so two builds give the same PDF bytes. |
| `mwoyeo-method/check.py` | `python3 -I check.py [--ref REV] [--repin]`: every row of `sources.tsv` (a number, a constant or a claim about code of the paper: needle, `path:line`, section, claim) must still hold; the listings must equal their source lines; every reference has its fetched line in `sources/refs.txt`. rc 1 prints where a needle moved. `--repin` moves a row to the line where its needle now is, never changing a needle. |
| `mwoyeo-method/facts.py` | the counted and computed facts (scenes and units of the use-case bench, the corpus of the translation bench, the numbers derived from the predictor's constants); `sources.tsv` rows of kind `cmd:` look for their needle in its output. |
| `mathdense.py <pdf>` | which pages are densest in inline mathematics: the `SIDE` pages of `tools/paper-bench/pages.sh`. |

Run the paper bench on it: `tools/paper-bench/pages.sh <pages dir>` (default PDF: `mwoyeo-method/main.pdf`, built when missing), then
`PAGES=<pages dir> tools/paper-bench/run.sh <Mwoyeo binary> <out dir>`. Results of the first run: `tools/paper-bench/RESULTS-own-2026-10-19.txt`.
The old document stays reachable: `PDF=<1706.03762.pdf> SIDE="4 5" pages.sh`. Results on the two documents are not comparable as a regression.

Rule: a sentence of the paper that carries a number, a constant or a claim about code has a row in `sources.tsv`; a number of a
result comes only from a result file committed in the repository (and the row says which).

## Third-party paper text in the repository (audit, 2026-10-19; nothing below was changed)

The only licences found are arXiv's non-exclusive licence (arXiv 1706.03762: nothing of it can be shown in public) and CC BY 4.0
(2401.10066, 2310.06142: usable with attribution). Replace with our own paper by pointing each place at `mwoyeo-method/` (its LaTeX source
and `main.pdf`).

| place | third-party text | licence | one-line way to replace it with our paper |
|---|---|---|---|
| `tools/keep-labels/papers.tsv`, `fetch.sh`, `regen.sh`, `make-labels.sh`, `Sources/regionfeed/main.swift:115` | three arXiv papers by id; labels hold their OCR text | 1706.03762: arXiv non-exclusive (labels gitignored, `tools/keep-labels/.gitignore:3`); 2401.10066 and 2310.06142: CC BY 4.0 (labels committed: `labels/2401.10066.jsonl`, `labels/2310.06142.jsonl`) | add a row for `mwoyeo-method` (math truth from its `.tex` through `latex_math.py`, glyphs from its PDF) as the dev paper in place of 1706 |
| `tools/keep-labels/RESULTS-2026-10-19.txt`, `RESULTS-code-region-2026-10-19.txt` | aggregates over the dev papers and a few quoted OCR fragments of them in "where the misses cluster" | as the row above | re-run `run-rules.sh` after the row above and keep the new file beside these (do not overwrite) |
| `tools/inline-math-probe` (`README.md:20`, `RESULTS-2026-10-19.md`) | measures pages p3-p6 of 1706 through the paper bench outputs | arXiv non-exclusive | `run.sh <out> <bench dir of mwoyeo-method>` with the pages `mathdense.py` names (the committed README keeps the 1706 numbers) |
| `tools/paper-bench` (`allow.txt`, `linkpx.py:2`) | `allow.txt` lists sentence fragments of 1706; `linkpx.py` names it in its docstring | arXiv non-exclusive | rebuild `allow.txt` from the `formula_translated` lines of `RESULTS-own-2026-10-19.txt`'s `detail.txt`, reviewed; reword the docstring (`pages.sh`, `score.py` already default to our paper) |
| `tools/usecase-bench/set` papers scenes (p01-p07) | HTML written for the bench with invented titles; only `p03-paper-references.html` and `.expected.txt` quote four real bibliographic entries (Vaswani et al., He et al., Smith, Baek et al.) | bibliographic facts, no licence needed | swap the four entries for those of `mwoyeo-method/refs.bib` in both files |
| `tools/translation-bench/sequences`, `memory`; `tools/engine-bench/data.json` | none: written for the benches (their READMEs say so) | ours | nothing to do |
| outside `tools/`: `Core/Tests/MwoyeoCoreTests/` (`FormulaLiteralTests`, `MathHeavyTests`, `PaperQualityTests`, `PaperRound2Tests`, `BlockLayoutTests`), `docs/research/paper-translation.md`, `docs/design/inline-math-and-code.md`, `docs/design/keep-boundary.md`, comment in `Core/Sources/MwoyeoCore/CodeRegion.swift` | OCR lines of 1706 as test strings and quoted examples | arXiv non-exclusive | take the fixtures from the OCR lines of the `RESULTS-own` run (`<out>/pN.out`), same shape |
