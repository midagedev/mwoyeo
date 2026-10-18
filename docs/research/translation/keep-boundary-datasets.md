# D0 dataset-sources (2026-10-19)

Marks: [V] fetched, text quoted by the WebFetch reader (a summariser, so quotes are as relayed); [S] search snippet; [U] inference.
Not legal advice. No dataset downloaded; cards and license pages only.

## 1. Existing datasets

| Dataset | Labels / unit | Source | Size | Languages | License of labels | License of images/text | Download | Ships in paid closed-source weights? |
|---|---|---|---|---|---|---|---|---|
| IBEM | isolated + embedded (inline) math boxes + LaTeX; page, bbox | arXiv LaTeX via KDD Cup collection, rendered | 600 docs, 8272 pages, 29603 isolated + 137089 embedded MEs [V] | en (printed science) [U] | "Creative Commons Attribution 4.0 International" [V zenodo 7963703] | pages are renders of arXiv papers; their per-paper licenses are not stated on the record [U risk] | IBEM.zip 2.8 GB [V] | Labels: yes (CC BY, attribution). Underlying arXiv paper rights unresolved. Best inline-math truth found; use as hold-out/eval or train after the paper-license question is answered. |
| DoTA | arXiv page images + markdown (with `$..$`) + zh/fr/de translation; page | arXiv | 126K pairs (139K unfiltered) [V] | en, zh, fr, de | repo "MIT license" [V sidebar] | arXiv papers, rights not discussed [V] | gated HF, application with name/affiliation [V] | Gated + arXiv rights unclear: skip. |
| Im2Latex-100k | formula image + LaTeX, mostly display; formula | arXiv LaTeX | ~100k [V] | en | "Creative Commons Zero v1.0 Universal" [V zenodo 56198] | same record | 306.8 MB [V] | Yes (CC0). Isolated formulas, no inline context: useful only for formula-crop classifier negatives/positives. |
| linxy/LaTeX_OCR | formula crops + LaTeX | im2latex-derived + synthetic | 268,764 rows [V] | en | Apache-2.0 [V] | derived from the above | ~1.25 GB-class [U] | Yes, same limits as Im2Latex. |
| CROHME (offline) | handwritten formula images | competition | n/a | n/a | no license on the competition page [V] | none stated | n/a | Unusable (no license; handwriting is off-distribution anyway). |
| MathWriting | handwritten ink + LaTeX | Google | 253,182 rows [V] | n/a | CC BY-NC-SA 4.0 [V] | same | 2.9 GB [V] | No (NC). Off-distribution. |
| DocLayNet | 11 classes incl. Formula (block); page bbox; no Code class [V] | PDFs: finance, science, patents, tenders, law, manuals [V] | 80,863 pages [V] | mostly en, some de/fr/ja [U] | "CDLA-Permissive-1.0" [V] | card says nothing about source PDF rights [V] | 28 GiB core [V] / 39.8 GB HF [V] | Labels yes. Block-level Formula, pages of documents, not inline, not screens. Low value for our units. |
| PubLayNet | layout bbox (formula not a class [U]) | "PubMed Central Open Access Subset (commercial use collection)" [V] | n/a on page | en | "Community Data License Agreement – Permissive – Version 1.0" [V] | PMC commercial-use subset [V] | n/a | Yes, but no math/code classes: skip. |
| DocBank | token-level, 12 classes incl. Equation [V] | arXiv | 500K pages [V] | en | no license stated on the page [V] | arXiv | 2.95 GB txt, 47.4 GB img [V] | Blocked (no license). |
| M6Doc | 74 classes, no formula/code mention [V] | magazines, arXiv, news | 9,080 images [V] | zh, en, ru | "CC BY-NC-ND 4.0" [V] | same | 12.45 GB [V] | No (NC-ND). |
| D4LA | document layout | RVL-CDIP | n/a | en | fetch returned 401 (gated) | - | - | Not verified; scanned business docs, irrelevant. |
| arXiv bulk source | LaTeX source: `$..$`, `\begin{lstlisting}`, fonts when compiled | arXiv | "complete set of source files is about 2.9 TB (March 2023)" [V]; tar ~500 MB each, requester-pays S3 bucket `arxiv` [V] | all | per paper | OAI-PMH `arXiv` format "includes ... category and license information" [V]; authors choose among CC BY 4.0, CC BY-SA 4.0, CC BY-NC-SA 4.0, CC BY-NC-ND 4.0, arXiv perpetual license, CC Zero [V] | pick a small slice | Only CC BY / CC0 / (BY-SA with care) papers; "we are unable to grant others the right to distribute arXiv articles" [V]. Filter: harvest OAI-PMH `https://oaipmh.arxiv.org/oai` metadataPrefix=arXiv, keep `<license>` = creativecommons.org/licenses/by/4.0/ or /publicdomain/zero/ (field name `license` [U], confirm on first harvest). Fraction of CC BY/CC0 is small [U]; measure on harvest. |
| The Stack v2 | code files, 600+ langs, license per file | Software Heritage | 67.5 TB full, 32.1 TB dedup [V] | code | card "other": "must abide by the terms of the original licenses" [V]; `license_type` permissive / no_license field [V] | same | login+agreement; "Bulk downloads of file contents require an agreement with Software Heritage and INRIA"; AWS credentials [V]; "Training models requires following Software Heritage's principles" [V] | Too heavy and encumbered for what we need (we need text to render, not TB). Use a few hundred permissive files from our own GitHub picks instead. |
| CodeSearchNet | functions + docstrings, 6 langs | GitHub | ~2 M pairs [V]; 3.5 GB (also "approximately 20 GB") [V] | Python, JS, Ruby, Go, Java, PHP [V] | code/docs MIT [V] | "licenses for source code used as data ... are provided with the data download" [V] | 3.5 GB | Per-file licenses; filter to MIT/BSD/Apache. Pure code, no prose; fine as code-text source for the renderer. |
| Rico | Android screenshots + view hierarchy | apps | ~72k screens [S] | many | CC BY 4.0 only via a derivative card [S]; original unverified | app UIs, copyright of app owners [U] | big | Unverified; do not count. |
| Screen2Words | summaries for 22,417 Rico screens [V] | Rico | 112,085 summaries [V] | en | no license on page [V] | - | - | No: no license; wrong labels. |
| ScreenQA | 86K QA, 35K Rico screenshots, element bounds + text [V] | Rico | ~86K / ~35K [V] | en | "Dataset is licensed under CC BY 4.0." [V] | Rico screenshots | small | Labels CC BY. Gives text-box bounds on real screens, no math/code classes: usable only as a prose-screen hold-out; Rico image rights unverified. |
| WebUI | 400K web pages: screenshots, accessibility trees, boxes, computed styles [V] | crawl | 400K [V] | many | no license stated [V] | third-party web pages | huge | Blocked (no license). Idea valid: our own crawl of permissive pages. |
| ScreenSpot | 1.27k instructions + bbox on iOS/Android/macOS/Windows/Web [V] | annotators | 602 MB [V] | en/zh [U] | "Apache 2.0" [V] | screenshots of real apps, third-party UI [U] | 602 MB | Eval only; no math/code labels. Real macOS/web screens, so a handy hold-out background for false positives (0 math/code expected). |
| Stack Exchange dump | Markdown/HTML posts, code blocks `<pre><code>`, inline `<code>`, math.SE/physics `$..$` | SE | stackoverflow Posts 7z 21.4 GB [V]; other sites separate archives | many sites; ko/ja/ru/pt SO exist [U] | "All user content contributed to the Stack Exchange network is cc-by-sa 4.0 licensed" [V] | same | per-site 7z; math.stackexchange is a few GB [U] | see CC BY-SA column. Best source of code-in-prose truth and math-in-prose truth with real prose. |
| Wikipedia | `<math>` tags, `<syntaxhighlight>`/`<code>`, 300+ languages | Wikimedia | dumps, multi-GB | all | "all original textual content is licensed under the GNU Free Documentation License" and CC BY-SA 4.0 [V] | same | multistream dumps | see CC BY-SA column. Only source with math in ko/ja/zh/en prose at scale. |
| unarXive-like / arXiver (neuralwork/arxiver) | arXiv papers as markdown | arXiv | 63,357 papers, 1.44 GB [V] | en | "CC BY-NC-SA 4.0" [V] | arXiv | 1.44 GB | No (NC). |
| Pygments / KaTeX / MathJax (tools, not data) | generators | - | - | - | Pygments BSD-style [V partial], KaTeX "The MIT License (MIT)" [V], MathJax "Apache License Version 2.0" [V] | - | - | Safe to bundle in the generator pipeline; they produce no encumbered text. |

