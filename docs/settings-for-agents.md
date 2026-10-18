# Editing Mwoyeo's settings (for agents and scripts)

Every setting is one JSON file. You can read it, edit it and check it without starting the app.

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
- the allowed values (`enum`), ranges and length caps (`maxLength`, `maxItems`);
- `additionalProperties: false` on every object, so a misspelt key is an error;
- `examples` for `appProfiles` and `engines`.

Any JSON Schema validator accepts it. `Mwoyeo --check-settings` says the same as the schema on the same file.

## The check

```
Mwoyeo --check-settings [path]
```

Without a path it checks the real file. Output is `ok` and exit 0, or one line per issue and exit 1:

```
settings.json:11: appProfiles[0].entries[0].gender: "x" is not allowed; use one of f, m, n; ignored
settings.json:7: unknown key appProfiles[0].paragraphReadr (did you mean paragraphReader?)
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
| `entries` | up to 40 rows |
| `entries[].src`, `dst` | text, not empty |
| `entries[].kind` | `person`, `place`, `term` or `org` |
| `entries[].gender` | `f`, `m` or `n` |
| `entries[].note` | text, up to 40 characters |
| `entries[].reading` | text |
| `entries[].addressing[]` | `to` (text) and `register` (`casual`, `polite`, `formal` or `honorific`), both required |
| `context.mode` | `off`, `nearby` or `conversation` |
| `context.previousLines` | whole number, 0 to 8 |

## What is never in the file

- **Learned entries.** Terms the app picks up while translating live in memory only. A term is in the file only as a row of `appProfiles[].entries`, which you or the user wrote.
- **Referents** (who "he" is in the current document) and **screen text**. They belong to one document and one session, so they are never saved.
- **API keys.** They stay in the Keychain. An engine in `engines` has no key field; a header that must carry the key holds the placeholder `{{key}}`.
- **Run-time state** such as engine rejections and the onboarding flag.

To keep a durable "who is who", write it as `entries` with a `note` instead.
