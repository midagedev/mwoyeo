# Research: existing math/code/prose detectors for a screen-translation lens (2026-10-19)

Marks: [V] verbatim from a fetched source, [S] search snippet only, [U] my inference or memory. "Not fetched" means I did not verify it.

## 1. Table

| name | detects | input | params / MB | license code / weights | MAS-usable? | Core ML path | notes |
|---|---|---|---|---|---|---|---|
| PDF-Extract-Kit MFD (YOLOv8_ft) | inline + block formulas | pixels (page image) | `yolo_v8_ft.pt` 349,867,002 B [V HF tree] | AGPL-3.0 repo / HF repo has no license field [V] | NO (AGPL) | ultralytics export, but AGPL blocks it | trained on CN+EN pages only [V README:70] |
| DocLayout-YOLO DocStructBench | layout incl. formula classes [U: isolate_formula, formula_caption] | pixels | 40,709,302 B `.pt` [V HF tree] | AGPL-3.0 code [V LICENSE] / HF card `apache-2.0` [V API] | NO for code; weights card says Apache but they are trained with the AGPL YOLOv10 code, legal risk [U] | BabelDOC runs it as ONNX, with a fixed 1024x1024 CoreML-provider path | no code class |
| MinerU | pipeline (layout + MFD + MFR) | pixels | n/a | Apache-2.0 + extra terms (no license needed below 100M MAU / USD 20M monthly revenue; online services must attribute) [V] | code yes; models inside are mixed (see PEK) | n/a | pipeline, not a small model |
| UniMERNet | formula recognition (image -> LaTeX), not detection | pixels | `pytorch_model.bin` (size not fetched) | Apache-2.0 [V LICENSE head] | yes (license) | heavy encoder-decoder, not a detector | irrelevant as detector |
| ScanSSD | math detection in page images | pixels | n/a | MIT [V] | yes (license) | PyTorch 1.1 / CUDA 9 era [V README:5]; SSD, convertible [U] | academic, English LaTeX pages; datasets (TFD-ICDAR2019) license not checked |
| IBEM dataset | math training data | pixels | - | not checked | ? | - | not verified |
| PP-DocLayout-S (PaddleOCR) | 23 classes incl. algorithm + formula | pixels | 4.834 MB, mAP50 70.9, CPU 11.54 ms [V doc table]; inference.pdiparams 4,804,904 B [V HF] | Apache-2.0 repo [V]; HF card `apache-2.0` [V API] | YES | Paddle -> ONNX -> coremltools [U] | classes: "算法、公式、公式编号" [V]. Pages (papers, books), not screens |
| PP-DocLayout_plus-L | 20 classes incl. algorithm + formula | pixels | pdiparams 129 MB [V HF] | Apache-2.0 | YES | as above | too big for a lens |
| PP-DocLayoutV2 | layout + reading order (RT-DETR) | pixels | model.safetensors 214,798,436 B [V HF tree] | Apache-2.0 [V API] | YES | transformers weights -> coremltools [U] | big |
| Surya layout (surya2) | has `Code-Block`, `Equation-Block` labels [V label.py] | pixels | not fetched | Apache-2.0 code / modified AI Pubs OpenRAIL-M weights, "free for research, personal use, and startups under $5M funding/revenue" [V README:69]; HF `surya_layout` card says cc-by-nc-sa-4.0 [V API] | NO for a paid MAS app (weights) | n/a | only mainstream model with a Code class, but license-blocked |
| DocLayNet (dataset) | 11 classes; Formula yes, Code no [U, memory, README grep did not show the class list] | pixels | 80,863 pages [V] | data: CDLA-Permissive-1.0 [V README:139] | YES as training data | - | usable as a teacher dataset for formula blocks |
| Florence-2 | general vision LM, no layout classes by default | pixels | base ~230M [U] | MIT [V HF API] | yes (license) | coremltools possible but large [U] | not a detector for this |
| LayoutLMv3 | layout / token tagging | pixels + OCR | ~125M [U] | CC BY-NC-SA 4.0 [V README:156] | NO (NC) | - | - |
| Nougat | page -> markdown with math | pixels | ~350M [U] | MIT code / CC-BY-NC weights [V README:213-215] | NO (weights NC) | - | - |
| Apple Vision RecognizeDocumentsRequest | title, paragraphs, tables, lists, barcodes, detectedData | pixels | system | Apple SDK | YES | native | NO code or math class (see below) |
| Guesslang | programming-language ID (54 languages), not "is code" | text | model 169,952 B pb + 2,698,424 B variables [V GitHub API] = about 2.8 MB | MIT [V] | YES | TensorFlow -> coremltools [U] | "accuracy higher than 90%" [V README:37]; no prose class, input is a whole file |
| kenhktsui code-natural-language-fasttext | Code vs NaturalLanguage | text | model size not fetched | MIT [V card] | YES | fastText has no Core ML path; reimplement bag-of-ngrams in Swift [U] | "~2000 doc/s with CPU", test F1 0.97 [V card]; English-heavy training [U] |
| vishnun/codenlbert-tiny | code vs natural language | text | BERT-tiny [U] | MIT [V API] | YES | transformers -> coremltools | accuracy claim only from a PR branch card [S] |
| CodeBERTa-language-id | 6 PL ID | text | ~84M [U] | apache-2.0 [V API tags] | YES | - | 6 languages only; not code-vs-prose |

## 2. How translation tools decide (all work on PDF internals, none on screen pixels)

