# Inline math as original pixels, and code left untranslated

Status: design notes, 2026-10-19 (opus design round plus lead addenda; main eb9f3c3 line numbers). §1-6 are the
implementation plan (rounds M0-M3). §7-10 on a learned judge are superseded by [keep-boundary.md](keep-boundary.md), which
is parked: no model work without the user's go.


1 Source box: both read paths already produce whitespace word boxes (Shared/VisionExec.swift:105-108 VN Lines; :130-133
RecognizeDocumentsRequest) carried as ReadWord(rect, UTF-8 start/end) over the wire (ReaderWire.swift:107-163); ReaderCheck.swift:441
equal gate compares words. Wire change: 0; survives R3a. Mapping: block text from TextRecognizer.swift:500-510 makeBlock (joins
lines by " " or ""); prefix sums give char offset → (line, word). InlineMath tokens are whitespace tokens (bracket spaces joined)
→ word unions; trailing ".,;:!?" trimmed, so box is one comma wide: cut small baseline ink components in the app. Spans across
lines stay text. Plan B (only if M0 shows bad word boxes): host adds char boxes for math tokens as ReadWords (one ReadJob flag,
same blob). Outside defect (S): RegionPipeline.swift:1138-1140 styleRuns builds new text from a substring while words' String.Index
stay relative to the parent line.text; math mapping passes there → rebase needed.
2 Drawing: overlay gets block images only (RegionPipeline.swift:22-27) → App/Overlay/* unchanged. Text system BlockRenderer.swift:52-161
(CTFramesetter); fit CTFramesetterSuggestFrameSize (Text.swift:213). Located span → U+FFFC with kCTRunDelegate (w/ascent/descent);
after CTFrameDraw walk lines/origins/runs and draw crops. Outline pass (:142-153) skips FFFC; truncating (Text.swift:181) cuts a
prefix so k-th FFFC = k-th image. Scale k = drawnSize / Block.fontSize (px; nil → line-height ratio); same size = 1:1 pixels.
Vertical: dy (crop centre vs line centre) → k·dy. Measure includes delegates, so the fit/ellipsis loop :89-131 is unchanged.
Line breaks: FFFC is UAX#14 CB → particle may wrap ("√dk로"); insert U+2060 between FFFC and adjacent non-space in
keepingWordsTogether (Text.swift:200). Attachment wider than the box → text. Block rule: if attachments make a block clipped/
ellipsis that was not without them, draw the whole block as text. Background: erased (seamless) uses raw crop; .box mode → paint
ink mask in textColor or keep text.
3 Fallback (proposed new first choice): locate span text in the translation ignoring spaces, in order (ProtectedSpans.resolve
rule), only when counts equal the source. Evidence: Apple plain path verbatim 22/24 (ll), 23/24 (hf), garbled 26/26
(inline-math-placeholders.md Table 2). Engine/OS independent, stateless (works with cache hits TranslationService.swift:336 and
context outputs). On 26.4+ with MWOYEO_INLINE_MATH=1 use inlineMath(:748) first if non-empty. Unfound/duplicate span → that span
text. DeepL <m>/OpenAI tags only if locate rate is low per engine; cheaper lever: add "formulas" to ChatTranslation.swift:100
"Keep names, numbers…". 26.0-26.3 works via the first path.
4 Default: no "paper" signal (ReaderDecider ParagraphReader.swift:100-111 picks documentLayout for nearly all). Gate per span:
InlineMath found + located + clean crop + one line + erased bg. On everywhere once gated; before that opt-in MWOYEO_INLINE_PX=1
(a settings.json schema key). Gates: usecase 160/251 per category unchanged with a list of blocks that drew spans; paper p1-15
overlaps/spill/cut 0, clipped/ellipsis/big +0, formula_translated same, debris_drawn down on p3-6; one opus vision verdict.
New metric: render emits `inline:` lines (span, src rect, dst rect, k); score.py computes math_px (drawn/located spans in
translated blocks), math_px_bad (luma NCC < 0.9 between resampled src crop and output dst, overlap with other ink, drawn twice),
crop_cut (ink touching crop border, neighbour-line intrusion); debris recounted on drawn text.
5 Rounds: M0 now (new tool only). M1 now, worktree: new Core InlineMathPlacement.swift (locate, offset→word box, k/dy, crop
hygiene) + tests, BlockRenderer.swift, Text.swift joiner — no overlap with T3a-2 or R3a. M2: RegionPipeline Block.math
(:105-126), 3 creation sites (:845/:852/:926), renderMissing (:1506), `inline:` trace, styleRuns rebase, paper-bench score.py;
not TranslationService; no hunk overlap with T3a-2 (parallel, lead applies in order); R3a edits pass functions (:796-950) adjacent
to the creation sites → land M2 before R3a branches or after R3a. M3: vision verdict + default flip.
6 Risks: ① word boxes miss sub/superscript ink or take in neighbour lines (biggest); ② garbled OCR cuts a span wrongly (half
pixels, half garbage): skip when neighbour token is €/IR/single letter; ③ taller lines → more ellipsis (block rule stops it);
④ box-mode rectangle; ⑤ crops clamped at lens edge → fallback.
First measurement M0 (CPU, minutes): on paper p3-6 PNGs, RecognizeDocumentsRequest word boxes → InlineMath → union crop; per
span (a) components touching the border, (b) share of ink connected within ±0.6 lh outside the box, (c) neighbour-line
intrusion → clean % + one failure montage (one opus look). ≥ 90 % → M1/M2; below → ink-grown box or Plan B first. Also verbatim
locate rate from existing bench .out pairs (free).

## Addendum (classifier + code), received 2026-10-19
7 Learned detector: pixels beat text (italic slant, sub/sup offsets, single-letter ink height vs line height, measured inside
word boxes) + token shape features. MAS candidates: (1) Create ML boosted tree on our features (KB, µs, ours); (2) small image
classifier on span crops (MB); (3) detector only if code AND weights Apache/MIT (RT-DETR, PicoDet family), data license too;
(4) Foundation Models only for ambiguous text spans, never default path. Trap: DocLayout-YOLO = ultralytics = AGPL-3.0, weights
too. Cascade: rules split sure-math (^ _ √ ∈ =) / sure-prose / uncertain band (weak ops - / *, single letters, "x2", garbled €/IR);
model only on the band; sure outputs byte-identical. First measurement: span P/R of today's rules. Free labels: arXiv LaTeX `$…$`
= inline math truth; PDF text layer (pdfpages.swift) per-glyph font (CMMI/CMSY math fonts) + bounds = per-glyph truth boxes; match
OCR words by IoU. Size: ≥150 math positive spans + ≥300 near-negatives (hyphens, slashes, "C++", versions) → ±5 % CI at R≈0.9;
≥3 papers (1706.03762 + 2 other styles, IBEM/DoTA sources), 1 hold-out. Rule: rules P and R ≥ 0.95 → defer the model; else (1) on
the band where misses cluster.
8 Code: block features from existing data (no wire change): indentation runs (line start x quantised in glyph widths), line-end
; { } ) ratio, symbol and keyword density (return const def if for import => fn let), monospace (CV of word width / chars small,
space width = glyph width), tinted background box (appearance.backgroundColor). RecognizeDocuments has no code marker
(DocumentObservation.Container: title, text, paragraphs, tables, lists, barcodes; Vision.swiftinterface :2793-2808). A code block
is kept whole before Text.swift:275 needsTranslation and not erased. Inline code (`foo()`, `--flag`, snake_case, a.b.c) → new
ProtectedSpans Kind `.code` (no borrowed math id), drawn via the same original-pixel path. Risk: lowLatency ignores word-attached
skipsTranslation (paper-translation.md §4), so "map" may be translated; code fallback must be "do not translate the block", not text;
measure on Apple ll/hf. One detector, classes prose/math/code, units block and span, one 3-class label set; rules first, training
only for classes under target on hold-out. usecase-bench scores segmentation only: add `(keep)` notes in expected.txt (score.py:19
bracket regex) and kept_ok / translated_ok columns. Cases: GitHub README (prose+headings translated; fenced/inline code, badges
kept), StackOverflow (prose translated, code kept), terminal (prompts/commands/output/logs kept; human error sentences optional),
IDE/diff (code, line numbers, +/- kept; UI chrome translated), paper algorithm listing (caption translated; keywords, math, vars kept).
Open decision: translate code comments (// …, ▷ …)? v1 recommends keep (partial translation inside a block needs pixel splits).

## Addendum 2 (user, 2026-10-19): the target is the translate/keep boundary, not "is it math"
The user: "수식인지 판단이 아니라 … 번역해야 하는지 안 해야 하는지, 번역해야 하는 바운더리를 찾아내는 걸 목표로".
9 Target. One judge answers, per word (and so per span and block): must this text be translated, or must it stay exactly
as written? Math and code are reasons to keep, not the target. Other keep reasons: commands, paths, URLs, identifiers,
keys and hotkeys, hashes, line numbers, diff markers, log lines. The output is the set of keep spans with exact word
boundaries, plus whole-block keep (a code block, comments included, per the user's 10-19 decision).
Labels, per word: `translate` | `keep` | `either`. `either` = no harm either way (numbers, versions or "C++" inside a
sentence, names: the engine decides), excluded from scoring. A `reason` field (math, code, command, path, url, id, ...)
rides along for debugging and for choosing the drawing path; it is never the scored target.
Metrics: (a) word level: keep precision and recall over keep vs translate words; (b) span level: exact-boundary keep-span
F1 (a span counts only when both edges match), and edge error in words; (c) block level: whole-block keep P/R;
(d) the two costly errors counted apart: keep→translated (a command or formula gets mangled) and translate→kept (prose
left untranslated). Use-case columns kept_ok / translated_ok are (d) on the rendered output.
Consequence for §7: the rules-vs-model decision rule (P and R ≥ 0.95) applies to keep vs translate at word and span
level, sliced by reason; a model is trained only where the slices miss. Near-negatives for math (hyphens, "C++",
versions) are mostly `either` or `keep` under this target, not `translate`; label them by the definition above.

## 10 Requirements for a keep-boundary model, if one is needed (lead, 2026-10-19, DRAFT — not approved; the user wants caution: no model work before the stage gates below are met and the user approves)
Place: after makeBlock (TextRecognizer.swift:500-510), before needsTranslation (Text.swift:275) and ProtectedSpans; output
feeds ProtectedSpans (new kinds per reason) and a whole-block keep. Rules settle sure cases; the model sees the band only.
Unit: the OCR word ranges we already box (VisionExec.swift:146 wordRanges: whitespace tokens, per character inside CJK
tokens), so "使用npm install命令" already has char edges. Edge punctuation (",", ")", "。") is trimmed by rule, not model.
Input, all already in memory, no extra Vision call: block text, word ranges + boxes, line boxes, the frame pixels.
Features: char classes/n-grams per word, a ±k-word window, geometry (indent, height vs line, width/char for monospace,
baseline offset for sub/sup), optional pixel cues (slant, tint). No language id, no dictionary of a language.
Output: per word p(keep) and per block p(keep whole). Calibrated (reliability error ≤ 0.05) so thresholds are per error
cost: keep→translated and translate→kept get separate thresholds.
Quality (hold-out H1, real screens): never worse than rules on any reason slice; keep-span exact-boundary F1 ≥ 0.90;
translate→kept on prose ≤ 1 % of words; keep→translated on code/command/math ≤ 5 % of spans; frame-to-frame flip rate
on re-reads of a still screen ≤ 1 % of words.
Budget (M1 Pro): CPU only, never the ANE (OCR owns it); p95 ≤ 1 ms per block, ≤ 5 ms per frame (OCR is 200-1000 ms);
weights ≤ 5 MB, RSS ≤ 20 MB, lazy load ≤ 50 ms; deterministic (cache keys). Core ML or plain Swift weights; no Python,
no server, no network, no telemetry.
License: trained by us on D0 sources only; no AGPL/NC/SA data or teacher output in the shipped weights.
Not its job: blocks (Vision), OCR correction, translation, names (either), language id.
Shape ladder, stop at the first that meets the bar: (1) boosted trees on word features with window (Create ML, KB, µs);
(2) tiny char-CNN or BiLSTM tagger with geometry features, ≤ 2 M params; (3) small token-tagging transformer ≤ 10 M.
LLM deciders (Kev, Laya, Jev) fail the budget by 100×; at most an offline teacher for unlabeled real screens.
Rollout: opt-in setting first; default flip only with a no-regression gate (usecase per category, paper bench) per
default-path rule.
