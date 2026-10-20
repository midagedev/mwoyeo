# Names, terms and context: profiles

Status: design, 2026-10-21, round profiles1 (§6 by uiux1: three levels); revises names1's version (4715d5b, 86d1fb2) on top of `docs/design/context-translation.md`.
Kept from names1: entries, row choice per request (§3), engine paths, provenance, D1, D2. New: profiles replace the scopes (§1), engine
permissions (§4), restore per tab (§9), hint vs replacement (§10), rewrites and scripts (§11, `rewrite-rules.md`). Inputs: the code at a39a0c8 and main
ca15dbf (`path:line`); the research report (glossary-2026-10, outside the repo); nameslens, trust1, hidelens in flight; applegloss landed.

The user, 2026-10-21: "문맥사용 설정이 각 엔진별로 들어가는게 맞나 싶긴 한데" · "이 문맥사용 입력내용이 글로벌, 앱간(사용자 지정
프로젝트간), 엔진간 어떤 구조로 가야할지 고민된다" · "1.1.5에 같이 가. 그리고 내가 사용자지정이라고 함은 이게 앱전환간 알아서 전환되는
것과, 사용자가 전체 설정을 교체해서 프리셋처럼 바꿔가며 쓰게하는 것 사이에서 고민인거야" (context per engine?; global vs apps vs engines;
1.1.5; switching by itself as apps change vs presets swapped by hand).

## 0. Today, in facts

| Part | What it is | Where |
|---|---|---|
| Languages and engine | chosen by the app in front, one pair for every lens; pushed to the service on each app switch | `App/Model/AppModel.swift:28-40`; `App/Model/AppProfiles.swift:27-28` |
| Memory and context | chosen by the app under the lens (its bundle ID) | `App/Context/ContextRoute.swift:4-6`, `:24-28` |
| Profile key | one bundle ID; a profile always carries a pair | `Core/Sources/MwoyeoCore/AppProfile.swift:44-64` |
| Amount, owner 1 | each engine: `enabled`, `previousLines`, with `includeTitle`, `useLearned`, `deepLInstructions` | `Core/Sources/MwoyeoCore/EngineContext.swift:9-29`; `App/UI/EngineContextSection.swift:83-109` |
| Amount, owner 2 | each app: off / nearby / conversation n; on turns context on even when the engine's is off (an OR) | `AppProfile.swift:5-41`; `EngineContext.swift:64-71`; `App/UI/AppMemorySheet.swift:146-158` |
| The service | holds one settings value: pair, engine, glossary, cache namespace, pace slot | `App/Pipeline/TranslationService.swift:90`, `:122-143` |
| Cross pairing | a lens over app B while A is in front sends B's memory to A's engine ("Also sent to …") | `ContextRoute.swift:30-55`; `AppMemorySheet.swift:168-171`; `App/Support/EnginePermission.swift:68-82` |
| Glossary on Apple | a source term that comes back untranslated is replaced in the output | `TranslationService.swift:733-741`, `:825-832` |
| Apple pins | opt-in `appleUsesPinnedTerms`: the app's user rows, then the glossary pairs it lacks, put into the source; an answer without a target is asked again plain | `App/Context/ContextPlan.swift` (ca15dbf); `TranslationContextMemory.swift:411` (`applePins`); `TranslationService.swift:1074-1120` |
| Consent | per engine off this Mac, per host, in the preferences, never in settings.json | `EnginePermission.swift:4-11`; `App/Model/SettingsFile.swift:268` |
| Lenses | kept in the preferences (`regions`), not in settings.json | `AppModel.swift:146-148` |
| What a lens reads | owner's bundle ID and name, category word, confirmed title; only while `needsWindow` | `App/Context/LensWatch.swift:74-84`; `App/Context/LensContext.swift:9-30` |

- **D1** (memory lost by "Remember Languages", `App/Model/RegionSession.swift:693-705`): fixed by nameslens. **D2** (the whole glossary
  in every prompt): decided, only the pairs that occur go (§3).
- **D3, new.** Context has two owners joined by an OR, so neither screen says what is sent: an engine set to Off still sends lines
  for an app set to Nearby. This is the user's first question.

## 1. The model

### 1.1 One kind of thing: a profile
- A **profile** = a name, a language pair, and optionally an engine, a paragraph reader, a memory (note, names and terms, learned
  rows), a context amount, "learn names", rewrites and a script (`rewrite-rules.md`), and up to 8 conditions in **Used when** (`when`). A condition =
  an app (bundle ID), a title phrase, or both. Without conditions a profile is a **preset**, used only when picked. Today's app
  profile = one app condition; names1's window scope = one title condition.
- **All apps** is the base, under every chain: today's top-level languages, engine and reader, the glossary as its terms, and its own
  amount, learn switch, rewrites and script (new top-level keys). It is not in the list, cannot be removed and has no note.

### 1.2 Conditions and the OS signals they read

| Condition | Matches when | Signal | Permission (both builds) |
|---|---|---|---|
| App | the window's owner has this bundle ID | `NSRunningApplication` of the owner (`LensWatch.swift:82`) | none |
| Title | the confirmed title contains the phrase (`ContextText.occurs`, folded) | `kCGWindowName`, 3 equal reads over ≥ 1 s | Screen Recording, which every lens has |
| App + title | both | both | same |
| Category, URL, document path | dropped (names1: a store category spans unrelated works; URL and path need Accessibility or Apple Events) | — | — |

A phrase, not a hash: titles change with page, episode and unread count. The title picks the profile on this Mac and is never sent
because of it (memory-only requests carry no title, `LensContext.swift:28-30`). Until a new window's title is confirmed (≈ 1 s) only
app conditions match, so a title profile may take over a second later.

