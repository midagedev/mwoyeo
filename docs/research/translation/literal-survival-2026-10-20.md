# Does Apple Translation carry a literal through prose as written? (2026-10-20)

## The question

`InlineLiteral.spans(in:)` (Core/Sources/MwoyeoCore/InlineLiteral.swift) finds the literals inside prose that must stay
as written: a url, an email, a path, a command, a flag, an identifier, a hash, a version, a config filename, a hotkey.
The table is not wired into the app. Wiring it would mean marking each span `skipsTranslation` in an attributed request,
but the app translates with `translate(batch:)` (plain text, no attributes) and the marked path costs one request per line.

Per reason, then:

1. Does the **plain** path (what the app does) already keep the literal verbatim? If yes, no wiring is needed for that reason.
2. Where it does not, **does marking help**, and by how much?

Prior measurement (docs/research/paper-translation.md §4, lines 54-90): the language pack ignores `skipsTranslation` for
words it can translate; symbols are never touched. This round asks whether that holds for the literal table's reasons, on
real prose, in all four pairs the app ships.

## What was measured

**Corpus.** Block texts of `tools/keep-labels/labels-h2/h2.jsonl` and `tools/keep-labels/labels-h3/h3.jsonl` (`"kind":"block"`,
fields `text`, `lang`, `id`), doc reads only (ids without `-vn-`). A block was kept when today's rules translate it
(`keeprules` `needs` = `TranslationFilter.needsTranslation`) **and** `InlineLiteral.spans` finds at least one span.
Built with `swift build -c release --scratch-path /tmp/lit-survival/kb` (`tools/keep-labels`), run as
`/tmp/lit-survival/kb/release/keeprules <labels.jsonl>`; 345 blocks qualify, capped at 120 per pair by id order.

| pair | blocks | spans | pairs measured |
|---|---|---|---|
| en→ko | 120 | 156 | lowLatency, highFidelity |
| ja→ko | 70 | 85 | lowLatency, highFidelity |
| zh-Hans→ko | 40 | 44 | **highFidelity only** |
| ko→en | 71 | 103 | lowLatency, highFidelity |
| **total** | **301** | **388** | |

**Language packs.** `LanguageAvailability(preferredStrategy:).status(from:to:)`:

| pair | lowLatency | highFidelity |
|---|---|---|
| en→ko | installed | installed |
| ja→ko | installed | installed |
| zh-Hans→ko | **supported** (downloadable, not installed) | installed |
| ko→en | installed | installed |

The zh-Hans low-latency pack is **not installed** on this Mac, so zh-Hans→ko was measured with highFidelity only. No pack
was downloaded (`LanguageAvailability` was only asked, never triggered to fetch).

**Probe.** `tools/apple-translation-probe/literal-survival.swift`, in the style of `batch.swift` and `attributed-spans.swift`
beside it. It reads a JSON list of `{id, text, spans:[[start,end,reason]], src, dst}` and writes JSON lines: one per block
per mode per strategy, plus a summary per pair per mode per strategy.

