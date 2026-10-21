# What to translate and what to keep: the keep boundary

Status: parked, 2026-10-19. This is a record only. No model, generator, labelling or training work starts without the
user's go at a stage gate (§7). The user: "모델 생성은 비용이 크니까 신중하고 싶어", and later "모델 관련은 문서화만
해두고, 지금은 싼값으로 마무리짓고 앱스토어 등록". Near-term work stays on the cheap path: today's rules, plus the
inline-math pixel path in [inline-math-and-code.md](inline-math-and-code.md) if its first measurement passes.

Inputs:
- [math-code-detectors.md](../research/translation/math-code-detectors.md): existing detectors and their licenses.
- [keep-boundary-datasets.md](../research/translation/keep-boundary-datasets.md): datasets, render recipes and a
  train/hold-out plan.
- [inline-math-and-code.md](inline-math-and-code.md): how kept spans are drawn (original pixels), and code blocks.

## 1. The question

The user's framing (2026-10-19): the goal is not to answer "is this math?". The goal is to find the boundary between
text that must be translated and text that must stay exactly as written.

- Math and code are reasons to keep text. They are not the target.
- Other reasons: commands, paths, URLs, identifiers, keys and hotkeys, hashes, line numbers, diff markers and log lines.
- A code block stays whole, its comments included. This was the user's decision on 2026-10-19 (v1).
- Papers count as done when two things hold:
  - inline formulas appear as their original pixels inside the translation;
  - code is not translated.

Today the boundary comes from hand rules on OCR text:
- `Text.swift:275` needsTranslation, `:291` isLiteral, `:330` isFormula, `:341` isMathHeavy;
- `InlineMath.swift:7` spans.

These rules were tuned on one paper page.

## 2. Labels and metrics

Every OCR word gets one label:

| Label | Meaning |
|---|---|
| `translate` | Must be translated. |
| `keep` | Must appear unchanged. |
| `either` | No harm either way: numbers, versions or "C++" inside a sentence, and names (the engine decides). Not scored. |

A `reason` (math, code, command, path, url, id, hotkey, log, prose) goes with each label. It is used for debugging and to
choose how a kept span is drawn. It is never the scored target.

The unit is the OCR word range we already box (`Shared/VisionExec.swift:146` wordRanges). These are whitespace tokens,
and each character inside a CJK token, so "使用npm install命令" already has character edges. A rule trims edge
punctuation.

Metrics:
- (a) word-level keep precision and recall;
- (b) keep-span F1 with exact boundaries (a span counts only when both edges match), and the edge error in words;
- (c) whole-block keep precision and recall;
- (d) the two costly errors, counted apart:
  - keep→translated: a command or formula gets mangled;
  - translate→kept: prose is left untranslated.

All of them are reported per reason. In the use-case bench, (d) on the rendered output is the kept_ok / translated_ok
columns.

## 3. Two shapes: pick regions, or label words

| | Region: pick whole blocks to leave alone | Word: label each word |
|---|---|---|
| Decisions | One per block, so few | One per word, so many |
| Evidence per decision | Many lines: indentation, monospace, keyword density, line-end `; { }`, background tint | A few neighbouring words |
| Expected accuracy | Higher; the problem is easier and needs fewer labels | Lower, with edge errors on top |
| Cost of an error | Large: a whole block left untranslated or mangled | Small: a few words |
| Cannot do | `foo()` or x² inside a sentence | — |
| Cost | A classifier over the blocks Vision already gives; close to today's rules | Higher |

A pixel detector that finds regions straight from the frame was also weighed and set aside:
- Its box edges miss short inline spans.
- It would need the ANE or GPU, and OCR already owns the ANE.
- No public data labels keep/translate boxes on real screens.

Coordinates already come from OCR. Any judge only labels them, and a kept span is the union of its kept word boxes.

**The deciding measurement costs no model.** It comes from the labels round L0 builds, on papers and new use-cases, for
both the VN and Docs read paths:
1. **Keep-mass split:** the share of keep words in all-keep blocks (code blocks, terminals, display equations) versus
   inline spans inside translated blocks.
2. **Block purity:** the share of Vision blocks whose scored words are all keep or all translate.
3. **Region fit:** whether each all-keep region maps to whole OCR blocks or gets merged with prose.

Reading the result:
- If most keep words sit in pure blocks, the cheap answer is a region judge (rules first), with inline spans left to
  today's rules and the inline-math pixel path. A word judge may never be needed.
- If Vision often merges code with prose, a region judge must first split blocks, which removes most of its advantage.