### 1.3 Selection: Auto or pinned, per lens
- Each lens is on **Auto** (default) or **pinned**: to a profile, or to "All Apps Only". The menu bar's choice pins every lens at
  once and clears their own pins; its "Auto" returns every lens to Auto. A new lens follows the menu bar's choice.
- **Auto**: every profile with a condition that matches the window under the lens (the window it follows, else the topmost under its
  centre, `LensWatch.swift:74-84`), narrowest first: app + title (3) > title (2) > app (1); a tie goes to the longer phrase, then to
  the earlier profile in the list. Then All apps. This list is the lens's **chain**; its first profile is the **head**.
- **Pinned**: the chain is [that profile, All apps]; no condition is asked. A pin whose profile was removed falls back to Auto.
- **The whole chain is per lens**, languages and engine too (Q1): a title is seen only by the lens that reads it, a pinned preset
  brings its languages, and the cross pairing of §0 disappears. **Zero setup**: no profile → every chain is [All apps] = today's
  settings, byte for byte, and no window is read for it. With a profile, a lens knows its window's owner (from its anchor, else a
  read every 0.5 s, `LensWatch.swift:8`); the title is read only while some profile has a title condition.

### 1.4 Three axes, three owners

| Axis | What | Owner | Default |
|---|---|---|---|
| Content | note, names and terms (with `addressing`), each row's apply mode (§10), rewrites, script | each profile; the glossary is All apps' terms | empty |
| Amount | `off` (only the line) · `memory` (card, note, names) · `nearby` · `conversation` n; learn names | the chain: the narrowest profile that sets it, else All apps | `memory` (today's engine-Off behaviour); learn off |
| Permission, capability | screen lines may go to this engine; the title may; DeepL instructions; what the kind can take | the engine (§4) | §4.1 |

A request = what the chain wants ∩ what the engine allows ∩ what its kind takes: one table, `ContextOptions.requestOptions(engine:chain:)`
(§4.2), replacing today's OR (D3).

### 1.5 Why profiles with conditions, not per-app only or presets only
Per-app only: one bundle ID hosts many works (an emulator, a browser) whose names collide; papers in two apps need two copies of one
memory; nothing switches by hand. Presets only: the person switches on every change, and zero setup is lost. Here a profile without
conditions is a preset, one with an app condition is today's app profile, and a pin makes any profile a preset for a while. Practice
agrees: a professional tool ranks "the term bases in the project" (report §1), fan tools key term files by executable or window title
(report §4). An entry keeps names1's fields (`src`, `dst`, `kind`, `gender`, `note`, `addressing`, `reading`, `origin`) + `apply` (§10).

## 2. Merge and precedence

### 2.1 Rules (one owner: the chain, Core)
1. **Single-valued fields** (pair, engine, reader, amount, learn): the narrowest profile of the chain that sets it, else All apps. A
   profile always has a pair (`AppProfile.swift:51-52`), so the pair is the head's. A gone engine is skipped.
2. **Names and terms**: per folded `src` the narrowest user row wins, its `apply` included; the broader row is neither sent nor put in.
   User rows outrank learned rows everywhere; a learned row whose `src` is a user row anywhere in the chain is not sent.
3. **Learned rows** are kept, used and pinned under the head (under the bundle ID when All apps is the head, as today,
   `App/Context/ContextBook.swift:27`). Two games in one emulator never share learned names.
4. **Notes**: broad → narrow, a blank line between, at most 500 characters together; over that, whole notes are dropped, broadest
   first. The head's note is never cut.
5. **Glossary**: All apps' term rows, one mode (`glossaryApply`, §10); only hits go. **Rewrites, scripts**: before broad → narrow,
   after narrow → broad (`rewrite-rules.md` §4).

### 2.2 Provenance (names1, kept)
The merge returns each row with `from` (a profile id, `all`, or `learned:<id>`) and `shadows` (the broader rows it hid), shown in the
profile sheet, `get_memory` (§7) and the log's JSON line (`profile`, `names`: local, under `savesTranscripts`; no telemetry).

### 2.3 Worked examples
**A game in an emulator.** "Emulator" [app `com.example.emu`], ja→ko, no memory. "月涙譚" [app `com.example.emu` + title "月涙譚"],
ja→ko, Local Qwen, ハク → 하쿠 (both), conversation 3, learn on. "Star Tale" [same app + title "スターテイル"], ハク → Haku.
- Window "月涙譚 — 第二章": chain [月涙譚, Emulator, All apps]; pair, engine, amount and learn from 月涙譚; ハク is written as 하쿠 into
  the source and sent as a row; Star Tale's ハク is not in the chain; learned rows go to 月涙譚. Menu: "Auto picks 月涙譚: title
  contains “月涙譚”". The first second of a new window: [Emulator, All apps] (All apps' engine, no names), then 月涙譚.
**Papers in a PDF reader and a browser.** "Papers" [app `com.example.pdf`; title "Preprint"], en→ko, Cloud Chat (anthropic), note
"Academic register; keep formulas.", nearby. "Web" [app `com.example.browser`], auto→ko.
- PDF window: [Papers, All apps]. Tab "Preprint · The Mwoyeo method": title (2) beats app (1): [Papers, Web, All apps]; Web's rows join
  under Papers'; notes Web → Papers. Tab "News": [Web, All apps]. Cloud Chat gets the nearby lines (lines allowed by default, §4.1)
  and not the title (off for cloud): the title only chose the profile, on this Mac.
**Presets switched by hand.** "Work" (no conditions; en→ko; DeepL with "Use my notes with DeepL"; note "Formal.") and "Anime" (no
conditions; ja→ko; Local Qwen; conversation 3; a cast). Menu bar → "Anime": every lens [Anime, All apps], the language bar edits
Anime's pair. One chat lens's menu → "Work": that lens [Work, All apps], the others stay on Anime. Menu bar → "Auto": both pins go.

## 3. Choosing what goes with one request (names1 §2, kept)
- **Matching**: `ContextText.occurs` (substring; case, width and accents folded; an ASCII word guard) fits ja, zh and ko, where
  particles attach after a name. `reading` is a second key (九十九 / つくも). No fuzzy, stem, kana↔kanji or simplified↔traditional
  folding: a second row says "this too". A one-character Han `src` also hits inside longer words; the sheet warns under such a row.
  Overlaps: the LLM gets both rows; replacement keeps the longest (`TranslationContextAppleTerms.swift:55-57`).
- **The cap, measured**: over 15 bench sequences (481 lines) rows hit per line 0: 311, 1: 142, 2: 26, 3: 2; per 3-line batch
  (`RegionPipeline.swift:1598`, 164 batches) at most 4. `ContextBudget.maxRows`: 8 cloud and local, 4 Apple FM. Order: item hits,
  then speakers around, narrow → broad user rows, learned, then uses and recency. The report's "5 to 7" has no study number.
- **Apart**: the stable block holds the rules, the card and the chain's note (`TranslationContextLayout.swift:312-317`); the last
  message holds `memory`, `referents`, `context_before`, `context_after`, `translate` (`:464-487`). Glossary pairs leave the stable
  rules (`:450-453`) and join `memory` as hits. DeepL's glossaries API stays deferred (it "can't yet be used with automatic source
  language detection", DeepL docs, 2026-10-21); instructions kept the memory's name on 8 of 8 lines in the film run.
- **Hint and replace** (§10): hint rows are what this section chooses and caps; replace rows are written into the source whether they
  fit the cap or not (they cost nothing), longest first.

## 4. Engine permissions

### 4.1 What stays on the engine (`engines[].allow`) by kind, and today's switches

| Kind | Screen lines (`lines`) | Window title (`title`) | Hint rows (§10) | Learned reply | `deepLInstructions` |
|---|---|---|---|---|---|
| Chat server on this Mac | always (nothing leaves the Mac) | always | memory rows | yes | — |
| Chat server off this Mac, Anthropic | switch, **on** (Q2) | switch, off | memory rows | yes | — |
| DeepL | switch, on (`context` parameter) | switch, off | "Write X as Y." with instructions only | no | switch, off |
| Apple FM ("glossary first") | — | — | the glossary in its instructions (today, `TranslationService.swift:1306`) | — | — |
| Apple Translation | — (takes no context) | — | none; the glossary's survived-term output patch (today) | — | — |
| HTTP template, command | — (owns its body) | — | none | — | — |

Lines default to on: the person allowed this engine to receive the text the lens reads, per host (`EnginePermission.swift:4-11`), and
the lines around are that text; the amount in the profile is the opt-in, as an app's override is today (`EngineContext.swift:64-71`).
The switch says "send this engine only the line". The title can hold text from elsewhere, so it stays off off this Mac.
Replacement rows (§10) go into the source for every kind and cost nothing. Today's switches: `enabled` and `previousLines` become All
apps' amount (a profile's where needed, §5.2); `useLearned` the chain's learn switch (DeepL never learns, Q4); `includeTitle` →
`allow.title`; `deepLInstructions` → `allow.deepLInstructions`; `allow.lines` is new (on).

