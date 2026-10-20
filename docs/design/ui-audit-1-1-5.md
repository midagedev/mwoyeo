# UI audit for 1.1.5 (round ui-audit, 2026-10-21): today's screens against the HIG, with fixes as numeric contracts

Binary: `/tmp/latin-runs/dd-m4/Build/Products/Debug/Mwoyeo.app` (main, 4ca3efc tree). Captures are at 2x, so px / 2 = pt, in dark mode. HIG text read 2026-10-21 from the HIG JSON pages; the contrast script is `/tmp/uiaudit/contrast.py`.

Tags: P1 = wrong or confusing, P2 = HIG mismatch, P3 = polish. Effort S/M/L.

Not judged (capture artifacts):
- the Settings tab bar (a plain NSWindow draws it as a capsule);
- the app named in the lens menu;
- the pill's "English → Korean" in the Korean run, which is a literal in UICapture.

## HIG lines this audit relies on (verbatim)

- **H-set1** (settings): "Minimize the number of settings you offer."
- **H-set2** (settings): "people often use the standard Command-Comma (,) keyboard shortcut to open an app’s settings"
- **H-set3** (settings): "because a settings window accommodates the size of the current pane"
- **H-acc1** (accessibility): "macOS | 28x28 pt | 20x20 pt"
- **H-acc2** (accessibility): "Up to 17 pts | All | 4.5:1"
- **H-lay1** (layout): "Group related items to clearly express related information or functions. For example, you might use negative space, container shapes, or separator lines to show which elements are related and which are unrelated."
- **H-lay2** (layout): "Align elements to make them easier to scan, and use indentation to convey hierarchy."
- **H-col1** (color): "Avoid using the same color to mean different things. Use color consistently throughout your interface, especially when you use it to help communicate information like status or interactivity."
- **H-wri1** (writing): "Build language patterns. Consistency builds familiarity, helping your app feel cohesive, intuitive, and thoughtfully designed."
- **H-wri2** (writing): "Choose simple, plain language and write with accessibility and localization in mind, avoiding jargon and gendered terminology."
- **H-wri3** (writing): "Begin with language like “Get Started” to indicate you’re starting a flow. … Make it clear when a flow is complete by using language like “Done.”"
- **H-wri4** (writing): "If you need to direct someone to a setting, provide a direct link or button, rather than trying to describe its location."
- **H-alt1** (alerts): "Aim for a one- or two-word title that describes the result of selecting the button."
- **H-alt2** (alerts): "when people deliberately choose a destructive action — such as Empty Trash — the resulting alert doesn’t apply the destructive style"
- **H-sht1** (sheets): "Avoid showing all three buttons — Cancel, Done, and Back — together."
- **H-mod1** (modality): "Make it easy to identify a modal view’s task."
- **H-men1** (menus): "Show people when a menu item is unavailable."
- **H-ctx1** (context-menus): "Show keyboard shortcuts in your app’s main menus, not in context menus." The lens menu already complies.
- **H-mbx1** (the-menu-bar): "Display a menu — not a popover — when people click your menu bar extra. Unless the app functionality you want to expose is too complex for a menu, avoid presenting it in a popovers." The panel is kept: it holds a language bar, per-lens switches and an empty state, which is too much for a menu.
- **H-sld1** (sliders): "In many cases, labeling only the minimum and maximum values is sufficient."

## X. Across screens

**X1 — P2, M. Icon buttons are below the 20 × 20 pt minimum (H-acc1).** Measured glyphs are 12–14 pt, and the hit area is the label. Make each hit area 22 × 22 pt with `.frame(width: 22, height: 22).contentShape(Rectangle())`; drawing stays the same.
- `MenuPanel.swift:150,153,156`. The footer icon group goes from 51.5 to 74 pt and starts at 250 pt. "Hide Lenses" ends at 231.5 pt, so 18.5 pt stays free.
- `MenuPanel.swift:202` (trash) and `:483` (notice ✕).
- `SettingsView.swift:238,787` (⋯ menus): apply the frame after `.fixedSize()`.
- `SettingsView.swift:634` (shortcut ✕).
- `AppMemorySheet.swift:252,314` (minus buttons).
- Gate: AccessibilityChecks fails any of these frames under 20 × 20, with a FAIL-first run on today's tree.

