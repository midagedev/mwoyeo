# Translating papers: findings and plan (2026-10-18)

Started from a user report on arXiv 1706.03762 ("Attention Is All You Need") read in Safari: formulas were translated and
translated lines overlapped. This file keeps what was measured and decided, so nothing has to be found twice.
Companion files in this folder:

- `doc-translation-survey.md`: 19 papers and systems on in-image and document translation, each with a quoted line and a
  "use for Mwoyeo" note.
- `inline-math-placeholders.md`: placeholder survival through Apple Translation, measured.
- `apple-attributed-spans-{lowlatency,highfidelity}.txt`: the attributed-span experiment below, raw output.
- Probes: `tools/apple-translation-probe/` (`batch.swift`: plain batch like the app; `attributed-spans.swift`: skip spans).

## 1. What shipped in 1.1.1 (not advertised; the user kept papers out of the release notes)

| Change | Where | Evidence |
|---|---|---|
| Formula fragments and camelCase names stay as written | `TranslationFilter.isFormula`, `isIdentifier` (Core/Text.swift) | page 4: "K"→"1천" and 9 more fragments now kept; 253 use-case bench units: only 4 formulas + 1 brand newly kept |
| A formula call read with a space ("Attention (Q, K, V) = softmax") | same | Core test |
| Blocks never paint over each other | `BlockLayout.swift` (BlockMerge, Territory, ColumnEdge, LayoutCheck), RegionPipeline `joinSplitLines`/`layoutPlaces` | `--render` layout line, page 4: overlaps=1 cut=1 → 0/0; pages 5, 6: 0; use-case bench 160/251 unchanged per category |
| A transient OCR failure (e5rt, nilError) no longer leaves a still lens empty | `OCRHealth.passFailureIsTransient`, RegionPipeline `noteReadFailure` | healthy.sh check 9: 0 → 19 arrows |

## 2. Seen live after 1.1.1 (page 5, the user's Mac)

1. `where headᵢ = Attention(QWᵢ^Q, KWᵢ^K, VWᵢ^V)` is still translated: OCR puts a space before "(" and reads the arguments
   as multi-letter runs, and "headᵢ" as "head;".
2. Lines with sub/superscripts are drawn ~1.5x the body size: the em size comes from glyph heights inflated by scripts.
3. A line cut by the lens edge is read in part and its translation covers the visible half.
4. Sentences dense with inline math come out garbled ("W ∈ ℝ^{dmodel×dk}" → "WO € R dmod × dx").