## CC BY-SA consequence for trained weights (quoted, no opinion)
- Condition: "The Adapter's License You apply must be a Creative Commons license with the same License Elements, this version or later, or a BY-SA Compatible License." and "You may not offer or impose any additional or different terms or conditions on, or apply any Effective Technological Measures to, Adapted Material" [V, CC BY-SA 4.0 legalcode 3(b)].
- "Adapted Material means material subject to Copyright and Similar Rights that is derived from or based upon the Licensed Material and in which the Licensed Material is translated, altered, arranged, transformed, or otherwise modified in a manner requiring permission under the Copyright and Similar Rights" [V].
- CC FAQ: "Regarding ShareAlike, the condition only applies if a work is modified and if the work is shared publicly." and "No special or explicit permission regarding new technologies from a copyright perspective is required." [V]. It also says whether a modification is an adaptation "depends primarily on the applicable copyright law." [V]
- Open question for the lead: whether a classifier's numeric weights are "Adapted Material" is unsettled by these texts [U]. Attribution (BY) is required either way. Risk-minimising use: CC BY-SA text as test/render source for the generator only where the model learns shapes (a few thousand sentences) and weights hold no text; or use BY-SA only for the hold-out that never ships. Wikipedia is additionally GFDL (dual) [V].

## 2. Make-our-own recipes
Throughput assumptions [U]: M1 Pro, Vision `RecognizeDocumentsRequest` ~0.5 s per 1000 px frame (range 0.2-1 s), one render+OCR pipeline at a time (the ANE is shared with other rounds), HTML->WebKit snapshot ~0.15 s, LaTeX/KaTeX render ~0.05 s each when batched in one page. Units = labelled spans or lines per hour, per recipe; frames are the bottleneck: ~4-7k frames/h.

