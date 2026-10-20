# Roadmap

What the next versions carry. Ideas without a version live in [IDEAS.md](IDEAS.md); a version takes rows from there.
A version is tagged only when what it promises is usable in the app, UI included.

## 1.1.4 — translation that knows the conversation

- **Context translation for added engines.** Each request can carry the lines around it and the recent lines of the same
  window, plus the person's own notes, names and terms for that app. Off by default; switched on per engine (Settings ›
  Engines › Context) or per app. Defaults follow the benches, not guesses. Design: `docs/design/context-translation.md`.
- **Memory per app.** A sheet for an app's note to the translator, names and terms; learned names shown faintly, pinned
  with one click; "Forget learned" and "Start fresh".
- **Language packs that never leave you stuck.** The first translation must not wait on a download that silently fails:
  a clear state, a retry, and what works meanwhile.
- **Store page leads with live translation.** New name and subtitle ("Mwoyeo – 실시간 화면 번역", "Mwoyeo – Screen
  Translator"), keywords, and a hero screenshot that shows the translation following a changing screen.
- **Investigation (done):** macOS 15 is possible at size L, 14 is not; own track once a macOS 15 machine is available.

## 1.1.5 — engines you can trust, and reading what is hard to read

Order of work: A first (it fixes what 1.1.4 promises), then B and C in parallel tracks, then D. Each item is done when
its gate is green and, for anything on screen, a vision verdict says SHIP.

**A. What 1.1.4 promises, working with every engine** (found recording film 2, 2026-10-21; a known issue in the 1.1.4 notes)
- **Claude 5 engines answer without thinking.** Thinking off is a row per model family in `ModelQuirks`, not one field:
  Haiku 5.5 `thinking: {type: disabled}`; Sonnet 5.5 `{type: between_tools}`; Opus 5.5 and Fable cannot turn it off, so
  the lowest effort. Measured: Haiku 5.5 without the field thinks (~500 output tokens a line) and misses the 7 s deadline.
  Done when: Core golden bodies re-pinned per model with FAIL-first, and a live lens run with Haiku 5.5 shows the memory's
  names on screen.
- **The log names who really translated.** A line Apple translated while the engine rested or was busy is logged as Apple,
  not under the engine's name; the lens's engine badge says the same.
- **Lines reach the engine while it works.** Measured: with an engine call in flight, full lines went to Apple in ~70 ms
  and never reached the engine. Find the owner of that choice (rest after a cancel, in-flight limit), fix it there, gate it
  on a fake clock.
- **Structured replies for Anthropic.** `output_config.format` with the reply's JSON schema, so a reply always parses.
- **DeepL Free preset.** One click adds DeepL Free with Context and "memory as DeepL instructions" on; DeepL followed an
  app's memory on every line in the film's run (츠쿠모 ×8).

**B. Names that never drift** (round mem-hints, gates green, landing first)
- A line that is only a name in the memory (a name plate) is translated from the memory without asking the engine.
- Recognition hints from the memory were measured with no effect on Japanese (36/36 reads unchanged) and are not shipped.

**C. Reading what is hard to read**
- See and fix a misread line: the recognised original per line, edit, retranslate.
- Identifiers inside paragraphs keep their case; end-of-line hyphens are joined before translating.
- A wrapped message's short last line (1–3 characters) stays with its paragraph.

**D. Games and video**
- Ignore a region inside a lens (HUD, name tag, timer); one key hides every lens; the last few lines stay on screen.
- A moving background beside the text does not slow translation: the lens re-read the scene ~3× as often (median frame
  latency 3.7 s vs 1.2 s) when the scene moved in the band just above a game's text box.

**E. Agents** (MCP shipped in 1.1.4)
- `translate_text`: an agent translates text with the app's engine and an app's memory, so it can check a memory it wrote.
- An unknown command-line flag prints usage instead of opening the app.

## 1.2 — for people learning a language

- Save a line from the lens menu (source and translation), explain a word with the active engine, export saved lines as
  flashcards.

## Any time

- Mac App Store review answers come first.