Items 1-3 (and a "…" for text clipped at the minimum size, and keeping math-dominated blocks as written) are round
`paper-quality` (spec in the lead's gate folder), measured with a paper bench (`tools/paper-bench/`, every page).

## 3. Inline math: where the damage happens

Measured (`inline-math-placeholders.md`): Apple Translation returns math spans as sent — 23/24 spans unchanged with plain
text, and it copies OCR-garbled spans unchanged too (26/26). So "WO € R dmod" is OCR's reading of sub/superscripts, not
the engine. Consequences:

- Placeholders (`{1}`, `X1`, `<m1/>` …) all survive (24/24) but cost the sentence: Korean particles attach to the
  placeholder's last letter (~1/4 wrong), and a phrase was dropped once. Not the default.
- The text of the math cannot be repaired after OCR; the original pixels can be shown instead.

## 4. Apple Translation, code level

App: `App/Pipeline/TranslationService.swift` — `session(source:)` picks lowLatency (language pack) or highFidelity (Apple
Intelligence) per pair; `makeSession` uses `TranslationSession(installedSource:target:preferredStrategy:)` (26.4+);
`stream(_:through:)` sends `TranslationSession.Request(sourceText: String, clientIdentifier:)` with
`session.translate(batch:)` and reads `r.targetText`; then `TranslationCleanup.restoreSourceTokens` and `applyGlossary`
("Apple Translation has no glossary; enforce entries whose source term survived untranslated").

Framework (MacOSX27.0.sdk, Translation.swiftinterface), new in macOS 26.4 and unused by the app so far:

- `TranslationSession.Request(sourceText: AttributedString, clientIdentifier:)` — works in `translate(batch:)`.
- `AttributeScopes.TranslationAttributes.skipsTranslation` (`a[range].translation.skipsTranslation = true`).
- `Response.attributedSourceText` / `attributedTargetText`.

Experiment (`attributed-spans.swift`, 6 paper sentences, both strategies): each math span marked `skipsTranslation` and
given a marker attribute (`link = math:N`) comes back **unchanged, in place, carrying both attributes** in
`attributedTargetText`:

- highFidelity: the run is exactly the span (`[√dk]`, `[W_i^Q ∈ R^{dmodel×dk}]`, `[q · k]`).
- lowLatency: the run is the span plus the Korean particle the engine attached (`[√dk로 ]`, `[dk의]`, `[h = 8개의 ]`,
  `[LayerNorm(x + Sublayer(x))입니다.]`), and once whitespace was normalised (`q·k`). The span is the run's prefix after
  whitespace normalisation; the rest is translated text.
- Grammar stays natural (the engine sees the span text), unlike placeholders.

Measured next with words (round apple-spans, 2026-10-18; the probe `glossary-spans.swift`, removed since, is at
`git show 04092b1:tools/apple-translation-probe/glossary-spans.swift`; outputs `apple-glossary-spans-*.txt`), which corrects the
above for anything the engine can translate:

- A `translate(batch:)` response has no `attributedTargetText` (nor `attributedSourceText`); only `translate(_: AttributedString)`
  returns it. A source with spans goes as its own request; at once with the others it costs the same wall time as the batch
  (high fidelity 18.4-18.9 s against 17.9-19.2 s for 20 lines), one after another 1.2 times (low latency) to 1.5 times (high fidelity).
- `skipsTranslation` is ignored for words by the language pack: the marker comes back on the engine's own rendering plus the
  particle it attached ("토큰으로", "데이터 세트에는"). High fidelity honours it, but writes pieces of its own rendering beside the
  forced word in 11 of 20 lines ("손실실은", "데이터데이터셋에는", "인encoder") and drops particles ("알드릭 홀로"). Symbols were
  never affected (nothing to translate), so the six paper sentences above were not a test of it.
- So a glossary term gets a marker and no skip: the run is the engine's rendering, and the glossary target replaces the word
  before the particle. 33 terms in 20 lines: honoured 33/33 in both strategies (post-hoc `applyGlossary`: 25 and 23, nearly all
  because the engine chose the same word). The particle the engine chose for its own word was wrong for the target 3 of 22 times
  (low latency) and 5 of 20 (high fidelity); a rule that fitted it to the target's last sound left 0 wrong.
- Dropped (1.1.2). It worked, but only by patching the engine's output. Where the engine's word ends was guessed: a rendering
  that ends like a particle was cut inside the word (20 of 41 wrong with the language pack, 18 with Apple Intelligence; a lookup
  of the engine's own word brought both to 3, `apple-glossary-words-{before,after}-*.txt`), and outside Korean the marked path
  applied 1 (ja) and 4 (zh) of 14 terms with Apple Intelligence, 12 and 13 with the lookup, the plain path 1 and 3
  (`apple-glossary-{ja,zh}-{before,after}-highfidelity.txt`). The Korean particle was redone on top. Apple Translation takes no
  term constraint, so that patching was the whole feature. The glossary engine is Foundation Models ("용어집 우선"), and glossary
  terms already feed OCR's custom words. The glossary spans, `KoreanParticle` and the probe are removed (history: f35e079, bc187b8,
  its revert 04092b1); `ProtectedSpans` keeps formulas.

This is Apple's equivalent of DeepL's `tag_handling=xml` + `ignore_tags` ("placeholder tags are placed next to the
translation of the words that precede or follow them", developers.deepl.com/docs/translate/translating-xml), and of the
learned tag placement that Hanneman & Dinu (WMT 2020, "How Should Markup Tags Be Translated?") found better than
detag-and-project.

## 5. Plan

1. Round `paper-quality` (running): paper bench; formula line misses; body font cap; lens-edge lines; "…" when clipped;
   math-dominated blocks kept as written.
2. Inline math as original pixels: mark each inline math span (`isFormula`-style scan over the block's text) with
   `skipsTranslation` + a marker attribute; find it in `attributedTargetText`; draw the translation with the span's
   original image (cropped from the frame by `VNRecognizedText.boundingBox(for:)`) as an inline attachment scaled to the
   text size. Fallback to text when a span does not come back exactly once. DeepL: `<m>` + `ignore_tags`; OpenAI-
   compatible engines: the same tags with an instruction, checked once each. Requires macOS 26.4 for Apple; earlier: text.
3. Same mechanism, other uses: protect URLs, code and names instead of `restoreSourceTokens`. (Glossary terms in Apple
   Translation were tried with it and dropped, §4; `applyGlossary` stays as the post-hoc replacement.)
4. Later: a page-image regression set beyond one paper (DoTA, IBEM pages); "…" with the full text on hover.