### 4.2 The request table (`ContextOptions.requestOptions(engine:chain:)`, one owner)

| Amount of the chain | Kind takes context, lines allowed | Lines denied | DeepL without instructions |
|---|---|---|---|
| `off` | Off (today's bytes) | Off | Off |
| `memory` | memory only if the chain has hint rows or a note, else Off (DeepL with instructions: as instructions) | same | Off |
| `nearby` | lines around, 0 earlier; title per §4.1; learned if learn ∧ the kind learns | as `memory` | `context` lines only |
| `conversation` n | as `nearby` + n earlier lines (n > 4 sets `longTranscript`) | as `memory` | `context` lines only |

Apple Translation, templates and commands are outside the table: they take only replacement rows (§10). `memory` is a new case of
`AppContextOverride.Mode`, not a count; a build before 1.1.5 reads an unknown mode as "no override" (`AppProfile.swift:143-144`).

## 5. settings.json

### 5.1 Shape (new keys only; everything else as today)
```json
{"context": {"mode": "conversation", "previousLines": 3}, "useLearned": true, "profilePin": "anime", "glossaryApply": "both",
 "engines": [{"id": "…", "kind": "anthropic", "name": "Cloud Chat", "allow": {"title": true}}],
 "profiles": [
  {"id": "com.example.emu", "name": "Emulator", "when": [{"app": "com.example.emu"}], "source": "ja", "target": "ko"},
  {"id": "profile-1", "name": "月涙譚", "when": [{"app": "com.example.emu", "titleContains": "月涙譚"}], "source": "ja", "target": "ko",
   "customEngineID": "…", "note": "…", "entries": [{"src": "ハク", "dst": "하쿠", "kind": "person", "apply": "both"}],
   "context": {"mode": "conversation", "previousLines": 3}, "useLearned": true,
   "rewrites": [{"stage": "before", "find": "（[ぁ-ゖ]+）", "replace": "", "regex": true}],
   "script": {"source": "function after(src, dst, ctx) { return dst.replace(/\\.\\.\\./g, '…') }", "on": true}},
  {"id": "anime", "name": "Anime", "source": "ja", "target": "ko", "customEngineID": "apple"}]}
```
- `id`: unique, 1-255 of letters, digits, `.`, `-`, `_`, never `all`; an app's profile (made or converted) uses the bundle ID, so
  learned rows and `Memory/<id>.json` keep their names; others a slug of the name, else `profile-<n>`. A profile's `customEngineID`:
  an engine id or `"apple"` (new); absent = All apps'. `profilePin`: absent = Auto, `"all"`, or an id; a lens's pin stays with the lens.

### 5.2 Migration (one Core function, run on read; `--check-settings` says "converted on the next save")

| Old key | New key | Rule |
|---|---|---|
| `appProfiles[i]` | `profiles[i]` | `id` = `bundleID`; `name` = `appName`; `when` = [{`app`: `bundleID`}]; `source`, `target`, `customEngineID`, `paragraphReader`, `note`, `entries`, `context` copied |
| `engines[j].context.enabled`, `.previousLines` | top-level `context` | from the engine in use, else the first with `enabled`; off or absent → no key (`memory`); on + 0 → `nearby`; on + n → `conversation` n |
| same, of a profile's own engine | `profiles[i].context` | set when the profile has none and its engine's old amount differs from the top-level one |
| `engines[j].context.enabled == false` | `engines[j].allow.lines = false` | only when the top-level amount sends lines and no profile does |
| `engines[j].context.useLearned` | `useLearned` (top-level, profile) | from the same engine as the amount; a profile whose own engine differs gets its own |
| `.includeTitle`, `.deepLInstructions` | `allow.title`, `allow.deepLInstructions` | copied when `enabled` was on, else false (they did nothing, `EngineContext.swift:57-62`) |
| `appleUsesPinnedTerms: true` | `entries[].apply = "both"` on every user row; `glossaryApply: "both"` | A3; false or absent → nothing written (`hint`): Apple stays exactly as today |
| `glossary`, `sourceLanguage`, `targetLanguage`, `customEngineID`, `engine`, `paragraphReader` | unchanged | All apps' fields |

- Every request a 1.1.4 file made is made again, except four cases, pinned as a list in R3's gate: (a) a lens over app B while A is in
  front uses B's pair and engine (Q1); (b) a spare engine's own `previousLines` follows the profile amount (the only value with no new
  home); (c) an engine with context off × an app whose override sent lines × another engine with context on: the new rules apply;
  (d) with the Apple switch on, engines other than Apple Translation also get those names put into the source (`both`; R7 measures it).
- Before the first save in the new shape the file is copied once to `settings-1.1.4.json` beside it. `appProfiles`,
  `engines[].context` and `appleUsesPinnedTerms` are read, never written; with both `profiles` and `appProfiles`, the latter is ignored.

### 5.3 Schema rows (strict check, lenient decode, limits from the Core types)
- `profiles` (≤ 50; a bad item reported and dropped): `id`, `name` (≤ 40), `when` (≤ 8; each needs `app` or `titleContains` ≤ 60),
  `source`, `target`, `customEngineID` (id or `apple`), `paragraphReader`, `note` (≤ 500), `entries` (≤ 40; `apply`: hint · replace ·
  both), `context` ({`mode`: off · memory · nearby · conversation, `previousLines` 0-8}), `useLearned`, `rewrites`, `script` (`rewrite-rules.md` §2-3).
- Top-level `context`, `useLearned` (only when true), `profilePin` (only when set; names a profile or `all`), `glossaryApply` (only when
  not hint), `rewrites`, `script`. `engines[].allow` {`lines` true, `title` false, `deepLInstructions` false}, written when not default.
- Errors, each FAIL-first in `SettingsFileChecks`: a 9th condition, an empty condition, a duplicate id, the id `all`, a pin to no
  profile, a 33rd rewrite, a pattern that does not compile, a script over 8,000 characters.

## 6. UI contract: simple by default, detailed when sought (numbers; implementable without captures)

The user, 2026-10-21: "ui 잘 만들어줘. 직관적이어야 하고, 기본은 간단하게 보여야 하고 별다른 설정 없이 쓸 수 있어야 하지만, 사용자가
커스터마이징 하려고 보면 상세한 옵션이 잘 드러나도록." The HIG lines this follows, the four "first five minutes" walkthroughs (the
capture scripts) and the vision checklist of R4 and R9 are in `profiles-ui-checklist.md`.

