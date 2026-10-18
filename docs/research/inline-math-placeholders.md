# Inline-math placeholders through Apple Translation (en->ko), 2026-10-18 (raw JSON was in /tmp/inline-math and is not kept)

Tool: tools/apple-translation-probe/batch.swift (was /tmp/inline-math/main.swift, binary ./tr) uses TranslationSession(installedSource:target:preferredStrategy:) batch, same as TranslationService.swift:617. Runs outside an app. ll = lowLatency pack, hf = highFidelity.
Data: 12 clean paper sentences (sents.json; r3-r6.out hold only ~6 math lines, so sentences were rebuilt from the paper text in OCR style), plus 10 OCR-garbled / harder sentences (sents.json.ocr), plus 4 paragraph/fragment probes (p.json). Span rule: spans.py. DeepL skipped (needs key).
Raw: all_ll.json, all_hf.json, all_ll_ocr.json, scored_*.json (restored outputs), p_ll.json, p_hf.json.

## Table 1: placeholder survival (clean 12 sentences, 24 spans)
| form | ll once | hf once | notes |
|---|---|---|---|
| {n} | 24/24 | 24/24 | sentence 3 (ll) dropped "dot product attention" |
| [n] | 24/24 | 24/24 | |
| Xn | 24/24 | 24/24 | |
| ⟨n⟩ | 24/24 | 24/24 | |
| <mn/> | 24/24 | 24/24 | best content fidelity in ll sentence 3/6 |
| §n§ | 24/24 | 24/24 | |
| Zqn | 24/24 | 24/24 | sometimes drops counter word (N=6 -> "Zq1의 층") |
Survival does not separate the forms. Restoring the original spans into the Korean gave the exact symbols in every case (string replace, 84/84 per strategy).

## Table 2: the control that matters (no placeholders, text as is)
- Clean Unicode input, 24 spans: ll kept 22/24 verbatim, hf 23/24. Failures: sentence-initial capital ("Dk", "Dmodel-차원"), and "q · k" respaced to "q·k".
- The 4 W_i^Q ∈ R^{dmodel×dk} matrices come back unchanged in ll and hf, alone, in a paragraph, with or without final period.
- OCR-garbled input ("WQ € IR dmodel×dk", "W; ∈ R^dmodelxdk", "qiki", "β1 = 0.9"): Apple copies the garbled symbols verbatim too (see all_ll_ocr.json). Apple did NOT alter the symbols in any of 26 sentences.
=> The altered symbols in the lead's example ("WO € R dmod × dx") are very likely OCR output, not engine output. Placeholders cannot repair that: they restore the same garbled OCR text.

## Word order / reading (my judgement, 12 per form, ll)
- All 7 forms read as normal Korean sentences in 12/12. Differences are small and noisy (engine non-determinism between runs of similar input).
- Costs of any placeholder: (1) Korean particles are chosen for the placeholder's last character, not the span: "{1}으로" vs "1/√dk로", "X1은", "Zq2를"; wrong about 1 in 4 times. (2) content drops: ll {n} sentence 3 lost "dot product attention"; Zqn dropped a counter ("Zq1의 동일한 층"). (3) A bare placeholder removes the cue that it is a number, so "h = 8개의" became "{1}개의" (fine) but "N = 6개" became "Zq1의" (lost 개 in one form).
- hf mistranslates a sentence fragment starting "Where the projections..." as "추정치가 ... 인 곳" with or without placeholders; not a placeholder effect.

## Table 3: span detection is the weak point
spans.py (token rule) is exact on clean text but on garbled OCR it cut spans wrongly: "W;" split, "= 0.9" without "β1", "lrate =" left outside, "R dmodel×dv" without "W9 ∈". The leftover half is still sent to the engine and still translated around the placeholder ("{3}와 함께 변동되었습니다"). Sentences with no detected span were identical to as-is (safe). A bad span is worse than no placeholder.

## Recommendation
1. Do not protect by default. Apple (ll and hf) preserves well-formed math verbatim; placeholders add particle and drop risk for no gain.
2. Add a cheap post-check: each detected span (whitespace-normalised, case-insensitive for sentence-initial Dk/Dmodel) must appear in the output. If all present: done. If one is missing or altered: re-translate that sentence once with its spans as `<mn/>` (or `{n}`); accept only if each placeholder appears exactly once; restore; else keep as-is output (or leave the source sentence untranslated if the as-is output also fails the check and the sentence is mostly math).
3. Protect only confident spans: contain one of = ∈ × ^ _ √ or a dk/dmodel/dff token, balanced as a whole expression. If the OCR line looks garbled (€ for ∈, "IR", digits fused to letters), do not protect: leave the whole sentence untranslated or translate as is; placeholders only hide the garbling.
4. Form: `<mn/>` (XML-like also fits DeepL tag_handling, untested), fallback `Zqn` for engines that treat tags badly. Particle fix after restore: re-derive 은/는, 이/가, 을/를, 으로/로 from the span's last glyph only for pure ASCII-letter ends; skip for symbols.
5. Real fix for the shown example lies in OCR (dk read as dx, ∈ as €), not translation: try an OCR-side math-line detector before translating.
6. Caveat: 12+10 sentences, one run each, engine output may vary run to run.
