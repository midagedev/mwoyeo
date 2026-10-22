# Editing Mwoyeo's settings (for agents and scripts)

Every setting is one JSON file. You can read it, edit it and check it without starting the app.

## Prefer the MCP server

If Mwoyeo is connected as an MCP server (`claude mcp add mwoyeo -- "<app>/Contents/MacOS/Mwoyeo" --mcp`, and *Connect an agent (MCP)* on in
Settings › General, key `agentConnection`), use its tools instead of editing the file: `list_apps`, `read_translation_log` and `term_renderings` for the log,
`get_memory` and `set_memory` for one app's note, names and terms, `translate_text` to check a memory by translating a few lines the way the lens does,
`get_settings`, `set_settings` and `get_settings_schema` (give it a `key`: the whole schema is about 30 KB) for everything else. The tools apply the same
checks as this file and write nothing when a value is wrong. They also work in the App Store version, whose files an agent cannot reach.
`agentConnection` and command engines are changed only by the person.

Results are compact JSON, one copy (a text block, no `structuredContent`). A log is `{columns, rows, ...}`: what never varies (app, languages, engine, day)
sits once in the header, a row is an array in the order of `columns`, and a row id is the line's place in the whole log, the same in every tool.
`read_translation_log` returns the newest 50 rows (`limit`, up to 500); with `distinct` (the default) the pieces of a line an OCR read again and again are
folded into the fullest read and exact repeats are counted. To check a few names, `term_renderings` is smaller than reading the log.

## Where the file is

```
Mwoyeo --settings-path
```

