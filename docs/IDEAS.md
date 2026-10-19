# Idea ledger

Ideas for Mwoyeo that are not scheduled yet, with the evidence behind each and where it stands. One row per idea; a row
moves to a design doc (`docs/design/`) when work starts and is marked shipped with the version that carried it.
Evidence: the market research of 2026-10 (kept outside the repository), the benches, and
user requests. Competing products are described by kind, not by name.

Status: **next** (proposed for the coming version), **open** (wanted, not planned), **parked** (decided to wait, with the
reason), **shipped** (version).

## Translation quality

| Idea | Why (evidence) | Status |
|---|---|---|
| Context-aware translation: a per-app rolling transcript sent with each request, cached; configurable, measured defaults | The strongest wish in the research: LLM-grade quality with context and tone (13 communities). Design: `docs/design/context-translation.md` | **next** (1.1.4) |
| Keep identifiers inside paragraphs: camelCase and code names in running prose come back with their case changed | Seen in the App Store screenshot renders (2026-10-19); today the guard works per line or block | open |
| Join end-of-line hyphens before translating ("noth-ing") | Paper renders leave such words untranslated | open |
| Keep a wrapped message's short last line (1–3 characters) with its paragraph | Chat renders translate such a tail on its own ("イだわ" became a separate block) | open |
| Inline math kept inside translated lines | Display equations are kept; inline ones come out as plain text. Design: `docs/design/keep-boundary.md` | parked (keep-boundary judge) |

## Recognition (OCR)

| Idea | Why (evidence) | Status |
|---|---|---|
| Let people see and fix a misread: show the recognised original for a line, correct it, retranslate | OCR failing on display fonts, small and vertical text is the third most common wish and a reason people quit game and manga tools | **next** |
| Vertical text and stylised game fonts: measure on our own scenes before promising anything | Same evidence; not verified in our benches yet | open (measure first) |

## First run and trust

| Idea | Why (evidence) | Status |
|---|---|---|
| Language pack flow that cannot get stuck: clear state, retry, what works meanwhile | The system translation app's reviews are dominated by packs that will not download; our default engine depends on the same packs | **next** |
| Lower the macOS floor to 15 (14 is impossible: the Translation framework starts at 15) | Comparable apps run on macOS 14–15. Measured 2026-10-19: size L; the blocker is `TranslationSession(installedSource:target:)` (26.0), so 15 needs sessions from a hosted `.translationTask`; Foundation Models engine, Liquid Glass and the document reader need guards or fallbacks; must be verified on a real 15 machine | open (own track, needs a macOS 15 machine) |
| Check behaviour on the newest macOS releases before each update | Rival tools lose ratings to breakage after OS updates | open |

## Games, video and chat

| Idea | Why (evidence) | Status |
|---|---|---|
| Ignore a region inside a lens (HUD, name tag, timer) | Asked in several game-overlay tools (7 communities for overlay manners) | open, small |
| One key to hide every lens | Same group of requests; ⌃⌥O shows the original but keeps the lens | open, small |
| Keep the last few translated lines visible (on-screen history) | Asked for chat and visual novels; today the history is only in transcript files | open |
| Gamepad control | Asked by console-style players | parked (narrow audience) |
| Audio to subtitles, dual subtitles on streaming sites | Real demand, but a different product (audio pipeline) | parked |

## Learners

| Idea | Why (evidence) | Status |
|---|---|---|
| "Save this line" from the lens menu (to a list, with source and translation) | The one group of wishes no comparable tool covers; every request is a user's own (3 communities) | open |
| "Explain this word": meaning, reading, example, from the active engine | Same | open |
| Export saved lines to a flashcard format | Same | open |

## Documents

| Idea | Why (evidence) | Status |
|---|---|---|
| Batch PDF translation, docx, export | Strong demand, but file-in/file-out tools already serve it; our strength is in place on screen | parked |
| Column width from the column, not from the widest line in the lens | Long translated lines without a wide neighbour get squeezed (paper renders) | open |

## Reach

| Idea | Why (evidence) | Status |
|---|---|---|
| Translation hub: Services menu, Shortcuts/Intents, a CLI or MCP server, a local API | Lets other apps and agents use the same engines; selection and typed-text translation is a gap against desktop translators | parked (after papers and the App Store release) |
| Positioning line: free, follows live text, papers in place | The in-place niche has new paid entrants with few ratings and no clear winner | open (store copy, site) |
