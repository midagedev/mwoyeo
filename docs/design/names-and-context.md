# Names, terms and context: profiles

Status: design, 2026-10-21, round profiles1; revises names1's version (4715d5b, 86d1fb2) on top of `docs/design/context-translation.md`.
Kept from names1: entries, row choice per request (§3), engine paths, provenance, D1, D2. New: profiles replace the scopes (§1), engine
permissions (§4), restore per tab (§9), hint vs replacement (§10), rewrites and scripts (§11). Inputs: the code at a39a0c8 and main
ca15dbf (`path:line`); the research report (glossary-2026-10, outside the repo); nameslens, trust1, hidelens in flight; applegloss landed.

The user, 2026-10-21: "문맥사용 설정이 각 엔진별로 들어가는게 맞나 싶긴 한데" · "이 문맥사용 입력내용이 글로벌, 앱간(사용자 지정
프로젝트간), 엔진간 어떤 구조로 가야할지 고민된다" · "1.1.5에 같이 가. 그리고 내가 사용자지정이라고 함은 이게 앱전환간 알아서 전환되는
것과, 사용자가 전체 설정을 교체해서 프리셋처럼 바꿔가며 쓰게하는 것 사이에서 고민인거야" (context per engine?; global vs apps vs engines;
1.1.5; switching by itself as apps change vs presets swapped by hand).

## 0. Today, in facts

| Part | What it is | Where |
|---|---|---|
| Languages and engine | chosen by the app in front, one pair for every lens; pushed to the service on each app switch | `App/Model/AppModel.swift:28-40`; `App/Model/AppProfiles.swift:27-28` |
| Memory and context | chosen by the app under the lens (its bundle ID; a profile = one bundle ID + a pair, `Core/Sources/MwoyeoCore/AppProfile.swift:44-64`) | `App/Context/ContextRoute.swift:4-6`, `:24-28` |
| Amount, owner 1 | each engine: `enabled`, `previousLines`, with `includeTitle`, `useLearned`, `deepLInstructions` | `Core/Sources/MwoyeoCore/EngineContext.swift:9-29`; `App/UI/EngineContextSection.swift:83-109` |
| Amount, owner 2 | each app: off / nearby / conversation n; on turns context on even when the engine's is off (an OR) | `AppProfile.swift:5-41`; `EngineContext.swift:64-71`; `App/UI/AppMemorySheet.swift:146-158` |
| The service | holds one settings value: pair, engine, glossary, cache namespace, pace slot | `App/Pipeline/TranslationService.swift:90`, `:122-143` |
| Cross pairing | a lens over app B while A is in front sends B's memory to A's engine ("Also sent to …") | `ContextRoute.swift:30-55`; `AppMemorySheet.swift:168-171`; `App/Support/EnginePermission.swift:68-82` |
| Glossary on Apple | a source term that comes back untranslated is replaced in the output | `TranslationService.swift:733-741`, `:825-832` |
| Apple pins | opt-in `appleUsesPinnedTerms`: the app's user rows, then the glossary pairs it lacks, put into the source; an answer without a target is asked again plain | `App/Context/ContextPlan.swift` (ca15dbf); `TranslationContextMemory.swift:411` (`applePins`); `TranslationService.swift:1074-1120` |
| Consent, lenses | consent per engine off this Mac, per host; lenses (`regions`): both in the preferences, never in settings.json | `EnginePermission.swift:4-11`; `App/Model/SettingsFile.swift:268`; `AppModel.swift:146-148` |
| What a lens reads | owner's bundle ID and name, category word, confirmed title; only while `needsWindow` | `App/Context/LensWatch.swift:74-84`; `App/Context/LensContext.swift:9-30` |

**D1** (memory lost by "Remember Languages", `App/Model/RegionSession.swift:693-705`): fixed by nameslens. **D2** (the whole glossary in
every prompt): only the pairs that occur go (§3). **D3, new**: context has two owners joined by an OR, so neither screen says what is
sent (an engine set to Off still sends lines for an app set to Nearby). This is the user's first question.

## 1. The model

### 1.1 One kind of thing: a profile
- A **profile** = a name, a language pair, and optionally an engine, a paragraph reader, a memory (note, names and terms, learned
  rows), a context amount, "learn names", rewrites and a script (§11), and up to 8 conditions in **Used when** (`when`). A condition =
  an app (bundle ID), a title phrase, or both. Without conditions a profile is a **preset**, used only when picked. Today's app
  profile = one app condition; names1's window scope = one title condition.