**X2 — P2, S. Tertiary text measures 2.2:1 (H-acc2).** Change `.tertiary` to `.secondary`, which measures 5.1–5.3:1 on the same backgrounds.
- `SettingsView.swift:686` (version) and `:733` (©)
- `OnboardingView.swift:63` (footer)
- `AppMemorySheet.swift:187` ("Seen once…")
- Placeholders stay tertiary.

**X3 — P3, S. Five keys use straight quotes.** Change them to ’ and “ ”: "Your engine's provider…", "The engine's answer…", "…isn't supported yet", "…isn't responding…", `One "original = translation"…`.

## 1. Menu bar panel (`App/UI/MenuPanel.swift`)

**1.1 — P1, S. Show Original works with no lens.**
- Problem: it toggles `translationsVisible` (`AppModel.swift:581`), and a new lens inherits that (`:493`). The first lens then shows only the original, and the footer reads "Show Translation".
- Fix: at `:132-138`, add `.disabled(model.regions.isEmpty && model.translationsVisible)`.
- Gate: in check-logic, with 0 lenses the button is disabled.

**1.2 — P2, S. No ⌘, or ⌘Q (H-set2).**
- Fix: the gear (`:153`) gets `.keyboardShortcut(",", modifiers: .command)`; the power button (`:156`) gets `.keyboardShortcut("q", modifiers: .command)`.
- Help text gets the shortcut appended: "Settings (⌘,)" and "Quit Mwoyeo (⌘Q)".

**1.3 — P2, S. "Use Apple" sits under "… · using Apple" (H-alt1).**
- Problem: the headline says Apple already translates; the button actually pins Apple as the engine.
- Fix: at `:482`, "Use Apple" → "Switch to Apple".

**1.4 — P3, S. The header says "No lenses on" while the body says "No lenses yet".**
- Fix: at `:84`, with 0 lenses don't draw the status line. "No lenses on" stays for lenses that exist but are off.

## 2. Lens pill and lens menu

**2.1 — P2, S. Pill hit targets are 16 × 16 (close) and 18 × 16 pt (mode) (H-acc1).**
- Keep `closeRect` and `modeRect` (`RegionFrameWindow.swift:285-292`) for drawing.
- Add hit rects and use them in `mouseDown` (`:462`), the cursor (`:446`), the tooltip (`:428`) and accessibility (`:714`):
  - close: `NSRect(x: tab.maxX-26, y: tab.midY-11, width: 22, height: 22)`
  - mode: `NSRect(x: tab.maxX-(strong ? 48 : 26), y: tab.midY-10, width: 22, height: 20)`
- They fit the 26 pt tab, and the title's room (`:571`) already clears them.

**2.2 — The lens menu at L0 needs no change.** Dimmed items follow H-men1, the menu shows no shortcuts per H-ctx1, and Show Original uses a checkmark.

## 3. Settings › General (`SettingsView.swift:29-128`)

**3.1 — P2, M. Each caption is its own 37 pt row with a separator (H-lay1).**
- Rows affected: `:49`, `:69`, `:84`, `:86`, `:114`, plus Appearance `:504`.
- Fix: make each caption the control label's second `Text`, which the grouped form draws as a subtitle. Examples:
  - `Picker {…} label: { Text("Display"); Text(detail) }`
  - `Toggle(isOn:) { Text("Save transcripts"); Text(…) }`
  - The same for Screen checks and Connect an agent.
- Merge the two Saving captions into one: "Each lens writes what it reads and its translation to Markdown and SRT files, with the names and terms an engine learns."
- Expected: General is about 110 pt shorter at L0.

**3.2 — P2, S. "Settings file" and "Run in a terminal" are labels drawn in the accent color (H-col1).**
- Cause: `.borderless` and `.tint` sit on the LabeledContent (`:106-108`, `:121-122`), so the label turns blue too.
- Fix: move both modifiers onto the HStack of buttons.

