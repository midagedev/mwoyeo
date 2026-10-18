# Research: document / in-image translation for Mwoyeo (label research-doc-mt, 2026-10-18)

Quote rule: each quote was copied from a WebFetch of the URL. The fetch tool's summarizer truncates long sentences, so some quotes are sentence fragments. They are exact. UNVERIFIED = not fetched, or only seen in search snippets.
"Use for Mwoyeo" assumes on-device, real-time, image-only input (no PDF text layer).

## A. In-image / document image machine translation

A1. Towards End-to-End In-Image Neural Machine Translation. Mansimov, Stern, Chen, Firat, Uszkoreit, Jain. 2020. EMNLP NLP Beyond Text workshop (oral). https://arxiv.org/abs/2010.10648
- First end-to-end image-to-image translation model (rendered text image in, translated text image out).
- Quote: "We propose an end-to-end neural model for this task inspired by recent approaches to neural machine translation"
- Use for Mwoyeo: not applicable as a model (synthetic rendered text, no layout). Value is the framing: the cascade OCR -> MT -> render that Mwoyeo already uses is the accepted baseline.

A2. Translatotron-V(ison): An End-to-End Model for In-Image Machine Translation. Lan, Niu, Meng, Zhou, Zhang, Su. 2024. ACL 2024 Findings. https://arxiv.org/abs/2407.02894
- End-to-end IIMT model. Abstract names two challenges of end-to-end models (translation quality vs. background/style preservation).
- Quote: "Thus, constructing end-to-end models has become an option, which, however, faces two main challenges"
- Use for Mwoyeo: not applicable (heavy generative model, no latency fit). Confirms cascade pipelines are the practical choice; its failure modes (style/background loss) are what Mwoyeo's erase+draw step must avoid.

A3. Document Image Machine Translation with Dynamic Multi-pre-trained Models Assembling (DIMTDA, DoTA dataset). Liang, Zhang, Ma, Zhang, Zhao, Xiang, Zong, Zhou. 2024. NAACL 2024 long, pp. 7084-7095. https://aclanthology.org/2024.naacl-long.392 ; code https://github.com/liangyupu/DIMTDA
- Task "DIMT2Markdown": whole document image (arXiv pages, 126K image-translation pairs in DoTA) to translated Markdown, using a dynamic assembler of several pre-trained models.
- Quote: UNVERIFIED (ACL page fetch failed with socket hang up; facts above are from search snippets).
- Use for Mwoyeo: not applicable as a model (page-level seq2seq, seconds per page). DoTA is useful as a free corpus of arXiv page images with math, to build a regression set for the formula filter.

A4. IMTBench: A Multi-Scenario Cross-Modal Collaborative Evaluation Benchmark for In-Image Machine Translation. Lyu, Fu, Li, Zeng, Zhang, Yang, Ma, Zhou, Luo, Luan. 2026. https://arxiv.org/abs/2603.10495
- 2,500 samples, 4 scenarios, 9 languages. Scores translation accuracy, background preservation, visual quality, and whether the text rendered in the image matches the translation.
- Quote: "existing IIMT benchmarks are largely synthetic and thus fail to reflect real-world complexity"
- Use for Mwoyeo: its four axes map to a gate: translation text equals drawn text, background kept, no overflow. Reuse the "rendered text matches translation" check as an OCR round-trip of Mwoyeo's own output.

