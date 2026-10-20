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

## H2: own developer screens (round k3a, 2026-10-20)

The cases k01-k12 were written by hand and also set the CodeRegion thresholds, so they overstate the rules. H2 measures the same rules on
material written for the purpose and never looked at while the rules were tuned: 46 screens (27 scenes in 11 looks, ko / ja / en) of this repo's
own developer content, with labels known by construction. Results: `RESULTS-h2-2026-10-20.txt` (rules OR CodeRegion: word P 0.98 / R 0.78 on the doc read).

    ./make-h2.sh                  # h2.py (html + units) -> snap (2x pictures) -> ocrdump through tools/ane-env.sh run pool -> h2_labels.py -> labels-h2/h2.jsonl
    ./test_h2.sh [A.jsonl B.jsonl] # generator determinism, frozen manifest, label test on a fake OCR; every check has its FAIL-first line
    KEEP_WORK=<dir> ./run-rules.sh labels-h2      # the rules report on H2 (needs <dir>/h2 from make-h2.sh for CodeRegion; the report warns when a block has no picture)
    python3 -B -I h2_report.py labels-h2 <rules.jsonl> --sheet <dir> --pics <KEEP_WORK>/h2    # sizes, verdict per reason slice, cuts, clusters, disagreement sheet
                                                  # rules.jsonl = KEEP_FEED=<regionfeed output> keeprules labels-h2/h2.jsonl

- **What a screen is.** `h2_scenes.py` holds the scenes: Swift, shell, JSON and YAML excerpts of the repo at the pinned commit (`h2.verify` checks every code line
  against `git show d8e50d8:<path>`; comments are replaced by Korean / Japanese ones), README passages (checked as passages of the three READMEs), tool outputs
  (git log, git diff, swift test, xcodebuild: captured once into `h2/src/*.txt` by `h2/capture.sh`; the generator reads only those), terminal sessions, chats and
  issue pages written for the scene, and a shortcut cheat sheet. `h2.py` draws each scene in a look: dark or light terminal (the light one is a window on a desktop),
  an IDE with a gutter, a browser page (GitHub-like), a chat window; two looks have untinted code, and the monospace face is Menlo, SF Mono, Monaco or Courier New.
