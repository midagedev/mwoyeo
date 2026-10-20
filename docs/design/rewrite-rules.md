# Rewrite rules and scripts

Status: design, 2026-10-21, round profiles1 (addenda A2, A4, A5). A part of `docs/design/names-and-context.md`: profiles, chains and
the row apply modes (hint · replace · both, its §10) are defined there; this file adds free-form text rewriting that costs no tokens.
Its rounds (R8 `rewrite-run`, R9 `rewrite-ui`, R10 `rewrite-agents`) are in that file's §8.

The user, 2026-10-21: "ai 번역시에 토큰을 소모하는 문맥주입과 소모하지 않는 기계적 치환을 구분해서 넣고 싶어. 자바스크립트 같은걸 넣게
할 수 있을까" · "ui를 통한 입력모드와 스크립트언어를 이용한 치환을 둘다 넣고 싶어" · "고급자나 에이전트는 스크립트 잘 쓰니까" (token-free
mechanical replacement apart from context; a table in the UI and scripts, both; agents and advanced users write scripts).

## 1. What it is
- Two modes on every profile, All apps included (top-level keys there): a **rules table** (`rewrites`) and a **script** (`script`). Both
  change text before the engine (`before`, on the source) or after it (`after`, on the output), on this Mac, at 0 tokens.
- A name or term row with `apply` replace (names-and-context §10) is the common case and needs neither: it is a row, inflected right
  because the engine translates around it. Rewrites are for the rest: furigana, page marks, fixed UI phrases, punctuation.
- **Output rewriting can break Korean particles** (은/는, 이/가 after a word with a different final consonant); the UI says so (§7).

## 2. The rules table
- `rewrites`: ≤ 32 rows, applied in order. A row = {`stage`: before | after, `find` (1-200 characters), `replace` (0-200), `regex`
  (default false), `on` (absent = on)}.
- Plain rows: every occurrence, case-sensitive, no folding. Regex rows: JavaScript regular expressions with flags `gu`; `$1` … in
  `replace`. One dialect with scripts, so a pattern tried in a script behaves the same in the table.