The lead's prior is the first case.

## 4. Off-the-shelf models

None fits. The detail is in math-code-detectors.md.

| Model | Problem |
|---|---|
| PDF-Extract-Kit MFD, DocLayout-YOLO (best formula detectors) | AGPL-3.0. They cannot ship in a Mac App Store app. Using their output as training labels is legally unclear, so we do not. |
| Surya (has a code class) | OpenRAIL-M with a revenue cap, or NC weights. |
| LayoutLMv3, Nougat | NC weights. |

Apple Vision `RecognizeDocumentsRequest` gives title, text, paragraphs, tables, lists and barcodes, with no code or math
signal (SDK Vision.swiftinterface, checked).

LLM deciders (Jev, its local look-alikes Kev, Laya and NanoJev, and Strands Decider) answer typed questions with
probabilities. They run 100× over the budget in §5, so at most they could label unlabeled real screens offline.

## 5. If a model is ever needed: requirements (draft, not approved)

- **Place:** after makeBlock (`TextRecognizer.swift:500-510`) and before needsTranslation.
  - Rules settle the sure cases; the model sees only the uncertain band, so sure outputs stay byte-identical.
  - The output feeds ProtectedSpans (one new kind per reason, never a borrowed id) and a whole-block keep.
- **Input:** only what is already in memory, with no extra Vision call: block text, word ranges and boxes, line boxes and
  the frame pixels.
  - Features: character classes, a ±k-word window, geometry (indent, height versus line, width per character for
    monospace, baseline offset for sub/superscripts) and optional pixel cues inside word boxes (slant, tint).
  - No language ID and no per-language dictionary.
- **Output:** per word p(keep), and per block p(keep whole).
  - Calibrated: reliability error ≤ 0.05.
  - Separate thresholds for the two error costs.
- **Quality, on the real-screen hold-out:**
  - never worse than the rules on any reason slice;
  - exact-boundary keep-span F1 ≥ 0.90;
  - translate→kept on prose ≤ 1 % of words;
  - keep→translated on code, command and math ≤ 5 % of spans;
  - on re-reads of a still screen, ≤ 1 % of words flip between frames, so the lens does not flicker.
- **Budget on an M1 Pro:**
  - CPU only, never the ANE;
  - p95 ≤ 1 ms per block and ≤ 5 ms per frame (OCR takes 200-1000 ms);
  - weights ≤ 5 MB, RSS ≤ 20 MB, lazy load ≤ 50 ms;
  - deterministic, because cache keys depend on it;
  - Core ML or plain Swift weights, with no Python, no server, no network and no telemetry.
- **License:** trained by us on the sources in §6 only. No AGPL, NC or SA material, and no output of such models, goes
  into shipped weights.
- **Shape ladder:** stop at the first rung that meets the bar.
  1. Boosted trees on word features with a window (Create ML; KB in size, µs per word).
  2. A tiny character CNN or BiLSTM tagger with geometry, ≤ 2 M parameters.
  3. A small token-tagging transformer, ≤ 10 M parameters.

  The training rig (A6000 + 3090) matters only from rung 2 up.
- **Rollout:** opt-in setting first. The default flips only with a no-regression gate: use-case per category and the
  paper bench, per the default-path rule.
- **Maintenance cost:** OCR output shifts with macOS releases and with the per-id e5rt cache. A learned judge must be
  re-measured, and maybe retrained, on each major macOS. Rules need the same re-measurement but no retraining.

## 6. Data, if a model is ever needed

The detail is in keep-boundary-datasets.md. No public dataset labels keep/translate on real screen pixels.
- Word-exact boundaries exist only where markup survives: Stack Exchange `<code>`/`<kbd>`/`$…$`, Wikipedia, READMEs and
  LaTeX.
- Real pixels exist only without such labels: ScreenSpot, ScreenQA.
- The bridge is to render markup ourselves (WebKit) and read it with our own Vision OCR. That gives real OCR noise with
  free truth.

| Rank | Source | Role | Size target | License risk |
|---|---|---|---|---|
| 1 | Real screens labelled by hand (Xcode, Terminal, Safari on SO/GitHub/arXiv, Preview, VS Code, diffs, ko/ja/zh/en UIs) | Hold-out, the only trustworthy score | ≥ 1,000 keep spans, ≥ 100 per reason, ≥ 300 mixed sentences; ~10-15 h by hand, less with a rules draft plus a vision pass and a human review of disagreements | Low (local only) |
| 2 | Own HTML renders of SE-, Wikipedia- and README-style Markdown with inline keep spans, many fonts, themes and languages, then Vision OCR | Train | ≥ 15k keep spans, ≥ 3k per reason, ko/ja/zh ~25 % each | Low with own or permissive text |
| 3 | CC BY / CC0 arXiv papers: LaTeX → PDF, math-font glyphs and `\texttt` / `\url` macros as truth | Train/dev, paper domain | 20-40 papers, ≥ 3k keep spans, split by paper | Medium (per-paper license filter) |
| 4 | ScreenSpot (Apache-2.0), ScreenQA (CC BY 4.0) | Hold-out for translate→kept on UI chrome | 300-500 screens | Low, local only |

