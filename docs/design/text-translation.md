# Translate Text: ordinary text, not only what is under a lens

Status: designed and built in round text117, 2026-10-22. Branch wt/text117, on main dd652f0.

Why: a lens translates what is on the screen. A person who has text in hand (a sentence to send, a paragraph selected in an app that
cannot be read by a lens, an email to understand) has no way in, and every desktop translator has one (idea ledger, Reach row:
"selection and typed-text translation is a gap"). The agent tool `translate_text` already does it for an agent, through the very
`TranslationService` a lens uses, under the profile an app or a title picks. This is the same path for a person.

The default path is not touched: a lens sends the bytes it sent. Nothing here runs until someone asks (a menu row, a shortcut they
assigned, the Services menu, a Shortcuts action): no first-run step, no setting that is on by itself, no new network call.

## 1. Owners (one each)

| Concern | Owner | Used by |
|---|---|---|
| Which settings a request translates under: profile (pinned or picked by the app and title), languages, engine; what an engine may be sent | `TextTranslation.resolve` (App/Pipeline/TextTranslation.swift), the body of `MCPTranslate.translate` moved, not copied | `translate_text`, `test_rules`, the window, Services, the intent |
| The call: a `TranslationService` over those settings, the lines through `service.translate(_, context:)`, which engine answered | `TextTranslation.run` (same file) | the same five |
| A text in, a text out: split into units, run, put back with the separators it had | `TextTranslator` (App/Pipeline/TextTranslation.swift) over `TextParagraphs` (Core) | the window, Services, the intent |
| Units and separators; which lines are one wrapped paragraph (`TextParagraphs.Seam`) | `TextParagraphs` (Core/TextParagraphs.swift) | `TextTranslator` |
| Typing pause, and whether a pause may call an engine | `TypingPause`, `TextTrigger` (Core/TextWindow.swift) | the window's model |
| The window | `TextTranslationWindow` (owner), `TextTranslationModel`, `TextTranslationView` (App/UI/TextTranslationWindow.swift), in the shape of `ImageTranslation` | menu panel, shortcut, app menu, Services |
| Services entry | `ServicesProvider` (App/Support/TextEntryPoints.swift), the `NSServices` array of project.yml | the system's Services menu |
| Shortcuts / Spotlight | `TranslateTextIntent` (same file) | Shortcuts, Spotlight |
| A way in with the menu bar item out of reach | `ReopenWindow` (Core/MenuBarIcon.swift) decides, `WindowPresenter.showForReopen` (App/MwoyeoApp.swift) shows | Spotlight, Finder, `open -a` while the app runs |
| The shortcut | `HotKeyAction.translateText`, no default (HotKeys.swift); the settings file, its schema and its validation take the key from `HotKeyAction.allCases` | Settings › Shortcuts, settings.json |

What is shared with MCP `translate_text` is the whole of `resolve` and `run`: the chain of the app (and title) in front, `profile` as a pin, an
added engine by id or "apple", the memory a lens would send (`ContextPlan`), rewrites and scripts of the profile, the engine's name per line.
What differs is who asks, and so what is refused (`TextTranslation.Asker`):