- Examples: before, regex `（[ぁ-ゖ]+）` → "" (drop furigana after kanji); before, "▼" → "" (a game's page mark); before, "セーブしますか？"
  → "Save?" (a fixed UI phrase the engine keeps mistranslating); after, "..." → "…".
- Strict check (`SettingsFileChecks`, each FAIL-first): a 33rd row, an empty `find`, a field over 200, a `stage` outside the two, a
  regex that does not compile (compiled by JavaScriptCore at check time, never run). Lenient decode: a bad row is reported and dropped.

## 3. Scripts
- `script`: {`source` (≤ 8,000 characters), `on`}. The source may define either or both:
  - `function before(line, ctx) -> string` — the source line as read; returns the line to translate.
  - `function after(src, dst, ctx) -> string` — `src` is the line sent (after `before`), `dst` the engine's answer; returns the shown line.
- `ctx` = {`app`: bundle ID or "", `profile`: id or "all", `source`: language code or "auto", `target`: language code}. Nothing else:
  no lens, no window title, no memory, no clock, no state kept between lines (a fresh global object per call).
- Two examples (the same ones go into `docs/settings-for-agents.md`):
  ```js
  function before(line, ctx) { return line.replace(/（[ぁ-ゖ]+）/gu, "") }         // drop furigana
  function after(src, dst, ctx) { return ctx.target === "ko" ? dst.replace(/\.\.\./g, "…") : dst }
  ```
- Strict check: over 8,000 characters; a syntax error (parsed in the service at check time, with line and column); neither function.

## 4. Order, per line
1. `before`, broad → narrow over the chain (All apps first); in each profile the table, then the script.
2. Names: replace and both rows are written into the cleaned source (names-and-context §10); hint rows are chosen by hits on it.
3. The engine (and Apple's answer check with its plain retry, unchanged).
4. `after`, narrow → broad (the head first, All apps last); in each profile the script, then the table.
- The cache namespace adds a fingerprint of the chain's rewrites and scripts (none → today's string, so today's cache stays valid).
- The log keeps the screen text as `original` and adds `sent` only when `before` changed it; `after` changes show as the translation.

## 5. Where it runs
- **Plain rows** run in the app (linear time, no service).
- **Regex rows and scripts** run in a new XPC service, `MwoyeoScript`, built on the reader's pattern:
  - a `project.yml` target like `ReaderService` (`project.yml:28-71`); no entitlements in the direct build, only
    `com.apple.security.app-sandbox` in the App Store build (as `Reader/Reader-MAS.entitlements`): no network, no files;
  - the app side copies `ReaderConnection`: the connection with its interruption and invalidation handlers
    (`App/Reader/ReaderConnection.swift:153-160`), SIGKILL to the pid it recorded (`:145-149`), exit when idle (`:135`).
- **Time limit.** `JSContextGroupSetExecutionTimeLimit` is private API, and 2.5.1 says "Apps may only use public APIs and must run on
  the currently shipping OS." So the app times each call itself: **50 ms per line** for a script, and for a profile's regex rows
  together. Over it, the app kills the service, writes `on: false` on that script or regex row (agents see it in the file) and shows
  "Turned off: took longer than 50 ms on a line." The next line starts a fresh service without it.
- **Why 50 ms.** A line is ≤ ~300 characters; a replace or a few regexes over it take well under 1 ms, so 50 ms is ≥ 50× headroom and
  still catches a loop or catastrophic backtracking (`(a+)+$`). A 3-line batch (`App/Pipeline/RegionPipeline.swift:1598`) adds at
  most 150 ms against "about 1 s a line" for Apple's slowest model (`App/Model/Settings.swift:31`).
- **Errors.** A throw or a non-string return leaves that line unchanged for that stage and shows the error with line and column; the
  script stays on. A reply longer than 4 × the input + 200 characters is an error (a guard against runaway output).
- **Default path.** No regex row and no script in the chain → nothing is loaded and the service never starts. It starts when a chain
  that needs it becomes active, and exits after 60 s idle.

## 6. App Store (quotes read 2026-10-21 from developer.apple.com/app-store/review/guidelines; 2.5.1 and 2.5.2 checked verbatim by the lead, 4.7 and 4.7.2 against a summary of the page only)
- 2.5.2: "Apps should be self-contained in their bundles, and may not read or write data outside the designated container area, nor
  may they download, install, or execute code which introduces or changes features or functionality of the app, including other
  apps." Our reading: the scripts are not downloaded or shipped by us; the person (or their agent) writes them in the app, they see
  four strings and return one, and they cannot reach a file, the network or an API.
- 4.7: "Apps may offer certain software that is not embedded in the binary, specifically HTML5 and JavaScript mini apps and mini
  games, streaming games, chatbots, and plug-ins." 4.7.2: "Your app may not extend or expose native platform APIs or technologies to
  the software without prior permission from Apple." `ctx` exposes no native API.
- Precedent, by kind only: a writing app on the Mac App Store whose user-made actions are JavaScript; an iOS app built to run
  user-written JavaScript. Our own audit keeps `command` engines out of the App Store build for 2.5.2
  (`docs/app-store/audit-2026-10-17.md:59`). If review objects, the App Store build hides Script (one `Distribution` row) and keeps
  the table.

## 7. UI (inside the profile sheet's Customize: level L2 of names-and-context §6.1, §6.3; numbers for R9)
- **Level.** Both sections are drawn only with Customize open, after Context; at L0-L1 nothing of them shows, and Customize's summary
  names them once set ("2 rewrites · script"). The sheet stays one scroll: no sheet, tab or popover of their own. Words: the stages are
  "Original" (before) and "Translation" (after); "regex" appears only in help, never as a label.
- **Rewrites**: caption under the header, "Change the text on this Mac, free: the original before it is translated, or the
  translation after." Empty: one borderless "Add Rewrite". A row, left to right: stage pop-up (96 pt: "Original", "Translation"), Find
  (flexible, layout priority 1, prompt "Find"), "→" (tertiary), Replace with (flexible, prompt "Replace with"), ".*" toggle (24 pt; help
  "Treat Find as a pattern (a JavaScript regular expression)"), minus (≥ 20 pt). New rows go last; ≤ 32, at 32 "Add Rewrite" is dimmed
  with the caption "That is the most: 32." Under its row, in red: a pattern that does not compile ("Pattern error at column n: …"); a row
  turned off by the time limit shows dimmed with "Turned off: took longer than 50 ms on a line." and "Turn On".
- With a Translation row, an orange caption under the table: "Changing the translation can leave a wrong particle (은/는, 이/가) after a
  replaced word. Prefer “Swap into the text” on the name’s row."
- **Script**: one collapsed row "Script · Off / On / Error" (a disclosure; one click). Open: a monospaced editor (min 120 pt, max 240
  pt, then it scrolls) whose empty state shows §3's two examples in tertiary as a starting point; counter "n / 8,000" (orange at the
  cap); "Run this script" switch (off until turned on); a sample field filled with the opening lens's last line (else any lens of this
  profile; empty: prompt "A line to test"); "Test" → "Before → …" and "After → …" (callout, monospaced, selectable; on the sample and
  its last shown translation, else on the sample; nothing is sent). Errors in red with line and column; the same errors go to the log
  (category `script`). Every new help tag starts with a verb and stays ≤ 75 characters.
- Empty and zero setup: a profile without rewrites shows, inside Customize, only "Add Rewrite" and the collapsed Script row (R9's gate);
  with Customize closed, neither. The App Store build hides Script if review objects (§6); the table stays.
- The power user's walkthrough and R9's capture items are in `profiles-ui-checklist.md` (§3 walkthrough 3; checklist items 7-9).

## 8. Agents (MCP; one compact text block, `docs/settings-for-agents.md:14`)
- `set_memory(profile | app, rewrites?, script?)` writes them with the same checks; the result carries `issues` with line and column.
- `test_rules {profile | app (+ title), lines: [≤ 20], translate?}` dry-runs the chain without the screen:
  `{"columns":["line","source","translation","shown"],"rows":[[0,"漢字（かんじ）","漢字","한자","한자"]],"errors":[{"stage":"after",
  "item":0,"line":3,"column":12,"message":"…"}]}`. Without `translate`: only `source` (no engine, nothing leaves this Mac); with it, the
  translation through `translate_text`'s path. `item` is the rewrite row index, or -1 for the script.
- `docs/settings-for-agents.md` (R10) documents the two signatures, `ctx`, the limits (32 rows, 200, 8,000, 50 ms, 4 × + 200) and the
  two examples of §3.

## 9. Gates (FAIL-first each; timeouts are parameters, no wall-clock waits)
- R8: no rewrite and no script → connection count 0 and the request bytes are main's; a `while(true){}` script is cut within
  50 ms × lines + 100 ms and turned off; `(a+)+$` on a long "aaaa…b" line is cut the same way; a throw leaves the line unchanged; the
  order of §4 on a two-profile chain; the cache namespace is today's with nothing set.
- R9: captures of the empty state and of a filled table with an After row; opus vision.
- R10: `test_rules` on a profile without rewrites returns each line unchanged and starts no service; a syntax error comes back with
  its line and column.