Blocked sources:

| Source | Reason |
|---|---|
| M6Doc, MathWriting, arxiver | NC |
| DocBank, WebUI, Screen2Words | No license stated |
| DoTA | Gated |

Two license points:
- **CC BY-SA** (Stack Exchange, Wikipedia): whether trained weights are "Adapted Material" is not settled by the license
  text. Use such text as test or render material only, unless the user decides otherwise.
- **The benched paper 1706.03762** carries the arXiv non-exclusive license, not CC. Its labels hold OCR text, so they
  are regenerated locally from the arXiv ID and kept out of git.

## 7. Stage gates

Each step needs the user's go. Every stage reuses what the earlier ones built, so a stop loses nothing.

| Stage | What | Cost | Go/stop rule |
|---|---|---|---|
| 0 | Measure today's rules on L0's labels: P/R per reason, plus the §3 split, purity and fit | One round, running now | — |
| 1 | Fix the rules where misses cluster, with a code-block rule from existing features (indentation, monospace, line ends, keywords, tint) | Cheap, no model | Stop here if every reason slice reaches P and R ≥ 0.95 on the hold-out |
| 2 | Choose region versus word from the §3 numbers | Free | — |
| 3 | Rung-1 model (boosted trees) on the uncertain band only, with the hold-out built (rank 1) and a small render set (rank 2) | Labelling hours plus one generator round; training takes minutes on a Mac | Ship opt-in only if it beats the rules on the hold-out per §5 |
| 4 | Rungs 2-3 on the rig | High: data at scale, export, maintenance | Only with new evidence and the user's go |

## 8. Open decisions (the user's)

- Who labels the real-screen hold-out: by hand, or a rules draft plus a vision pass with a human review of
  disagreements (recommended).
- CC BY-SA as training data: recommended no (test and render material only).
- Names as `either` (the engine decides), or as `keep`.

## 9. Stage 0 results (2026-10-19)

Sources: tools/keep-labels/RESULTS-2026-10-19.txt (rules report), CODE-FEATURES-2026-10-19.txt, and
tools/inline-math-probe/RESULTS-2026-10-19.txt. Labels: two CC BY 4.0 papers (2401.10066 dev, 2310.06142 hold-out),
1706.03762 (dev, local only), and twelve code use-cases k01-k12 (dev k01-k08, hold-out k09-k12). Read: the document
model (doc); the VN read is in the files and similar.

**Today's rules on the keep boundary**

| Source | Word P / R | Span exact F1 | Block keep P / R | keep→translated words | translate→kept words |
|---|---|---|---|---|---|
| Papers dev | 0.91 / 0.39 | 0.26 | 0.85 / 0.76 | 798 / 1309 | 51 / 6791 |
| Papers hold-out | 0.95 / 0.32 | 0.38 | 0.90 / 0.59 | 312 / 462 | 8 / 4781 |
| Cases dev | 0.91 / 0.40 | 0.56 | 0.95 / 0.56 | 143 / 239 | 10 / 362 |
| Cases hold-out | 1.00 / 0.58 | 0.77 | 1.00 / 0.78 | 88 / 208 | 0 / 249 |

The rules rarely leave prose untranslated, but they miss most keep words. By reason, on the cases hold-out:
- recall 1.00 for cmd (n = 13), math (n = 18) and hotkey (n = 4);
- path 0.90 and code 0.52;
- id 0.08;
- flag and url 0.00.

The misses cluster in five places:
- single letters and bare operands (246 of 788 missed math words, papers dev);
- garbled symbols and weak operators;
- code lines with English words or CJK comments;
- git-log lines;
- terminal blocks mixing commands and CJK output.

**Region versus word (§3)**

| Source | Pure blocks | Keep words in all-keep blocks | Display regions whole / split / merged with prose |
|---|---|---|---|
| Papers dev | 61 % | 31 % | 24 / 13 / 32 |
| Papers hold-out | 65 % | 46 % | 8 / 5 / 12 |
| Cases dev | 83 % | 88 % | 3 / 6 / 0 |
| Cases hold-out | 91 % | 87 % | 8 / 5 / 0 |