- **All apps** is the base, under every chain: today's top-level languages, engine and reader, the glossary as its terms, and its own
  amount, learn switch, rewrites and script (new top-level keys). It is not in the list, cannot be removed and has no note.

### 1.2 Conditions and the OS signals they read

- **App**: the window's owner has this bundle ID (`NSRunningApplication` of the owner, `LensWatch.swift:82`; no permission).
  **Title**: the confirmed title (`kCGWindowName`, 3 equal reads over ≥ 1 s; Screen Recording, which every lens has) contains the
  phrase (`ContextText.occurs`, folded). **App + title**: both. Category, URL and document path are dropped (names1: a category spans
  unrelated works; URL and path need Accessibility or Apple Events).
- A phrase, not a hash: titles change with page, episode and unread count. The title picks the profile on this Mac and is never sent
  because of it (`LensContext.swift:28-30`). Until a new window's title is confirmed (≈ 1 s) only app conditions match.

### 1.3 Selection: Auto or pinned, per lens
- Each lens is on **Auto** (default) or **pinned**: to a profile, or to "All Apps Only". The menu bar's choice pins every lens at
  once and clears their own pins; its "Auto" returns every lens to Auto. A new lens follows the menu bar's choice.
- **Auto**: every profile with a condition that matches the window under the lens (the window it follows, else the topmost under its
  centre, `LensWatch.swift:74-84`), narrowest first: app + title (3) > title (2) > app (1); a tie goes to the longer phrase, then to
  the earlier profile in the list. Then All apps. This list is the lens's **chain**; its first profile is the **head**.
- **Pinned**: the chain is [that profile, All apps]; no condition is asked. A pin whose profile was removed falls back to Auto.
- **The whole chain is per lens**, languages and engine too (Q1): a title is seen only by the lens that reads it, a pinned preset
  brings its languages, and the cross pairing of §0 disappears. **Zero setup**: no profile → every chain is [All apps] = today's
  settings, byte for byte, and no window is read for it; the title is read only while some profile has a title condition.

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
   after narrow → broad (§11).

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
- **Matching**: `ContextText.occurs` (substring; case, width, accents folded; an ASCII word guard) fits ja, zh, ko, where particles
  follow a name; `reading` is a second key (九十九 / つくも); no fuzzy or script folding: a second row says "this too". A one-character
  Han `src` hits inside words; the sheet warns. Overlaps: the LLM gets both; replacement keeps the longest (`TranslationContextAppleTerms.swift:55-57`).
- **The cap, measured** (15 sequences, 481 lines): rows hit per line 0: 311, 1: 142, 2: 26, 3: 2; per 3-line batch (`RegionPipeline.swift:1598`)
  at most 4. `ContextBudget.maxRows` 8, Apple FM 4. Order: item hits, speakers around, narrow → broad user rows, learned, uses, recency.
- **Apart**: rules, card and the chain's note in the stable block (`TranslationContextLayout.swift:312-317`); `memory`, `referents`,
  `context_before`, `context_after`, `translate` last (`:464-487`). Glossary pairs leave the stable rules (`:450-453`) and join `memory`
  as hits. DeepL's glossaries API stays deferred (it "can't yet be used with automatic source language detection", DeepL docs).

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

- Every 1.1.4 request is made again except four cases, listed in R3's gate: (a) a lens over B with A in front uses B's pair and engine
  (Q1); (b) a spare engine's own `previousLines` has no new home; (c) engine context off × an app override that sent lines × another
  engine on: the new rules apply; (d) with the Apple switch on, other engines also get those names in the source (`both`; R7).
- The first save in the new shape copies the file once to `settings-1.1.4.json`. Old keys are read, never written; `profiles` wins.

### 5.3 Schema rows (strict check, lenient decode, limits from the Core types)
- `profiles` (≤ 50; a bad item reported and dropped): `id`, `name` (≤ 40), `when` (≤ 8; each needs `app` or `titleContains` ≤ 60),
  `source`, `target`, `customEngineID` (id or `apple`), `paragraphReader`, `note` (≤ 500), `entries` (≤ 40; `apply`: hint · replace ·
  both), `context` ({`mode`: off · memory · nearby · conversation, `previousLines` 0-8}), `useLearned`, `rewrites`, `script` (§11).
- Top-level `context`, `useLearned` (only when true), `profilePin` (only when set; names a profile or `all`), `glossaryApply` (only when
  not hint), `rewrites`, `script`. `engines[].allow` {`lines` true, `title` false, `deepLInstructions` false}, written when not default.
