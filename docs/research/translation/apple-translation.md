# research-apple: what can improve Apple Translation (default engine) on screen text
Round research-apple, 2026-10-18. Machine: macOS 27.0 (26A428), SDK MacOSX27.0.sdk. Probes in /tmp/research-apple/ (predictions.txt written before runs; ctx.swift, d/main.swift, s/main.swift; outputs ll.txt hf.txt dll.txt dhf.txt sll.txt shf.txt). Repo and user's app untouched. zh lowLatency pack is not installed on this Mac: I did not download it, so zh ll is not measured (zh hf is).

## 1. API surface (primary source: the SDK swiftinterface; developer.apple.com pages are JS-rendered and WebFetch returned only the title)
File: /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/Translation.framework/Versions/A/Modules/Translation.swiftmodule/arm64e-apple-macos.swiftinterface (201 lines, read whole).
- Session: `public func translate(_ string: Swift::String) async throws`, `translate(_ string: AttributedString)` (26.4), `translate(batch:)`, `translations(from:)`, `prepareTranslation()`, `cancel()`, `init(installedSource:target:preferredStrategy:)`.
- `Strategy`: only `.highFidelity`, `.lowLatency`.
- `Request`: `sourceText`, `attributedSourceText`, `clientIdentifier`. `Response`: `targetText`, `attributedTargetText`, `clientIdentifier`.
- The ONLY attribute scope: `public let skipsTranslation: ...SkipTranslationAttribute` (Value = Bool).
- No formality, honorific, domain, context, glossary or custom-vocabulary parameter exists anywhere in the interface (`grep` of all 201 lines: the words formality/context/glossary/domain/vocabulary do not occur as API; `LanguageAvailability` has `status(from:to:)`, `status(for:to:)`, `supportedLanguages`, `preferredStrategy`).
- Errors seen in probe: `TranslationError(cause: ...notInstalled...)` for the missing zh pack.
- 27 SDK has the same surface as 26.4 (paper-translation.md §4 recorded the 26.4 additions). No 27-only addition found.
- Therefore the answer to Q1: no hook. Only tricks: attributes (skip), what we put in the text, which strategy.

## 2. Context by concatenation (measured)
Cases: 30 pairs (prev line, current line with a dropped subject/pronoun/honorific): 10 ja, 10 zh, 10 en, target ko. Variants: A current alone; B "prev\ncur" with cur marked by a link attribute and extracted by run; C same with prev skipsTranslation; D "prev cur" in ONE segment (space-joined, none for CJK), cur marked, extracted by run.
Predictions (predictions.txt): ll sentence-wise, no effect; hf differs 40-70 %, improved 30-50 %, extraction 60-90 %.

