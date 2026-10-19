# Language packs: every state has a line, an action, and a way back

Status: built in round pack1, 2026-10-19. Branch wt/pack1, on main 4b90f1c.

Why: reviews of the system translation app are dominated by language packs that will not download and languages that
fail without a word. Apple Translation is our default engine, so the first translation is where people quit. The default
path (what is translated and what is sent) is not touched; this only closes states where the person is stuck.

## 1. The states

A pair (`PackPair`: source, target) is in one of these states with the system's translator:

| State | Meaning |
|---|---|
| installed | the fast pack, or the only model asked for, translates it |
| via Apple Intelligence | pack not installed and downloadable; Apple Intelligence's model translates meanwhile |
| downloadable | pack not installed, nothing else translates it: the lens waits |
| asked | the system's sheet is up (a download runs or waits for a click) |
| not finished | the sheet ended and the pair still does not translate: declined, interrupted, no connection |
| unsupported | no translation for the pair (the same language twice) |

Owners (one each): `TranslationService.packStatus` (the system's answer, `PackStatus` in Core), `PackLedger` in Core
(asked / not finished), `PackDownload` (every download, whoever asks), `LensSignals.hint()` in Core (the pill's one
line), `LensHintText` (the words).

## 2. Before (main 4b90f1c): what each surface did

| State | Lens pill | Menu panel | Settings › Translation | Image window |
|---|---|---|---|---|
| downloadable | "Download X (once) ›" opens Settings and the sheet | banner "…not installed. Download it in Settings › Translation." with "Open Settings", which opens the last tab and starts nothing | row "Download", its own sheet | label + button, sheet over the picture |
| asked | same line, nothing says it is happening | same banner | row button disabled for its own sheet only | same label |
| not finished | DEAD END: `try?` swallowed the error, the issue was cleared, the lens went quiet and the same ask came back after the re-read, no reason given | same loop | row stays "Download", no word | picture translated again (spinner), same label: silent loop |
| unsupported | DEAD END: nothing, a lens that reads and says nothing | banner "…not supported" + "Open Settings" (wrong tab, no fix) | "Not supported" | message text, no action |
| via Apple Intelligence | translates; no line | none | WRONG: "Installed" (see below) | translates |
| offline, pack installed | translates (packs are local) | none | Installed | translates |
| offline, pack missing | = not finished | = not finished | = not finished | = not finished |

Two more dead ends found while tracing:
- No way to open Settings (`openSettingsAction` is nil): the click did nothing, silently.
- A sheet replaced by another pair's: its cancelled task ended the host's new pair.

The Settings list asked `LanguageAvailability()`. On a Mac with Apple Intelligence its default model is the
translation model, so it says "installed" for pairs whose pack is not (this Mac, macOS 27: fr, th, vi, uk, zh-Hans →
en: default `installed`, `.lowLatency` `supported`, `.highFidelity` `installed`). The list could never offer the fast
pack there, and its footer promised "translate quickly".

## 3. After

| State | Lens pill | Menu panel | Settings › Translation | Image window |
|---|---|---|---|---|
| downloadable | "Download X (once) ›" | the lens row shows the line (below the name, replacing the size line) with the same click; the banner only when no lens says it | "Download" | "Language pack needed" + button |
| asked | "Downloading X… ›" (click brings the sheet's window forward) | row line / banner with spinner and "Open Settings" | spinner + "Downloading…" | spinner + "Downloading X…" |
| not finished | "X download didn't finish — try again ›" (click asks again; the issue stays up, no re-read for nothing) | row line "X download didn't finish ›" / banner + "Try again" | "Didn't finish" + "Try again" | warning + "Try again" |
| unsupported | "X → Y isn't supported ›" (click: Settings › General) | row line / banner + "Choose Languages" | "Not supported" | warning + "Choose Languages" |
| via Apple Intelligence | no line, it translates | none | "Using Apple Intelligence" + "Download" (the faster pack) | translates |

- The pill's line sits in the name tag, never over translated text. The unsupported line is said only by a lens whose
  source is chosen and which shows nothing: on Detect it is one block the detector got wrong.
- Recovery needs no relaunch: "try again" asks again; a pack arriving anywhere (`languagePacksChanged`) drops old
  failures and the lenses read again. A sheet that ended installed re-reads; one that ended without the pack only
  refreshes the lines.
- One host per window: the Settings window hosts every lens/panel/row download, the image window its own. A second ask
  for a pair whose sheet is up starts nothing and only brings the window forward. Without a way to open Settings the ask
  ends as "not finished" instead of "downloading" with nothing to show.
- The ask names the model (macOS 26.4+): the pack, or Apple Intelligence's model when high fidelity is the engine
  chosen (the pack would not help there).
- What the sheet threw is logged (type, domain, code; category `packs`, counters `pack.download.*`), never used to decide:
  "Cancel" and a missing connection both throw. Whether the pair translates now decides.

## 4. Gates

- Core: `PackLedgerTests` (ledger, hint priority, actions); `LensHintTests` unchanged and green.
- App: `--capture-ui <dir> pack-checks` (also in `check-logic`), `App/Support/PackChecks.swift`: a fake status
  (`PackDownload.status`), no real download. FAIL-first lines against main 4b90f1c are in the round report.
- Captures: `lens-hint-pack-downloading`, `lens-hint-pack-notfinished`, `lens-hint-unsupported`, `menu-pack-rows`,
  `menu-pack-banner-*`, `translation-packs-states`, `image-window-pack-*`.

## 5. Not done, and why

- Telling offline from declined: the sheet reports only that it ended. "Didn't finish" says no more than that.
- A real download is never run by a gate; the sheet itself (a real pack for a pair on a Mac without Apple
  Intelligence) was not exercised. The statuses and the ask's model are checked, the sheet is the system's.
- The "Download" on a "Using Apple Intelligence" row asks for the fast pack with `.lowLatency`; on this Mac that sheet
  was not opened (it would download).
