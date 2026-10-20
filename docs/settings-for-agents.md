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

It prints the path. By default that is `~/Library/Application Support/Mwoyeo/settings.json` (inside the app's container for a sandboxed build). Ask the command; do not guess the path.

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
- `examples` for `appProfiles` and `engines`.

Any JSON Schema validator accepts it. `Mwoyeo --check-settings` says the same as the schema on the same file.

## The check

```
Mwoyeo --check-settings [path]
```

Without a path it checks the real file. Output is `ok` and exit 0, or one line per issue and exit 1:

```
settings.json:7: unknown key appProfiles[0].paragraphReadr (did you mean paragraphReader?)
settings.json:11: appProfiles[0].entries[0].gender: "x" is not allowed; use one of f, m, n; ignored
settings.json:14: appProfiles[0].entries[1]: missing "src"; dropped
settings.json:21: engines[0].thinking: "maybe" is not allowed; use one of off, provider; ignored
```

A line is `settings.json:<line>: <path>: <what is wrong>; <what happened>`. `<line>` is the line of that value in the file, nested values included. `<path>` is the JSON path. `<what happened>` is one of:

| Ending | Meaning |
|---|---|
| `keeping the current value` | The whole setting is wrong (a wrong type, a bad value, an item that cannot be read). It is not applied. |
| `ignored` | An optional field inside an item is wrong. It is treated as not written; the item applies. |
| `dropped` | One row of a list of independent rows (a memory entry, an addressing row, a log format) is wrong. It is left out; the other rows apply. |

An unknown key is reported with the closest known one and is ignored. A list over its cap keeps its first items. A trailing comma is reported, because other tools cannot read it.

## Per-app memory

Inside `appProfiles`, a profile can carry a note for the translator, names and terms, and a context override. All of these fields are optional. A profile still needs `bundleID`, `source` and `target`.

What a request to an added engine (an OpenAI-compatible server or Anthropic) carries from them:

| The app has | The engine's `context` | The app's `context.mode` | The request carries |
|---|---|---|---|
| nothing written | off | left out | the lines to translate, as always |
| a `note` or `entries` | off | left out, `nearby` or `conversation` unset | the **memory only**: the app's name and category, the note, and the names whose `src` is in the text. No screen lines, no earlier lines, no window title. |
| anything | on, or the app says `nearby` or `conversation` | | all of the above, and the lines around the text on screen (`nearby`: the two lines above and the two below; `conversation`: also the last `previousLines` lines read) |
| anything | any | `off` | the lines to translate, as always. `off` turns the memory off too. |

Writing a `note` or `entries` is the opt-in for the memory-only request. DeepL, an HTTP template, a command engine and Apple Translation get nothing from it (DeepL takes the memory only through its own `context.deepLInstructions`; Apple follows `appleUsesPinnedTerms`).

```json
{
  "appProfiles": [
    {
      "bundleID": "com.example.chat",
      "appName": "Example Chat",
      "source": "ja",
      "target": "en",
      "note": "Casual chat between two friends. Keep it informal and short.",
      "entries": [
        {
          "src": "田中", "dst": "Tanaka", "kind": "person", "gender": "m",
          "note": "the speaker's older colleague", "reading": "たなか",
          "addressing": [{ "to": "Hana", "register": "polite" }]
        },
        {
          "src": "花", "dst": "Hana", "kind": "person", "gender": "f",
          "addressing": [{ "to": "Tanaka", "register": "casual" }]
        }
      ],
      "context": { "mode": "nearby", "previousLines": 3 }
    }
  ]
}
```

| Field | Type and limit |
|---|---|
| `note` | text, up to 500 characters |
| `entries` | up to 40 rows; a second row with the same `src` is left out |
| `entries[].src`, `dst` | text, 1 to 80 characters |
| `entries[].kind` | `person`, `place`, `term` or `org`; left out, `term` |
| `entries[].gender` | `f`, `m` or `n` |
| `entries[].note` | text, up to 40 characters |
| `entries[].reading` | text, up to 80 characters |
| `entries[].addressing[]` | up to 4 rows; `to` (text, 1 to 80 characters) and `register` (`casual`, `polite`, `formal` or `honorific`), both required |
| `context.mode` | `off`, `nearby` or `conversation`; required when `context` is there |
| `context.previousLines` | whole number, 0 to 8; left out, 3 |

`context` is how much surrounding text goes along with each line of that app. Left out, the app follows the default, which is off. `previousLines` counts only in `conversation` mode. `nearby` sends the lines right above and below the text on screen (two each), and no lines read before.

## Context for an engine

Each entry of `engines` can carry a `context` object. It says what that engine is sent besides the lines to translate. Everything is off by default: an engine without `context`, or with `"enabled": false`, gets exactly the requests it always got. Every field is optional.

```json
{
  "engines": [
    {
      "kind": "openAICompatible",
      "name": "Local Qwen",
      "baseURL": "http://localhost:8765/v1",
      "model": "qwen3:8b",
      "context": { "enabled": true, "previousLines": 3 }
    }
  ]
}
```

| Field | Type and limit |
|---|---|
| `context.enabled` | `true` or `false`; left out, `false`. While it is `false`, the other fields do nothing. |
| `context.previousLines` | whole number, 0 to 8; left out, 3. How many earlier lines go along with each line. |
| `context.includeTitle` | `true` or `false`; left out, `false`. Also sends the window title. The title leaves this Mac when the engine is a cloud service. |
| `context.useLearned` | `true` or `false`; left out, `false`. Also sends the terms the app learned while translating, and records the terms the engine's reply names. They stay in memory. |
| `context.deepLInstructions` | `true` or `false`; left out, `false`. DeepL only: `custom_instructions` and a formality come from the memory written for the app. |

The names are those of `appProfiles[].context`, which is laid over the engine's `context` for that app. A wrong value inside `context` is reported and treated as not written:

```
settings.json:7: engines[0].context.previousLines: 12 is out of range 0 to 8; ignored
```

A second global key, `appleUsesPinnedTerms` (`true` or `false`), lets Apple Translation follow the names and terms pinned in an app's memory, by putting your translation into the source text. It is off by default. The app writes the key to the file only while it is `true`; write `false` to turn it off.

The app keeps and checks these keys. With context off, which is the default, a request is exactly the one earlier versions sent.

## The learned names, as a file to read

Terms the app picks up while translating (`context.useLearned`) live in memory. While `savesTranscripts` is `true` the app also writes the ones it uses to one file per app, beside the translation log:

```
<exportFolder>/Memory/<bundle id>.json
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
- The app writes it at most once every 5 seconds per app, and never reads it back. To keep a row, add it to `appProfiles[].entries` (or press Pin in the app's Memory sheet).

## What is never in settings.json

- **Learned entries.** Terms the app picks up while translating live in memory only (and in the file above while `savesTranscripts` is on). A term is in settings.json only as a row of `appProfiles[].entries`, which you or the user wrote.
- **Referents** (who "he" is in the current document) and **screen text**. They belong to one document and one session, so they are never saved.
- **API keys.** They stay in the Keychain. An engine in `engines` has no key field; a header that must carry the key holds the placeholder `{{key}}`.
- **Run-time state** such as engine rejections and the onboarding flag.

To keep a durable "who is who", write it as `entries` with a `note` instead.
