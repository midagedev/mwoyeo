# Profiles UI: guidance, walkthroughs, vision checklist

Status: design, 2026-10-21, round uiux1. The contract is `names-and-context.md` §6 (three levels: L0 nothing set up = today, L1 what
one natural act makes, L2 behind one explicit control) and `rewrite-rules.md` §7. This file is what R4 `prof-ui` and R9 `rewrite-ui`
capture, and what their opus vision round judges.

## 1. Apple's guidance it follows
Verbatim from the JSON behind https://developer.apple.com/design/human-interface-guidelines/<page> (read 2026-10-21).

| §6 rule | Page | Line |
|---|---|---|
| L2 behind a disclosure | disclosure-controls | "Use a disclosure control to hide details until they’re relevant." |
| Customize's label says what it holds | disclosure-controls | "Provide a descriptive label when using a disclosure triangle." |
| L0 stays today's | settings | "Minimize the number of settings you offer." |
| Defaults serve most people | settings | "Aim to provide default settings that give the best experience to the largest number of people." |
| The lens menu before Settings | settings | "When possible, prefer letting people modify task-specific options without going to your settings area." |
| One submenu, one level | menus | "Use submenus sparingly." · "Limit the depth and length of submenus." |
| Dimmed, not hidden, menu items | menus | "Show people when a menu item is unavailable." |
| Plain words | writing | "Keep settings labels clear and simple." |
| Empty states | writing | "Provide clear next steps on any blank screens." |
| "Change…", "Profiles…" links | writing | "If you need to direct someone to a setting, provide a direct link or button, rather than trying to describe its location." |
| Pop-ups that say their options | pop-up-buttons | "Give people a way to predict a pop-up button’s options without opening it." |
| No sheet over a sheet | modality | "Let people dismiss a modal view before presenting another one." |
| Warnings as captions | popovers | "Avoid using a popover to show a warning." |
| Sent line, title off off this Mac | privacy | "Be transparent about how your app collects and uses people’s data." |

## 2. The apple-design check (addendum A2)
The `apple-design` skill (a reviewer grounded in the HIG; its references/hig/*.md) applied to §6, each point checked against Apple's JSON:
- Modality, "Take care to avoid creating a modal experience that feels like an app within your app.": the sheet is one scroll of
  sections; Rewrites and Script open in place; "Change…" and "Edit Glossary…" close it before opening the next window.
- Modality, "Make it easy to identify a modal view’s task.": the header names the profile and, in one line, where it is used.
- Help: "Be brief. As much as possible, limit tooltip content to a maximum of 60 to 75 characters": every new help tag ≤ 75
  characters, verb first.
- Accessibility, "Offer sufficiently sized controls." (macOS minimum 20x20 pt): ⋯, minus and ".*" are ≥ 20 pt; caption2 (the menu bar
  caption) is the smallest text. Customize is one element whose value is its summary; no state is told by colour alone.
- Menus, "if a submenu contains more than about five items, consider creating a new menu": the Profile submenu passes five with two or
  more profiles. Kept: it is one choice (a checked list) plus two "New" items, cut at 8 profiles with "More in Settings…".

## 3. The first five minutes (capture scripts; each step: control, level; capture name in brackets)
1. **Never opens Settings.** Menu bar → Add Lens (L0) [menu-default] → the lens translates with Apple → right-click: today's items,
   then nameslens' "Memory for <App>…" and "Remember Languages for <App>" (L0) [lens-menu-l0]. No profile, engine or context word
   anywhere; settings.json gains no key.
2. **A gamer fixes one name.** Lens over an emulator, ハク reads "Haku" → lens menu "Memory for Emulator…" (L0) → the sheet, Names first
   (L1) [sheet-l1] → "Add Name": ハク → 하쿠; Apple is in effect and the name has 2 characters, so the row is Both (§10) → Done; the
   lens shows 하쿠. The lens menu now has "Names: 1 — Emulator 1" and "Profile: Emulator" (L1) [lens-menu-l1, lens-menu-l1-sub];
   Settings › Translation has Profiles (L1) [settings-profiles]. A second game: Profile ▸ "New Profile for This Window…" (L2) → the
   sheet with Customize open, the phrase "月涙譚 — 第二章" selected [sheet-new-window] → type "月涙譚" → Add Name; every later window of
   that game picks it.
3. **A power user.** Settings › Translation › Profiles → click "月涙譚" (L1) → "Customize" (L2) [sheet-l2] → Rewrites "Add Rewrite":
   Original, （[ぁ-ゖ]+）, ".*" on, empty; a Translation row "..." → "…" [sheet-rewrites] → "Script · Off" (L2) → paste §3's after(),
   "Run this script", "Test" [sheet-script] → a name row's disclosure, Use "Swap into the text" (L2) [sheet-row-details]. Then the menu
   bar "Profile: Auto" (L1) [menu-l1] → "Anime": every lens pinned; "Auto" undoes it.
4. **An agent (MCP).** `list_apps` (profiles, pin) → `get_memory {app, title}` (chain, why) → `set_memory {profile, when, entries with
   apply, rewrites, script}` → `issues` → `test_rules {lines}` (no engine) → `set_settings {profilePin}`. The person meets the result
   where it acts: Profiles appears (L1), the lens menu says "Profile: …", that profile's sheet opens on Customize because it has rules.
Also: [settings-translation] and [settings-general] at defaults, [settings-general-changed] after one change, and
[engine-cloud-context] (a cloud engine's sheet, Context opened).

## 4. Vision checklist (each item yes/no or a number; the captures of §3)
1. L0 [settings-translation, settings-general]: Translation shows exactly Translation engine, Apple Translation language packs,
   Recent translations, Glossary; neither capture shows Restore Defaults.
2. L0 [menu-default, lens-menu-l0]: no caption under the language bar, no engine menu; the lens menu has no "Profile" item and equals
   nameslens' list.
3. L1 [sheet-l1]: Names and terms is the first section; Customize is one collapsed row with a one-line summary; at 640 pt no
   condition, language, context, rewrite or script control is drawn; the bottom bar holds only "Done".
4. OCR of [sheet-l1, lens-menu-l1, lens-menu-l1-sub, menu-l1, settings-profiles] finds none of the whole words hint, replace, apply,
   chain, head, regex, mode.
5. [settings-profiles] (8 profiles, one name of 40 characters): every row is 2 lines; the long name has a middle ellipsis within 32
   characters; 6 profile rows, then "Show All 8 Profiles".
6. [lens-menu-l1, lens-menu-l1-sub, menu-l1]: one new top-level lens item, "Profile: …", with a one-level submenu; no menu line over
   48 characters; the menu bar caption is one line with a chevron.
7. [sheet-l2, sheet-new-window]: When it’s used, Languages, Context, Rewrites, Script, in that order; Script collapsed as "Script ·
   Off"; an empty profile shows only "Add Rewrite" under Rewrites.
8. [sheet-rewrites]: each row on one line (stage, Find, →, Replace with, .*, minus); the orange particle caption is under the table.
9. [sheet-script]: a monospaced editor ≥ 120 pt tall, "n / 8,000", "Run this script", "Before → …" and "After → …"; an error, if
   staged, in red with its line and column.
10. [sheet-row-details]: the first control is Use; its items read "Tell the translator", "Swap into the text", "Both", each with
    "≈ n tokens" or "free".
11. [engine-cloud-context]: the row reads "Context · <words>" when closed; opened, "Send the window title" is off.
12. [settings-general-changed]: after one changed preference, "Restore Defaults…" is at the foot of that tab and of no other.