- **Labels by construction** (addendum A1.1). `h2.py` writes the units of a screen in reading order with the class the author gives them: a line of code, a command, a log
  line, a config line, a path, a hotkey is keep (with its reason); a heading, a paragraph, a list item, a table cell and the window's text are translate, every token of
  them, except inline code (keep, the reason from the author's INLINE table), a name `{n:..}` or a time or number `{t:..}` (either); program output with CJK is either
  (as the notes of k05 do). `h2_labels.py` aligns the OCR words with the units (difflib, as `code_labels.py`) and a word takes its unit's class; it calls none of
  truth.py's shape rules, so the rules are not graded against themselves. A token without a letter in a translate unit is either. What the construction does not
  settle is `uncertain` (the prose-looking comment of a code region, a bare path in a sentence): those words feed the disagreement sheet.
- **Independence** (A1.2): nothing from `usecase-bench/set/k*`, `RESULTS-*`, `CODE-FEATURES-*` or `CodeRegion.swift`; only commits by midagedev in the git log. The sources
  are frozen in `h2/MANIFEST.tsv` (path or command with the sha256 of the text read, the language given to ocrdump per screen); `make-h2.sh` and `test_h2.sh` refuse a different manifest.
- **Own labels dir.** `labels-h2/` holds H2 alone (set `h2` in rules_report.py's SOURCES, not under `hold`), so `run-rules.sh` on `labels/` is unchanged.
- **Vision is not byte-stable across cache states** (bench-id-cache): warm the binary with one pass, then compare legs.

## H3: a second hold-out (round h3, 2026-10-20)

H2 turned into a development set when the five defects it showed were fixed. H3 is a fresh hold-out for those fixes, built with the H2 machinery (`h2.py` draws, `h2_labels.py --set h3`
labels; `h2.py main(<scenes module>)` and `--set` are the only parameters added, and H2's generator output stays byte-identical to its pre-h3 digests, `h3/h2-generator.sha256`).
68 screens (38 scenes, ko 18 / ja 16 / en 16 / zh-Hans 18, 57 code regions) in 15 looks that H2 does not have: terminal (`term-solarized`, `term-green`), editor (`ide-solar`, and `pane-*`, a narrow editor in a side panel
whose lines wrap), browser page (`md-sepia`, `md-night`, and `docs-*`, a docs site with a left nav and a contents list), chat (`chat-dark-plain` with untinted inline code, `chat-mint`), `review-*` (a code review page: old and new line-number gutters, sign column, a commit panel with hashes)
and `card-*` (notification-sized cards); monospace faces Andale Mono, PT Mono, Courier, Menlo, Monaco, SF Mono.

    ./make-h3.sh                  # h3.py (html + units) -> snap -> ocrdump through tools/ane-env.sh run pool -> h2_labels.py --set h3 -> labels-h3/h3.jsonl  (set KEEP_WORK and KEEP_BUILD)
    ./test_h3.sh [A/h3 B/h3]      # determinism, frozen manifest, label test on a fake OCR, independence, H2 unchanged, two legs; every check has its FAIL-first line
    python3 -B -I h3_size.py labels-h3/h3.jsonl            # sizes, words by class, keep words per reason with the `thin` flag
    H3_WORK=<KEEP_WORK of a make-h3.sh run> KEEP_BUILD=<dir> ./run-h3.sh <scratch dir>     # the unchanged report tools on H3 (labels copied to a scratch dir as `h2`, so the headings say H2)

- **New material.** `h3_scenes.py` reads files and fixtures H2 did not use, at the pinned commit `5c25067` (every code line verified): `scripts/mas.sh`, `release.sh`, `setup-release-secrets.sh`, `stats.py`, `ExportOptions-MAS.plist`, `Config/MAS.xcconfig`,
  three Core tests (none of the keep / translate ones), entries of `App/Resources/Localizable.xcstrings` (real ko / ja / zh-Hans values), `docs/settings-for-agents.md`, `CONTRIBUTING.md`, `README.zh-CN.md`, `tools/engine-bench`, `tools/mock-openai`; tool outputs captured once by
  `h3/capture.sh` into `h3/src/*.txt` (git diff / show --stat / blame / grep of midagedev's commits that H2 did not show, a swift build, `ls -l`, the bench report); `nl -ba` rows (the number is its own unit, keep lineno, inside a block with letters); flag, hotkey (plain text keys), id, path and hash tables; url lists.
- **Labels by construction** as H2 (units with the author's class; `truth.py` is not called). Frozen: `h3/MANIFEST.tsv` (written before any Vision read; `make-h3.sh` and `test_h3.sh` refuse a different one).
- **Independence.** `h3_independence.py`: no k-case passage, no excluded source, no source or unit of H2 (units of 4+ words), none of the rule code or keep tests (InlineMath, Text, CodeRegion, TranslationFilter and their tests). `RESULTS-h3-build-2026-10-20.txt` has sizes and counts, no rule result; the rules are not measured on H3 here.
- **Vision reads Latin runs of a CJK page as single characters** (the ja / zh-Hans document reads cut `https://...` into one word per character): word counts of the url slice are ja / zh-Hans dominated; read them by language.

## Files

`truth.py` word truth rules | `label.py`, `code_labels.py` labellers | `h2.py`, `h2_scenes.py`, `h2_labels.py`, `h2_report.py` the H2 screens, their labels and report | `h3.py`, `h3_scenes.py`, `h3_looks.py`, `h3_independence.py`, `h3_size.py`, `run-h3.sh` the H3 screens, looks, checks and report wrapper | `rules_report.py` the report | `Sources/keeprules` Core rules on
every block | `Sources/ocrdump` both Vision reads of the app (`VisionExec.swift` linked from `Shared/`) | `Sources/snap` HTML -> picture.

Record kinds (JSONL): `paper` header (schema 2, `word_fields`, counts, regions), `block` (id, read, rect, text, `keep` class, `reason`, stats, words
`[start, end, keep, reason, tag, text, region]`, ranges in Characters), `span` (a run of keep words in the sequence of scored words),
`near` (a word of a shape mistaken for math or code, with its `keep` and `reason`). Every row has `keep` and `reason`. Block class: keep (keep words only), translate, mixed, either, none.
