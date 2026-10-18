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
- the allowed values (`enum`), ranges (`minimum`, `maximum`) and lists whose values must be unique (`uniqueItems`);
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
settings.json:14: engines[0].thinking: "maybe" is not allowed; use one of off, provider; ignored
```

A line is `settings.json:<line>: <path>: <what is wrong>; <what happened>`. `<line>` is the line of that value in the file, nested values included. `<path>` is the JSON path. `<what happened>` is one of:

| Ending | Meaning |
|---|---|
| `keeping the current value` | The whole setting is wrong (a wrong type, a bad value, an item that cannot be read). It is not applied. |
| `ignored` | An optional field inside an item is wrong. It is treated as not written; the item applies. |
| `dropped` | One value in a list of independent values (a log format in `transcriptFormats`) is wrong or is listed twice. It is left out; the other values apply. |

An unknown key is reported with the closest known one and is ignored. A trailing comma is reported, because other tools cannot read it.

## What is never in the file

- **API keys.** They stay in the Keychain. An engine in `engines` has no key field; a header that must carry the key holds the placeholder `{{key}}`.
- **Run-time state** such as engine rejections and the onboarding flag.