- PDFMathTranslate (AGPL-3.0 [V LICENSE]). `pdf2zh/converter.py:197-212` `vflag()`: font name regex `r"(CM[^R]|MS.M|XY|MT|BL|RM|EU|LA|RS|LINE|LCIRCLE|TeX-|rsfs|txsy|wasy|stmary|.*Mono|.*Code|.*Ital|.*Sym|.*Math)"` [V]. `converter.py:244-252`: a char is a formula if layout class is "reserved" (cls==0), or is a superscript (size < 0.79 x previous), or has a formula font, or is a vertical font [V]. The layout class comes from a DocLayout-YOLO ONNX model. The `.*Mono|.*Code` fonts are its only "code" handling, so code is treated as formula and kept verbatim. [U]
- BabelDOC (AGPL-3.0 [V LICENSE]). `babeldoc/format/pdf/document_il/utils/formular_helper.py:16-50` `is_formulas_start_char`: unicode category `Mn/Sk/Sm/Zl/Zp/Zs/Co`, Greek range 0x370-0x400, `[0-9\[\]•]`, or a char missing from the font [V]. `formular_helper.py:111+` `is_formulas_font` has a large font-name allowlist (GlosaMath, STIXMathJax, ...) [V]. `babeldoc/docvision/doclayout.py:41` `_FIXED_IMGSZ = 1024  # fixed input size for static-shape CoreML` [V]. The paper describes "formula placeholdering" [S].
- DeepL: no formula or code detector. The caller marks it: `ignore_tags` = "comma-separated list of XML tags that indicate text not to be translated" [S, developers.deepl.com translating-xml]. Document translation internals not found.
- Immersive Translate: closed source; its PDF mode is BabelDOC-based [S]. Nothing verified about code blocks.
- Google Translate document mode: not researched.
- OCR translators: Easydict (GPL-3.0) grep over `*.m`/`*.swift` for latex/formula/code finds only Markdown rendering of results and one `LaTeX` word-split comment (`NSString+EZHandleInputText.m:219`) [V]: no formula/code skipping. LunaTranslator (GPL-3.0): grep over `*.py` for latex/formula/mathjax/公式 finds nothing relevant [V]. Bob, ScreenTranslate: not checked. [U] OCR translators translate everything.
- Apple Vision: `Vision.swiftinterface` (arm64e-apple-macos) lines 2793-2808: `Container` exposes only `title`, `text`, `paragraphs`, `barcodes`, `tables`, `lists`; `Text` has `detectedData` and `textAlignment` [V]. A grep for formula/equation/math/code near these types found nothing [V]. So Apple gives no math or code signal.

## 3. Text-only classifiers
- Code vs prose: kenhktsui fastText (MIT, F1 0.97 on its own test set, English-heavy) and codenlbert-tiny (MIT) exist. They classify whole documents, not 1-3 line OCR fragments, and have no inline-span or formula class. Guesslang identifies a language, not "code vs text".
- Math-in-text taggers and MT placeholder/terminology NER (CAT tools): no usable small model found in this round; not searched in depth. [U] CAT tools use regex placeholders (tags), which is what we have already.

## 4. Verdict
No off-the-shelf model fits. Page-image detectors (MFD, DocLayout-YOLO) are AGPL or trained on printed papers; the only permissive layout family (PP-DocLayout, Apache-2.0, S is 4.8 MB, 11.5 ms CPU) has formula/algorithm classes but works on whole pages of papers/books, not on screen UI, and gives block boxes, not inline spans. The only mainstream model with a Code class (Surya) has restricted weights. LayoutLMv3 and Nougat are non-commercial. Apple Vision marks neither code nor math. The translation tools themselves rely on PDF font names and unicode categories (BabelDOC, PDFMathTranslate) or on caller markup (DeepL), and the OCR translators do nothing, so there is no reusable OCR-side logic. Distillation of a tiny model on OCR text + word boxes (+ optional crop) is the right path. PP-DocLayout-S (Apache) is the one candidate worth a quick screen test as a block-level formula/algorithm cue, but expect low recall on screens, and it cannot do inline spans. [U]

## 5. Teachers / training data (permissive)
- DocLayout-style formula boxes: DocLayNet CDLA-Permissive-1.0 [V] (Formula class [U]).
- PP-DocLayout-S/L/V2 as pseudo-label teachers, Apache-2.0 [V]; use their output as labels only, not shipped.
- fastText code/NL classifier (MIT) and Guesslang (MIT) as weak text labelers for code vs prose.
- Own synthetic data: render LaTeX/MathJax/Code in Terminal/Xcode/VS Code/browser themes, OCR with Vision to get realistic noisy text + boxes (labels come free from the generator). This matches the Vision-noise distribution better than any paper dataset. [U]
- Avoid as teachers if the labels or weights ship: AGPL (MFD, DocLayout-YOLO), NC (LayoutLMv3, Nougat), Surya weights. Using AGPL model outputs as labels for our own model is a legal gray area; ask the user. [U]

## 6. Gaps / things not verified
IBEM license and data; Florence-2 params; Bob/ScreenTranslate; Google doc mode; DocLayNet and DocLayout-YOLO exact class lists (memory); Surya model size; CJK behavior of every model (PP-DocLayout is CN+EN trained [V]; others untested).

## 7. Outside this assignment
- `tools/paper-bench/__pycache__/` is untracked (git status); add to .gitignore.
- BabelDOC already ships a fixed-shape 1024 CoreML-provider path for DocLayout-YOLO (`doclayout.py:41`); worth reading its static-shape ONNX rewrite as a reference for a coremltools conversion recipe. Read-only, small.
