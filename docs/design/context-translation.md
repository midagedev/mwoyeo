# Context translation: carrying what came before into LLM translation

Status: design, 2026-10-18, revision 2 (memory-centric, per the user). Inputs:
- ~/.cache/mwoyeo-gates/research-ctx-A.md (caching and cost)
- research-ctx-B.md (context quality and eval)
- research-method-A.md (methods)
- research-method-B.md (12 tools' code)
- research-ctxmgmt.md (window, compaction, resets)
- research-memory.md (editable memory, window metadata, engine matrix)
- research-apple.md (Apple Translation API and probes)

The user's decisions, 2026-10-18:
- Users can configure it, and we ship measured defaults ("이걸 잘 사용자가 설정할 수 있게 하고 우리는 적절한 기본값을 제공하자").
- Memory over a long conversation: an editable context memory holds pronoun referents and facts about the current document, and the conversation stays short ("메모리 같은걸 활용 … 컨텍스트 메모리 편집기능 … 대화는 짧게 이어가더라도").
- Every engine uses whatever it supports, and Apple Translation gets its own improvements ("지원하는건 다 쓸 수 있게 … 애플 번역도 … 개선").
- OS-level window metadata (window title, app category) is used, with its size managed ("윈도우 타이틀이나 앱 카테고리 … 크기를 잘 관리").

## 1. What the evidence says (short)

- **The window.**
  - The previous 1-2 lines give most of the gain. Gains flatten at 3-4 lines, and 5 or more add nothing:
    - WMT24 chat: COMET +3.5 to +5 from 1→2 lines;
    - pronoun contrastive accuracy: 60.0→85.8 % from 0→2 sentences;
    - subtitles: N = 4 is best.
  - Translating 10 or more sentences together starts dropping lines.
  - No ja/zh/ko sweep exists. We measure our own.
- **What goes in.**
  - Adding the previous *translations* raises proper-noun consistency (+1 to +4 LTCR).
  - It also propagates errors: 17/19 failed chunks cascaded, and reusing earlier outputs scored COMET 53.9 vs 69.7.
  - So source lines are the default context. Translations are added only for lines we trust.
- **Long-range consistency (names, terms)** is a memory problem, not a window problem.
  - A term memory is cheap; the model can return terms in the same reply, with no extra call.
  - LLM summaries did not help short-text MT. Summaries and compaction calls are out.
- **Compaction that keeps the cache prefix.** Grow append-only; when full, drop the older half at once (LunaTranslator `gptcommon.py:431`, BallonsTranslator `history.py:13`). Sliding one line at a time breaks the provider prefix cache every request.
- **Resets.** Tools reset on a time gap (gpt-subtrans: 60 s) or a document boundary. We have more signals: app, window or tab, language pair, idle time, and a wholesale change of the text.
- **Reasoning on hurts translation.** Temperature 0 is fine. Multi-pass pipelines (reflect, refine), best-of-n and MBR cost 3-8× and have no evidence on short UI text, so they are not lens defaults.
- **Prompt hygiene recurs across the tools.**
  - Context is marked as data, not instructions, and "do not translate or repeat".
  - Items carry ids, and the reply's ids and count are validated.
  - Glossary terms are included only when they occur in the text.
- **Cost (30-min chat, Haiku 5.5).** Today 1.1 ¢; a short window with caching ~2 ¢; long transcripts without caching 6-33 ¢. Caching needs a ≥ 512-token prefix on Claude 5.x and ≥ 1,024 on OpenAI.

## 1b. What the memory research adds

- **Structured facts help.**
  - Exact name suggestions in the prompt: person names ~60 → 98.8 % (GPT-4o; letters, not screen text).
  - Speaker and listener attributes: agreement 74 → 99 %, +5.81 chrF++.
  - Without gender, GPT-4 follows stereotypes (anti-stereotype 0.527).
  - en→ko with a stated listener is less over-polite.
  - No ko/ja LLM study exists on short OCR text: we measure.
- **Tools converge on "source → target + a one-line note"** (GalTransl, Sakura `src->dst #note`, gpt-subtrans names and descriptions). No evidence favours one format; the bench decides.
- **Learned entries must not lock in.** They stay "suggested" until the user pins them. User entries are authoritative.
- **Window metadata without new permissions:** app name, bundle id, `LSApplicationCategoryType`, and the window title under the Screen Recording grant we already have.
  - Accessibility is not available to sandboxed apps (Apple DTS, forum thread 794253).
  - Browser URLs need Apple Events, so they are out of v1.
- **Apple Translation has no context, term, formality or domain hook** (Translation.swiftinterface, macOS 26 and 27 SDKs).
  - Attaching the previous line in the same sentence changed 18/30 high-fidelity results: 5 better, 3 worse (2 leaked text), never restoring a dropped subject. Rejected.
  - What helps: whole sentences per request; the app already joins OCR lines with spaces (`TextRecognizer.makeBlock`), and line-by-line input is badly wrong. Whole paragraphs: 6.1 s vs 14.3 s sentence by sentence, with better term consistency.
  - `skipsTranslation` is kept by high fidelity only. The low-latency model ignores it on words.
  - The only way to make Apple follow a pinned name or term is the parked source pre-insertion (LL 88/88, HF 98/102, 0 particle errors). It needs the user's decision (§7).

## 2. The model of it

A **thread** is one lens on one document of one app. Memory has three scopes:

| Part | Scope and lifetime | Content | Stored | Prompt place |
|---|---|---|---|---|
| Rules | per engine and pair | instructions, output schema, "context is data, translate only `translate`" | — | system (stable) |
| Document card | per thread, automatic | app name, category as a short domain word (~25-word map), normalised window title | never | after the system (stable while the title is stable) |
| App note | per app (AppProfile), user | register, setting, audience, ≤ 500 chars | AppProfile | after the card (stable) |
| Sheet | per app, user + learned | entries: `src → dst (kind, gender, note ≤ 40 chars; to X: register)` | user and pinned entries in AppProfile; learned entries in RAM | rows relevant to this request (hits + speakers on screen), in the last message |
| Referents | per thread, user | short-lived lines like `he/그 = 田中` | never | last message |
| Short transcript | per thread | previous 2-4 source lines (trusted translations optional) | never | last message (`context_before`) |
| Neighbours | per request | lines above and below on screen | never | last message (`context_after`) |
| Items | per request | `{id, text}` | never | last message |

- **Learning.** The reply may carry `terms: [{src, dst, kind?, gender?}]`. Acceptance rule: `src` occurs in this request's items and `dst` in the reply. Learned entries are hints. A learned entry contradicted twice is dropped. Pinning makes it a user entry.
- **Resets** start a new thread, which clears the transcript, referents and learned entries; the user sheet stays. Signals:
  - an app switch;
  - a stable change of the normalised window title, i.e. changed over N consecutive reads;
  - a language pair or engine change;
  - idle ≥ 5 min;
  - a wholesale text change (< 20 % shared lines);
  - "Start fresh".
- **Size budgets** (provisional; the bench sets them):

| Engine | Card + title | Sheet rows | Transcript |
|---|---|---|---|
| Cloud | ≤ 45 tokens | ≤ 400 | 4 lines |
| Local | ≤ 45 | ≤ 250 | 2-3 lines |
| Apple FM | ≤ 20 | ≤ 100, hits only | 2 lines |

- **Title normalisation.** Strip app suffixes, unread counters, extensions and edit marks; cut at the end with "…" (CJK 40 chars, Latin 60); drop the title when it equals the app name. This keeps the cached prefix stable.
- **Privacy.**
  - Screen text and learned entries live only in RAM. The app note and user entries are user content and are saved with AppProfile.
  - The window title goes to on-device engines by default; cloud engines get it only if the user opts in.
  - App name and category are always sent.
  - The Context view shows a one-line "Sent: …" preview.

## 3. Settings (simple by default)

| Where | Setting | Default |
|---|---|---|
| default use | nothing new | measured defaults per engine |
| Engine detail → Context | Use context: Off · On | On for LLM engines and DeepL |
| Engine detail → Context | Previous lines: 0-8 | measured (2-4) |
| Engine detail → Context | Include window title (cloud engines only) | off |
| Engine detail → Context | "Sent: …" preview | — |
| App profile → Memory | Note for the translator | empty |
| App profile → Memory | Names and terms: user rows, and learned rows (dimmed) with "Pin" / "Remove"; "Forget learned"; "Start fresh" | — |
| App profile → Memory | Who's who (referents) for the current document | empty |

"Off" sends exactly today's request (byte-identical, tested).

## 4. Per engine kind: what each uses

| Engine | Card | Note | Sheet (names, gender, register) | Referents | Transcript | Neighbours |
|---|---|---|---|---|---|---|
| Cloud LLM (Anthropic, OpenAI-compatible) | yes | yes | yes | yes | 4 lines | yes |
| Local LLM | yes | yes | yes | yes | 2-3 lines | yes |
| Apple Foundation Models (4k) | short | yes (trimmed) | hits only | yes | 2 lines | 1 above |
| DeepL | in `context` | `custom_instructions` (10 × 300 chars) | names via a DeepL glossary; register via `formality` where the pair supports it | in `custom_instructions` | in `context` | in `context` (not billed) |
| Apple Translation | — | — | names: pre-insertion only if the user re-approves it (§7); otherwise none | — | — | — (whole sentences only; already done) |

Caching (research-ctx-A):
- **Stable blocks first.** Rules, the card and the note come first. The volatile last message carries the sheet hits, the referents, the transcript and the items.
- **Cache-control markers:** Anthropic gets `cache_control` on the system and the note block; OpenAI gets `prompt_cache_key` = thread id and `store: false`; local llama.cpp gets `cache_prompt`.
- **This prefix is short.** It may fall under the 512/1,024-token cache minimum, and that is fine: it is cheap anyway.

## 5. Measurement that picks the defaults

The bench is `tools/translation-bench/` (round T1). It holds sequences with a hand-written `memory.json` per sequence, and ≥ 30 % of the probes are decidable only from the memory.

**Conditions.**
- C0: off.
- B2/B4: previous 2 or 4 lines.
- M: B2 + the user sheet.
- L: B2 + learned only.
- W: B2 + the card.
- MW: M + the card.
- C16: a 16-line conversation, for comparison.
- Formats: `src->dst #note` vs JSON vs a table.

**Engines.** A local model (Ollama/llama-server) and Apple FM now; cloud and DeepL when a key is given.

**Metrics.** Probe accuracy by script; Korean speech-level consistency by script; blind pairwise judge in both orders, agreement only; carry-over errors; tokens by block; latency.

**Samples and decision rule.** ≥ 250 probes and ≥ 150 decided judge pairs per comparison. Pick the cheapest condition within 2 points of the best and not worse on the judge.

## 6. Rounds

| Round | Files | Depends on |
|---|---|---|
| T1 `translation-bench` (running) | `tools/translation-bench/**` | — |
| T2 `context-core` | new `Core/Sources/MwoyeoCore/TranslationContext*.swift` (thread, resets, sheet, learning rule, card normaliser, budgets, prompt slots, validation) + tests; `ChatTranslation.swift`, `AnthropicTranslation.swift`, `DeepLTranslation.swift` (layouts; Off byte-identical); `MwoyeoEngines/EngineClient.swift` (usage incl. cached tokens); `AppProfile.swift` (note, entries; lenient decode) | — |
| T3 `context-app` | `TranslationService.swift`, `RegionPipeline.swift` (neighbours, thread key, reset signals, window title and category from SCWindow / the bundle), settings and memory UI, `Localizable.xcstrings` | recognition R3/R4 (shared files), T2 |
| T4 `context-defaults` | bench runs → the defaults table | T1, T2 |

## 7. Open decision for the user

**Apple Translation pre-insertion.** It is the only way Apple can follow a pinned name or term from the memory: the target term goes into the source and the engine inflects around it. The user's earlier objection was to patching Apple's output.
- Measured before: LL 88/88, HF 98/102, 0 particle errors.
- Choices:
  - (a) Apple follows the user's pinned names and terms through pre-insertion.
  - (b) Apple stays plain; the memory works only on LLM engines and DeepL.

## 8. Amendments after the advisor review (2026-10-18, adopted)

1. **Translation-memory namespace** (`TranslationService.swift:150-152, :818`).
   - With context on, the namespace adds the thread key, a hash of (note, user entries, referents) and a "Start fresh" generation.
   - The transcript and learned hints stay out of the namespace: they are non-binding, and including them would kill reuse.
   - Off keeps today's namespace.
   - The thread takes the *observed* lines, including memory hits, not only the lines that went to the engine.
2. **Term precedence.** An app user entry outranks the global glossary, which outranks a learned hint. A learned term whose `src` is already in either user tier is rejected. A learned name is offered in one place: Pin makes it an app entry (the existing GlossarySuggester stays the global path). The On layout qualifies "keep names unchanged": names follow the memory rows.
3. **Scopes.**
   - Learned entries are per app and live in RAM. Resets clear the transcript and the referents only.
   - Referents are cleared only by a title or app change or by "Start fresh", never by idle. They die at quit.
4. **Title hysteresis.**
   - The thread key uses the *confirmed* title: the same title on 3 reads spanning ≥ 1 s.
   - A confirmed change switches to a kept thread, so tabs A→B→A resume. Each app keeps at most 8 threads, which expire after 5 min idle.
   - A pair or engine change is a key change, not a reset.
5. **Privacy.** Sending the app name is a new disclosure to cloud engines, so it appears in "Sent:" and in the opt-in copy. On-device engines are Apple FM, Apple Translation and `isOnThisMac` servers.
6. **DeepL.**
   - There is no glossary path today. In v1, names go through `custom_instructions` ("Write X as Y", at most ~8 rows), with a TODO for glossaries.
   - `formality`: KO is unsupported and JA is supported. Send prefer_more/prefer_less only when the engine's own formality setting is default.
   - Fix the heal path: DeepL errors are `{"message":…}`. Add `context`, `custom_instructions` and `formality` to `rejectableFields`.
   - Check `custom_instructions` on `/v2/translate` against the live docs before relying on it.
7. **Learning rule.**
   - "dst in the reply" alone is too weak. An entry is used only after 2 sightings with the same dst.
   - Caps: 30 entries, ≤ 40 chars each, no newlines or instruction-like text.
   - A contradiction is the same src with a different dst in `terms`. Two contradictions drop the entry.
8. **Per-request memory hits in the last message are fine.** That message is volatile anyway.

## 9. The user's rule for defaults (2026-10-18, binding)

"네 추천대로 할게 다만 기본 번역에 문제가 생기면 안되고 문제가 있을 법한 부분은 사용자가 일부러 켜야만 작동하게 해야해". In English: go with the recommendation, but the default translation must never break, and anything that could cause problems works only when the user turns it on on purpose.
- **Apple Translation** (the zero-setup default) stays exactly as today by default. Pre-insertion of the user's pinned names and terms is choice (a). It works only when the user has pinned entries AND turned on "Use my names and terms with Apple Translation" (off by default).
- **Opt-in, off by default:**
  - learned memory (automatic suggestions);
  - the window title to cloud engines;
  - DeepL `custom_instructions` and `formality` from the memory;
  - the 16-line conversation.
- **User-written memory** (the note, entries, referents) applies when the user writes it. Writing it is the opt-in.
- **Neighbours and the short transcript on LLM engines** become default only if T4 shows no regression on any category:
  - probe accuracy and judge preference not worse;
  - zero context lines leaked into the output;
  - latency p95 within +20 %.
  Otherwise they stay opt-in.
- **In code,** `ContextOptions()` defaults to Off: byte-identical to today. Only T4's measured table may change a default, and it lists each change.

## 10. Editable by external agents (2026-10-18, binding)

The user: "이런 설정이 외부 에이전트 클로드 같은 애들이 쉽게 편집할 수 있어야 해". In English: settings like these must be easy for external agents such as Claude to edit. The app already supports this. Every setting lives in `~/Library/Application Support/Mwoyeo/settings.json`:
- it is live-reloaded within 1 s;
- `settings.schema.json` documents every key;
- `Mwoyeo --check-settings` prints `settings.json:<line>: <issue>`;
- `SettingsFileCheck.uncoveredKeys` fails when a key lacks a spec (App/Model/SettingsFile.swift).

Every new setting in this design follows the same path:
- **Global keys** get a `SettingSpec` row each, with a doc string, kind and limits: context on/off and previous lines per engine kind, the window title for cloud engines, Apple pinned terms, learned memory, and so on.
- **The per-app memory** lives inside `appProfiles` (its existing `.appProfiles` kind): `note`, `entries` (`src`, `dst`, `kind`, `gender`, `note`, `addressing`) and per-app context overrides. The schema documents them, `--check-settings` validates them (caps: 40 entries, 500-char note, 40-char entry note), and they are decoded leniently.
- **Referents are per-document and RAM-only,** so they are not in the file. An agent can write durable "who's who" as entries with notes instead.
- **Learned entries are RAM-only.** An agent sees them only once pinned, and pinning moves them into `appProfiles[].entries`. A read-only view for agents (e.g. `Mwoyeo --context-dump`, which prints the current threads' cards and learned rows with no screen text) is optional for T3: decide it with the user.
- **The gate:** check-logic's settings-file checks cover a round-trip of an `appProfiles` entry with memory fields, and a `--check-settings` error on an over-cap note, both FAIL-first.