Measured:
- Extraction: marker run found 30/30 in hf (B, C, D), 20/20 in ll (ja, en). So link-attribute runs survive in attributed single requests (consistent with the existing marked-request path). But in D two hf outputs bled the previous line into the run: "있습니다마법사에게는 강력하게 타격합니다." (#27) and "있어요깨우지 마세요." (#28) (dhf.txt). Bleed 2/30 = 7 %, silent (no failure signal).
- B and C, "\n" separator: cur output == A in 20/20 ll and 30/30 hf. The newline starts a new segment; the engine translates segments independently, so context is cut. Also `full=` shows the output keeps the line break (⏎⏎), i.e. segments are separate.
- C: hf honours skipsTranslation on a whole sentence (prev stays in source language: "田中さんは昨日会議に遅れた。⏎⏎사과하러 왔다."); ll ignores it and translates prev anyway (hf.txt vs ll.txt). So skip on prev is no way to hide it in ll.
- D (same segment):
  - ll: cur == A in 20/20 (ja, en). The pack translates sentence by sentence even inside a segment; context has zero effect.
  - hf: cur differs from A in 18/30; 12/30 identical. My read of the 18: better 5 (#3 丁寧に: "꼼꼼하게 ... 주었다" -> "정중하게 ... 주셨다"; #13 teacher honorific "말씀하셨어요"; #17 "가는다고" ungrammatical -> "갈 거라고"; #21 "싶어 해요" third person; #29 "플레이했어요"->"틀어봤어"), worse 3 (#20 subject "그는" lost; #27, #28 bleed), neutral 10 (mostly register 다/요 flips). Noise floor: the same line translated twice in hf and ll is identical 5/5, so the diffs are caused by the context, not randomness.
  - The target use case, a dropped subject resolved from the previous line: 0 of the ja/zh dropped-subject cases (#0, #1, #6, #9, #10, #17...) gained an explicit subject or pronoun. The gains are lexical and honorific, not pronoun grounding.
  - Latency hf: B/D about 1.2-2.0 s vs A 0.5-1.1 s median 1.04 s (hf.txt); roughly 1.5-2x. ll: 40-60 ms vs 25-35 ms (still small, but no gain).
- Verdict: concatenation is not worth it. ll (the default for ja/en/zh on most Macs) ignores it completely; hf gains about 5/30 and loses about 3/30 with a silent bleed failure. The only context that works inside Apple Translation is context inside ONE paragraph (see S4), which the app already sends.

## 3. Input shaping (measured; sll.txt, shf.txt)
- S1 wrapped OCR lines of one sentence, per line vs joined with a space vs joined with newline (5 sources en/ja):
  - per line and newline give the same garbage in both strategies, e.g. ll "The model is trained on a large" -> "모델은 큰 것에 대해 훈련됩니다.", "corpus of text and then fine-tuned" -> "텍스트 코퍼스와 그 후 미세 조정된", vs joined: "모델은 방대한 텍스트 코퍼스에서 학습된 후 특정 하위 작업에 맞게 미세 조정됩니다."
  - "Click the button in the upper right / corner of the window ..." per line -> "창문의 모서리를 열어 주세요" (wrong), joined -> "창 오른쪽 상단에 있는 버튼을 클릭하여 설정 패널을 엽니다."
  - joined also faster: ll 52 vs 98 ms; hf 1.4 vs 2.5 s (sum of three requests).
  - Prediction was joined better in >= 60 %; measured 5/5 in both strategies.
  - The app already joins lines with a space in `TextRecognizer.makeBlock` (App/Pipeline/TextRecognizer.swift:624-634: `text += last == "-" ? "" : " "`) and CJK lines with nothing. So this is confirmed as a keep, and a regression gate: never send a wrapped paragraph with "\n" (segments split).
- S2 hyphenation. Raw "trans-\nlation" (newline kept) -> garbage in both ("우리는 trans-를 사용합니다.⏎⏎평가를 위한 레이션 모델"). "trans- lation" with a space and the repaired word gave identical translations in ll (4/4) and equal in hf except "Pre-/trained": hyphen+space "사전 훈련된" vs repaired "예비 훈련된" (hf repaired was worse once). The app's join (`makeBlock`) turns "trans-"+"lation" into "trans-lation" (no space). Probed exactly that form (/tmp/research-apple/h/main.swift): ll and hf both translate "trans-lation", "atten-tion", "net-work", "rele-vant", "Pre-trained" correctly, same as the repaired text (ll 4/4 identical to repaired; hf same). So the current join needs no dehyphenation change.
- S3 explicit source vs auto: not measurable in a script. `TranslationSession(installedSource:target:)` needs an explicit installed source (swiftinterface lines 188-190); auto-detect needs the SwiftUI `.translationTask` configuration with `source: nil`, which shows system UI. The app already passes an explicit source (TranslationService.swift:585-615). Nothing to do.
- S4 long paragraph, six English sentences, whole vs per sentence:
  - hf whole 6.1 s vs per sentence 14.3 s (sum); whole is better in quality: "position" -> "위치" (per sentence "부서", wrong), "weights" -> "가중치" (per sentence "무게"), consistent terms. That is context inside a single segment working.
  - ll whole 235 ms vs per sentence 285 ms, same text. Batch of 6 requests: 238 ms (ll), 6.1 s (hf): batch is not parallel in hf; it equals the sum, same as whole.
  - Conclusion: send a paragraph as ONE string; do not split into sentences for hf; no truncation seen at 6 sentences (about 370 characters). Longer than that not probed.

## 4. Memory for Apple Translation
- Names kept in source: `skipsTranslation` span. Measured earlier (paper-translation.md §4): hf honours it but writes pieces of its own rendering beside the word in 11/20 lines; ll ignores it for words and honours it only for symbols. My C probe confirms hf honours a whole sentence, ll does not. So names-by-skip: only reliable for symbols/formulas (as shipped), not as memory for names.
- Names/terms forced via pre-insertion (the parked patch): gates in ~/.cache/mwoyeo-gates/glossary-preinsert/ measured ll 88/88 and hf 98/102 with 0 particle errors (as given in the spec; I did not re-run). It places the target word into the SOURCE sentence and lets the engine inflect it, so no output patching and no particle guessing. This is different from the dropped version (which swapped words in the output and guessed where the engine's word ended). I found nothing in the API surface that is a better hook, so pre-insertion remains the only term constraint for Apple Translation. FOR THE LEAD TO BRING TO THE USER: the dropped feature failed because of output patching; pre-insertion measured clean, but the user's reason ("why is a glossary needed here at all; Foundation Models already serves it") still stands. Pre-insertion would also lock the chosen word for names/terms across a document with zero extra latency, which Foundation Models does at 4k window cost. It is the user's call.
- Pronoun/honorific hints: none exist; the concatenation probe shows ll cannot use them and hf only partly (section 2). Say so in the UI docs: Apple Translation has no memory.
- Post-edit risks: any output patching (glossary swap, particle rules) guesses word ends: 20/41 wrong with ll before the lookup (paper-translation.md §4). Pre-insertion avoids it.

## 5. Hybrid: Apple first, Foundation Models (on device) post-edits flagged lines only
- Evidence for the risk: research-method-A.md line 21: WMT25 QE-informed retranslation https://arxiv.org/html/2511.13884v1 "APE systems are still known to overcorrect the output of Machine Translation (MT), leading to a degradation in performance."; masked correction avg -0.0108 vs retranslation +0.0201. research-ctx-B.md line 24: "WMT25 paper [S]: LLM post-editors over-correct."
- Gate idea from research-method-A.md line 57: second pass only where a cheap gate fires (a memory entry applies, Apple-vs-LLM disagreement, low OCR confidence). Gain is large only for weak drafts; overcorrection on good drafts.
- Cost: I did not measure Foundation Models latency in this round (the app already has that engine; its 4k window is the limit). [unmeasured]. Retranslating with Foundation Models rather than post-editing the Apple text is the safer form (retranslation won in the WMT25 numbers), and that is exactly the existing "Foundation Models engine" choice, so this hybrid adds routing, not a new engine.

## 6. Ranked improvement points
| # | Point | Expected gain | Evidence | Size | Risk |
|---|---|---|---|---|---|
| 1 | Keep paragraphs as ONE string with spaces; add a gate that fails on "\n"-joined or per-line sends (also for hf: do not sentence-split) | Prevents garbage translations of wrapped text; hf whole paragraph is 2.3x faster and better terminology than per sentence | S1 5/5 joined better both engines; S4 hf 6.1 s vs 14.3 s | tiny (a gate; code already joins) | none |
| 2 | Pre-insertion of glossary/name targets into the source (parked) | The only term constraint Apple takes; 0 particle errors measured | glossary-preinsert gates.txt ll 88/88, hf 98/102 (spec) | already built as a patch (glossary-root.patch) | user already rejected the output-patch version; needs the user's decision |
| 3 | Route lines the user cares about (a glossary/memory entry applies, or detected dropped subject) to Foundation Models / LLM retranslation instead of post-editing Apple | Quality where Apple has no hook | WMT25 retranslation > masked correction (method-A) | medium (routing + gate) | latency for those lines; no evidence of benefit for short UI lines |
| 4 | Concatenated context (prev line + cur, extract by run) | hf only: about +5/30 better, -3/30 worse | D probe; ll 0/20 changed | small-medium | silent run bleed 2/30; 1.5-2x latency; REJECT |
| 5 | skipsTranslation for names | none for ll (ignored), hf garbles words 11/20 | paper-translation.md §4; C probe | small | REJECT; formulas only (shipped) |
| 6 | Explicit source / hyphen repair beyond the current join | none: current join output translates fine | S2, h probe, S3 | n/a | none |

First to implement: 1 (a gate only, it protects what exists), then the user's decision on 2. Do not implement 4 or 5.

## 7. Places outside the assignment where improvement looked possible
- TranslationService.swift:631: `translate(batch:)` is sequential in hf (6 requests 6.1 s = whole-paragraph time); for hf paragraphs of one block the app sends one request per block already, so nothing to do, but a multi-block lens gets no hf parallelism from batch (measured 18 s for 20 lines in paper-translation.md). Check whether concurrent single requests help (only the marked path uses a task group). Report only; size small; unmeasured.

DONE-research-apple