- Errors, each FAIL-first in `SettingsFileChecks`: a 9th condition, an empty condition, a duplicate id, the id `all`, a pin to no
  profile, a 33rd rewrite, a pattern that does not compile, a script over 8,000 characters.

## 6. UI contract (numbers; implementable without captures)

**Settings › Translation › Profiles** (replaces "App profiles", `App/UI/SettingsView.swift:227-265`; shown when a profile or an
added engine that takes context exists, so zero-setup Settings is unchanged):
- Row 1 "All apps": subtitle "<pair> · <amount words> · Glossary: n", ⋯ → "Edit…"; not removable. A row per profile, list order: name
  (cut in the middle at 32); one subtitle line = conditions (priority 2: "月涙譚 in Emulator", "Emulator", "Title contains “Preprint”",
  "Chosen by hand") · pair (1) · memory summary (0, cut first); trailing caption "Pinned". ⋯: "Edit…", "Paragraphs ▸", "Duplicate",
  "Pin for Every Lens" / "Use Auto", divider, "Remove…" (alert "Remove <name>? Its note and <n> names are removed.").
- "New Profile…" (borderless) under the rows. Footer, 2 lines: "Each lens picks the narrowest match: a window title, then an app, then
  All apps. Pin one from a lens's menu or the menu bar." The Apple switch goes (A3; `:250-252`, `AppMemorySheet.swift:351-356`).

**The profile sheet** (`AppMemorySheet`, 520 × 640, Form scrolls), sections in order:
- Header: the name field (≤ 40, headline, layout priority 1; plain "All apps" for the base). **Used when** (not for All apps): ≤ 8
  rows (14 pt symbol, words, trailing minus); "Add Condition" menu: "<App of the opening lens>", "This Window's Title: “<title, cut at
  40>”" (confirmed title only), "Other App…", "Title Contains…" (≤ 60, caption "Used while the window title contains this."). Empty:
  "No conditions: used only when you pick it." **Languages** (not for All apps): source → target; Engine: "Same as All apps
  (<name>)", "Apple Translation", each engine.
- **Note** (not for All apps) and **Names and terms** ("Names: n of 40"). Each row gets a 22 pt mode button before its minus (§10).
  All apps shows "Glossary: n pairs" with "Edit Glossary…". A row that hides a broader one: caption "Replaces “ハク → Haku” from
  Emulator". With Apple Translation in effect: caption "Apple Translation uses only rows set to Replace or Both."
- **Rewrites** and **Script** (§11.4). **Context**: "Same as All apps (<words>)" (not for All apps), "Off — only the line", "Names and
  note", "Nearby lines", "Conversation" + "Earlier lines: n" (0-8); "Learn names and terms" only when the engine can learn; caption
  "Applies only to engines you added." When the engine denies lines and the amount asks for them: orange "<Engine> gets only the
  line." + "Change…". "Also sent to …" goes. **Learned** (when not empty), then the "Sent:" line.

**Lens menu** (after nameslens' items; only when a profile exists): "Profile: Auto (<head>)" / "<name> (pinned)" / "<name> (every
lens)" / "All Apps Only", cut in the middle at 40 → a disabled line "Auto picks <head>: <why>" (cut at 48; "title contains “…”",
"<App>", "nothing matches"); "Auto" ✓; separator; "All Apps Only"; each profile ✓ (cut at 32); separator; "Edit <head>…"; "New Profile
for This Window…" (confirmed title only: app + title, the pair in effect, name = title cut at 40); "New Profile…". nameslens' "Memory
for <App>…" becomes "Memory for <head>…"; with All apps as head it keeps its meaning (`AppProfiles.ensuring` on the first edit).

**Menu bar** (`MenuPanel.swift:44-47`): with a profile, the caption is a borderless menu "Profile: Auto" / "Profile: <name>" (caption2,
secondary, centred, -6 pt top) → "Auto — each lens picks", "All Apps Only", the profiles, "Profiles in Settings…". The language bar
edits the pinned profile; on Auto, the head for the front app's window, else All apps. A lens row appends " · <head>" (cut at the tail).

**Engine sheet** (`EngineContextSection`): "Context · <words>"; "How much goes along is set per profile: All apps sends <words>." +
"Profiles…"; "Send lines around and before" (off this Mac; on); "Include window title" (off this Mac; off); "Use my notes with DeepL"
(DeepL); the Sent line. "Use context", "Previous lines" and "Learn names and terms" leave it.