It prints the path. By default that is `~/Library/Application Support/Mwoyeo/settings.json` (inside the app's container for a sandboxed build). Ask the command; do not guess the path. A flag Mwoyeo does not know (`--help` too) prints the usage to stderr and exits 64: it opens no app and writes no file.

`settings.schema.json` sits next to it. The file's `"$schema"` key points at it, so an editor offers completion and checks as you type.

## Changes apply live

Mwoyeo watches the file. A change you save applies within a second. A key you leave out keeps its value. You do not restart the app.

If you save a file with problems, the app applies what is good, reports the rest in Settings, and keeps your text as `settings.json.broken` the next time it writes the file itself.

## The schema

```
Mwoyeo --settings-schema
```

It prints the JSON Schema (draft 2020-12) to stdout: the same text as `settings.schema.json`. It has:

- a description for every key and every nested field;
- the allowed values (`enum`), ranges (`minimum`, `maximum`), length caps (`maxLength`, `maxItems`) and lists whose values must be unique (`uniqueItems`);
- `additionalProperties: false` on every object, so a misspelt key is an error;
- `examples` for `profiles` and `engines`. A key of Mwoyeo 1.1.4 that is read and never written (`appProfiles`, `appleUsesPinnedTerms`) is marked `deprecated`.

Any JSON Schema validator accepts it. `Mwoyeo --check-settings` says the same as the schema on the same file.

## The check

```
Mwoyeo --check-settings [path]
```

Without a path it checks the real file. Output is `ok` and exit 0, or one line per issue and exit 1. A file in the shape of 1.1.4 adds a note line before `ok` (see below), so read the last line or the exit code, not the whole output:

```
settings.json:7: unknown key profiles[0].paragraphReadr (did you mean paragraphReader?)
settings.json:11: profiles[0].entries[0].gender: "x" is not allowed; use one of f, m, n; ignored
settings.json:14: profiles[0].entries[1]: missing "src"; dropped
settings.json:21: engines[0].thinking: "maybe" is not allowed; use one of off, provider; ignored
```

A line is `settings.json:<line>: <path>: <what is wrong>; <what happened>`. `<line>` is the line of that value in the file, nested values included. `<path>` is the JSON path. `<what happened>` is one of:

| Ending | Meaning |
|---|---|
| `keeping the current value` | The whole setting is wrong (a wrong type, a bad value, an item that cannot be read). It is not applied. |
| `ignored` | An optional field inside an item is wrong. It is treated as not written; the item applies. |
| `dropped` | One row of a list of independent rows (a memory entry, an addressing row, a log format) is wrong. It is left out; the other rows apply. |

An unknown key is reported with the closest known one and is ignored. A list over its cap keeps its first items. A trailing comma is reported, because other tools cannot read it.

## Profiles: names, notes and context

`profiles` is the list of profiles. A profile is a name, a language pair, and optionally an engine, a note for the translator, names and terms, an amount of context and a learn switch. A profile needs `id`, `source` and `target`; every other field is optional.

`when` says where a profile is used. Each condition is an app (`app`, a bundle ID), a window-title phrase (`titleContains`), or both. A profile with no conditions is a **preset**: it is used only when it is picked (`profilePin`, or a lens's own pick). A lens uses every profile whose conditions match the window it covers, narrowest first (an app and a title, then a title, then an app), then **All apps**, which is the top-level keys of the file. The first profile of that chain decides the languages and where the learned names are kept. A note, names and terms of all profiles in the chain go together, narrow over broad.

```json
{
  "context": { "mode": "memory" },
  "profilePin": "anime",
  "glossaryApply": "both",
  "profiles": [
    {
      "id": "com.example.chat",
      "name": "Example Chat",
      "when": [{ "app": "com.example.chat" }],
      "source": "ja",
      "target": "en",
      "note": "Casual chat between two friends. Keep it informal and short.",
      "entries": [
        {
          "src": "田中", "dst": "Tanaka", "kind": "person", "gender": "m",
          "note": "the speaker's older colleague", "reading": "たなか", "apply": "both",
          "addressing": [{ "to": "Hana", "register": "polite" }]
        },
        {
          "src": "花", "dst": "Hana", "kind": "person", "gender": "f",
          "addressing": [{ "to": "Tanaka", "register": "casual" }]
        }
      ],
      "context": { "mode": "conversation", "previousLines": 3 },
      "useLearned": true
    },
    { "id": "anime", "name": "Anime", "source": "ja", "target": "ko", "customEngineID": "apple" }
  ]
}
```

| Field | Type and limit |
|---|---|
| `profiles` | up to 50; an item that cannot be read is reported and dropped |
| `id` | unique; 1 to 255 of letters, digits, `.`, `-` and `_`; never `all`. An app's profile uses its bundle ID, so its learned names keep their file name |
| `name` | text, 1 to 40 characters; left out, the id |
| `when` | up to 8 conditions; each needs `app` or `titleContains` (up to 60 characters); an empty one is reported and dropped; left out or empty, a preset |
| `source`, `target` | as `sourceLanguage` and `targetLanguage`; required |
| `customEngineID` | an id from `engines`, or `apple` for Apple Translation; left out or `null`, All apps' engine |
| `paragraphReader` | `automatic`, `documentLayout` or `lineGrouping`; left out, All apps' |
| `note` | text, up to 500 characters; over 500 in all, the broadest notes are dropped whole |
| `entries` | up to 40 rows; a second row with the same `src` is left out; of two profiles in use, the narrower one's row wins |
| `entries[].src`, `dst` | text, 1 to 80 characters |
| `entries[].kind` | `person`, `place`, `term` or `org`; left out, `term` |
| `entries[].gender` | `f`, `m` or `n` |
| `entries[].note` | text, up to 40 characters |
| `entries[].reading` | text, up to 80 characters |
| `entries[].apply` | `hint`, `replace` or `both`; left out, `hint` (see below) |
| `entries[].addressing[]` | up to 4 rows; `to` (text, 1 to 80 characters) and `register` (`casual`, `polite`, `formal` or `honorific`), both required |
| `context.mode` | `off`, `memory`, `nearby` or `conversation`; required when `context` is there |
| `context.previousLines` | whole number, 0 to 8; left out, 3 |
| `useLearned` | `true` or `false`; left out, the top-level `useLearned` |

### How much goes with each line

`context` says how much goes along with each line. A profile's own `context` lays over the top-level one (All apps'); with neither, the amount is `memory`.

| `context.mode` | A request to an added engine carries |
|---|---|
| `off` | the line to translate, as always. A note and names are not sent either |
| `memory` (left out) | when the chain has a note or a name that is a hint: the app's name and category, the note, and the names whose `src` is in the text. No screen lines, no window title. With neither, the line alone |
| `nearby` | also the lines around the text on screen (two above, two below) |
| `conversation` | also the last `previousLines` lines read before |

An engine takes only what it allows. `engines[].allow` has three switches, written only when they are not the default: `lines` (`true`: the lines around the text and the earlier lines may go; `false`: this engine gets the memory at most, whatever the amount), `title` (`false`: the window title may go; a server on this Mac gets it whenever lines go) and `deepLInstructions` (`false`; DeepL only: the memory goes as `custom_instructions` and a formality). DeepL takes the memory only through `deepLInstructions`. Apple Translation, an HTTP template and a command engine take no context; they take only the rows below that are written into the text.

```json
{
  "engines": [
    {
      "kind": "openAICompatible",
      "name": "Cloud chat",
      "baseURL": "https://api.example.com/v1",
      "model": "gpt-example",
      "allow": { "lines": true, "title": true }
    }
  ]
}
```

### How a name or term is used

`entries[].apply` says how a row is used:

| `apply` | What happens |
|---|---|
| `hint` | The row is told to the translator where its `src` occurs in the text. It costs tokens. This is what a row without `apply` does |
| `replace` | The translation is written into the text before translating. It is free, works for every engine including Apple Translation, and the translator is not told about it |
| `both` | Both. The row is chosen on the original line; the rewritten line is sent |

The top-level `glossary` is used the same way for every pair, by one key: `glossaryApply` (`hint`, `replace` or `both`; written only when it is not `hint`). A pair that a profile in the chain has a row for is not used.

### Pinning

`profilePin` pins every lens to one profile: its `id`, or `all` for All apps only. Left out, each lens picks by its window (Auto). It must name a profile in `profiles`; a pin to none is reported and keeps the current value. A lens's own pin, set from its menu, stays with the lens and is not in this file.

`lensSnap` (default true) makes a lens snap to the text columns under it: while it is dragged or resized, a guide shows when an edge is within 8 points of a column's edge, and a dragged lens settles on the edge when it is let go; holding ⌘ places a lens freely. `lensAutoFit` (default false) is only the default of the lenses you add: after a read settles, a lens with Auto Fit on that cuts the text of its column at the left or right edge grows to the column once (it never makes a lens smaller, and a manual resize turns it off for that lens). A lens keeps its own Auto Fit (its menu row) with the lens, not in this file, like its profile pin. Both keys are booleans, written to the file only while they differ from the default (`lensSnap` while false, `lensAutoFit` while true); a value of another type is reported with its line and keeps the current value. Fit to Column has no key: it is a lens-menu row, VoiceOver's action and a double-click on the lens's ring.

A wrong value inside a profile is reported and treated as not written:

```
settings.json:7: profiles[0].context.previousLines: 12 is out of range 0 to 8; ignored
settings.json:9: profiles[0].when[1]: needs app or titleContains; dropped
settings.json:9: profiles[0].when: 9 items; the limit is 8; the first 8 apply
```

## Files from Mwoyeo 1.1.4

Mwoyeo 1.1.4 wrote `appProfiles`, a `context` object in each engine and `appleUsesPinnedTerms`. All three are **read and never written** now. A file that has them and no `profiles` is converted when it is read: `appProfiles` become `profiles` (the id is the bundle ID, `when` is that app), an engine's `context` becomes the top-level `context`, `useLearned` and the engine's `allow`, and `appleUsesPinnedTerms: true` becomes `apply: both` on the rows of each profile whose engine in effect is Apple Translation (its own engine, else All apps', else Apple), and `glossaryApply: both` when All apps' engine is Apple; a profile on an added engine keeps `hint`. A file that has both `profiles` and `appProfiles` is read as `profiles`; the old key is ignored.

`Mwoyeo --check-settings` says so on such a file:

```
settings.json:1: in the shape of Mwoyeo 1.1.4: converted on the next save (appProfiles to profiles, engines[].context to context and allow); the old file is kept as settings-1.1.4.json
```

Before the first save in the new shape the app copies the file once, as it was, to `settings-1.1.4.json` beside it, and never overwrites that copy. A request is the one 1.1.4 made, except in four named cases: a lens over app B uses B's languages and engine while app A is in front; an engine kept spare has its earlier lines follow the amount; an engine with context off, an app whose override sent lines and another engine with context on follow the new rules; and with the Apple switch on, a profile Apple Translation translates gets its names both written into the source and told to the translator.

With no profile, no engine `context` and the Apple switch off, a request is byte for byte what earlier versions sent.

## The learned names, as a file to read

Terms the app picks up while translating (`useLearned`) live in memory. While `savesTranscripts` is `true` the app also writes the ones it uses to one file per profile, beside the translation log. The first profile of the chain keeps them (its `id`; with All apps first, the app's bundle ID):

```
<exportFolder>/Memory/<profile id>.json
```

```json
{
  "about": "Names and terms Mwoyeo learned while translating in this app ...",
  "app": "com.example.chat",
  "appName": "Example Chat",
  "rows": [{ "dst": "Tanaka", "gender": "m", "kind": "person", "src": "田中" }],
  "updated": "2026-10-19T12:34:56Z"
}
```

- There is no setting for it: it is part of what `savesTranscripts` saves. Off, nothing is written; a file already there stays.
- A row is a pair (`src`, `dst`) with its `kind` and `gender`. There are no sentences, no window titles and no counts.
- The app writes it at most once every 5 seconds per app, and never reads it back. To keep a row, add it to `profiles[].entries` (or press Pin in the app's Memory sheet).

## What is never in settings.json

- **Learned entries.** Terms the app picks up while translating live in memory only (and in the file above while `savesTranscripts` is on). A term is in settings.json only as a row of `profiles[].entries`, which you or the user wrote.
- **Referents** (who "he" is in the current document) and **screen text**. They belong to one document and one session, so they are never saved.
- **API keys.** They stay in the Keychain. An engine in `engines` has no key field; a header that must carry the key holds the placeholder `{{key}}`.
- **Run-time state** such as engine rejections and the onboarding flag.

To keep a durable "who is who", write it as `entries` with a `note` instead.

## Profiles over MCP

A profile (`profiles` in settings.json) is a name, a language pair and optionally an engine, a note, names and terms, an amount of context and a learn switch. One with `when` conditions (an app, a window-title phrase, or both) is used by a lens whose window meets one of them; one with none is a preset, used only when it is picked. The tools below speak of profiles and pass every write through the same checks as the file: a wrong field rejects the whole call and writes nothing. An app's own profile has the bundle ID as its id.

| Tool | Argument and result |
|---|---|
| `list_apps` | `profiles` is `{columns: [id, name, when, pair, engine, names, context], rows}`, in the order of the file (of two conditions that fit, the earlier profile wins a tie). `when` lists `app <id> title <phrase>` for each condition; `engine` is `apple`, the engine's name, or null for All apps' own; `context` is `off`, `memory`, `nearby` or `conversation <n>`, or null for All apps' amount. `pin` names the profile every lens is pinned to, or `all`. A Mac with no profile gets neither key. |
| `get_memory` | `{app}`: the memory of that app's own profile, the keys of 1.1.4 and `profile` (its id). `{profile}`: that profile as the file holds it, and `exists`. `{app, title}`: the chain a lens over that window uses, as `selected` (the first profile), `why`, `chain` (ids, narrowest first, then `all`), `pair`, `note` (the notes together), `rows` (`src, dst, kind, apply, from`: where each name comes from), `shadowed` (names a narrower row hid) and `learned` (from `Memory/<id>.json`, while Save transcripts is on). |
| `set_memory` | `{app}` writes the app's own profile, made on the base languages when it has none. `{profile}` writes that profile; an id nothing has makes a preset. Beside `note`, `entries` and `mode` it takes `name`, `when` (up to 8 conditions; only with `profile`; `[]` makes a preset), `source`, `target`, `customEngineID` (an engine id, `apple`, or null for All apps' own), `context`, `useLearned`, `rewrites` and `script` (see Rewrites and scripts below), and `remove: true`, which deletes the profile (its learned-names file stays, a pin to it goes) and takes no other field. It answers `{profile, created, names, pair (when created), added, updated, removed, issues}`; a profile deleted answers `{profile, deleted: true}`. |
| `translate_text` | beside `app`, `title` (the window title as a lens would have confirmed it) makes the profiles with a title condition apply, and `profile` translates as if every lens were pinned to it. The profile that decided the languages is in the answer as `profile`. The title picks a profile on this Mac and is never sent because of it. |
| `set_settings` | `{"values": {"profilePin": "<id>"}}` (or `"all"`) pins every lens; the id must name a profile. `{"values": {"profilePin": null}}` sets every lens back to Auto. |
| `reset_settings` | `{tab, dryRun?}` with `tab` one of `general`, `translation`, `appearance`, `shortcuts` sets the preferences of that tab back to their defaults, as Restore Defaults in Settings does, and answers `{changed: [[key, now, default], ...], kept: [key, ...]}`. Consent and data are never changed: `kept` names them (`agentConnection`, `savesTranscripts`, `exportFolder`, `context`, `useLearned`, `engines`, `glossary`, `glossaryApply` and `profiles`). With `dryRun: true` nothing is written. The old file is kept as `settings.json.before-restore`. A tab already at its defaults changes nothing. |

The translation log's JSON lines carry what the memory had. `profile` (the profile that decided the line, `all` when All apps did) follows `app`; `names` ends the line, `[[src, dst, from], ...]` for each name of the memory (and each glossary pair, `from` `all`) that occurs in the line, and is left out when none does. A Mac with no profile and no glossary writes the lines it always did. A line that stays in the lens and is translated differently (a script, a name or an engine was changed under it) is written again with the new translation, so the log shows what a change did to text already read; the same translation is not written twice. `read_translation_log` shows `profile` once in its header when it never varies, and a `names` column only when some row has names.

## Rewrites and scripts

Besides names and terms (which cost tokens when they are hints), a profile can change text on this Mac at no token cost: a table of **rewrites** and a **script**. Both sit on every profile and, as top-level keys, on All apps. They change the text **before** the engine sees it (the source line, as read) or **after** it (the engine's answer). Replacing a name or a term is better done with a row of `entries` whose `apply` is `replace` or `both`: the engine then translates around it and the grammar stays right. Rewrites are for the rest: furigana, page marks, a fixed phrase, punctuation. Changing the translation can leave a wrong particle in Korean (은/는, 이/가) after a replaced word.

```json
{
  "profiles": [
    {
      "id": "com.example.emu",
      "name": "Emulator",
      "when": [{ "app": "com.example.emu" }],
      "source": "ja", "target": "ko",
      "rewrites": [
        { "stage": "before", "find": "（[ぁ-ゖ]+）", "replace": "", "regex": true },
        { "stage": "before", "find": "▼", "replace": "" },
        { "stage": "after", "find": "...", "replace": "…" }
      ],
      "script": { "source": "function before(line, ctx) { return line.replace(/（[ぁ-ゖ]+）/gu, \"\") }", "on": true }
    }
  ]
}
```

| Field | Type and limit |
|---|---|
| `rewrites` | up to 32 rows, applied in order; a bad row is reported and dropped |
| `rewrites[].stage` | `before` or `after`; required |
| `rewrites[].find` | text, 1 to 200 characters; required |
| `rewrites[].replace` | text, 0 to 200 characters; left out, nothing (the text is deleted) |
| `rewrites[].regex` | `true` or `false`; left out, `false`. A plain row replaces every occurrence, case-sensitive, with no folding. A regex row is a JavaScript regular expression with the flags `gu`; `$1` and the like work in `replace`. |
| `rewrites[].on` | `true` or `false`; left out, `true`. The app writes `false` itself when a regex row took too long (below). |
| `script.source` | text, up to 8,000 characters |
| `script.on` | `true` or `false`; left out, `true` |

### The script

The source may define either or both of these functions, in plain JavaScript:

```js
function before(line, ctx) { return line.replace(/（[ぁ-ゖ]+）/gu, "") }          // drop furigana
function after(src, dst, ctx) { return ctx.target === "ko" ? dst.replace(/\.\.\./g, "…") : dst }
```

- `before(line, ctx)` gets the source line as read and returns the line to translate.
- `after(src, dst, ctx)` gets `src`, the line that was sent (after `before`), and `dst`, the engine's answer, and returns the line to show.
- `ctx` is `{app, profile, source, target}`: the bundle ID of the app (or `""`), the id of the profile (or `"all"`), the source language code (or `"auto"`) and the target language code. There is nothing else: no window title, no memory, no files, no network, no clock, and nothing kept between lines (each call gets a fresh global object).
- Each call is timed by the app. A script, and a profile's regex rows together, get **50 ms a line**. Over that the app stops the script service, writes `"on": false` on that script or row, and shows "Turned off: took longer than 50 ms on a line." in Settings. Read the file to see it; turn it back on after fixing the code.
- A call that throws, or returns something that is not text, leaves that line as it was for that stage and records the error with its line and column; the script stays on. An answer longer than 4 times the input plus 200 characters is such an error.
- A script that does not parse is refused where it is written: `set_memory` says `script, line 3: <the engine's message>` and writes nothing. JavaScriptCore gives a syntax error its line and no column, and a pattern that does not compile (`rewrites[2]: <message>`) neither, so neither is invented. A script that defines neither function is refused too. Nothing is ever run to check it.
- Plain rows run in the app. The script service starts only when a profile in use has a script or a regex row, and exits when idle: with none, nothing is loaded.

### The order of one line

1. `before`: All apps first, then each profile of the chain from the broad to the narrow; in each profile the table, then the script.
2. Names: rows that replace are written into the text; rows that hint are chosen by what occurs in it.
3. The engine.
4. `after`: the head of the chain first and All apps last; in each profile the script, then the table.

### Writing and testing them over MCP

- `set_memory` takes `rewrites` (the whole list; `[]` clears it) and `script` (`{source, on}`; an empty `source` removes it) beside the other profile fields, for a `profile` or an `app`. Every row, every length and the stage are checked as in the file, a regex row's pattern is compiled and the script parsed by the script service (a plain table asks no service), and one wrong thing refuses the call and writes nothing.
- `test_rules` runs the rules of a chain over lines you give it, without a screen: `{profile}` (as if every lens were pinned to it), or `{app}` with `title` for a window, `lines` (1 to 20) and `translate` (default false). The answer is `{profile, columns, rows, errors}`:
  - `columns` is `["line", "source"]`: `line` is the index of the line you gave and `source` is what `before` leaves of it, the line the engine would be sent. Nothing leaves this Mac, no engine is asked, and a chain with no regex row and no script starts no service.
  - With `translate: true` it adds `translation` (the engine's answer to `source`, the way `translate_text` gets it; null for a line left as it was) and `shown` (`after` over the answer, what the lens would show). The text then goes to that engine, and a cloud one sees it.
  - `errors` is present only when something went wrong: `{stage, item, line, column, message}` where `item` is the row's index, or -1 for the script, and `line` and `column` appear when known. A call over its 50 ms is reported as "Turned off: took longer than 50 ms on a line." and is skipped for the rest of the call. `test_rules` is a dry run: it never writes `on: false`, whatever it finds.
