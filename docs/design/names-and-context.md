# Names, terms and context: what applies where

Status: design, 2026-10-21 (round names1). It builds on `docs/design/context-translation.md` (the request model, §2-§10) and
does not repeat it. Inputs:
- ~/.cache/mwoyeo-research/glossary-2026-10/report.md (web evidence by kind). Its §6 is read as proposals. Each one is
  taken or dropped below, and the strength of its evidence is stated where this design leans on it.
- The code at 513ce90 (cited `path:line`), and round mem-hints' diff (name-only lines), which is not on main yet: it is
  uncommitted in /Users/hckim/repo/mwoyeo-wt-mh2 (`ContextMemory.sendable`, `ContextMemory.exactTranslation`).
- Our own bench data (`tools/translation-bench/memory`, `sequences`) and the film runs (README "이름이 줄마다 다르게 나올
  때", docs/ROADMAP.md 1.1.5).

The user, 2026-10-21: "이 단어장 혹은 문맥을 좀 더 잘 디벨롭 해줘. 상황에 맞게 쓰이게 잘 구성해야 해. 이게 글로벌도 있을 거고
앱 단위로도 해야 되고, 이런 걸 설정 UI와 실제 OS에서 읽어낼 정보와 잘 맞춰야 해. 모범사례 있는지 리서치도 해 보고." In
English: develop the glossary and the context so each is used where it fits; there is a global one and a per-app one; match
them to the settings UI and to what the OS actually tells us; look for best practice.

## 0. Today, in facts

| Part | What it is | Where |
|---|---|---|
| Glossary (global) | one string, a `src = dst` pair per line; no language pair, no kind | `App/Model/Settings.swift:200`, `:261-267` |
| ↳ Apple Translation | the output is patched where `src` survived into it (default path, untouched by this design) | `App/Pipeline/TranslationService.swift:733`, `:826-832` |
| ↳ Foundation Models ("glossary first") | the whole list in the instructions, inside a 4,096-token window | `Core/Sources/MwoyeoCore/TranslationContextLayout.swift:501-519`, `:198` |
| ↳ chat and Anthropic | the whole list in the system prompt (Off) or the rules (context path), minus pairs an app row replaces | `ChatTranslation.swift:97-105`; `TranslationContextLayout.swift:336`, `:457-460` |
| ↳ DeepL | only with `deepLInstructions`: the pairs that occur, after the rows, at most 8 names | `DeepLTranslation.swift:40`, `:89-94` |
| App memory | `AppProfile.note` (500) and `entries` (40) | `Core/Sources/MwoyeoCore/AppProfile.swift:44-62` |
| ↳ language lock | a profile always carries a pair; the app in front applies it | `AppProfile.swift:49-52`, `:197-202` |
| ↳ how it is made | the lens menu's "Remember Languages for X", only on an anchored lens; or MCP `set_memory`, on the base pair | `App/Model/RegionSession.swift:692-705`; `App/Support/MCPTools.swift:427-428` |
| ↳ how it is edited | Settings › Translation › App profiles › ⋯ › Memory…, nowhere else | `App/UI/SettingsView.swift:237`; `App/UI/AppMemorySheet.swift:5-6` |
| Learned rows | per app, RAM; opt-in `useLearned`; written to `Memory/<bundle id>.json` under `savesTranscripts`, never read back | `TranslationContextMemory.swift:189-226`; `App/Context/LearnedMemoryFile.swift:12-31` |
| Pin | a learned row becomes an app row; never creates a profile | `AppProfile.swift:211-221` |
| Selection | rows whose `src` occurs in an item, and persons named in the lines around; user rows first; a token budget (400 / 250 / 100) | `TranslationContextLayout.swift:377-399`, `:189-200` |
| Matching | case, width and accents folded; an ASCII word guard; any other script matches as a substring | `Core/Sources/MwoyeoCore/TranslationContextTokens.swift:77-104` |
| Apple pins | opt-in `appleUsesPinnedTerms`: the app's user rows go into the source; the glossary does not | `App/Context/ContextPlan.swift:39-40`; `TranslationContextAppleTerms.swift:45-49` |
| What the lens knows | bundle ID and name of the window's owner, `LSApplicationCategoryType` as a word, the confirmed normalised title | `App/Context/LensWatch.swift:42-84`; `App/Context/LensContext.swift:9-30` |
| How a memory is found | the profile of the lens's bundle ID; the engine is the front app's | `App/Context/ContextRoute.swift:24-28` |

Two defects found while reading:
- **D1, memory lost from the lens menu.** "Remember Languages" is offered when `existing != now` (`RegionSession.swift:699`).
  `now` has no memory, so once an app has a note or names the item is always there. Choosing it replaces the whole profile
  (`AppProfiles.remembering`, `AppProfile.swift:223-227`): the note, names, reader and context override are gone. "Forget
  Languages" (`RegionSession.swift:703`) deletes the memory too, and says only "Languages".
- **D2, the whole glossary in every prompt.** A 300-line glossary goes into each chat, Anthropic and Foundation Models
  request. On Foundation Models it shares 4,096 tokens with the instructions, the line and the answer.

## 1. The model

### 1.1 Scopes

Three nested scopes: **all apps** (the glossary) ⊃ **one app** (its bundle ID) ⊃ **one window of that app** (its confirmed
title contains a phrase the person chose).

| Scope | Key | OS signal | Permission | Direct build | App Store build |
|---|---|---|---|---|---|
| All apps | none | — | — | yes | yes |
| One app | bundle ID | `NSRunningApplication(processIdentifier:)` of the window's owner (`LensWatch.swift:82`) | none | yes | yes |
| One window | phrase ⊂ confirmed title | `kCGWindowName` (`App/Support/Graphics.swift:105`), confirmed on 3 reads over ≥ 1 s | Screen Recording, which every lens already needs | yes | yes |
| App category | — dropped | `LSApplicationCategoryType` | none | — | — |
| Site URL, document path | — dropped | Accessibility (`kAXDocumentAttribute`, AX tree) or Apple Events | Accessibility or Automation | new prompt | no |

**Why a window scope, and keyed how.**
- One bundle ID often hosts many works: an emulator runs many games, a compatibility layer runs Windows games, a VM, a
  browser runs many sites, a video player plays many shows. The bundle ID cannot tell two games in one emulator apart, and
  their names collide (one game's ハク is not the other's).
- Practice: termbases are ranked by client, domain and document in professional tools (report §1, a quote on ranking by
  "client, domain, subject"). Fan-translation tools split term files by executable or window title (report §4; the quote
  supports only that a generated file has the lowest priority). Both are thin on windows. So the window scope comes after
  the app scope works, and only the person who looks for it sees it (§3).
- Keyed by a **phrase**, not by a hash of the title (report §6 proposes a hash). Titles change with the page, the episode,
  the chapter and unread counts; a hash would lose the memory on every change. The person shortens the confirmed title to the
  part that names the work ("月涙譚"). It matches with `ContextText.occurs` on the normalised title, so case and width do not
  matter. The title picks the scope on this Mac and is not sent anywhere because of it: memory-only requests still carry no
  title (`LensContext.appOnly`, `LensContext.swift:28-30`).
- A new window shows the app scope until its title is confirmed (≈ 1 s, `LensContext.swift:15-16`).

**Why not the others.**
- App category: the developer sets it for store browsing (report §5 quote: "The category that best describes your app for the
  App Store"). One category spans unrelated works whose names conflict, and "every game" is covered by the glossary. It
  stays the card's domain word.
- Site URL and document path: they need Accessibility or Apple Events. Sandboxed apps get neither (design
  context-translation §1b). A site that names itself in its title is reached by a window phrase in both builds.
- Apps with no bundle ID (Windows games run by a compatibility layer report a bare executable): `LensWatch.window(of:)`
  returns nil and they get no memory at all (`LensWatch.swift:82`). Unmeasured on this Mac; a probe comes first (§5, G16).

### 1.2 What an entry carries

| Field | Decision | Why |
|---|---|---|
| `src`, `dst`, `kind`, `gender`, `note` (40), `addressing` | keep | `TranslationContextMemory.swift:43-60`; the localisation kits of report §4 carry name, gender, role and register per character |
| `reading` | keep, and **also match on it** | Japanese writes one name in kanji or kana (九十九 / つくも). An exact match on a string the person wrote; the IGDA quote (report §4) asks for pronunciations in the term list |
| keep as written | **no flag**: `dst == src` means it | already a valid user row (`AppProfile.swift:104-121` checks only empty). The sheet gets a "Keep as Written" action. Apple pre-insertion skips identity rows (`TranslationContextAppleTerms.swift:58`), so the sheet says Apple may still change it |
| case rule | **no field** | case exists only in Latin-script sources. The LLM side folds case and a false hit costs one row. Apple pre-insertion already matches a capitalised term as written (`TranslationContextAppleTerms.swift:62-64`), and its one false hit ("Will" at a sentence start) is not cured by a flag |
| forbidden ("never write X") | **no** | report §3: negative constraints fail on small models (stated without a quoted number: opinion-grade) |
| `origin` user / learned | keep, RAM only | `TranslationContextMemory.swift:83-87` |
| scope | **not a row field** | the container is the scope; provenance is computed when scopes merge (§1.4) |
| target language | **not a row field** | an app memory lives under its profile's pair (the lock above), so its `dst`s are in that target. The glossary stays pair-free, as today |

### 1.3 Precedence and conflicts

One rule with one owner: `ContextMemory.sendable` (mem-hints), widened to take the scopes in order.
1. The same `src` (`MemoryEntry.id`, folded) in several scopes: the narrowest user row wins (window > app > all apps). The
   broader row is neither sent nor pre-inserted. Today this holds for app over glossary (`TranslationContextLayout.swift:336`).
2. A user row outranks a learned row at every scope. A learned row whose `src` is a user row in any active scope is not sent
   (today: app and glossary, `TranslationContextLayout.swift:331-332`).
3. Learned rows are kept under the narrowest active scope (the window scope when one matched, else the app). Two games in one
   emulator never share learned names. Pin puts a learned row into that same scope.
4. One window scope is active at a time. When two phrases match one title, the longer phrase wins; on a tie, the first in the
   list.
5. Notes: the app note, then the window note, each with its own cap, both in the stable block. The glossary has no note.

### 1.4 Provenance

The merge returns each row with `from` (`all` / `app` / `window:<phrase>` / `learned:<scope>`) and `shadows` (the broader rows
it hid). It is shown in three places, and none of them sends anything off this Mac:
- the Memory sheet (§3);
- `get_memory` (§4);
- the translation log's JSON line gets `names`: the `src`s of the rows sent with that line. It is a local file, written under
  `savesTranscripts` like the rest of the log. No new telemetry.

## 2. Choosing what goes with one request

### 2.1 Matching (ja, zh, ko without guesses)

- Keep `ContextText.occurs` (substring, folded). It fits ja, zh and ko: particles attach after a name (アリスが, 앨리스가) and
  the name stays a substring, so no segmenter is needed. The report's "particle-aware stripping" (§6) cures a problem that
  token matching has and substring matching does not.
- Add the `reading` as a second key for the same row.
- Not added: fuzzy or stem matching, kana↔kanji, simplified↔traditional folding. Each is a guess; a second row is the
  person's way to say "this too".
- A one-character Han `src` (王) also hits inside longer words (王様). On an LLM that costs one row. Apple pre-insertion would
  break the word, so the sheet warns under such a row: "One-character names also match inside longer words." No matching
  change.
- Overlaps: the LLM gets both rows (田中 and 田中太郎; harmless). Apple pre-insertion keeps the longest, as today
  (`TranslationContextAppleTerms.swift:55-57`).

### 2.2 The cap, measured

- Measured in this round over our 15 bench sequences (481 lines, 4-8 rows each, script in the round's scratch): rows hit per
  line 0: 311, 1: 142, 2: 26, 3: 2. Per 3-line batch, the lens's batch size (`App/Pipeline/RegionPipeline.swift:1598`,
  `limit: 3`), across 164 batches: 0: 59, 1: 55, 2: 28, 3: 17, 4: 5. The maximum is 4.
- The report's "5 to 7 per request" (§3, §6) has no quoted study number behind it: opinion-grade.
- Decision: the token budget stays the owner (`ContextBudget`), and it gets one more column, `maxRows`: **8** for cloud and
  local (DeepL already sends at most 8 names, `DeepLTranslation.swift:40`), **4** for Apple FM (its 100 tokens hold about 4
  rows). 8 is twice the observed maximum, so it binds only on dense lines.
- Order inside the cap: item hits before speakers in the lines around, then window, app, all-apps user rows, then learned
  rows, then today's uses and last-seen order.
- On the context path the glossary becomes rows under the same selection and cap (hits only), instead of the whole list in
  the rules. Off sends today's bytes (the golden gate, §5).

### 2.3 Note, cast and rolling context stay apart

- The stable block (system, cacheable) holds the rules, the card, the app note and the window note (`cardNote`,
  `TranslationContextLayout.swift:312-317`).
- The volatile last message holds `memory` (cast and terms in one list; `kind` says which), `referents`, `context_before`,
  `context_after` and `translate` (`:472-497`). Unchanged.
- The only change: glossary pairs leave the stable rules and join `memory` as hits. The cached prefix gets shorter, which
  design context-translation §4 already accepts.

### 2.4 Per engine kind

| Kind | Rows | Notes | Glossary |
|---|---|---|---|
| Chat, Anthropic | hits, cap 8, scopes merged | app + window note in system | Off: today's whole list (unchanged). Context path: hits as rows |
| Apple FM ("glossary first") | hits, cap 4 | trimmed, as today | today the whole list; hits only if the user agrees (Q2) |
| DeepL (opt-in `deepLInstructions`) | "Write X as Y." up to 8, scopes merged | note in 2 pieces of 300 chars | hits, after the rows (today) |
| Apple Translation | pre-insertion of user rows from every active scope, only with `appleUsesPinnedTerms`; learned rows never | — | off: today's output patch, untouched. On: pre-inserted like the app's rows (Q3) |

**DeepL glossaries API vs today's instructions.**
- For it: DeepL applies glossary entries exactly and inflects them (report §2, DeepL docs quote). There is no 8-name limit and
  it does not use the 10 × 300 instruction budget. It also reaches targets that get no names today: instructions are sent
  only for DE, EN, ES, FR, IT, JA, KO and ZH (`DeepLTranslation.swift:36`).
- Against it:
  - A glossary needs `source_lang`. The DeepL docs, read 2026-10-21, say "glossaries can't yet be used with automatic source
    language detection", and lenses often run on auto.
  - It keeps state on DeepL's side per key and pair: create, PATCH on change, delete on forget, and heal a stale id.
  - The glossary count is limited by plan; the Free plan's limit is not stated.
- Measured: instructions kept the memory's name on 8 of 8 lines in the film run (README; ROADMAP 1.1.5 A).
- Decision: instructions stay the DeepL path. Glossaries are parked until a user asks for a target outside the 8 families,
  or a measured miss shows more than 8 hit rows (Q4).

**Apple Intelligence "glossary first"** is the Foundation Models engine choice (`Settings.swift:11`, `:32`). It promises to
follow the glossary. Hits only keeps that promise on every line: every pair it could follow on that line still goes.

## 3. The settings UI

### 3.1 Where each scope lives

| Scope | Edited in | Seen from the lens |
|---|---|---|
| All apps | Settings › Translation › Glossary (text, as today). The footer adds: "For every app. Names of one app go in its memory." | counted in the lens menu's info line |
| One app | the Memory sheet, from the lens menu **or** Settings › Translation › App profiles › ⋯ › Memory… | "Memory for <App>…" |
| One window | the same sheet, scope control "This window" | "Memory for <phrase> (<App>)…" when a window scope matched |

### 3.2 An app gets a memory without "Remember Languages"

- The lens menu gets **"Memory for <App>…"** for every lens whose app is known, anchored or not. It uses the window rule of
  `LensWatch.window(of:)` (anchored window, else the topmost window under the centre). Today profile items need an anchor
  (`RegionSession.swift:694`).
- It opens Settings at Translation with that app's Memory sheet. One sheet, one owner; there is no second window type.
- Opening creates nothing. The first edit (a note, a name, a pin) creates the profile with the pair in effect while that app is
  in front (`AppSettings.effective(frontmost:)`). So nothing translates differently at that moment. It is the same function MCP
  `set_memory` uses, moved into one owner (`AppProfiles.ensuring`), and Pin's `.noProfile` goes away for the same reason.
- D1 fix:
  - "Remember Languages" compares only the pair and the engine, and merges them into an existing profile.
  - On an app with memory, "Forget Languages" becomes "Forget <App>…" with an alert: "Forget the languages and the memory
    for <App>? Its note and <n> names are removed."

### 3.3 What the lens shows

- No change to the lens pill (progressive disclosure).
- In the lens menu, a disabled info line sits above "Memory for …" when any row applies: "Names: 5 — 月涙譚 3 · all apps 2".
  It is at most 48 characters, cut at the tail. It is hidden when nothing applies. The app name in the item is cut in the
  middle at 24 characters.
- The engine sheet's "Sent:" line adds the scope words: "3 names (2 this app, 1 all apps)"
  (`TranslationContextLayout.swift:562-581`).

### 3.4 The Memory sheet contract (520 × 640, `AppMemorySheet.swift:41`, `:18`)

- **Header:** "Memory for <App>" (layout priority 1, cut in the middle). Then, only when the opening lens has a confirmed title
  or the app has a window scope, a segmented control **220 pt** wide: "All of <App>" | "This window". "This window" is
  disabled without a confirmed title.
- **"This window" with no scope yet:** a phrase field above the note, prefilled with the confirmed title (the normaliser's caps:
  CJK 40, Latin 60 characters), caption "Used while the window title contains this." The app has at most 8 window scopes;
  the others are listed in a menu beside the field ("Other windows").
- **Sections, in today's order:** Note, Names and terms ("Names: n of 40" per scope), Context, Learned.
- **New "Also used here"** (collapsed, read-only, after Names):
  - in a window scope: the app's rows and the glossary rows that apply;
  - in the app scope: "<n> from the Glossary" and an "Edit Glossary…" button.
  - Hidden when empty.
- **A row that shadows a broader row:** one caption line, secondary, cut at the tail: "Replaces “ハク → 하쿠” from all apps".
- **Row ⋯ menu** (trailing; the minus button stays): "Keep as Written", "Move to All Apps" (the glossary keeps only the name
  and its translation; the menu item says so), "Move to <App>" or "Only in This Window".
- **Learned rows:** Pin goes to the active scope.
- **Empty Names section:** "Names you add here are used only in <App>." (or "…only in this window") above Add Name.
- **Unchanged:** the "Use my names and terms with Apple Translation" switch stays where it is (`SettingsView.swift:247-249`).

## 4. Agents (MCP)

- `get_memory(app, scope?, title?)`:
  - adds `windows` (each `titleContains`, `note`, `entries`);
  - with `title`, adds `effective`: the merged rows for that title with `from` and `shadows`, the glossary included;
  - adds `learned` read from `Memory/<bundle id>.json` with its `updated` time. `Mwoyeo --mcp` is another process and cannot
    read the app's RAM; the tool says so when the file is absent.
- `set_memory(app, scope = app | window | all, titleContains?)`:
  - `window` needs `titleContains`;
  - `all` merges `src = dst` lines into `glossary` and rejects kind, gender and note with a message.
  - It is the same validation and the same `AppProfiles.ensuring` as the sheet.
- `term_renderings(app, title?, since?, limit?)`, new and read-only:
  - for each row in effect: the log lines whose original holds `src`, how many translations hold `dst`, and up to 3 lines
    that do not (time, original, translation);
  - names not in the memory that came out inconsistently, from `GlossarySuggester`, which is in Core and unwired today
    (`Core/Sources/MwoyeoCore/GlossarySuggester.swift:4-8`). That is an analysis for the agent and is never applied to output.
  - Same preconditions as `read_translation_log` (log on, jsonl).
- The log line's `names` (§1.4) lets an agent see which rows went with a line.

## 5. Gap table and rounds

| # | Today | Target | Size | Gate (FAIL-first on today's code) |
|---|---|---|---|---|
| G1 | D1: `RegionSession.swift:699-704`, `AppProfile.swift:223-227` | Remember merges pair+engine; Forget asks when memory exists | S | check-logic "remembering languages keeps the app's memory" |
| G2 | memory needs an anchored lens + Remember; sheet `.noProfile` (`App/Model/AppProfiles.swift:5-13`, `:105-111`) | "Memory for <App>…" on every lens; `AppProfiles.ensuring` shared with MCP and Pin | M | check-logic: a first edit creates a profile whose pair equals `effective(frontmost:)`; MCP and sheet call one function |
| G3 | precedence only app > glossary > learned | `sendable` takes ordered scopes, returns `from`/`shadows` | M | Core unit tests per rule of §1.3 |
| G4 | D2: glossary whole in rules (`TranslationContextLayout.swift:457-460`) | hits as rows on the context path | M | Core: a 300-pair glossary sends only its hits; Off goldens unchanged |
| G5 | token budget only (`:177-200`) | `ContextBudget.maxRows` 8 / 8 / 4, order of §2.2 | S | Core: 12 hits → 8 rows in that order |
| G6 | `src` only (`:378-381`, `TranslationContextAppleTerms.swift:51`) | `reading` also matches | S | Core: つくも hits the 九十九 row |
| G7 | Apple pins = app rows (`ContextPlan.swift:39-40`) | merged user rows of every active scope; glossary per Q3 | S | Apple request bytes unchanged with the switch off |
| G8 | no window scope (`AppProfile.swift:44-62`, `SettingsFile.swift:207-225`) | `appProfiles[].windows[]` ≤ 8: `titleContains`, `note`, `entries`; schema, strict check, lenient decode; `ContextRoute.pair` picks it before `appOnly` drops the title; `needsWindow` counts window rows | M | `AppProfileTests` key test extended; `--check-settings` error on a 9th window; route unit test |
| G9 | sheet has one scope (`AppMemorySheet.swift:28-41`) | §3.4 contract | M | MemorySheetChecks captures + one opus vision verdict |
| G10 | `get_memory`/`set_memory` app only (`MCPTools.swift:402-460`) | §4 scopes, `effective`, `learned` | M | MCPChecks: window and all scopes round-trip; a bad scope names its path |
| G11 | `GlossarySuggester` unwired | `term_renderings` | M | MCPChecks on a fixture log |
| G12 | log lines carry no rows | `names` per line | S | check-logic: a line without memory has no `names` key |
| G13 | learned per app (`App/Context/ContextBook.swift:27`) | per narrowest scope | S | unit: two window scopes keep separate learned rows |
| G14 | name-only lines need an engine (mem-hints `exactRows`) | Apple with pins on serves a name plate from a user row | S | check-logic; off → Apple asked as today |
| G15 | "Sent:" counts only | scope words | S | ContextChecks sent-preview rows re-pinned (copy) |
| G16 | apps with no bundle ID get no memory (`LensWatch.swift:82`) | probe first: what such a window reports; then key by executable name | S probe | a probe tool in `tools/`, report only |

Rounds, each under 400k. Every round keeps the **default-path gate**: Core `TranslationContextGoldenTests` (`*OffIsToday`)
and check-logic "Off …: the request bytes are main's" (`App/Support/ContextChecks.swift:561`). Each also adds its own:

| Round | Gaps | Files (one owner each) | Its own default-path gate |
|---|---|---|---|
| R1 `names-lens` | G1, G2, G15 | `RegionSession.swift`, `App/Model/AppProfiles.swift`, `AppProfile.swift`, `MCPTools.swift` (the `ensuring` call), strings | "a profile with no note and no name sends the bytes of no profile" (`ContextChecks.swift:768`) |
| R2 `names-core` | G3, G4, G5, G6, G13 | `TranslationContextMemory.swift`, `TranslationContextLayout.swift`, `ContextBook.swift`, Core tests (after mem-hints lands) | Core goldens; DeepL bodies without the opt-in unchanged (`ContextChecks.swift:786`) |
| R3 `names-apple` | G7, G14 | `ContextPlan.swift`, `TranslationContextAppleTerms.swift`, `TranslationService.swift` | `theFlagIsOffByDefaultAndOffMeansTheInputUntouched` (`TranslationContextAppleTermsTests.swift:19`) |
| R4 `names-window` | G8, G12 | `AppProfile.swift`, `SettingsFile.swift`, `ContextRoute.swift`, `ContextPlan.swift`, transcript writer | a profile without `windows` encodes byte-identical (`AppProfileTests.swift:69-76` pattern) |
| R5 `names-window-ui` | G9 | `AppMemorySheet.swift`, `AppMemoryEditor.swift`, `SettingsView.swift`; then a vision round | Settings with no profile shows no App profiles section (captures) |
| R6 `names-agents` | G10, G11, G16 | `MCPTools.swift`, `MCPChecks.swift`, `docs/settings-for-agents.md`, `tools/` probe | MCP `get_memory` of an app without windows returns today's keys plus empty ones only |

R1 and R2 can run in parallel (no shared file). R4 waits for R2 (the scoped `sendable`). R5 waits for R4. R6 waits for R4.

## 6. Open questions for the user

1. **A memory for one window** (one game in an emulator, one site in a browser), chosen by a phrase of the window title?
   Recommended: yes, as R4-R5 after the app memory works. It is shown only in the Memory sheet when the lens has a title. It
   reads nothing new: the title is already read under the Screen Recording grant, in both builds.
2. **Foundation Models ("glossary first") with a long glossary**: send only the pairs that occur in the line instead of the
   whole list? Recommended: yes. Every pair it could follow on that line still goes, and its 4,096 tokens stop filling up.
3. **With "Use my names and terms with Apple Translation" on**, do the glossary's pairs also go into the source, like the
   app's names? Recommended: yes, so "my names" means one thing. With the switch off, Apple stays exactly as today.
4. **DeepL**: keep names in DeepL instructions (8 of 8 kept in our run) and park the glossaries API until a target outside
   DE/EN/ES/FR/IT/JA/KO/ZH is asked for? Recommended: park. A glossary also needs a fixed source language.
5. **"Memory for <App>…" in every lens's menu**, unanchored lenses included, creating nothing until the first edit?
   Recommended: yes. The lens is where the person is when a name comes out wrong.

**Decided 2026-10-21 (the user):** window scope yes; only the glossary pairs that occur go with a request; the Apple switch
pre-inserts pinned names of every scope, the glossary included; "Memory for <App>…" goes in every lens menu. DeepL's
glossaries API stays deferred (it cannot be used with automatic source detection).