## 7. Agents (MCP; one compact text block per result, `docs/settings-for-agents.md:14`)
- `list_apps` adds `"profiles": {"columns": ["id","name","when","pair","engine","names","context"], "rows": [["profile-1","月涙譚",
  ["app com.example.emu title 月涙譚"],"ja>ko","Local Qwen",12,"conversation 3"]]}` and `"pin"`. No new tool.
- `get_memory(app | profile, title?)`: a profile in file shape, or for an app (+ title) `{"selected", "why", "chain": [ids…, "all"],
  "rows": {"columns": ["src","dst","kind","apply","from"], "rows": […]}, "shadowed": […], "learned"}` (learned from `Memory/<id>.json`).
- `set_memory(app | profile, …)` also takes `name`, `when`, `source`, `target`, `customEngineID`, `context`, `useLearned`, `rewrites`,
  `script`, `remove: true`; a new id creates it; the sheet's validation. → `{"profile", "created", "names", "added"/"updated"/"removed", "issues"}`.
- `test_rules` (new, §11.5). `set_settings {"profilePin": id | "all" | null}` pins every lens; `translate_text` takes `profile`, `title`.

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
| P14 | no rewrites, no scripts | §11: the table, the script service, the editor, `test_rules` | L |

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
  `SettingsView.swift:604-605`, becomes it), disabled when no preference of the tab differs from its default. About has none.
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
- **A new row is hint**, its mode one click away: no source changes unless asked; a one-character Han `src` replaced breaks a word (王
  in 王様) where a hint costs one row. **Both is better for names** (person or place, 2+ characters) where Apple translates, and
  likely on LLMs (final form plus gender; R7 measures it): with Apple in effect the menu marks Both "recommended for names".
- **Replacing in the OUTPUT** breaks Korean particles (은/는, 이/가 after a different final consonant): only as an explicit
  after-rewrite (§11), with that warning beside it.
- **Cost on the row**: a 22 pt mode button (`text.bubble` hint, `arrow.left.arrow.right` replace, `plus.bubble` both) opens "Hint — told
  to AI engines · ≈ n tokens where it occurs", "Replace — written into the text first · 0 tokens · Apple Translation too", "Both · ≈ n
  tokens"; n = `approxTokens(renderRow(e)) + 1`, the budget's own count (`TranslationContextLayout.swift:386`). The Glossary gets "Use
  these as: Hints · Replace in the text · Both" with the same costs per pair.

## 11. Rewrites and scripts (A2, A4, A5)

The user: "ui를 통한 입력모드와 스크립트언어를 이용한 치환을 둘다 넣고 싶어" · "고급자나 에이전트는 스크립트 잘 쓰니까": a table and
scripts, both in 1.1.5, with agents as script authors. Both cost 0 tokens and live on every profile, All apps included.

### 11.1 Model
- **Rewrites** (`rewrites`, ≤ 32, in order): {`stage`: before (source) | after (output), `find` ≤ 200, `replace` ≤ 200, `regex`, `on`
  (absent = on)}. Patterns are JavaScript regular expressions (flags `gu`, `$1`): one dialect with scripts, compiled (never run) at
  check time. Examples: before `（[ぁ-ゖ]+）` → "" (furigana); before "▼" → "" (a page mark); after "..." → "…".
- **Script** (`script`: {`source` ≤ 8,000 characters, `on`}): `function before(line, ctx) -> string`, `function after(src, dst, ctx)
  -> string`, both optional; `ctx` = {`app`, `profile`, `source`, `target`}, nothing else.
- **Order**: before = table, then script; after = script, then table; over the chain before broad → narrow, after narrow → broad. Then
  §10's replace rows go into the cleaned source, and hint rows are chosen by hits on it. The cache namespace adds a fingerprint of the
  chain's rewrites and scripts (none → today's string); the log adds `sent` only when `before` changed the line.

### 11.2 Where it runs
- Plain rows run in the app (linear). Regex rows and scripts run in a new XPC service `MwoyeoScript` on the reader's pattern: a target
  like `ReaderService` (`project.yml:28-71`); no entitlements in the direct build, only `com.apple.security.app-sandbox` in the App Store
  build (as `Reader/Reader-MAS.entitlements`): no network, no files. The app side copies `ReaderConnection`
  (`App/Reader/ReaderConnection.swift:153-160` handlers, `:145-149` kill of the recorded pid, `:135` exit when idle).