- `plain`: one `translate(batch:)` for the whole pair — what the app does (`TranslationService.stream`, batch request).
- `marked`: one `translate(_: AttributedString)` per block, every InlineLiteral span marked `skipsTranslation` and carrying
  `link = literal:<n>`, the app's `ProtectedRequest.swift` shape (App/Pipeline/ProtectedRequest.swift:9-18). At most 8 at a
  time (the app's own marked path runs them in a task group).
- Both strategies, `.lowLatency` and `.highFidelity`.
- Per span: `verbatim` (the span's exact text is a substring of the target), `verbatim_ci` (case-insensitive),
  `returned` (the marker link came back on a run of the target, marked mode only).

**The casing fix.** The probe is compiled **against MwoyeoCore** (not a copy of the logic):
`swiftc -O -I /tmp/lit-survival/core/release -L /tmp/lit-survival/core/release -lMwoyeoCore …`, so it calls the app's own
`TranslationCleanup.restoreSourceTokens` (Core/Sources/MwoyeoCore/Text.swift:242) on the target before the `verbatim` test,
as the app does on both paths (TranslationService.swift:741 for the batch, :805/:812 for the marked one). The engine's own
text is kept as `target_raw` and measured too (`verbatim_raw`), because the fix itself changes the answer — see §5.

**Raw data.** `docs/research/translation/apple-probe/literal-survival-2026-10-20.jsonl` (1139 lines, 588 KB).

## 1. Wall time

| pair | mode | strategy | wall | sum of requests | blocks | wall/block | req/block |
|---|---|---|---|---|---|---|---|
| en→ko | plain | lowLatency | 8 417 ms | – | 120 | 70 ms | – |
| en→ko | marked | lowLatency | 9 250 ms | 44 954 ms | 120 | 77 ms | 375 ms |
| en→ko | plain | highFidelity | 117 610 ms | – | 120 | 980 ms | – |
| en→ko | marked | highFidelity | 130 915 ms | 641 060 ms | 120 | 1 091 ms | 5 342 ms |
| ja→ko | plain | lowLatency | 9 918 ms | – | 70 | 142 ms | – |
| ja→ko | marked | lowLatency | 11 631 ms | 63 427 ms | 70 | 166 ms | 906 ms |
| ja→ko | plain | highFidelity | 106 668 ms | – | 70 | 1 524 ms | – |
| ja→ko | marked | highFidelity | 121 917 ms | 599 530 ms | 70 | 1 742 ms | 8 565 ms |
| zh-Hans→ko | plain | highFidelity | 56 759 ms | – | 40 | 1 419 ms | – |
| zh-Hans→ko | marked | highFidelity | 64 345 ms | 304 349 ms | 40 | 1 609 ms | 7 609 ms |
| ko→en | plain | lowLatency | 4 941 ms | – | 71 | 70 ms | – |
| ko→en | marked | lowLatency | 5 708 ms | 29 874 ms | 71 | 80 ms | 421 ms |
| ko→en | plain | highFidelity | 79 172 ms | – | 71 | 1 115 ms | – |
| ko→en | marked | highFidelity | 98 575 ms | 463 546 ms | 71 | 1 388 ms | 6 529 ms |

**Marking costs 1.10–1.25× the wall time of the plain batch** (×1.10 en→ko ll, ×1.17 ja→ko ll, ×1.16 ko→en ll; ×1.11
en→ko hf, ×1.14 ja→ko hf, ×1.13 zh-Hans→ko hf, ×1.25 ko→en hf). That is with 8 requests in flight; run one at a time it is
the "sum of requests" column: 375 ms a block instead of 70 ms (low latency), 5 342 ms a block instead of 980 ms (high
fidelity). The request count goes from 1 per pair to 1 per block.

## 2. The verbatim table

`verbatim` = after the app's casing fix (what the app would show). `raw` = the engine's own text. `returned` = the marker
link came back (marked mode only).

### Pooled over all pairs, by reason

| reason | mode | strategy | n | verbatim | verbatim_ci | raw | raw_ci | returned |
|---|---|---|---|---|---|---|---|---|
| cmd | plain | lowLatency | 26 | 65.4 | 76.9 | 50.0 | 76.9 | – |
| cmd | marked | lowLatency | 26 | 69.2 | 76.9 | 50.0 | 76.9 | 65.4 |
| cmd | plain | highFidelity | 33 | 78.8 | 84.8 | 81.8 | 84.8 | – |
| cmd | marked | highFidelity | 33 | 84.8 | 93.9 | 93.9 | 93.9 | 100.0 |
| config | plain | lowLatency | 14 | 100.0 | 100.0 | 71.4 | 100.0 | – |
| config | marked | lowLatency | 14 | 100.0 | 100.0 | 71.4 | 100.0 | 64.3 |
| config | plain | highFidelity | 14 | 100.0 | 100.0 | 100.0 | 100.0 | – |
| config | marked | highFidelity | 14 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 |
| flag | plain | lowLatency | 30 | 83.3 | 86.7 | 66.7 | 86.7 | – |
| flag | marked | lowLatency | 30 | 83.3 | 86.7 | 66.7 | 86.7 | 76.7 |
| flag | plain | highFidelity | 30 | 70.0 | 70.0 | 70.0 | 70.0 | – |
| flag | marked | highFidelity | 30 | 93.3 | 96.7 | 96.7 | 96.7 | 100.0 |
| hash | plain | lowLatency | 21 | 100.0 | 100.0 | 100.0 | 100.0 | – |
| hash | marked | lowLatency | 21 | 100.0 | 100.0 | 100.0 | 100.0 | 81.0 |
| hash | plain | highFidelity | 22 | 100.0 | 100.0 | 100.0 | 100.0 | – |
| hash | marked | highFidelity | 22 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 |
| id | plain | lowLatency | 175 | 88.0 | 96.0 | 93.1 | 96.0 | – |
| id | marked | lowLatency | 175 | 91.4 | 96.0 | 93.1 | 96.0 | 65.7 |
| id | plain | highFidelity | 194 | 87.1 | 93.3 | 93.3 | 93.3 | – |
| id | marked | highFidelity | 194 | 93.8 | 100.0 | 100.0 | 100.0 | 100.0 |
| path | plain | lowLatency | 46 | 87.0 | 93.5 | 82.6 | 93.5 | – |
| path | marked | lowLatency | 46 | 87.0 | 93.5 | 82.6 | 93.5 | 71.7 |
| path | plain | highFidelity | 51 | 84.3 | 88.2 | 88.2 | 88.2 | – |
| path | marked | highFidelity | 51 | 94.1 | 100.0 | 100.0 | 100.0 | 100.0 |
| url | plain | lowLatency | 32 | 100.0 | 100.0 | 100.0 | 100.0 | – |
| url | marked | lowLatency | 32 | 100.0 | 100.0 | 100.0 | 100.0 | 81.2 |
| url | plain | highFidelity | 44 | 100.0 | 100.0 | 100.0 | 100.0 | – |
| url | marked | highFidelity | 44 | 100.0 | 100.0 | 100.0 | 100.0 | 100.0 |

### The plain path, per pair (the app's behaviour today)

`lo` = lowLatency, `hi` = highFidelity. `fixed (raw)`.

| reason | en→ko | ja→ko | zh-Hans→ko | ko→en |
|---|---|---|---|---|
| url | 100.0 (100.0) lo, 100.0 (100.0) hi, n=1 | 100.0 (100.0) lo/hi, n=25 | 100.0 (100.0) hi, n=12 | 100.0 (100.0) lo/hi, n=6 |
| hash | 100.0 (100.0) lo/hi, n=17 | – | 100.0 (100.0) hi, n=1 | 100.0 (100.0) lo/hi, n=4 |
| config | 100.0 (55.6) lo, 100.0 (100.0) hi, n=9 | – | – | 100.0 (100.0) lo/hi, n=5 |
| flag | **75.0** (60.0) lo, **60.0** (60.0) hi, n=20 | 100.0 (66.7) lo, 100.0 (100.0) hi, n=3 | – | 100.0 (85.7) lo, **85.7** (85.7) hi, n=7 |
| cmd | **25.0** (0.0) lo, **37.5** (37.5) hi, n=8 | 100.0 (77.8) lo, 100.0 (100.0) hi, n=9 | 100.0 (100.0) hi, n=7 | **66.7** (66.7) lo, **77.8** (88.9) hi, n=9 |
| path | **81.8** (90.9) lo, **72.7** (77.3) hi, n=22 | 100.0 (72.7) lo, 100.0 (100.0) hi, n=11 | 100.0 (100.0) hi, n=5 | **84.6** (76.9) lo, 92.3 (92.3) hi, n=13 |
| id | **82.3** (93.7) lo, **75.9** (83.5) hi, n=79 | 94.6 (91.9) lo, 100.0 (100.0) hi, n=37 | 100.0 (100.0) hi, n=19 | 91.5 (93.2) lo, **89.8** (100.0) hi, n=59 |

### What marking buys (highFidelity, the strategy where it is honoured)

| reason | pair | plain fixed | marked fixed | plain raw | marked raw | n |
|---|---|---|---|---|---|---|
| flag | en→ko | 60.0 | **95.0** | 60.0 | **100.0** | 20 |
| cmd | en→ko | 37.5 | **75.0** | 37.5 | **75.0** | 8 |
| path | en→ko | 72.7 | **95.5** | 77.3 | **100.0** | 22 |
| id | en→ko | 75.9 | **91.1** | 83.5 | **100.0** | 79 |
| cmd | ko→en | 77.8 | 66.7 | 88.9 | **100.0** | 9 |
| path | ko→en | 92.3 | 92.3 | 92.3 | **100.0** | 13 |
| id | ko→en | 89.8 | 91.5 | 100.0 | 100.0 | 59 |
| flag | ko→en | 85.7 | 85.7 | 85.7 | 85.7 | 7 |
| url, hash, config | all | 100.0 | 100.0 | 100.0 | 100.0 | – |

With lowLatency the marked path buys **nothing**: for every reason the marked rate equals the plain rate, and for
en→ko and ko→en the marked request's raw text is **byte-identical** to the plain request's in 261 of 261 blocks. The
language pack ignores `skipsTranslation` — the paper note holds.

## 3. The marker comes back only when the target is not Latin script

`returned` per pair (marked mode):

| pair | lowLatency | highFidelity |
|---|---|---|
| en→ko | 155/156 | 156/156 |
| ja→ko | 85/85 | 85/85 |
| zh-Hans→ko | (not measured) | 44/44 |
| ko→en | **0/103** | 103/103 |

Isolated probe (`/tmp/lit-survival/marker4.swift`, one marked span `git commit` in a short sentence, lowLatency):

| pair | runs carrying the marker link |
|---|---|
| en→ko | 1 |
| ja→ko | 1 |
| ko→ja | 1 |
| en→ja | 1 |
| **ko→en** | **0** |
| **ja→en** | **0** |

**Mechanism (measured, not inferred):** the language pack keeps the `link` attribute on its runs when the *target* is
Korean or Japanese, and drops it when the target is English. The high-fidelity model keeps it either way. So on the
low-latency path with an English target, a marked request comes back with the text but **without any run carrying the
marker** — the app's `ProtectedSpans.resolve` would find no span at all. This is the same asymmetry paper-translation.md §4
recorded for words ("the marker comes back on the engine's own rendering plus the particle") but it was not named: it is
the *target script*, not the source, that decides.

## 4. Failures, by reason

Ten per reason (source span → what came back); the full list is in the raw JSONL.

### cmd (29 failing span instances)

1. `plain/lowLatency en→ko` `swift build -c release` → `'Swift build -c 릴리스가 완료되었습니다. 그 출력물의 마지막 줄:'`
2. `plain/lowLatency en→ko` `swift build` → `'누군가 tools/keep-labels/run-rules.sh를 확인해 주실 수 있나요? 제 브랜치 wt/k3a에서 swift 빌드가 실패했습니다.'`
3. `plain/lowLatency en→ko` `swift test. Build` → `'• cd Core && swift 테스트를 실행합니다. 빌드 단계는 README에 있습니다.'`
4. `plain/lowLatency en→ko` `run: "Restart` → `'/// 워커가 크래시 루프되어 이번 실행을 위해 꺼졌습니다: "Restart Mwoyeo".'`
5. `plain/lowLatency en→ko` `Swift` → `'빠른'` (the English word translated to Korean)
6. `marked/lowLatency en→ko` `swift build -c release` → `'Swift build -c 릴리스가 완료되었습니다. …'` (identical to plain; the marker came back but the pack still translated `release`)
7. `marked/lowLatency en→ko` `swift build` → `'Swift 빌드에 실패했습니다: /tmp/k3a/build/keeprules-build.log'`
8. `marked/lowLatency en→ko` `swift test. Build` → `'• cd Core && swift 테스트를 실행합니다. …'`
9. `marked/lowLatency en→ko` `run: "Restart` → `'/// 워커가 … : "Restart Mwoyeo".'`
10. `marked/lowLatency en→ko` `Swift` → `'빠른'`

The pack translates the *English words inside* a command (`release` → `릴리스`, `build` → `빌드`, `swift` → `빠른`) and
leaves the punctuation. Marking does not stop it on the low-latency path.

### flag (21 failing span instances)

1. `plain/lowLatency en→ko` `--publish` → `'--게시'`
2. `plain/lowLatency en→ko` `--pairs` → `'--쌍 «목록'`
3. `plain/lowLatency en→ko` `--settings-path` → `'… Mwoyeo --settings-path는 해당 위치에 …'` (kept, but the casing fix turned `settings. json` into `settings. json`/`Settings. json`)
4. `marked/lowLatency en→ko` `--pairs` → `'--쌍 «목록'`
5. `marked/lowLatency en→ko` `--publish` → `'--게시'`
6. `marked/lowLatency en→ko` `--settings-path` → `'… Mwoyeo --settings-path는 …'`
7. `plain/highFidelity en→ko` `--key-id` → `'공증인=(--키 "$MWOYEO_NOTARY_KEY" --키-아이디 "$MWOYEO_NOTARY_KEY_ID" -- 발행자'` (the flag translated)
8. `plain/highFidelity en→ko` `--check-settings` → `'--설정 확인 [경로]'`
9. `plain/highFidelity en→ko` `--publish` → `'--게시하다'`
10. `plain/highFidelity en→ko` `--pairs` → `'--쌍 «목록'`

### id (73 failing span instances)

1. `plain/lowLatency en→ko` `cLoud` → `'cLaude-haiku-5-5 | 구름 | … | cLaude-sonnet-5-5 | cLoud | …'` (kept; the casing fix broke it)
2. `plain/lowLatency en→ko` `macOS` → `'macOS 텍스트 인식이 응답하지 않습니다. Mac을 재시작하면 …'` (kept; casing fix broke it)
3. `plain/lowLatency en→ko` `GIT` → `'바보 자식'` (the acronym was read as a word)
4. `plain/lowLatency en→ko` `TERMINAL` → `'터미널'`
5. `plain/lowLatency en→ko` `resultPath` → `'HTTPTemplate(url: url, …, resultPath: path, …)'` (kept; casing fix broke it)
6. `plain/lowLatency en→ko` `JSON` → `'모든 설정은 JSON 파일이므로 …'` (kept; casing fix broke it)
7. `plain/lowLatency en→ko` `customEngineID` → `'프로필 자체의 customEngineID는 더 이상 요구되지 않습니다. …'` (kept; casing fix broke it)
8. `plain/lowLatency en→ko` `requestOptions` → `'Let options = ContextOptions. requestOptions (engine: engine, profile: p)'` (kept; casing fix broke it)
9. `plain/lowLatency en→ko` `EXPLORER` → `'탐험가'`
10. `plain/lowLatency en→ko` `restartApp` → `'케이스 재시작 앱'`

### path (23 failing span instances)

1. `plain/lowLatency en→ko` `Core/Sources/MwoyeoCore/ReadWait. swift` → `'예상: 알약이 즉시 제거됩니다. 상태는 Core/Sources/MwoyeoCore/ReadWait에 있습니다. swift; …'`
2. `plain/lowLatency en→ko` `~/Library/Application` → `'… (~/Library/Application Support/Mwoyeo/settings. json)를 …'` (kept; the OCR space inside the path)
3. `plain/lowLatency en→ko` `Support/Mwoyeo/settings. json` → `'… ~/Library/Application Support/Mwoyeo/settings. json를 …'` (kept; the space at the dot)
4. `plain/lowLatency en→ko` `App/Support/EnginePermission. swift` → `'앱/지원/엔진 권한. swift'` (translated!)
5. `marked/lowLatency en→ko` `Core/Sources/MwoyeoCore/ReadWait. swift` → same as 1 (the marker came back, the text did not change)
6. `marked/lowLatency en→ko` `Support/Mwoyeo/settings. json` → same as 3
7. `marked/lowLatency en→ko` `App/Support/EnginePermission. swift` → `'앱/지원/엔진 권한. swift'`
8. `plain/highFidelity en→ko` `/run-rules. sh` → `'… KEEP_BUILD=/tmp/k3a/build ./run-rules.sh를 시도하고 …'`
9. `plain/highFidelity en→ko` `tools/nock-openal/server.py` → `'파이썬 -i 도구/nock-openal/server.py 스포츠 도카르 내장, stanpa'`
10. `plain/highFidelity en→ko` `HITPremplaterests. swift` → `'HITPremplaterests.swift의 테스트에서는 …'`

### url, hash, config

No failures at all in any pair, mode or strategy: 32 url spans (lowLatency) and 44 (highFidelity), 21-22 hash spans,
14 config spans, all 100.0 %. The engine never touches a url, a hash or a config filename.

## 5. Two defects found on the way (both outside this round's scope)

**The app's own casing fix corrupts literals.** `TranslationCleanup.restoreSourceTokens` (Core/Sources/MwoyeoCore/Text.swift:242)
replaces a token's **first case-insensitive substring** match, so a shorter source token that sits inside a longer one
replaces it: the source `HTTPTemplate(url: url, …, resultPath: path, …)` yields the token `path`, and the fix rewrites
`resultPath` to `resultpath`. Measured in this corpus: the fix **breaks** 20 of 344 spans that the engine had returned
verbatim on the plain low-latency path, 15 of 388 on the plain high-fidelity path, 10 of 344 marked low-latency and
19 of 388 marked high-fidelity. Concrete damage in the data: `resultPath` → `resultpath`, `customEngineID` →
`customengineID`, `requestOptions` → `requestoptions`, `macOS` → `MacOS`, `xcodebuild` → `xcodeBUILD`, `MWOYEO_NOTARY_KEY`
→ `MWOYEO_nOTARY_KEY`, `ANE_SLOT` → `ANE_slOT`.

The fix is also **not deterministic**: it iterates a `Set` of tokens, whose order Swift randomises per process, so the same
input yields `resultPath` on one run and `resultpath` on the next (`/tmp/lit-survival/det.swift`: 6 calls, 1 correct and 5
mangled in one process). Two marked/plain pairs of the same block can therefore disagree for this reason alone.

This is why the table above carries both `verbatim` (after the fix) and `raw` (the engine's own text): for `id` and `path`
the plain path's *engine* rate is higher than its *app-visible* rate, and the difference is this fix, not the engine.

**`TranslationCleanup.restoreSourceTokens` is also the wrong tool for a literal.** The tokens it matches are
`[A-Za-z][A-Za-z0-9_\/.\-]*`, which is exactly the shape of an InlineLiteral `id` or `path`; a literal-safe fix would
match whole tokens, and would have to know which spans are literals (InlineLiteral's job), not guess from the source text.

## 6. Conclusion

1. **The plain path already keeps `url`, `hash` and `config` verbatim, in every pair and both strategies (100.0 %, 80 of 80
   spans).** For these three reasons no wiring is needed — the engine never touches them, and the app's casing fix does not
   damage them either.
2. **The plain path does not keep `flag`, `cmd`, `path` and `id` verbatim on the low-latency path** (pooled 83.3 %, 65.4 %,
   87.0 %, 88.0 %; the engine's own rates 66.7 %, 50.0 %, 82.6 %, 93.1 %). The pack translates the English words inside a
   command (`release` → `릴리스`) or a flag (`--publish` → `--게시`), and reads an all-caps acronym as a word
   (`TERMINAL` → `터미널`, `EXPLORER` → `탐험가`). The failures are concentrated in en→ko, where the source is English and
   the literals are English words.
3. **Marking does not help at all on the low-latency path** (the app's default): the marked request's raw text is
   byte-identical to the plain request's in 261 of 261 blocks, and the per-reason rates are unchanged. The language pack
   ignores `skipsTranslation` for these spans. Marking also costs 1.10–1.17× the wall time and turns one batch into one
   request per block.
4. **Marking helps a lot on the high-fidelity path, where the model honours it**: for en→ko, `id` 75.9 → 91.1 %,
   `path` 72.7 → 95.5 %, `flag` 60.0 → 95.0 %, `cmd` 37.5 → 75.0 % (engine rates all reach 100 %); pooled over the pairs,
   `id` 87.1 → 93.8 %, `path` 84.3 → 94.1 %, `flag` 70.0 → 93.3 %, `cmd` 78.8 → 84.8 %, while `url`, `hash` and `config`
   stay at 100 %. It costs 1.11–1.25× the wall time.
5. **A marked request on the low-latency path with an English target comes back with no marker at all** (0/103 for ko→en;
   isolated: ko→en and ja→en lose the link, en→ko, ja→ko, ko→ja and en→ja keep it). So the marked path cannot even locate
   its spans there — the app's `ProtectedSpans.resolve` would find nothing.

**For the decision this round feeds:** wiring `InlineLiteral` into the app is only worth it on the **high-fidelity**
strategy, where it takes `flag`, `cmd`, `path` and `id` from 60–87 % to 91–95 % at 1.1–1.25× the latency; `url`, `hash` and
`config` need no wiring at all. On the low-latency path (the default when the pack is installed) marking is a pure cost:
no gain in verbatim rate, one request per line, and no marker back at all when the target is English. **And before any
wiring: `restoreSourceTokens` must be made literal-safe (whole-token match) or it will damage the identifiers it is meant
to protect — it broke 20 of 344 spans the engine had already returned correctly.**

## 7. What was not measured

- zh-Hans→ko on the low-latency path: the pack is not installed on this Mac and no pack was downloaded.
- The `email`, `version` and `hotkey` reasons: no block in either corpus produced such a span (the reasons found are
  url, id, path, cmd, flag, hash, config), so they are untested here.
- The block ids of the `vn` (Vision) reads: excluded by the spec, only doc reads were used.
- The marked path was measured with at most 8 requests in flight; the app's own marked path runs them in an unbounded task
  group, so the wall-time ratio in the app may be lower than the 1.10–1.25× measured here.
- Only the app's `restoreSourceTokens` was applied. `applyGlossary` (TranslationService.swift:826) was not, because no
  glossary was configured; it replaces whole source terms, so it would only touch a literal that is itself a glossary entry.

## 8. Files

- `tools/apple-translation-probe/literal-survival.swift` — the probe (new).
- `docs/research/translation/apple-probe/literal-survival-2026-10-20.jsonl` — the raw output (new, 1139 lines, 588 KB).
- `docs/research/translation/literal-survival-2026-10-20.md` — this file (new).