| Recipe | Generator | Free truth | Gap to real screens | Frames/h -> units/h |
|---|---|---|---|---|
| A. KaTeX/MathJax inline in prose carriers (ko/ja/zh/en sentences from Wikipedia/Tatoeba-like permissive text or LLM-free templates), many fonts/sizes/themes | tools/usecase-bench HTML renderer + KaTeX (MIT) | span char offsets of every `$..$`, exact bboxes via DOM Range rects | KaTeX glyph spacing is cleaner than app UIs and PDFs; lacks real PDF Computer Modern Type 1 hinting and sub/superscript baseline quirks of Word/Pages/Preview | ~5k frames/h x ~3 lines x ~1.2 math spans -> ~15k lines, ~18k math spans/h |
| B. Code in monospace: syntax themes light/dark, editor chrome, terminal, diff, README/SO pages | HTML + Pygments/highlight.js (BSD/BSD) + permissive source (CodeSearchNet MIT/Apache subset, own repos) | block/line/inline `<code>` extents from DOM; class code/prose from tag | Real editors use bitmap/subpixel fonts and ligatures; real apps overlay minimap, gutter, selection | ~5k frames/h x ~25 lines -> ~125k code lines/h (or ~5k blocks) |
| C. Stack Exchange / GitHub Markdown -> HTML -> render | cmark/markdown-it -> HTML with site-like CSS (own CSS, not SE's) | Markdown marks `code`, fences, `$..$`; prose is the remainder | Style realism lower than a screenshot of the real site; CC BY-SA text (weights concern above) | same frame rate; ~4k blocks/h with ~30 % code, ~10 % math if math.SE |
| D. arXiv LaTeX -> PDF -> PDF text layer fonts (L0 round) | texlive build per paper (1-3 min each, failing often) + PDFKit glyph fonts | per-glyph font name (CMMI/CMSY/CMEX = math) | Only papers; scanned papers excluded; build cost dominates | per paper ~10 pages x 4 s OCR = 40 s + build 2 min -> ~20-25 papers/h, ~1.5k inline-math spans per paper => ~30k spans/h, but license-filtered slice only (CC BY/CC0) |
| E. Real-screen hold-out (not ours) | Screenshots of real macOS apps captured by the user/us (Xcode, Terminal, Safari on SO/GitHub/arXiv HTML, Preview PDFs), hand-labelled with a small tool | manual | expensive (human) | ~150-300 labelled units/h by hand [U] |

## 3. Recommendation

| Rank | Source | Role | Count target | License risk |
|---|---|---|---|---|
| 1 | Recipe A+B+C own renders (KaTeX/MathJax, Pygments, own CSS) with permissive text (code: CodeSearchNet MIT/Apache subset + own repos; prose: own sentences and CC0/CC BY text) through Vision OCR | train | math: 3k span positives + 6k near-negatives (hyphens, slashes, "C++", versions, x2); code: 1.5k blocks + 3k inline + 3k negatives; prose: 5k lines; ko/ja/zh/en each >= 20 % | low (generator licenses [V] MIT/Apache/BSD; text sources chosen) |
| 2 | Recipe D from CC BY / CC0 arXiv papers (OAI-PMH filtered), PDF font truth; fallback IBEM (CC BY labels) for inline-math truth | train (real paper typesetting) and dev | 20-40 papers, >= 3k math spans, split by paper | medium: paper-level license must be CC BY/CC0 [V list]; IBEM images are arXiv renders of unstated rights |
| 3 | Stack Exchange (math.SE, SO, plus ko/ja SO) as sentence and code *carrier text* for A-C, truth from Markdown | train, small slice, no pixels from SE | ~5k units | medium-high: CC BY-SA 4.0, ShareAlike on weights unsettled [V quotes above]; attribution list required; or restrict to hold-out |
| H1 | Real screens, human-labelled, not from our generator (own captures of Xcode/Terminal/Safari SO, GitHub, arXiv ar5iv, Preview PDFs, ko/ja/zh pages) | hold-out (mandatory) | 300 math spans, 300 code blocks, 300 inline code, 500 prose lines, 3 papers fully held out | none (own captures); keep only if the shown sites' content is not redistributed in the repo |
| H2 | ScreenSpot (Apache-2.0 [V]) and ScreenQA (CC BY 4.0 [V]) screenshots | hold-out for false positives (expect ~0 math/code on UI chrome) | 300-500 screens | low labels, unverified third-party UI rights; keep out of the repo, local only |

Skip: DoTA (gated), DocBank/WebUI/Screen2Words (no license), M6Doc/MathWriting/arXiver (NC), The Stack v2 (TB-scale, agreement), DocLayNet/PubLayNet (wrong unit; fine as optional block-level extra since labels are CDLA-Permissive [V]).

Sizing: ±5 % CI at R≈0.9 needs ~150 positives (design §7); the targets above give headroom for per-language and per-theme slices.

## License blockers
1. arXiv: "we are unable to grant others the right to distribute arXiv articles" [V]; only CC BY / CC BY-SA / CC0 papers qualify; the per-paper license must come from OAI-PMH, not assumed.
2. CC BY-SA (Stack Exchange, Wikipedia): ShareAlike on trained weights is untested by the licence text [V quotes]; user decision needed before any BY-SA text trains shipped weights.
3. IBEM images are arXiv renders; its CC BY label does not cover the arXiv papers' rights [U].
4. Rico, WebUI, Screen2Words, DocBank: no verifiable licence [V] -> do not use.

## Verification gaps
D4LA (401); Rico original license (interactionmining 404, only a derivative card [S]); the exact OAI-PMH license element name; CC BY/CC0 share of arXiv; Pygments full license name; DocLayNet source-PDF rights; GitHub README text licenses (not researched); throughput numbers are assumptions, not measured.

## Outside this assignment
- tools/usecase-bench: add the `(keep)` note and kept_ok/translated_ok columns (design §8) — also the natural home for recipes A-C; size M.
- Recipe C needs a Markdown renderer in tools/; check the repo has one before adding a dependency.

---
# Addendum (lead, user 2026-10-19): the target is the translate/keep boundary (design §9)
Rating: BOUNDARY = word-exact keep/translate edges; REASONS = keep reasons covered (math, code, command, path, URL, id, hotkey, log); MIXED = keep span inside translated prose; REAL = pixels from real screens. [U] unless marked; the license facts above are unchanged.

| Source | BOUNDARY | REASONS | MIXED | REAL screens |
|---|---|---|---|---|
| IBEM | box-exact for embedded math, no tokens of prose around it | math only | yes (embedded MEs sit in sentences), paper pages | no (paper renders) |
| DocLayNet / PubLayNet / DocBank / M6Doc | block or token labels, layout classes; no inline | Formula block only (DocBank: Equation tokens) | no | no |
| Im2Latex / LaTeX_OCR / MathWriting / CROHME | crop only | math | no | no |
| arXiv LaTeX -> PDF (D) | glyph-exact via font names (math); `\texttt`/`\verb`/`lstlisting` give code, `\url`/`\href`/`\path` give URL/path, `\cite` etc. | math, code, url, path, id (macros) | yes, richest paper source | no (PDF) |
| Stack Exchange dump | Markdown/HTML marks inline `<code>`, `<pre>`, `<kbd>`, `$..$`: char-exact, word-exact after tokenising | code, command, path, URL, id, hotkey (`<kbd>`), log lines in `<pre>`, math (math.SE) | yes, the best: inline code in sentences is the norm | no pixels; render ourselves |
| Wikipedia | `<math>`, `<code>`, `<syntaxhighlight>`, `<kbd>`: char-exact | math, code, some command/URL | yes, 300+ languages incl. ko/ja/zh | no pixels |
| GitHub READMEs (permissive repos; not fetched) | Markdown backticks/fences/badges: char-exact | code, command, path, URL, id | yes | no pixels; license per repo [U] |
| CodeSearchNet | docstring vs code split per function | code, comments | partial (comments inside code = keep per user's block decision) | no |
| ScreenSpot / ScreenQA / Rico / WebUI | element boxes only, no keep/translate | none | no | yes (ScreenSpot macOS/iOS/Web [V]; ScreenQA/Rico Android) |
| Own HTML renders (A-C) | DOM Range rects: word-exact, any tag we choose | all of the above, by construction incl. kbd/path/URL/log/diff markers | yes, built in | no (we render) but via real WebKit + Vision OCR |
| Real-screen hand labels (H1) | word-exact, by hand | whatever we label; sample every reason | yes | yes |

Finding: no public dataset labels keep/translate on real screen pixels. Word-exact boundaries exist only where markup survives (SE, Wikipedia, READMEs, LaTeX); real pixels exist only without such labels (ScreenSpot, ScreenQA). The bridge is rendering markup-labelled text ourselves (WebKit) and OCRing it, plus a hand-labelled real hold-out.

## Re-ranked recommendation (boundary quality on real screens first)
| Rank | Source | Role | Why | Target counts (words/spans) | License risk |
|---|---|---|---|---|---|
| 1 | H1 real-screen hand labels: Xcode, Terminal, Safari on SO/GitHub/arXiv HTML/Wikipedia, Preview PDFs, VS Code, diffs, Finder paths, System Settings, ko/ja/zh/en UIs; labelled per word as translate/keep/either + reason | hold-out (and the only trustworthy score) | only source with real boundaries on real pixels | >= 1,000 keep spans spread over reasons (>= 100 each for math, inline code, command, path, URL, id/hotkey/log), >= 300 mixed sentences, >= 500 translate-only lines, 3 papers held out | none (own captures; keep screenshots out of the repo if third-party content) |
| 2 | Own HTML renders from SE-/Wikipedia-/README-style Markdown, mixed sentences with inline keep spans (recipes A-C), many fonts/themes/languages, then Vision OCR; truth from markup | train | word-exact on every reason, mixed sentences by construction, real Vision noise | ~40k lines, >= 15k keep spans, >= 3k per reason, 25 % ko/ja/zh each | low if text is permissive (own sentences, CC0/CC BY, MIT/Apache READMEs and CodeSearchNet); CC BY-SA text is the open question above |
| 3 | arXiv CC BY/CC0 LaTeX -> PDF (D) with font + macro truth; IBEM as extra inline-math truth | train/dev for the paper domain | word-exact math, plus code/URL/id via macros | 20-40 papers, >= 3k keep spans, split by paper | medium (paper licence filter; IBEM image rights) |
| 4 | ScreenSpot (Apache-2.0 [V]) / ScreenQA (CC BY 4.0 [V]) screens | hold-out for translate->kept errors on UI chrome | real UI text, expect (almost) all `translate`/`either` | 300-500 screens, pseudo-truth by rules + spot check | low labels; third-party UI rights unverified, local only |

Change vs the first ranking: the real-screen hand-labelled set moves to rank 1 and its target grows (all keep reasons, mixed sentences); the synthetic set must now include the non-math reasons (command, path, URL, id, kbd, log lines, diff markers) explicitly, which recipes B and C cover but A did not. Dataset licence blockers and verification gaps are unchanged. Labelling cost for H1 at ~150-300 labelled units/h by hand [U] is the main time cost: ~10-15 h for ~3k units; weak-label the draft with rules and review only, to cut that.

DONE-dataset-sources