**3.3 — P2, S. "Open at login" is filed under Performance.**
- Fix: move `:71-78` into a new first `Section` with no header, above Languages.

**3.4 — P3, S. The last section (`:99-125`) has no header.** Add the header "Advanced".

**3.5 — P3, S. The Folder row (`:88-95`) shows while saving is off.**
- Fix: draw it only while `savesTranscripts` is on. Turning saving on already asks for a folder (`:142`) (H-set1).

**3.6 — P3, S. "Rendering" is a developer word (H-wri2).**
- Fix: header `:58` "Rendering" → "Display"; segmented label `:45` "Display" → "Style".

**3.7 — P3, S. The settings.json problem caption (`:109`) gives no sign of a warning.**
- Fix: `Label(note, systemImage: "exclamationmark.triangle.fill")`, symbol yellow, text secondary.

## 4. Settings › Translation (`SettingsView.swift:178-393`)

**4.1 — P1, S. "Translation memory" (the cache) vs "Memory for/Remember/Forget <App>" (the names and note) (H-wri1).**
- Fix:
  - `:361` → "Recent translations"
  - `:363` → "Text seen again is shown from this list instead of being translated again. The list is kept only while Mwoyeo runs and is never written to disk."
  - `:808` "% from memory" → "% reused"
- settings.json keys are unchanged.

**4.2 — P2, S. Jargon in the Glossary first line (H-wri2).**
- Fix: `Settings.swift:32` → "Apple Intelligence follows your glossary exactly · for names in games and stories".

**4.3 — P3, S. The "Engine" label (`:278`) repeats the section header.**
- Fix: `.labelsHidden()`, keeping the accessibility label.

## 5. Appearance

**5.1 — P3, S. "Colour" is the only British spelling among 516 keys.**
- Fix: `:487` and `:504` → "Color".

**5.2 — P3, S. The Opacity slider (`:508`) has no end labels (H-sld1).**
- Fix: minimum label "Lighter", maximum label "Solid", both `.caption`, as the stillness slider does at `:52-54`.

## 6. Shortcuts

No new finding. §9 already covers it: no Restore Defaults while every shortcut is the default (`:603-606`). The ✕ size is in X1.

## 7. About and the Settings window

**7.1 — P3, S. The privacy lines' text starts at 42.5 / 44 / 45.5 / 44.5 pt.**
- Fix: at `:723-731`, give the icon a fixed `.frame(width: 18)`.

**7.2 — P3, M. One fixed 560 × 520 window for all five panes (`:23`) (H-set3).**
- Problem: About and Shortcuts leave about 120 pt empty; General and Translation scroll.
- Fix: a height per tab, with General and Translation capped at 640 pt. Do this after 3.1.

## 8. Onboarding (`OnboardingView.swift`)

**8.1 — P2, S. "Get Started" closes the flow, and the step that starts using the app is the secondary button (H-wri3).**
- Fix:
  - `:65` → "Done", `.glass`, no default action.
  - `:44` "Try It Now" → `.glassProminent` plus `.defaultAction`, disabled without permission as today.
  - While permission is missing, "Allow" (`:33`) is the default action.

**8.2 — P2, S. The Languages step describes a setting's location (H-wri4) and wraps to 4 lines.**
- Fix: `:37-38` → "Apple Intelligence translates with context. A lens offers a faster language pack when one helps." and "Mwoyeo uses Apple Translation. A lens offers the language pack it needs."
- No new control: the lens's own Download pill and the panel banner already offer the pack.

**8.3 — P3, S. Permission name.**
- macOS 15 and later list the setting as "Screen & System Audio Recording"; the app says "Screen Recording" (`:29`, `MenuPanel.swift:30`, and the pill).
- Verify the name on macOS 26 before changing the copy.

## 9. Engine sheet (`EngineSheet.swift`)

**9.1 — P1, S. "Privacy Policy" (`:265`) opens Mwoyeo's policy, right under a sentence about the provider's policy.**
- Fix: label it "Mwoyeo Privacy Policy" (new key). About keeps "Privacy Policy".