### 6.1 Three levels, on every screen
- **L0, nothing set up** (no profile, no added engine, every preference default): today's screens improved per the ui-audit
  (R4a, 2026-10-21, ids from `ui-audit-1-1-5.md`; the user: "전후가 완전히 같아야 한다가 아니라 애플 디자인에 의거 개선하는 작업"),
  with no new control unless listed. Allowed at L0: removing a row or button that cannot act,
  hit areas ≥ 22 × 22 pt (X1, 2.1), secondary for tertiary text (X2), captions as row subtitles (3.1), regrouping (3.3-3.4),
  renamed labels (1.3, 3.6, 4.1, 4.2, 5.1, 8.1-8.3, 9.1), keyboard shortcuts with no visible change (1.2). New visible
  controls: none. The only new text is 9.2's sheet title and 5.2's two slider end labels.
- **L1, after the one natural thing** (write a name from a lens, add an engine, write a glossary line): only what that act made
  appears, in its words: the names, the profile they made and its picker, the engine's rows. Both sheets are L1: reached only by an act.
- **L2, sought**: every other option sits behind one explicit control where it takes effect (a disclosure row whose label says what
  it holds, "Customize · …", "Context · …", "Script · Off"; a ⋯ menu; one submenu), ≤ 2 clicks away, never drawn unopened. A sheet
  opens on L2 only for a profile that already uses it or is being made by hand.