A5. PRIM / VisTrans (EMNLP 2025 main; model card https://huggingface.co/yztian/VisTrans/blob/main/README.md). Authors and arXiv ID not found.
- Handles visual text and background separately, two-stage training. Tested on MTedIIMT, PRIM, IIMT30k.
- Quote: UNVERIFIED (seen only in search snippet; model card not fetched).
- Use for Mwoyeo: not applicable (generative model). Same lesson as A2.

A6. manga-image-translator. zyddnys and contributors, open source. https://github.com/zyddnys/manga-image-translator
- Pipeline of detector, OCR, translator, inpainter (e.g. lama_large), renderer.
- Quote: "The text rendering area is determined by the detected text, not the bubbles."
- Use for Mwoyeo: closest open-source analogue of erase+draw in place. Its default is "render inside the detected text box", with an alternative that fits the enclosing container. Mwoyeo's equivalent: fit into the paragraph box, allow growth only into verified empty space.

## B. Scientific document translation preserving layout and math

B1. PDFMathTranslate: Scientific Document Translation Preserving Layouts. Ouyang, Chu, Xin, Ma. 2025. EMNLP 2025 System Demonstrations. https://arxiv.org/abs/2507.03009 ; code https://github.com/Byaidu/PDFMathTranslate
- Layout detection (DocLayout-YOLO) -> translate -> re-render. Formulas, figures, tables and standalone formulas are left untouched. Non-OCR mode uses PDF text positions with "font and character formula safeguards" (rules on font names and characters).
- Quote (paper): "the translated text and previously detected layouts are re-rendered as a translated document with preserved layouts."
- Quote (README): "Preserve formulas, charts, table of contents, and annotations."
- Use for Mwoyeo: the safeguard idea is the key one, but Mwoyeo has no font names. Image-only analogue: character-class and geometry rules (see C3). The paper does not explain placeholder mechanics (the fetch showed none).

B2. BabelDOC: Better Layout-Preserving PDF Translation via Intermediate Representation. 2026. ACL 2026 demo. https://arxiv.org/abs/2605.10845 ; code https://github.com/funstory-ai/BabelDOC
- Separates layout metadata from text. Formula placeholdering is an IR operation. An "adaptive typesetting engine" fits translated text back. Evaluated on a 200-page benchmark (papers, docs, patents) by humans and an LLM judge on layout fidelity, aesthetics, terminology consistency, against DeepL Document Translation and PDFMathTranslate.
- Quote (paper): "The translated content is then re-anchored to the original layout through an adaptive typesetting engine."
- Quote (README): "PDF scientific paper translation and bilingual comparison library."
- Use for Mwoyeo: the README exposes `--formular-font-pattern`, `--formular-char-pattern` (formula detection by font/char) and `--add-formula-placehold-hint`, which it says is "not recommended" because it can hurt translation quality. So: skip formula-in-sentence placeholders for the cheap path; skip the paragraph instead. The LLM-judge setup is reusable for a vision verdict on overflow.

B3. Nougat: Neural Optical Understanding for Academic Documents. Blecher, Cucurull, Scialom, Stojnic. 2023. arXiv. https://arxiv.org/abs/2308.13418
- Page image -> LaTeX-like markup, formulas included, with a vision transformer.
- Quote: "We release the models and code to accelerate future work on scientific text recognition."
- Use for Mwoyeo: not applicable at real-time (page-level autoregressive decoder, hundreds of ms to seconds per page on GPU, no Apple Neural Engine path). Could only serve as an offline oracle to label a formula test set.

B4. MinerU: An Open-Source Solution for Precise Document Content Extraction. Wang, Xu, Zhao, Ouyang, et al. 2024. arXiv technical report. https://arxiv.org/abs/2409.18839
- Pipeline of layout detection, formula detection and recognition (UniMERNet), table recognition, reading order.
- Quote: "To address these challenges, we present MinerU, an open-source solution for high-precision document content extraction."
- Use for Mwoyeo: confirms the standard design: detect formula regions first, then skip them. No inline-formula rules cited in what was fetched.

B5. DocLayout-YOLO. Zhao, Kang, Wang, He. 2024. arXiv. https://arxiv.org/abs/2410.12628 ; code https://github.com/opendatalab/DocLayout-YOLO
- YOLO-v10 based layout detector; PDFMathTranslate uses it. License AGPL-3.0 (README sidebar). Model sizes and latency not stated in README.
- Quote (paper): "Extensive experiments on downstream datasets demonstrate that DocLayout-YOLO excels in both speed and accuracy."
- Quote (README): "We present DocLayout-YOLO, a real-time and robust layout detection model for diverse documents, based on YOLO-v10."
- Use for Mwoyeo: a candidate for a CoreML formula/figure region detector, with two caveats: AGPL conflicts with App Store distribution (needs a license check or retrain on a permissive dataset), and it detects only display formulas (isolated), not inline ones (class list not confirmed from README; verify).

B6. LaTeXTrans: Structured LaTeX Translation with Multi-Agent Coordination. Zhu, Wang, Xv, Xing, Huo, Tian, Du, Yang, Zhang, Xiao, Zhu. 2025. https://arxiv.org/abs/2508.18791
- Placeholder substitution: LaTeX commands/environments are replaced before translation and restored after.
- Quote: "LaTeXTrans ensures format preservation, structural fidelity, and terminology consistency through six specialized agents:"
- Use for Mwoyeo: source-level only, not applicable to images. Technique relevant to DeepL/OpenAI paths: DeepL supports XML tag handling (`tag_handling`, `ignore_tags`) which achieves the same effect. Not fetched here; check DeepL docs before relying on it.

B7. English to Arabic machine translation of mathematical documents. Eddahibi, Mensouri. 2023. https://arxiv.org/abs/2312.03753
- Expressions are extracted and replaced by indexed tokens (Expr1, Expr2), restored by index after translation (from search snippet).
- Quote: "a rule-based translator for Arabic mathematical expressions" (the only abstract text the fetch returned; it does not itself describe the token scheme).
- Use for Mwoyeo: the indexed-token pattern is the safest for an engine that returns free text. Apple Translation may mangle tokens, so test with letter-digit tokens and verify all tokens survive; fall back to dropping the paragraph.

## C. Math formula detection / recognition in page images

C1. ScanSSD: Scanning Single Shot Detector for Mathematical Formulas in PDF Document Images. Mali, Kukkadapu, Mahdavi, Zanibbi. 2020. arXiv. https://arxiv.org/abs/2003.08005
- Visual-only detector for display and embedded (in-line) formulas, run on 600 dpi pages with sliding windows.
- Quote: "uses only visual features for detection" (fetch summary of the abstract; exact wording of the full sentence not confirmed).
- Use for Mwoyeo: SSD is small, but 600 dpi windowed scanning is too slow for a live lens, and screen text is far below 600 dpi. Reported errors (splitting at wide gaps, merging neighbouring lines) say a detector alone is not enough.

C2. UniMERNet: A Universal Network for Real-World Mathematical Expression Recognition. Wang, Gu, Liang, Xu, Zhang, Shi, He. 2024. arXiv. https://arxiv.org/abs/2404.15254 ; code https://github.com/opendatalab/UniMERNet
- Recognizes cropped formula images to LaTeX. README download sizes: base 1.3 GB, small 773 MB, tiny 441 MB. No latency numbers.
- Quote: "The paper introduces the UniMER dataset, marking the first study on Mathematical Expression Recognition (MER)"
- Use for Mwoyeo: recognition is not needed (we only need to skip formulas). Too big for an app bundle. Not applicable.

C3. ICDAR 2021 Mathematical Formula Detection (IBEM dataset, 1st place solution). https://arxiv.org/abs/2107.05534 ; dataset https://zenodo.org/records/4757865
- IBEM: about 600 documents, 8,000+ pages, 29,596 displayed and 137,095 inline expressions. The 1st-place paper reports 58,834 isolated and 260,323 embedded expressions in its training data.
- Quote: UNVERIFIED (known only from search snippets).
- Use for Mwoyeo: the inline-to-display ratio (about 4.6:1) says the common case is inline, so a display-formula detector alone fixes a minority. Dataset gives ground-truth boxes to measure a heuristic's recall without a model. Search snippets also said inline formulas stay hard for detectors.

C4. Cheap heuristics (no source found; our own proposal, not a citation). The search found no paper on hand-crafted inline-vs-display rules. Candidates to test on IBEM/DoTA:
- Line-level non-prose score: fraction of OCR characters that are not letters of the target script (digits, Greek, operators, brackets, sub/superscript glyphs), plus Vision confidence dips and mixed-script runs (the Cyrillic misread of a radical sign is a signal, not noise).
- Short-fragment rule: a block of 1-3 characters, or a block with no word of 3+ letters, sitting between prose lines at a different baseline or x-offset, is math debris.
- Geometry: display formulas are centered with large left and right margins and a trailing equation number "(1)". Inline pieces have a line height or baseline different from the line's median.
- Use for Mwoyeo: fastest to ship, no model, runs on the OCR output already in hand. Validate against IBEM boxes.

## D. Fitting translated text and evaluation

D1. ForMaT: Dataset for Visually-Grounded Multilingual PDF Translation (Format-Preserving Multilingual Translation). Ciesiolka, Wisniewski, Charkiewicz, Guttmann. 2026. EAMT 2026, pp. 143-157. https://aclanthology.org/2026.eamt-1.12/
- 3,956 PDFs, 15 language pairs, layout metadata kept. Authors report MT systems struggle with spatial grounding.
- Quote: "We present ForMaT (Format-Preserving Multilingual Translation), a parallel corpus of 3,956 PDFs across 15 language pairs"
- Use for Mwoyeo: source of real length-expansion ratios per language pair (EN to KO vs. EN to DE etc.) to set font-scale limits from data.

D2. M3T: A New Benchmark Dataset for Multi-Modal Document-Level Machine Translation. 2024. https://arxiv.org/html/2406.08255v1
- Benchmark for semi-structured documents. Shows OCR without layout scrambles reading order.
- Quote: UNVERIFIED (only seen in search snippet).
- Use for Mwoyeo: justifies two-column paragraph grouping before translation; a test case for column order.

D3. Font fitting evidence from the tools above. BabelDOC calls its fitter an "adaptive typesetting engine" but neither the abstract nor the README gives the algorithm. manga-image-translator fits to the detected text region by default. No paper found that defines an overflow metric. Our proposed metrics (not from literature): overflow area ratio (drawn glyph pixels outside the source box and not on verified background), pairwise overlap IoU between drawn paragraphs, and min font scale versus the source line height.

## Top 5 ideas for Mwoyeo (value / effort)

1. Non-prose scoring filter on OCR lines (C4): non-target-script character fraction, short-fragment and baseline-offset rules, trailing equation-number and centred-line geometry. Skip translating and skip erasing those blocks. Source: PDFMathTranslate font/char safeguards (B1), BabelDOC formula-char-pattern (B2), IBEM stats (C3) for validation. Effort low, fixes problem 1 at once.
2. Group a flagged formula fragment with its neighbours as one untouched region: if a paragraph contains a math line in the middle, keep the whole block out of the erase mask. Source: PDFMathTranslate "left untouched" behaviour (B1). Effort low.
3. Inline formulas inside a prose sentence: use indexed tokens (Expr1...) or skip the sentence; do not rely on prompt hints, since BabelDOC says its placeholder hint can hurt quality. Source: B7, B2, B6. Effort medium; test token survival per engine first.
4. Overflow handling: fit to the source paragraph box, shrink font to a floor, then truncate or hold the original; never grow into non-verified space. Draw paragraphs in reading order with a collision check against already drawn boxes. Source: manga-image-translator (A6), BabelDOC adaptive typesetting (B2). Effort medium, fixes problem 2.
5. Regression set and metrics: build a page-image set from DoTA/IBEM (A3, C3) with formula boxes, and score formula recall of the filter, overflow ratio and overlap IoU, plus an LLM/vision judge on layout fidelity as BabelDOC did (B2, A4). Effort medium, needed to prevent recurrence.

Deferred: a CoreML display-formula detector based on DocLayout-YOLO (B5). Blocked by AGPL-3.0 and an unverified class list; revisit only if idea 1 recall on IBEM is below the bar.
