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
- **Investigation:** can Mwoyeo run below macOS 26, and at what cost.

## 1.1.5 — reading what is hard to read

- See and fix a misread line: the recognised original per line, edit, retranslate.
- Identifiers inside paragraphs keep their case; end-of-line hyphens are joined before translating.
- Games and video: ignore a region inside a lens, one key hides every lens, the last few lines stay on screen.

## 1.2 — for people learning a language

- Save a line from the lens menu (source and translation), explain a word with the active engine, export saved lines as
  flashcards.

## Any time

- Mac App Store review answers come first.