- **Words**: L0-L1 say what happens ("Tell the translator", "Swap into the text", "Picked by hand"); "hint", "replace", "apply",
  "chain", "head", "regex", "mode" stay in settings.json, MCP and this file. A menu item that cannot act is dimmed, a Settings row
  that cannot act is not drawn; no popovers (a warning is a caption on its row); no sheet over a sheet (a link out closes it first).

| Screen | L0 (today, improved) |
|---|---|
| Menu bar panel | header (no status line at 0 lenses, 1.4), language bar (no engine menu), lens rows or "No lenses yet", Add Lens, footer: Show Original dimmed at 0 lenses (1.1), icons 22 pt (X1); no profile caption |
| Lens menu | today's items: Show Original … Save Lens Image; nameslens' names line, "Memory for <App>…", "Remember Languages for <App>"; pill targets 22 pt (2.1) |
| Settings › General | Open at login first (3.3); Languages; Display with Style + subtitle (3.1, 3.6); Performance; Saving, Folder only while on (3.5); Advanced (3.4); no accent on labels (3.2) |
| Settings › Translation | Translation engine (no "Engine" label, 4.3), Apple Translation language packs, Recent translations (4.1), Glossary; no Profiles section |
| Appearance, About | today's + Color (5.1), Opacity ends (5.2), aligned privacy lines (7.1), secondary version text (X2) |
| Shortcuts | today's, no Restore button while all defaults (§9) |
| Onboarding | today's cards; "Try It Now" is the default, "Done" closes (8.1); the Languages line names no Settings path (8.2) |

### 6.2 Settings › Translation › Profiles (replaces "App profiles", `App/UI/SettingsView.swift:227-265`)
- **L1**, shown while a profile exists. Row 1 "All apps", subtitle "Everywhere else · <pair> · glossary n"; then the profiles in list
  order, ≤ 6, then a borderless "Show All n Profiles" (expands in place; ≤ 50). A row: the name (cut in the middle at 32), one subtitle
  line (caption, secondary, tail cut; priority where 2, pair 1, memory 0): where = "In Emulator", "“月涙譚” in Emulator", "Title has
  “Preprint”", "In Safari +2", "Picked by hand"; memory = "note · 12 names · 2 rewrites · script"; trailing "Pinned" (caption) while
  every lens is pinned to it, then ⋯ (≥ 20 pt). A click on the row opens its sheet. ⋯: "Edit…", "Duplicate", "Use for Every Lens" /
  "Back to Auto", divider, "Remove…" ("Remove <name>? Its note and n names go with it."); All apps: "Edit…". "Paragraphs" moves into
  the sheet. "New Profile…" (borderless, plus) under the rows. Footer: "Each lens uses the closest match: a window title, then an app,
  then All apps. To choose by hand, use a lens’s menu or the menu bar." The Apple switch goes (A3; `:250-252`, `AppMemorySheet.swift:351-356`).
- **Glossary**, L1 once it holds a pair: a "Use them" pop-up under the editor (§10's items, cost per pair).

### 6.3 The profile sheet (`AppMemorySheet`, 520 × 640, the Form scrolls)
- **Header**: "Memory for <name>" (headline, one line, tail cut) over one caption line, "<used> · <pair> · <engine>": "Used in Safari ·
  Japanese → Korean · Apple Translation"; used = "Used when the title has “月涙譚” in Emulator", "Used when you pick it", "Used everywhere else".
- **L1**, in order: (1) **Names and terms** first, as the reason people come: today's rows (name → translation, minus, the details
  disclosure), "Add Name", "Names: n of 40"; empty: "Type a name as the screen shows it, then how it should read."; All apps:
  "Glossary: n pairs" + "Edit Glossary…". Rows on Tell while the engine in effect takes no hints: one callout "<Engine> uses only
  names swapped into the text; n here are not." + "Swap Them In" (sets Both). (2) **Note** (not All apps). (3) **Learned**, only
  when not empty, "Forget All" in its footer. (4) With an added engine in effect, today's "Sent: …" line (wraps); with Apple none.
  (5) **Customize**: a disclosure triangle, "Customize" and, trailing in secondary (one line, tail cut), what differs from All apps
  ("Local Qwen · conversation 3 · 2 rewrites · script"), else what it holds ("When, languages, context, rewrites"); one accessibility
  element whose value is that summary. Bottom bar: "Start Fresh" only while the profile keeps a conversation; "Done".
- **L2, a row's details**: the Use pop-up first (§10), then today's kind, gender, note, pronunciation, speaks to.
- **L2, Customize open**, in order: (a) **When it’s used** (not All apps): "Name" (≤ 40); ≤ 8 conditions (14 pt app icon or
  `textformat`, words, minus); "Add Condition": "<App of the opening lens>", "This Window’s Title" (dimmed until confirmed), "Other
  App…", "Title Contains…" (≤ 60; "Keep the part that stays the same, like a game’s name."); none: "No conditions: used only when you
  pick it." (b) **Languages** (not All apps): From, To; Engine "Same as All apps (<name>)", "Apple Translation", each engine;
  Paragraphs. (c) **Context**, if the engine in effect takes it (else "<Engine> gets only the line."): "Same as All apps (<words>)",
  "Only the line", "Names and note", "Nearby lines", "Conversation" + "Earlier lines: n" (0-8); "Learn names and terms" if it learns;
  lines asked but denied: orange "<Engine> gets only the line." + "Change…" (its engine sheet, Context open). (d) **Rewrites**, (e)
  **Script**: `rewrite-rules.md` §7. Customize starts open (scrolled to) when the profile uses (a)-(e) beyond one app condition, or is
  new by hand ("New Profile…": Name focused; "… for This Window…": the phrase focused and selected); the state is not kept.