- **Developer screens:** a region judge carries about 90 % of keep words. The cases are hand-written and few, so this
  needs confirming on real screens.
- **Papers:** most keep words are inline math inside mixed blocks, and Vision merges about half the display equations
  with prose. Papers need a span-level judge, or a block splitter first.

**Code blocks the rules translate:** 24 of 74 pure-keep blocks (doc read). The document model often cuts a code region
into one-line blocks. The features that catch them are listed below; thresholds were set on the same set, so the catch
counts are an upper bound.

| Feature | Catches (of 24) | False fires (of 44 pure-translate blocks) |
|---|---|---|
| Indentation | 17 | 4 |
| Tinted background | 12 | 5 |
| Keyword density | 10 | 2 |
| Line end `; { } )` | 2 | 0 |
| Monospace | 1 | 1 |

Together, any of the five catches 23 of 24; tint or keyword alone catches 20.

**Inline math pixels (M0)**
- Word-box crops are clean for 76 % of spans (VN) and 64 % (Docs) on p3-p6.
- An ink-grown box (≤ 3 px) raises that to 94 % / 86 %, and drawing only the span's own ink components gives 100 % on the
  (a, b) criteria.
- Word boxes never missed sub/superscript ink, so Plan B (character boxes) is not needed.
- Verbatim locate of the span text in Apple's translation: 95 % (38/40).

But the rules find only 13 % of inline math spans (hold-out span recall 0.13), so the pixel path would reach few
formulas. It is deferred with this document (user scope for the first MAS submission, 2026-10-19).

**Decision for the first MAS submission (cheap path):**
- A rule-based code-region keep: group adjacent blocks by tint and indentation, then score keywords and line ends.
- No model.
- The paper-side gaps (inline spans, block splitting) wait for the stage gates in §7.

## 10. Rows of displayed equations (D8, 2026-10-21)

The text rules cannot keep a row of a display that holds a word. `ô = 1.4826 medianpering| l(p) - l|,` holds a run of letters that reads
as a word (the garbled `median_{p∈ring}`), `∨ prompt ∨ S ≥ 2 ∧ D(R),` holds a real one. `isFormula` lets one word through only beside
an `=` and twice its letters in the rest, `isMathHeavy` needs 2 signs and 20 characters; both rows fail both, so the row was translated
and drawn over the typeset equation (4 of the 8 windows of the method paper that show a display; film3's A8 counted 5, its fifth is
prose). The place on the page says what the text cannot.

`CodeRegion.Reason.equation` keeps a block that stands off the body text of its column by 1.5 line heights on each side and holds a sign
of mathematics and at most one word of prose. The margins come from the blocks of four words (of two characters or more) over the
block's middle; a block whose box holds the middle of this one is no margin. Table: the four rows stand 2.5 to 6.8 off, a paragraph's
first line 0.7 to 1.0.

| signal (needs, on a block the text rules translate) | the four rows | pure-keep blocks of the two papers (doc read) | translate / mixed blocks |
|---|---|---|---|
| stands off both sides, a sign, at most one word | 4 of 4 | 5 flipped (dev 2, hold-out 3) | 0 |
| an equation number at the right margin on its row | 2 of 4 | 0 beyond the row above | 1 before it had to stand at the right margin (a reference `(A2)` cut off its sentence) |

The number was left out: it adds no row and costs a guard. Not done: rows with no sign (49 of 95 pure-keep blocks of the two papers are
still translated; most hold no sign of mathematics: recognizer garbage, `det Dy`), and the chain "a row next to a kept row".
Results, speed and the method: [tools/keep-labels/RESULTS-d8-equation-2026-10-21.txt](../../tools/keep-labels/RESULTS-d8-equation-2026-10-21.txt).

### 10.1 A row the reader put into a paragraph (D14, round d14, 2026-10-21)

D8 judges blocks. film3's takes of page 6 of the method paper show a row that no rule ever saw as one: eq (10) `s* = max { s ∈ [smin, smax] : measure(s) ≤ box },`
was kept by a lens at 150,366,590,400 (pixel diff 0.48, ink 100 %) and drawn as Korean text, with the sentence above it, by a lens at 150,256,590,514 (takes
`equation-paper-p6` and `-p6b`). The row's own text is kept by the text rules (`isMathHeavy`: 3 signs, share 0.59; the take logged `kept math` for it when it was a block
of its own). The document reader had put the row into a paragraph, and the rules judge the whole text of a block.

