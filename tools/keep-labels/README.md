# keep-labels: where the translate / keep boundary lies, and how today's rules draw it

Target (design note addendum 2, `docs/design/keep-boundary.md`): not "is this math?" but "must this text be translated, or stay
exactly as written?". Every OCR word gets a label `keep` | `translate` | `either` and a `reason` (math, code, cmd, flag, path, url,
id, hash, hotkey, log, config, lineno, diffmark; prose, name, number, ... for the other labels). `either` (a number, version or
"C++" inside a sentence, a name, bare punctuation, text of a drawn figure, a word the glyphs could not decide) is not scored.
The reason is for debugging; it is never the scored target.

## Run

    ./regen.sh                    # fetch, render, trace, read with Vision, label: papers and code cases -> labels/
    ./run-rules.sh                # Core rules (InlineMath, TranslationFilter) on every labelled block + the report
    ./test_keep_score.sh          # FAIL-first test of the kept_ok / translated_ok columns of usecase-bench/score.py
    python3 -B -I code_features.py $KEEP_WORK/code labels/code.jsonl <rules.jsonl>
                                  # the pure-keep code blocks the rules translate, and which cheap feature (indent, mono, line end,
                                  # keyword, tint) would have caught each; rules.jsonl = keeprules labels/code.jsonl

Vision needs the Bash sandbox off and the Neural Engine to itself (one run at a time). arXiv only; PDFs, sources and page pictures
live in a cache (`KEEP_CACHE`, `KEEP_WORK`), never in the repo. `regen.sh` run twice with a fresh cache and work dir gives
byte-identical label files (gate G1). Python runs as `python3 -B -I`.

## Papers (math and the typewriter text of the PDF as truth)

| paper | set | licence line on the abs page |
|---|---|---|
| 2401.10066v2 | dev | `<a href="http://creativecommons.org/licenses/by/4.0/" title="Rights to this article" class="has_license">` |
| 2310.06142v2 | hold-out | `<a href="http://creativecommons.org/licenses/by/4.0/" title="Rights to this article" class="has_license">` |
| 1706.03762v7 | dev (the paper bench) | `<a href="http://arxiv.org/licenses/nonexclusive-distrib/1.0/" title="Rights to this article">` (not CC: its labels are gitignored) |

`fetch.sh` checks the licence path and the sha256 of the PDF and the source against `papers.tsv`.

- `pdfglyphs` (Swift, CGPDF) traces every glyph of the PDF with its real font, size and box. PDFKit cannot do this: it reports a
  made-up "Helvetica" for every font of a page's text, so the math fonts (CMMI, CMSY, CMEX, MSBM, txfonts) cannot be told apart.
- `label.py` groups math-font glyphs and the glyphs TeX sets beside them into formulas, reads each OCR word's glyphs, and labels
  the word (`m`/`c`/`p`/`u`/`f` -> keep/translate/either by `truth.py`). Words set in a typewriter face (URLs, e-mail addresses) are keep.
  A displayed formula (no text letter close beside it on its line) is a region; the parts within an em of each other are one region.
- `latex_math.py` counts the `$...$` / `\(...\)` spans of the LaTeX source as a check of the glyph groups (header of each label file).

## Code cases

`../usecase-bench/set/k01..k12` (original text, ko/ja/zh/en): README, StackOverflow answer, terminal, IDE diff, algorithm listing,
release checklist with a git log, shortcut settings, traceback, Docker how-to. `.expected.txt` notes: `(keep)`, `(keep:<reason>)`,
`(keep:math)`, `(inline: a ; b)` (translated unit with kept substrings), `(optional)`. `score.py` reads them: columns kept_ok,
translated_ok, inline_ok. `code_labels.py` aligns every OCR block with the whole expected text (difflib) and labels word by word, so
a block that holds code and prose together is not lost. A block of nothing but line numbers or diff marks is the gutter the case
draws (keep, reason lineno / diffmark).

## Files

`truth.py` word truth rules | `label.py`, `code_labels.py` labellers | `rules_report.py` the report | `Sources/keeprules` Core rules on
every block | `Sources/ocrdump` both Vision reads of the app (`VisionExec.swift` linked from `Shared/`) | `Sources/snap` HTML -> picture.

Record kinds (JSONL): `paper` header (schema 2, `word_fields`, counts, regions), `block` (id, read, rect, text, `keep` class, `reason`, stats, words
`[start, end, keep, reason, tag, text, region]`, ranges in Characters), `span` (a run of keep words in the sequence of scored words),
`near` (a word of a shape mistaken for math or code, with its `keep` and `reason`). Every row has `keep` and `reason`. Block class: keep (keep words only), translate, mixed, either, none.