### 6.4 Lens menu (`RegionSession.swift` `addProfileItems`; names cut in the middle at 24, lines at 48, as `LensMemoryMenu`)
- **L0** as nameslens. **L1** (a profile exists): one item after "Memory for …": "Profile: <head>" / "Profile: <name> (pinned)" /
  "… (every lens)" / "Profile: All Apps Only", with one submenu: dimmed "Auto picks <head>: <why>" ("the app", "title has “…”",
  "nothing matches"); "Auto" ✓; separator; "All Apps Only"; the profiles ✓ (≤ 8, then "More in Settings…"); separator; "New Profile
  for This Window…" (dimmed until the title is confirmed; app + title cut at 40, the lens's pair, named by it); "New Profile…".
  "Memory for" and "Forget" name the head; with All apps as head, the app, as today (`AppProfiles.ensuring` on the first edit).

### 6.5 Menu bar (`MenuPanel.swift:44-47`) and engine sheet (`EngineContextSection`)
- **Menu bar**, L1 (a profile exists): today's "<App> profile" caption becomes a borderless menu (caption2, secondary, centred, -6 pt, 8 pt chevron):
  "Profile: Auto" (head All apps) / "Profile: <head>" / "Profile: <name> (every lens)", cut in the middle at 24 → "Auto — each lens
  picks" ✓, "All Apps Only", the profiles (≤ 8), separator, "Profiles in Settings…". A choice pins every lens (§1.3); the language bar
  edits that profile, on Auto the front window's head. A lens row appends " · <head>" only when it differs from the caption's.
- **Engine sheet**, L1 as today (key, "Send the text the lens reads to <host>", test). L2 "Context · <All apps' words>": "For all
  apps" pop-up (§6.3 c's items, top-level `context`) + "Earlier lines"; "Learn names and terms" (if it learns); "A profile can ask for
  more or less." + "Profiles…" (if one exists); off this Mac: "Send the lines around the text" (on; off: "<Engine> gets only the line,
  whatever a profile asks."), "Send the window title" (off); "Use my notes with DeepL"; the Sent line. "Use context", "Previous lines" go.

## 7. Agents (MCP; one compact text block per result, `docs/settings-for-agents.md:14`)
- `list_apps` adds `"profiles": {"columns": ["id","name","when","pair","engine","names","context"], "rows": [["profile-1","月涙譚",
  ["app com.example.emu title 月涙譚"],"ja>ko","Local Qwen",12,"conversation 3"]]}` and `"pin"`. No new tool.
- `get_memory(app | profile, title?)`: a profile in file shape, or for an app (+ title) `{"selected", "why", "chain": [ids…, "all"],
  "rows": {"columns": ["src","dst","kind","apply","from"], "rows": […]}, "shadowed": […], "learned"}` (learned from `Memory/<id>.json`).
- `set_memory(app | profile, …)` also takes `name`, `when`, `source`, `target`, `customEngineID`, `context`, `useLearned`, `rewrites`,
  `script`, `remove: true`; a new id creates it; the sheet's validation. → `{"profile", "created", "names", "added"/"updated"/"removed", "issues"}`.
- `test_rules` (new, `rewrite-rules.md` §8). `set_settings {"profilePin": id | "all" | null}` pins every lens; `translate_text` takes `profile`, `title`.

## 8. Gaps and rounds

| # | Today | Target | Size |
|---|---|---|---|
| P1 | languages follow the front app (`AppModel.swift:28-40`) | a chain per lens (§1.3) | M |
| P2 | one settings in the service (`TranslationService.swift:90`, `:122-143`) | each call carries its lens's settings, cache namespace and pace slot | L |
| P3 | a profile is one bundle ID (`AppProfile.swift:49`, `:190-193`) | id, name, `when` ≤ 8, pins | M |
| P4 | the amount has two owners and an OR (D3) | amount on profiles (+ `memory`), `engines[].allow`, §4.2 | M |
| P5 | precedence app > glossary > learned only (names1 G3) | chain merge §2.1, `from`/`shadows` | M |
| P6 | — | converter §5.2, schema §5.3 | M |
| P7 | learned per app (names1 G13) | per head | S |
| P8 | names1 G4 (glossary hits), G5 (`maxRows`), G6 (`reading`) | §3 | M |
| P9 | UI | §6 | L + vision |
| P10 | MCP app-only (`App/Support/MCPTools.swift:412-478`); log lines carry no rows (names1 G12) | §7; `profile`, `names` per log line | M |
| P11 | apps without a bundle ID get nothing (`LensWatch.swift:82`, names1 G16) | a probe first | S |
| P12 | one Restore button (Shortcuts) | §9 | S-M |
| P13 | pre-insertion is Apple's, behind one switch (`ContextPlan.swift`, ca15dbf) | `apply` per row and `glossaryApply`, every kind (§10) | M |
| P14 | no rewrites, no scripts | `rewrite-rules.md`: the table, the script service, the editor, `test_rules` | L |

Done or in flight: names1 G1, G2, G15 (nameslens), G7 (applegloss), G11, G14; G8-G10 become P3, P9, P10. Every round keeps the
**default-path gate** (Core `TranslationContextGoldenTests` `*OffIsToday`; check-logic "Off …: the request bytes are main's",
`App/Support/ContextChecks.swift:562`) plus its own below; all start after nameslens, trust1 and hidelens land; each fits in 400k.