- **Time limit**: `JSContextGroupSetExecutionTimeLimit` is private API, and 2.5.1 says "Apps may only use public APIs". So the app
  times each call: 50 ms per line for a script, and for a profile's regex rows together; over it the app kills the service, writes
  `on: false` on that script or row (agents see it) and shows "Turned off: took longer than 50 ms on a line." Why 50 ms: a line is
  ≤ ~300 characters and a replace over it takes well under 1 ms (≥ 50× headroom); a 3-line batch adds ≤ 150 ms against "about 1 s a
  line" for Apple's slowest model (`App/Model/Settings.swift:31`). A throw or a non-string leaves the line unchanged and shows the
  error with line and column (the script stays on); a reply over 4 × the input + 200 characters is an error.
- **Default path**: no regex row and no script in the chain → nothing loaded; the service never starts. It starts when such a chain
  becomes active and exits after 60 s idle.

### 11.3 App Store (quotes read 2026-10-21 from developer.apple.com/app-store/review/guidelines; 2.5.1 and 2.5.2 checked verbatim by the lead, 4.7 and 4.7.2 against a summary of the page only)
- 2.5.2: "…nor may they download, install, or execute code which introduces or changes features or functionality of the app,
  including other apps." Our scripts are not downloaded: the person or their agent writes them, and they map text to text.
- 4.7: "Apps may offer certain software that is not embedded in the binary, specifically HTML5 and JavaScript mini apps and mini
  games, streaming games, chatbots, and plug-ins." 4.7.2: "Your app may not extend or expose native platform APIs or technologies to
  the software without prior permission from Apple." `ctx` is four strings, no API.
- Precedent, by kind: a Mac App Store writing app whose user actions are JavaScript; an iOS app built to run user scripts. The audit
  keeps `command` engines out of the App Store build for 2.5.2 (`docs/app-store/audit-2026-10-17.md:59`); if review objects, that
  build hides Script (a `Distribution` row) and keeps the table.

### 11.4 UI (the profile sheet, after Names)
- **Rewrites**: one "Add Rewrite" button until a row exists; a row = stage pop-up (Before/After, 72 pt), find, "→", replace, ".*"
  (regex, 24 pt), minus. With an After row, an orange caption: "Changing the translation can leave a wrong particle (은/는, 이/가)
  after a replaced word. Prefer Replace on the name's row."
- **Script**: a collapsed row "Script · Off / On / Error"; open: a monospaced editor (min 120 pt, "n / 8,000"), "Run this script", a
  sample line (the lens's last line) and "Test" → "before → …", "after → …"; errors in red with line and column, also in the log
  (category `script`).

### 11.5 Agents
- `set_memory` writes `rewrites` and `script` (same checks). `test_rules {profile | app (+ title), lines ≤ 20, translate?}` →
  `{"columns":["line","source","translation","shown"],"rows":[[0,"漢字（かんじ）","漢字","한자","한자"]],"errors":[{"stage":"after",
  "item":0,"line":3,"column":12,"message":"…"}]}`; without `translate` only `source` (nothing leaves this Mac); with it, through
  `translate_text`'s path. `docs/settings-for-agents.md` gets the signatures, `ctx`, the limits and two examples (furigana, "…").

## 12. Open questions for the user
1. **Per lens, everything**: languages and engine follow the window under each lens, not the app in front (a lens over app B while A
   is in front uses B's languages). Recommended: yes (title conditions and pinned presets need it; "Also sent to …" goes).
2. **Cloud engines and screen lines**: when a profile asks for lines, a cloud engine gets them unless its sheet says "only the line".
   Recommended: the profile's choice is enough, as an app's override is today.
3. **Window memory becomes a profile with a title condition**, made from the lens menu ("New Profile for This Window…"), not a "This
   window" tab. Recommended: yes (one concept less, the same read and matching).
4. **"Learn names and terms" moves from each engine to the profile.** Recommended: yes; what is read decides it.

**Decided 2026-10-21 (the user):** window memory (Q3: its form); only glossary hits go; Apple uses every scope's names (as replace rows);
"Memory for <App>…" in every lens menu; DeepL glossaries deferred; profiles, restore per tab, §10 and §11 all in 1.1.5.

**Decided 2026-10-21 (the user):** Q1 languages and engine follow each lens's profile; Q2 a cloud engine gets earlier lines when a profile
asks (the engine's allow switch can still say no); Q3 the window memory is a profile with a title rule; Q4 "learn names" moves to the profile.