THE STAGE. Both readers glue it, and which one does depends on a pixel of the capture. The take's trace lists the lines of its first block (`ocr-block 0`, Docs) as the seven lines of
the paragraph and the row (8 lines). Renders of the take's screen (page 6 in Preview, the lens plus its margin, 944x822 pt, cut at 12 offsets from y 99 to 110 pt, both readers,
build 1d7e0ab) put the row: on the Docs path into the paragraph *below* it in 2 of 12 captures (y 105 and 106: the row is the first of 4 lines), a block of its own in the other
ten; on the lines path (`ParagraphGrouper`: a line continues a paragraph at a gap of at most 0.6 heights of the taller line) onto the paragraph *above* it in 5 of 12 (y 99, 100, 102, 107, 110:
the row is the last of 8 lines, the take's shape), a block of its own in seven. There the row stands 0.60 to 0.63 heights under the sentence above (41 px against a limit of 40.8 in the
captures that did not glue it) and 0.80 to 0.89 above the next paragraph. No rule that works on the read can tell a glued capture from a whole one, so the cut belongs where the blocks are made.

| read | where the row went | row, px (x, y, w x h) | gap above | gap below | in from the left | in from the right |
|---|---|---|---|---|---|---|
| film take p6b, Release 1d7e0ab | last of 8 lines | 346, 747, 1077 x 63 | 40 px = 0.69 line heights | none | 51 = 0.88 | 58 = 1.00 |
| capture at y 105 pt, Debug 1d7e0ab | first of 4 lines | 352, 747, 1062 x 64 | none | 54 = 0.95 | 55 = 0.95 | 60 = 1.04 |
| capture at y 106 pt | first of 4 lines | 352, 739, 1062 x 64 | none | 64 = 1.16 | 55 = 1.00 | 60 = 1.09 |
| the lines of a paragraph (41 renders of the paper bench, 384 blocks of two lines or more, 1610 lines) | | | median 0.08, 99 % under 0.33 | | flush (0.0) | |

(Line heights are the median of the block's lines; the "in from" columns are against the left and right edges of the block's other lines.)

OTHER READS. On the blocks of two lines or more that the keep rounds' regionfeeds kept (papers 2401.10066, 2310.06142, 1706.03762 and the code cases, Docs and lines reads: 578 blocks; the H2
developer screens: 236; the H3 sanity feed: 426) the rule cuts 3, and none on the 384 blocks of the 41 renders of the paper bench. The three are displays that the lines read glued to a
paragraph: `0 < λ1 = λ2 = λ3 .....` (2401.10066 p3, the last of 4 lines, 0.66 under the line above), `Azu = tv if, and only if, Ip(Cov) = 1Cpv.` (p10, the first of 3, 0.80 above the next
paragraph) and `âz = â, √1 − a+ê √a,` (2310.06142 p5, the first of 3, 0.68). Their words are labelled keep, apart from the four of `if, and only if,` (translate). Cut, the three rows are kept:
21 words labelled keep leave the translated blocks, and so do those four (the Docs read of p10 hands the same row over as a block of its own, `isMathHeavy` keeps it, and the labels
count its four words the same way: D8's translate-to-kept words are of this kind).

THE RULE. `DisplayRow.pieces` (Core), called from `RegionPipeline.readBlocks` before the column break and the joins: a line of a block is a row of mathematics by the text
rules that already decide (`isFormula`, `isMathHeavy`, and D8's sign + at most one word, `CodeRegion.holdsMathNotProse`), and it stands off the prose of its block as a display
does: white space of half a line height above and below it, and in from both edges of the prose by as much. The row (a run of rows) becomes a block of its own; the prose
before and after it stay blocks. Nothing is kept by this rule: the cut row is judged as every block is (`isLiteral`, then D8's `Reason.equation`).

`isEquationRow`'s own test (1.5 line heights in from the body text, a sign, one word) cannot be the rule for a line of a block: eq (10) fails both halves: `shape` counts three prose words in it and it stands 0.9 line
heights in; it is kept by `isMathHeavy`. So the text half is the three tests the text rules have, and the stand-off is the white space round a
display, not its distance from the column.

EVERY ADDED GUARD (each one, taken out, fails a test of `DisplayRowTests`; table in the round's report): the three text tests of `isRow`; gap above; gap below; in from the left;
in from the right; a run of rows is one piece; prose must exist (a block that is all rows is not cut); `layoutRules` (`MWOYEO_LAYOUT=off` switches the cut off with the other layout rules).