| Round | Gaps | Files (one owner each) | Its own default-path gate | After |
|---|---|---|---|---|
| R1 `prof-core` | P3-P5, P6 (converter) | Core `AppProfile.swift`, `EngineContext.swift`, new `ProfileChain.swift`, new `ProfileMigration.swift`, tests | no profile → [All apps], and `requestOptions(engine:chain:)` = today's for every kind × every old `EngineContext` | in-flight |
| R1b `names-core` | P8, P13 (Core) | `TranslationContextLayout.swift`, `TranslationContextMemory.swift` (`apply`, `replaceRows` from `applePins`, row cost), `TranslationContextTokens.swift`, `TranslationContextAppleTerms.swift`, tests | goldens; absent `apply` selects exactly today's rows; DeepL without the opt-in unchanged | in-flight (∥ R1, R2) |
| R2 `prof-lens` | P1, P2 (today's app profiles as one-condition chains) | `TranslationService.swift`, `RegionPipeline.swift` (call sites), `AppModel.swift` (`pushSettings`), `RegionSession.swift` (settings), `ContextRoute.swift`, `LensWatch.swift`, `ContextChecks.swift` | no profile: each lens's settings, cache namespace and pace slot = main's; a lens over B with A in front uses B's pair (FAIL-first on main) | in-flight (∥ R1) |
| R7 `both-bench` | case (d) | `tools/translation-bench/memory` runs, a results note in `docs/research/` | measurement only: names kept and judge preference, `both` vs `hint`, chat and Anthropic kinds | R1b |
| R3 `prof-file` | P6 wiring, P7, schema, disclosures | `Settings.swift`, `SettingsFile.swift`, `SettingsFileChecks.swift`, `ContextPlan.swift`, `ContextRoute.swift`, `EnginePermission.swift`, `AppProfiles.swift`, `ContextBook.swift`, `LearnedMemoryFile.swift`, the trust1 preset file, `docs/settings-for-agents.md` | a 1.1.4 fixture: every (engine, app) request = 1.1.4's except §5.2's four cases, listed; a file with no profile, no engine context and the Apple switch off renders byte-identical | R1, R2, R7 |
| R4 `prof-ui` | P9, P13 UI | `AppMemorySheet.swift`, `AppMemoryEditor.swift`, `SettingsView.swift`, `EngineContextSection.swift`, `MenuPanel.swift`, `RegionSession.swift` (menu), `UICapture.swift`, `MemorySheetChecks.swift`, strings; opus vision | no profile, no added engine: no Profiles section, no Profile item (captures) | R3 |
| R5 `prof-agents` | P10, P11 | `MCPTools.swift`, `MCPTranslate.swift`, `MCPChecks.swift`, the transcript writer, `tools/mcp/`, a `tools/` probe | `get_memory(app)` of a converted profile = today's keys + `profile`; no memory → no `names` key | R3 (∥ R4) |
| R8 `rewrite-run` | P13 (all kinds), P14 runtime | `TranslationService.swift` (stages), new `Core/.../Rewrites.swift`, new `Script/` service + `project.yml` target, new `App/Script/ScriptConnection.swift`, checks | no rewrite, no script: the service never starts (connection count 0) and the bytes are main's; `while(true){}` is cut at 50 ms × lines + 100 ms (the gate's timeout is a parameter) | R3 (∥ R4, R5) |
| R6 `reset-tabs` | P12 | `SettingsFile.swift` (two columns), `SettingsView.swift`, new `App/UI/RestoreDefaultsSheet.swift`, `MCPTools.swift` (`reset_settings`) | Restore on a default file changes nothing and is disabled; no consent or data key is ever changed | R4, R5 |
| R9 `rewrite-ui` | P14 editor | `AppMemorySheet.swift`, `AppMemoryEditor.swift`, new `App/UI/ScriptEditor.swift`, captures; opus vision | a profile without rewrites shows one "Add Rewrite" button and a collapsed Script row | R4, R8 (∥ R6) |
| R10 `rewrite-agents` | P14 agents | `MCPTools.swift` (`test_rules`, `rewrites`, `script`), `MCPChecks.swift`, `docs/settings-for-agents.md` (script API) | `test_rules` on a profile without rewrites returns each line unchanged and starts no service | R6, R8 |

## 9. Restore defaults per tab (A1)

The user: "설정의 각 탭별로 리셋 투 디폴트 같은게 있어야 하지 않을까 … 기본값으로 돌리고 싶은 것과 보존하고 싶은 게 있고 유형별로
다를 것 같은데". **preference**: Restore sets the default. **consent**: kept, shown as "kept", turned off only by hand. **data**: never
touched; deleted per item with its own confirmation. Each `SettingSpec` gets `tab` and `nature`; a key without them fails (FAIL-first).