| | agent (`--mcp`) | person (window, Services, intent) |
|---|---|---|
| command engines (programs of the person's own) | refused: an agent must not start a program | run, as a lens runs them (not in the App Store build, as everywhere) |
| the engine's key in a Keychain this process cannot read | probed first and said (a separate process may be denied) | not probed: the app's own client reports the engine's trouble as an issue |
| a profile to translate under | one of `list_apps` (`test_rules` takes the same, so `all` is not one) | one of them, or All Apps Only |
| words of a refusal | the tool's (`translate_text was not run: …`) | the window's, localized |
| service | a fresh one per call (its cache is not keyed by memory) | one kept while the settings it was made for are equal, so a pause that changes one word does not translate the other paragraphs again |

## 2. The window

"Translate Text…": menu panel footer (beside "Translate Image…"), the app menu, `⌃⌥`-assignable shortcut (none by default), Services.

- Two panes, side by side: the source (editable) and the translation (selectable). Above them: the profile (a pop-up, only when a profile
  exists: the same progressive disclosure as the panel's caption), the language bar (`LanguageBar`, local to the window), and the engine (a
  pop-up, only when an engine was added). Below: the status line, Copy, Translate (⌘↩).
- Profile: Automatic (the profile of the app that was in front when the window was asked for: `AppModel.frontmostBundleID`, which never
  holds Mwoyeo), All Apps Only, or a profile by name. It decides languages, engine, names, rewrites and scripts exactly as on a lens.
  The pick, the languages and the engine chosen in the window are the window's state, not settings: they are gone with the app.
  A language or engine picked in the window lasts until the profile is changed.
- Long text: split into units (`TextParagraphs`): one per non-empty line, or one per paragraph where hard line breaks wrap it (§2.1), and a
  line over 1000 characters is cut at sentence ends (else at a space, else at 1000). The units go to the service in one call and its `onResult` fills the translation as each one comes back; the status
  line says "n of m". The separators (blank lines, indents, the space between cut pieces) are the source's own, so the shape of the text is
  kept. Over 50 000 characters the window says so and translates nothing: a text editor and an engine's bill are the reasons.
- When it translates by itself: `TextTrigger`. With Apple (every Apple engine, on the device, free) a pause in typing (0.8 s,
  `TypingPause`) translates, and so does ⌘↩. With an added engine only ⌘↩ and the button translate: each pause would send the person's
  text to a server, and cost tokens, for every half sentence typed. Services is the person asking, so it translates at once with either. The
  window says, in the empty translation pane, which of the two it is.
- A missing language pack is the image window's case, on the same owner (`PackDownload`, host `.text`): "Download <language>" under the pane,
  the translation again when it came. An unsupported pair says so and "Choose Languages" opens Settings.
- Every control has a name and answers `AXPress`; the source is a named text area and the translation a named group whose text a screen
  reader reads as it is; Copy and Translate are disabled while they have nothing to do. The window's least width (680 pt) is what the
  profile caption, the language bar and the engine pop-up need in one row.

### 2.1 Text that was wrapped by hard line breaks (round text2, 2026-10-22)

A PDF reader, a mail and a terminal hand over a paragraph with a line break where each line ended on the page. The window made one unit per
line, so a sentence the break cut in two was translated as two sentences: the film's "The background colour is the per-channel median of" and
"the ring." came back as 「…중앙값입니다.」 and 「그 반지」 (take t3r-text3). The lens never had the trouble: it joins by the boxes of the lines
(`ParagraphGrouper`: gap, height, column), and a text has no boxes.

Target: the lines of one block (no blank line between them) are one unit when the text shows they are one paragraph, and the window shows the
paragraph reflowed. The owner is `TextParagraphs.split`, which asks `TextParagraphs.seam(upper, lower)` for every pair of lines of a block; the
answer is a `Seam`, one case per reason, so a join or a refusal can be read in a trace and a test:

| Seam | When | Why |
|---|---|---|
| `.code` | the block reads as code, a log or a terminal on its text (`CodeRegion.readsAsCode`: the text clauses of the lens's own `verdict`, and a log or a diff alone) | a line of code is its own statement |
| `.columns` | either line has a tab or three spaces inside | a table row |
| `.listItem` | the lower line opens a list item (`ParagraphGrouper.startsListItem`, the lens's own rule) | a bullet or a number starts a block |
| `.short` | the upper line has fewer than `BodySize.bodyCharacters` (40) characters, a Han, kana or hangul glyph counting two | a heading, a label, a short typed line, the end of a paragraph; the lens's own "body-like" measure |
| `.sentenceEnd` | the upper line ends a sentence (or a colon, a semicolon) and the lower one does not go on in lower case | two sentences are two units, as they were |
| `.wrapped(glue:)` | none of the above | one paragraph; the glue is a space, nothing after a hyphen ("thresh-" "old" is "thresh-old": no character is changed, only the white space) and nothing beside Han or kana |

What was measured: the method paper's page 5 as a PDF reader copies it (`tools/paper-own`, the Mwoyeo method paper): its paragraphs and the
three-line table caption are one unit each, its listing keeps its lines, its headings stay alone (Core `TextParagraphsWrapTests`). Typed text
stays as it was: a line of fewer than 40 characters is never joined, and a typed line that ends its sentence is not joined to a line that
starts a new one.

A paragraph is cut between lines at 1000 characters, so a unit is never longer than a piece and the round trip `join(split(t), [:]) == t` holds
(`Part.source` keeps the lines of a joined unit as they were, for the part of the text not translated yet). The translation pane has one line
per paragraph: the translation of a paragraph is not the same number of lines as its source, so the source's line count is not kept; the blank
lines, the indents before the paragraph and the break after it are. MCP `translate_text` keeps its contract: an agent's lines are its own units
and it never goes through `TextParagraphs`; Services and the Shortcuts action do (they use `TextTranslator`). `Trace.count("text.wraps")` counts
the line breaks read as no break.

Known limit: lines of 40 characters and more that carry no full stop and are set one under the other on purpose (a poem, a lyric) read as one
paragraph. Quoted mail lines ("> …") are not told apart either.

### 2.2 A way in with the menu bar item out of reach (round text2)

A menu bar manager can hide the item and the notch can cover it; Translate Text has no default shortcut, and the app menu holds it only while a
Mwoyeo window is in front, so the feature could not be reached. The app already handled "opened again while running" (Spotlight, Finder,
`open -a`: the system's reopen, `applicationShouldHandleReopen`), by showing the welcome every time. Target: a reopen shows a window that
holds everything the item holds. `ReopenWindow.shown`: the welcome while it is still needed (it has not been completed, or Screen Recording
is not allowed: the welcome asks for a reopen after the grant), else the menu panel in a window of its own (`WindowPresenter.showMenu`), the
same `MenuPanel` view, so Translate Text is its button, with Add Lens, Settings and Quit. No default shortcut is assigned, no setting added, no
first-run step. Spotlight's own list already has "Translate Text" (the Shortcuts action, §3).

## 3. Services and Shortcuts

Services: `NSServices` in Info.plist (project.yml `info.properties`, so the direct and the App Store build alike): "Translate with Mwoyeo",
`NSMessage` `translateSelection`, plain text in, nothing out, `NSApp.servicesProvider`. It opens the window with the selection and
translates. The title is localized in InfoPlist.xcstrings (the Info.plist's own table). Sandbox-safe: a service gets the selection through
the pasteboard the system hands it.

Shortcuts: `TranslateTextIntent`, "Translate Text": text in, the translation out as text, an optional target language (a name or a code). It
runs `TextTranslator` under the settings file's own pair and engine (no app in front, so no profile but All apps), and fails with the
engine's reason in words when nothing came back. One App Shortcut phrase for Spotlight.

## 4. Gap table

| Wanted | Before (main dd652f0) | Now |
|---|---|---|
| Translate text a person has | only lines under a lens, or an agent through MCP | window, Services, Shortcuts |
| The same profile logic as a lens | in `MCPTranslate.translate` | moved to `TextTranslation.resolve`; MCP calls it; its checks unchanged |
| Long text | `translate_text` takes 20 lines of 2000 characters | units of at most 1000 characters, no count limit under 50 000 characters |
| Not paying for half sentences | n/a | `TextTrigger`: added engines wait for ⌘↩ |
| Words for a person when it fails | the tool's English sentences | the window's status line, localized: pack, unsupported pair, the engine's issue |
| A PDF's wrapped paragraph | one unit per line: a sentence cut in two was two sentences (film t3r-text3) | one unit per paragraph by `Seam` (§2.1); typed text and code as before |
| Translate Text with the menu bar item hidden | not reachable | a reopen opens the menu panel in a window (§2.2) |
| Trace and counters | none | `Trace.count("text.run")`, `text.units`, `text.service.reused`; the status line names the engine that answered |

## 5. Not here

Auto-detecting that the clipboard holds text; a history of texts; reading aloud; a menu bar field for typing in the panel. A global
shortcut that translates the selection without a window needs Accessibility; Services is the sandbox-safe way to that, and a shortcut
opens the window.