**9.2 — P2, S. Step 1 (`:108`) has no title (H-mod1).**
- Fix: a header "Add a Translation Engine" in `.headline`, padding 20 horizontal, 16 top, 4 bottom, as in `AppMemorySheet.swift:53-56`.

**9.3 — P3, S. Step 2 shows Cancel, Back and Add together (`:431-437`) (H-sht1).**
- Fix: for a new engine on step 2, the leading button is "Back" in place of Cancel. Esc still closes the sheet via `.onExitCommand { dismiss() }`.

The Context disclosure's contents belong to §6.5 and were not re-audited.

## 10. Memory sheet (`AppMemorySheet.swift`; L1, and §6.3 rebuilds its order and header)

**10.1 — P1, S. The Context section shows with Apple only.**
- What shows (capture memory-sheet-lens): "Follow the engine", "Applies only to engines you added. Apple Translation is not affected.", "Sent: lines only".
- Fix: at `:35`, draw it only while `!model.settings.engines.isEmpty`.
- Gate: memory-sheet-lens fails if this picker is in the accessibility tree when no engine exists.

**10.2 — P2, S. The bottom bar (`:77-84`) shows buttons that cannot act.**
- Problem: "Forget Learned" shows dimmed with nothing learned; "Start Fresh" is enabled with no conversation kept.
- Fix: draw each only while it can act, as §6.3 also says. At L1 the bar is "Done" alone.

**10.3 — P2, S. A name's details start at 30 pt, but its name field starts at 42 pt (H-lay2).**
- Fix: at `:274`, `details` gets `.padding(.leading, 12)`.

**10.4 — P2, S. "Speaks to" plus a borderless field reads as one label.**
- Fix: the Who field (`:302`) gets `.roundedBorder` and `.frame(maxWidth: 180)`.

**10.5 — P3, S. The title sits at 20 pt while section headers sit at 30 pt.**
- Fix: `:56`, change the horizontal padding from 20 to 30.

**10.6 — P3, S. Destructive styling on actions the person chose (H-alt2).**
- Sites: `AppProfiles.swift:285` (the Forget alert) and `AppMemorySheet.swift:70` (Start Fresh).
- Fix: plain style, with Forget as the default button. This one is your call.

## Summary table

| Screen | P1 | P2 | P3 | files |
|---|---|---|---|---|
| Across (X1-X3) | 0 | 2 | 1 | MenuPanel, SettingsView, AppMemorySheet, OnboardingView, EngineSheet |
| Menu bar panel | 1 | 2 | 1 | App/UI/MenuPanel.swift |
| Lens pill / menu | 0 | 1 | 0 | App/Overlay/RegionFrameWindow.swift |
| General | 0 | 3 | 4 | App/UI/SettingsView.swift |
| Translation | 1 | 1 | 1 | SettingsView.swift, App/Model/Settings.swift |
| Appearance | 0 | 0 | 2 | SettingsView.swift |
| Shortcuts | 0 | 0 | 0 | (covered by §9) |
| About / window | 0 | 0 | 2 | SettingsView.swift |
| Onboarding | 0 | 2 | 1 | OnboardingView.swift, MenuPanel.swift |
| Engine sheet | 1 | 1 | 1 | App/UI/EngineSheet.swift |
| Memory sheet | 1 | 3 | 2 | AppMemorySheet.swift, App/Model/AppProfiles.swift |
| **Total** | **4** | **15** | **15** | |

**Suggested order:** the four P1s (all S), then X1 and 2.1 under one gate, then 3.1-3.3 and 8.1-8.2, then the rest.

**English keys that change:**
- "Translation memory"
- "Text seen again is shown from memory…"
- "First result %@ s · %lld%% from memory"
- "Foundation Models follows your glossary · for names in games and stories"
- "Use Apple"
- "Privacy Policy" (the EngineSheet use only)
- the two Saving captions, merged into one
- the two onboarding Languages lines
- "Get Started"
- "Colour" and "Colour, weight and size are matched to the original text."
- "Rendering" and "Display"
- the five straight-quote keys

**New keys:** "Recent translations", "Switch to Apple", "Mwoyeo Privacy Policy", "Add a Translation Engine", "Advanced" (in General), "Lighter", "Solid".