| Tab | Nature | Keys |
|---|---|---|
| general | preference | `sourceLanguage`, `targetLanguage`, `renderMode`, `settleDelay`, `framesPerSecond`, `transcriptFormats` (file only) |
| general | consent | `savesTranscripts`, `exportFolder` (a chosen folder; a bookmark in the App Store build), `agentConnection` |
| translation | preference | `engine`, `customEngineID` (back to Apple; engines are kept), `cacheSize`, `paragraphReader` (file only), `profilePin` (Auto) |
| translation | consent | `context` (All apps' amount: what leaves this Mac), `useLearned` (an opt-in, context-translation §9) |
| translation | data | `engines` (with `allow`), `glossary`, `glossaryApply` (was the consent `appleUsesPinnedTerms`), `profiles` (was `appProfiles`), `rewrites`, `script` |
| appearance | preference | `useInpaintingModel`, `fontStyle`, `boxOpacity`, `lensStyle`, `lensTint`, `lensTabVisibility`, `lensTabPosition` |
| shortcuts | preference | `shortcuts` |
| about | consent | `checksForUpdates` |
| not in the file | consent, data | `enginePermissions`; `exportBookmark`, `engineRejections`, `hasCompletedOnboarding`, learned rows, lens pins: never reset |

- **Button** "Restore Defaults…" at the foot of General, Translation, Appearance and Shortcuts (today's Shortcuts button,
  `SettingsView.swift:604-605`, becomes it), shown only while a preference of the tab differs from its default: hidden, not
  disabled, so a tab at its defaults is today's (§6.1). About has none.
- **Sheet** (420 pt): "Changes" rows "<title>: <now> → <default>"; "Kept" rows for the tab's consent and data ("Connect an agent (MCP):
  on — kept; turn it off by hand"); Cancel, Restore (default). settings.json is first copied to `settings.json.before-restore`; then
  "Restored n settings." with Undo (writes back only those keys) and Done.
- **MCP** `reset_settings {tab, dryRun?}` from the same table: `{"changed": [[key, now, default]…], "kept": [key…]}`.

## 10. Hint vs replacement (A2, A3)

The user: "ai 번역시에 토큰을 소모하는 문맥주입과 소모하지 않는 기계적 치환을 구분해서 넣고 싶어" · "특히 애플 용어집 같은건 아예
기계치환쪽으로 빼고 통일하면 더 자연스러울 것 같아" (token-costing context apart from free replacement; Apple's terms on the latter).
- Each name or term row has `apply`: **hint** (sent as a row; costs tokens; the engine inflects it and reads kind, gender, addressing),
  **replace** (written into the SOURCE before translation; 0 tokens; the engine writes the particle for the word that stands there), or
  **both**. The glossary has one mode for all its lines, `glossaryApply` (a line that needs its own mode belongs in a profile).
- **By kind**: chat and Anthropic take both; DeepL takes hints only as instructions (`allow.deepLInstructions`); Apple Translation, FM
  (for profile rows), templates and commands take no hints, so only replace reaches them.
- **Apple pre-insertion is the replace mode**, not a path of its own. `ContextPlan`'s `.applePins` becomes `.replaceOnly(rows)`, the
  plan of every kind that takes no hints; `.engine` carries replace rows too. The rows come from `ContextMemory.applePins`
  (`TranslationContextMemory.swift:411`, main) generalised to `replaceRows(chain)`: the chain's replace/both user rows narrow → broad,
  then the glossary pairs (when `glossaryApply` is not hint) whose source the chain lacks; no switch gates it. `ApplePreinsertion`
  (longest match, plural, capital) inserts for every kind; the answer check and plain retry stay Apple's (`TranslationService.swift:1103-1120`).
- **Default path, byte for byte**: absent `apply` is hint, so with no replace or both row Apple gets today's request, and the glossary
  keeps today's survived-term output patch (`:825-832`). The switch's migration is §5.2; its toggles go (§6).
- **A new row's mode** (the sheet sets it when the row is first stored): **both** when the profile's engine takes no hints (Apple
  Translation, FM, a template, a command) and the name has 2+ characters, so a name written for Apple works at once (§6.3); else
  **hint**: no source change unless asked; a one-character Han `src` replaced breaks a word (王 in 王様) where a hint costs one row. A
  row without `apply` (an older file, an agent) is hint. **Both is better for names** (person or place) where Apple translates, and
  likely on LLMs (final form plus gender; R7 measures it): with Apple in effect the pop-up marks Both "recommended for names".
- **Replacing in the OUTPUT** breaks Korean particles (은/는, 이/가 after a different final consonant): only as an explicit
  after-rewrite (`rewrite-rules.md`), with that warning beside it.
- **Cost, in the row's details** (§6.3, L2): a "Use" pop-up, "Tell the translator · ≈ n tokens", "Swap into the text · free", "Both
  · ≈ n tokens", and one caption for the chosen item ("Told to AI engines where it appears." · "Written into the text before
  translating; Apple Translation uses it too." · "Both of these."); n = `approxTokens(renderRow(e)) + 1`, the budget's own count
  (`TranslationContextLayout.swift:386`). The Glossary's "Use them" pop-up (§6.2) offers the same three with the cost per pair.

## 11. Rewrites and scripts (A2, A4, A5) → `docs/design/rewrite-rules.md`
Every profile (All apps included) also gets a rules table (`rewrites`: ≤ 32 rows {before | after, find, replace, regex}) and a script
(`script`: JavaScript `before(line, ctx)` / `after(src, dst, ctx)`, ≤ 8,000 characters), both 0 tokens. Regex rows and scripts run in
an XPC service without entitlements, cut at 50 ms a line; with none in the chain the service never starts. Agents write and dry-run
them (`set_memory`, `test_rules`). The model, limits, App Store reading (2.5.2, 4.7, 2.5.1), UI and gates are in that file.

## 12. Decisions (the user, 2026-10-21)
- **Q1** per lens, everything: languages and engine follow each lens's chain, not the app in front ("Also sent to …" goes). **Q2** a
  cloud engine gets the lines a profile asks for (its `allow.lines` switch can still say no). **Q3** window memory is a profile with a
  title condition, made from the lens menu. **Q4** "Learn names and terms" moves from the engine to the profile.
- Also: only glossary hits go; Apple uses every scope's names (as replace rows); "Memory for <App>…" in every lens menu; DeepL
  glossaries deferred; profiles, restore per tab, §10 and §11 all in 1.1.5.
