#if !MAS
import AppKit
import Carbon.HIToolbox
import MwoyeoCore
import MwoyeoEngines
import SwiftUI

/// Window captures of the engine UI, for checking a look without clicking through the app:
///   Mwoyeo --capture-ui outdir scenario… [--mock http://host:port/v1] [--delay s] [--image picture] [--lang ko]
/// `vision-reads [--src ja] [--image picture] [--for seconds]` is a probe, not a capture: it starts the initialization of the text
/// models for the language and reads the picture in this process every half second until every step is done, printing each
/// read's latency and the steps as they change (what a lens sees during a cold compile; no window).
/// Scenarios: menu-init-running, menu-init-failed, menu-init-done (the panel during the initialization of the text
/// models, from a gate of its own, no real recognition), general-settings-file and general-settings-file-issue (Settings › General with
/// settings.json clean, then with problems in it; the file is a scratch one, `MWOYEO_SETTINGS_FILE` names it), translation-default, translation-packs, translation-packs-auto, translation-engines, general-saving, menu-default, menu-switcher, menu-notice,
/// menu-profile, image-window and image-window-original (the Translate Image window on `--image`, translated through the
/// mock, then with Show Original on; when the text recognizer reads nothing the picture stands in for its translation, which
/// still shows the toggle's two states), appearance (Settings › Appearance), lens-gallery (every lens style in every tint on a dark and
/// a light backdrop: one PNG each, lens-<style>-<tint>-<dark|light>.png, and a grid per backdrop), lens-tab-positions (the name tag
/// in its four places, one carrying a notice), lens-reading (the default glow while the lens reads), sheet-pick, sheet-preset-deepl-free (the DeepL Free row chosen, key field empty), sheet-config, sheet-config-remote (the box that allows sending to the host, unticked), sheet-config-remote-allowed (ticked), sheet-config-remote-context (ticked, with the context caption), sheet-context-collapsed-off, sheet-context-collapsed-on, sheet-context-chat, sheet-context-chat-off, sheet-context-local, sheet-context-deepl, sheet-context-template and sheet-context-memory (the sheet of an engine already added, its Context section collapsed or open, the last with Context off and a note written for an app; `--lang ko` for Korean), engine-context-checks (only that section's checks; `--dump` also writes the accessibility trees it read, a11y-engine-context-*.txt), profile-file-checks (only the settings.json profile checks), translation-engines-permission (the list with an engine that needs the person's permission), about-privacy (Settings › About), lens-badge, lens-notice, lens-menu, add-flow (adds an
/// engine through the sheet, prints where the key is), pack-checks (only the language pack flow's PASS/FAIL lines), lens-hint-disk (the pill
/// when the Mac has no room to prepare text recognition), lens-hint-pack-downloading,
/// lens-hint-pack-notfinished and lens-hint-unsupported (the pill in the states a pack or a pair can be in), menu-pack-rows (the panel's lens
/// rows with each of those lines), menu-pack-banner-ask|downloading|notfinished|unsupported (the panel's banner when no lens says it),
/// translation-packs-states (Settings › Translation with a row in each state), image-window-pack-ask|downloading|notfinished|unsupported
/// (the Translate Image window's status line), text-window-empty|translated|added-engine|pack (the Translate Text window, each in light and dark), text-checks (only the Translate Text checks), lens-menu-memory (the lens menu of an app with a memory: its info line, Memory for <App>…, Remember Languages and Forget <App>…), memory-forget-alert (the alert that Forget <App>… asks), memory-sheet-lens (Settings with no profile at all, a lens's "Memory for <App>…" set: the Memory sheet comes up empty; PASS/FAIL), names-lens-checks (only the lens menu's memory block and the first edit of a memory; PASS/FAIL lines), lens-route-checks (only the lens's own route: its app's languages and engine, its own cache and pace; PASS/FAIL lines), memory-profile-row, memory-menu, memory-sheet-empty, memory-sheet-filled, memory-sheet-tall (the filled sheet at 820 pt, every section in view), memory-sheet-fresh (the app profile's row with its memory, its ⋯ menu, and the Memory sheet empty, filled with learned rows, and asking whether to start fresh), check-logic (prints PASS/FAIL for the engine selection and the
/// engine notice's dismissal; no window). Run it with `MWOYEO_MEMORY_SECRETS=1` so it does not touch the Keychain. It keeps its
/// Profile and Restore Defaults screens (round ui-all; the names are the ones of docs/design/profiles-ui-checklist.md §3): settings-translation, settings-general,
/// settings-appearance and settings-shortcuts at defaults (no Restore Defaults… button), their -changed twins (one preference changed: the button at the foot),
/// restore-sheet and restore-sheet-done (the sheet of General's restore, asking, then after Restore), settings-profiles (eight profiles, one with a name of 40
/// characters), sheet-l1, sheet-l2, sheet-new-window and sheet-row-details (the profile sheet), lens-menu-l0, lens-menu-l1 and lens-menu-l1-sub (the lens menu
/// with no profile, with profiles, and its Profile submenu), menu-l1 and menu-l1-pinned (the panel's profile caption), engine-cloud-context (a cloud
/// engine's sheet, Context opened), sheet-row-details-use (a name's details with the Use pop-up open), sheet-rewrites (the sheet scrolled to the rules table:
/// an After row and its particle caption, the Script row collapsed), sheet-script (scrolled to the Script editor open on a script with a syntax error: its line)
/// and sheet-script-test (the Script editor with a script, a sample line and the Test run through the real service), and profile-ui-checks, rewrite-ui-checks and
/// restore-checks (only their PASS/FAIL lines).
/// preferences in a scratch suite of its own (deleted at exit; `MWOYEO_DEFAULTS_SUITE` names one to keep), never the app's real
/// ones; `CFFIXED_USER_HOME` does not move those. `--mock` is a tools/mock-openai server the sample translations go to.
enum UICapture {
    /// Checks that failed in this run, over every kind: the process exits 1 when any did, so a runner can trust its exit code (it was 0
    /// with "check-logic: 1 FAILED" printed, 2026-10-20).
    @MainActor private static var failures = 0

    /// The one summary line of a kind of checks ("check-logic: all passed" / "… 2 FAILED"), counted toward the exit code.
    @MainActor private static func report(_ kind: String, _ failed: Int) {
        failures += failed
        print("\(kind): \(failed == 0 ? "all passed" : "\(failed) FAILED")")
    }

    static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        // `--lang ko`: the sheet and the lines in that language, as the launch argument `-AppleLanguages (ko)` would give (it cannot come
        // first here, and the entry point wants `--capture-ui` first). The argument domain is in memory only, so no preference is written.
        if let i = args.firstIndex(of: "--lang"), i + 1 < args.count {
            UserDefaults.standard.setVolatileDomain(["AppleLanguages": [args[i + 1]], "AppleLocale": args[i + 1]], forName: UserDefaults.argumentDomain)
        }
        // Scratch preferences (AppModel reads the suite when it is first used): a capture never writes the app's real ones.
        // CFFIXED_USER_HOME does not move them. A suite named in the environment is kept.
        let suite = "dev.midagedev.mwoyeo.capture-\(getpid())"
        let ownSuite = ProcessInfo.processInfo.environment["MWOYEO_DEFAULTS_SUITE"] == nil
        if ownSuite { setenv("MWOYEO_DEFAULTS_SUITE", suite, 1) }
        // Likewise the settings file: the real one in Application Support is never read or written by a capture.
        let scratchDir = NSTemporaryDirectory() + "mwoyeo-capture-\(getpid())"
        let ownFile = ProcessInfo.processInfo.environment["MWOYEO_SETTINGS_FILE"] == nil
        if ownFile { setenv("MWOYEO_SETTINGS_FILE", scratchDir + "/settings.json", 1) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await Runner(args: args).go()
            if ownFile { try? FileManager.default.removeItem(atPath: scratchDir) }
            if ownSuite {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                // The preferences daemon leaves the emptied file behind, in the real home.
                try? FileManager.default.removeItem(atPath: NSHomeDirectoryForUser(NSUserName())! + "/Library/Preferences/\(suite).plist")
            }
            exit(failures == 0 ? 0 : 1)
        }
        app.run()
        exit(0)
    }

    @MainActor private struct Runner {
        let args: [String]
        var out: URL { URL(fileURLWithPath: args[0]) }
        var scenarios: [String] {
            var names: [String] = [], skip = false
            for a in args.dropFirst() {
                if skip { skip = false; continue }
                if a == "--mock" || a == "--delay" || a == "--key" || a == "--image" || a == "--engine-name" || a == "--lang" { skip = true; continue }
                if a == "--keep-key" || a == "--dump" { continue }
                names.append(a)
            }
            return names
        }
        func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        var mock: String { option("--mock") ?? "http://localhost:8765/v1" }
        var delay: Double { Double(option("--delay") ?? "1.2") ?? 1.2 }
        var model: AppModel { AppModel.shared }

        func go() async {
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            for name in scenarios { await scenario(name) }
        }

        // MARK: state

        private func engine(_ name: String, _ base: String, _ model: String) -> EngineConfig {
            EngineConfig(name: name, kind: .openAICompatible(baseURL: URL(string: base)!, model: model, thinking: .off, extraHeaders: [:]))
        }

        /// A cloud engine and a local one (the local one points at the mock and has run a few batches).
        private func seedEngines() async {
            let cloud = engine(option("--engine-name") ?? "Gemini", "https://generativelanguage.googleapis.com/v1beta/openai/", "gemini-3.1-flash-lite")
            let local = engine("Ollama", mock, "qwen3:8b")
            model.settings.sourceLanguage = "ja"
            model.settings.targetLanguage = "ko"
            model.settings.engines = [cloud, local]
            model.settings.customEngineID = local.id
            // Allowed, so the captures that are not about the permission read as they did; `translation-engines-permission` takes it back.
            model.settings.enginePermissions.set(true, for: cloud)
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<6 { _ = await model.translator.engineProbe(local) }
            for text in ["こんにちは", "ありがとう", "おはよう"] {
                _ = await model.translator.translate([text])
                _ = await model.translator.translate([text])
            }
        }

        // MARK: scenarios

        private func scenario(_ name: String) async {
            switch name {
            case "translation-default": await shoot(name, TranslationSettings(), CGSize(width: 560, height: 760))
            case "translation-packs", "translation-packs-auto":
                // The language packs section: the chosen pair alone (ja → ko), or the installed pairs while the source is automatic.
                model.settings.sourceLanguage = name == "translation-packs" ? "ja" : "auto"
                model.settings.targetLanguage = "ko"
                await shoot(name, TranslationSettings(), CGSize(width: 560, height: 1300))
            case "translation-profiles":
                model.settings.appProfiles = [AppProfile(bundleID: "com.apple.Safari", appName: "Safari", source: "ja", target: "en"),
                                              AppProfile(bundleID: "com.example.vn", appName: "Visual Novel", source: "ja", target: "en", paragraphReader: .lineGrouping)]
                await shoot(name, TranslationSettings(), CGSize(width: 560, height: 1300))
                model.settings.appProfiles = []
            case "general-settings-file": await settingsFileShot(name, withIssues: false)
            case "general-settings-file-issue": await settingsFileShot(name, withIssues: true)
            case "general-saving": await shoot(name, GeneralSettings(), CGSize(width: 560, height: 800))
            case "general-agent", "general-agent-on":
                // The Connect an agent row: the switch alone, then with the command and its Copy button.
                model.settings.agentConnection = name == "general-agent-on"
                await shoot(name, GeneralSettings(), CGSize(width: 560, height: 1100))
                model.settings.agentConnection = false
            case "menu-default": await shoot(name, MenuPanel(), CGSize(width: 340, height: 330))
            case "translation-engines":
                await seedEngines()
                await shoot(name, TranslationSettings(), CGSize(width: 560, height: 820))
            case "translation-engines-permission":
                // The list with one engine that waits for the person (Gemini) and one online engine already allowed.
                await seedEngines()
                let allowed = engine("OpenAI", "https://api.openai.com/v1", "gpt-5.5-mini")
                model.settings.enginePermissions.forget(model.settings.engines[0].id)
                model.settings.engines.insert(allowed, at: 1)
                model.settings.enginePermissions.set(true, for: allowed)
                await shoot(name, TranslationSettings(), CGSize(width: 560, height: 820))
            case "about-privacy":
                model.settingsTab = .about
                await shoot(name, SettingsView(), CGSize(width: 560, height: 760))
                model.settingsTab = .general
            case "settings-shortcuts":
                model.settingsTab = .shortcuts
                await shoot(name, SettingsView(), CGSize(width: 560, height: 760))
                model.settingsTab = .general
            case "engine-row-click": await engineRowClick()
            case "menu-switcher":
                await seedEngines()
                await shoot(name, MenuPanel(), CGSize(width: 340, height: 330))
            case "menu-notice":
                await seedEngines()
                model.selectEngine(model.settings.engines.first { $0.name == "Gemini" }?.id)
                model.received(.engineUnavailable(name: "Gemini", reason: "The engine did not accept the key."))
                await shoot(name, MenuPanel(), CGSize(width: 340, height: 400))
            case "menu-profile":
                model.settings.appProfiles = [AppProfile(bundleID: "com.apple.Safari", appName: "Safari", source: "ja", target: "en")]
                model.frontmostBundleID = "com.apple.Safari"
                await shoot(name, MenuPanel(), CGSize(width: 340, height: 330))
                model.frontmostBundleID = nil
                model.settings.appProfiles = []
            case "menu-init-running", "menu-init-failed", "menu-init-done":
                MenuPanel.fakeSetup = Self.fakeGate(String(name.dropFirst(10)))
                await shoot(name, MenuPanel(), CGSize(width: 340, height: 460))
                MenuPanel.fakeSetup = nil
            case "vision-reads": await visionReads()
            case "image-window": await imageWindow(name, showOriginal: false)
            case "text-window-empty", "text-window-translated", "text-window-added-engine", "text-window-pack": await textWindow(name)
            case "image-window-original": await imageWindow(name, showOriginal: true)
            case "check-logic": await checkLogic()
            case "pack-checks":
                let failed = await PackChecks.run(model)
                report("pack", failed)
            case "menu-pack-rows": await menuPackRows(name)
            case "menu-pack-banner-ask", "menu-pack-banner-downloading", "menu-pack-banner-notfinished", "menu-pack-banner-unsupported":
                await menuPackBanner(name)
            case "translation-packs-states": await packRowStates(name)
            case "image-window-pack-ask", "image-window-pack-downloading", "image-window-pack-notfinished", "image-window-pack-unsupported":
                await imageWindowPackStates(name)
            case "a11y-tree": await AccessibilityChecks.dump(model, into: out)
            case "onboarding": await shoot(name, OnboardingView(close: {}), CGSize(width: 600, height: 760))
            case "engine-permission-checks":
                // Only the permission checks (the whole of check-logic takes minutes). The first line is what the launch step made of settings.json.
                let record = model.settings.enginePermissions
                print("engine permission: at launch \(model.settings.engines.count) engine(s) in settings, \(record.hosts.count) allowed, upgrade step ran: \(record.migrated)")
                let failed = await EnginePermissionChecks.run(model)
                report("engine permission", failed)
            case "accessibility-checks":
                // Only the accessibility checks (the whole of check-logic takes minutes).
                let failed = await AccessibilityChecks.run(model)
                report("accessibility", failed)
            case "press-checks":
                // Only the press checks (the whole of check-logic takes minutes).
                let failed = await PressChecks.run(model)
                report("press", failed)
            case "drift-checks":
                // Only the drift meter's checks (the whole of check-logic takes minutes).
                let failed = DriftChecks.run()
                report("drift", failed)
            case "mcp-checks":
                // Only the MCP server's checks (the whole of check-logic takes minutes).
                let failed = MCPChecks.run(model)
                report("mcp", failed)
            case "program-checks":
                // Only the check of the Lines programs (the whole of check-logic takes minutes).
                let failed = await ProgramChecks.run()
                report("programs", failed)
            case "text-checks":
                // Only the Translate Text checks (the whole of check-logic takes minutes).
                let failed = await TextChecks.run(model)
                report("text", failed)
            case "lens-fit-shots":
                // The lens fit as the app draws it, light and dark, for the vision verdict (FIT_PAGE names the page picture).
                report("lens-fit-shots", await FitShots.run(model, into: out))
            case "lens-fit-click":
                // A double-click on a live lens's ring, with real mouse events (needs the accessibility grant; takes the pointer for a moment).
                report("lens-fit-click", await FitShots.click(model))
            case "fit-checks":
                // Only the lens fit's checks: Fit to Column, snap, Auto Fit, the probe (the whole of check-logic takes minutes).
                let failed = await FitChecks.run(model)
                report("fit", failed)
            case "game-shots":
                // A lens over a game scene with its HUD ignored (outlined and at rest) and with its recent lines, light and dark. Hold /tmp/r117/screen.lock.
                await GameShots.run(model: model, out: out, wait: delay)
            case "band-probe":
                // A moving scene beside a game's text box: how long a changed line takes to be read (`MWOYEO_READ_SCOPE=off` for the lens as it was).
                await BandProbe.run()
                report("band-probe", 0)
            case "game-checks":
                // Only the checks of games and video (the whole of check-logic takes minutes).
                let failed = await GameChecks.run(model)
                report("game", failed)
            case "hide-lens-checks":
                // Only the Hide Lenses checks (the whole of check-logic takes minutes).
                let failed = await HideLensChecks.run(model)
                report("hide-lens", failed)
            case "trust-checks":
                // Only the trust1 checks: the secret store of scratch runs, who translated a line, a line that reaches a busy engine.
                var t = ContextChecks.Tally()
                await ContextChecks.trustChecks(t)
                report("trust", t.failures)
            case "names-lens-checks":
                // Only the lens menu's memory block and how an app's memory begins (the whole of check-logic takes minutes).
                let failed = await NamesLensChecks.run(model)
                report("names lens", failed)
            case "lens-route-checks":
                // Only the lens's own route: its app's languages and engine, its own cache and pace (the whole of check-logic takes minutes).
                // Beside them, the default path: Off sends the bytes main sent, end to end through the service (round R2's gate).
                var t = ContextChecks.Tally()
                await ContextChecks.offChecks(t)
                await ContextChecks.routeChecks(t)
                let failed = await LensRouteChecks.run(model) + t.failures
                report("lens route", failed)
            case "profile-ui-checks":
                // Only the profile screens' checks (the whole of check-logic takes minutes).
                report("profile ui", await ProfileUIChecks.run(model))
            case "rewrite-ui-checks":
                // Only the rewrite editor's checks (the whole of check-logic takes minutes).
                report("rewrite ui", await RewriteUIChecks.run(model))
            case "restore-checks":
                // Only Restore Defaults' checks (the whole of check-logic takes minutes).
                report("restore defaults", await RestoreChecks.run(model))
            case "rewrite-checks":
                // Only the rewrite engine's and the script service's checks (the whole of check-logic takes minutes).
                let failed = await RewriteChecks.run()
                report("rewrite", failed)
            case "inpaint-footprint": await LensRobustChecks.inpaintFootprint()
            case "menu-icon": LensRobustChecks.menuIcon(into: out.appendingPathComponent("menu-icon.png"))
            case "sheet-pick": await shoot(name, EngineSheet(), CGSize(width: 480, height: 560))
            case "sheet-preset-deepl-free":
                // The picker's DeepL Free row chosen: step 2 with the Free host filled in and the key field empty (no key is typed, so nothing is sent).
                await shoot(name, EngineSheet(autopilot: .init(preset: "DeepL Free")), CGSize(width: 480, height: 560), wait: 2)
            case "sheet-config":
                let setup = EngineShare.encode(engine("Gemini", mock, "mock-model"))
                await shoot(name, EngineSheet(autopilot: .init(setup: setup, key: "sk-test-capture")), CGSize(width: 480, height: 560), wait: 5)
            case "sheet-config-remote", "sheet-config-remote-allowed", "sheet-config-remote-context":
                // A cloud engine: the box that allows sending to its host, unticked, then ticked; the last one also with an app whose
                // override puts context on, so the caption adds "Recent lines are sent too".
                let setup = EngineShare.encode(engine("Gemini", "https://gemini.example.invalid/v1beta/openai/", "gemini-3.1-flash-lite"))
                let withContext = name.hasSuffix("context")
                if withContext {
                    model.settings.appProfiles = [AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja", target: "en",
                                                             context: AppContextOverride(mode: .nearby))]
                }
                await shoot(name, EngineSheet(autopilot: .init(setup: setup, key: "sk-test-capture", allow: name != "sheet-config-remote")),
                            CGSize(width: 480, height: 560), wait: 5)
                if withContext { model.settings.appProfiles = [] }
            case "sheet-context-collapsed-off", "sheet-context-collapsed-on", "sheet-context-chat", "sheet-context-chat-off", "sheet-context-local",
                 "sheet-context-deepl", "sheet-context-template", "sheet-context-memory":
                await contextSheet(name)
            case "profile-file-checks":
                // Only the profile-file checks (the whole of check-logic takes minutes).
                let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-profile-file-\(getpid())")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: dir) }
                report("profile file", ProfileFileChecks.run(dir: dir))
            case "engine-context-checks":
                // Only the Context section's checks (the whole of check-logic takes minutes).
                let failed = await EngineContextChecks.run(model, dump: args.contains("--dump") ? out : nil)
                report("engine context", failed)
            case "appearance": await shoot(name, AppearanceSettings(), CGSize(width: 560, height: SettingsTab.appearance.height))   // the pane as the window shows it
            case "lens-gallery": await lensGallery()
            case "lens-tab-positions": await lensTabPositions()
            case "lens-reading":
                await lensShot("lens-reading", dark: false, busy: true)
                await lensShot("lens-reading-dark", dark: true, busy: true)
            case "lens-badge": await lens(name, badge: "cloud", notice: nil)
            case "lens-notice": await lens(name, badge: "cloud", notice: "Gemini unavailable · using Apple")
            case "lens-menu": await lens(name, badge: nil, notice: nil, menu: true)
            case "lens-menu-memory", "memory-forget-alert", "memory-sheet-lens": await lensMemory(name)
            case "lens-hint-allow", "lens-hint-restart", "lens-hint-pack", "lens-hint-preparing", "lens-hint-disk", "lens-hint-already", "lens-hint-notice",
                 "lens-hint-narrow", "lens-hint-pack-downloading", "lens-hint-pack-notfinished", "lens-hint-unsupported":
                await lensHints(name)
            case "image-window-pack", "image-window-blocked": await imageWindowBlocked(name)
            case "add-flow": await addFlow()
            case "memory-profile-row", "memory-menu", "memory-sheet-empty", "memory-sheet-filled", "memory-sheet-tall", "memory-sheet-fresh": await memoryScene(name)
            case "settings-translation", "settings-translation-changed", "settings-general", "settings-general-changed", "settings-appearance",
                 "settings-appearance-changed", "settings-shortcuts-changed", "restore-sheet", "restore-sheet-done", "settings-profiles", "sheet-l1", "sheet-l2",
                 "sheet-new-window", "sheet-row-details", "sheet-row-details-use", "sheet-rewrites", "sheet-script", "sheet-script-test", "lens-menu-l0", "lens-menu-l1", "lens-menu-l1-sub", "menu-l1", "menu-l1-pinned",
                 "engine-cloud-context":
                await profileScene(name)
            default: print("unknown scenario \(name)")
            }
        }

        /// The engine sheet open on an engine that is already added, with its Context section collapsed or open. The engine is a cloud chat
        /// engine unless the scene says otherwise (`-local` on this Mac, `-deepl`, `-template`); the key is in the scratch store, so the key
        /// row reads as it does for an engine in use. Run it with `-AppleLanguages "(ko)"` for the Korean sheet.
        private func contextSheet(_ name: String) async {
            let chat = engine("Gemini", "https://gemini.example.invalid/v1beta/openai/", "gemini-3.1-flash-lite")
            var e = chat
            if name.hasSuffix("-local") { e = engine("Ollama", mock, "qwen3:8b") }
            if name.hasSuffix("-deepl") { e = EngineConfig(name: "DeepL", kind: .deepL(baseURL: URL(string: "https://api-free.deepl.invalid/")!, formality: nil)) }
            if name.hasSuffix("-template") {
                e = EngineConfig(name: "My service", kind: .httpTemplate(HTTPTemplate(url: "https://service.example.invalid/translate", resultPath: "translatedText")))
            }
            switch name {
            case "sheet-context-collapsed-off", "sheet-context-chat-off": break
            case "sheet-context-memory":
                // Context off, and a note written for Mail: what the sheet says it sends (the context service's memory-only mode).
                model.settings.appProfiles = [AppProfile(bundleID: "com.apple.mail", appName: "Mail", source: "ja", target: "ko", note: "Formal register.")]
            case "sheet-context-collapsed-on": model.settings.context = AppContextOverride(mode: .conversation, previousLines: 3)
            case "sheet-context-deepl":
                model.settings.context = AppContextOverride(mode: .conversation, previousLines: 3)
                e.allow.deepLInstructions = true
            default:
                // The amount is All apps' (`context`, `useLearned`); what may leave is the engine's (`allow`). The title stays off in the "-chat" ones.
                model.settings.context = AppContextOverride(mode: .conversation, previousLines: 3)
                model.settings.useLearned = true
                e.allow.title = !(name.hasSuffix("-chat") || name == "engine-cloud-context")
            }
            let expanded = !name.contains("collapsed")
            model.settings.engines = [e]
            model.settings.customEngineID = e.id
            model.settings.enginePermissions.set(true, for: e)
            if !e.isOnThisMac { try? model.secrets.setSecret("sk-test-capture", for: e.id) }
            await shoot(name, EngineSheet(editing: e, autopilot: .init(expandContext: expanded)), CGSize(width: 480, height: 560), wait: 5)
            try? model.secrets.setSecret(nil, for: e.id)
            model.settings.appProfiles = []
            model.settings.engines = []
            model.settings.customEngineID = nil
            model.settings.context = nil
            model.settings.useLearned = false
        }

        /// A gate in the middle of the initialization, on a clock of its own: the text reader done in 34 s, then the paragraph reader
        /// running for 46 s (`running`), failed (`failed`), or done too with the last step finished a second ago (`done`).
        private static func fakeGate(_ state: String) -> (gate: SwiftVisionGate, now: TimeInterval) {
            let t: TimeInterval = 1000
            var g = SwiftVisionGate()
            g.want("auto")
            func step(_ s: SwiftVisionGate.Step, from: TimeInterval, to: TimeInterval?, failure: String? = nil) {
                g.started(SwiftVisionGate.Due(key: "auto", step: s), now: t - from)
                if let to { g.finished(failure: failure, now: t - to) }
            }
            step(.textModel, from: 90, to: 56)
            switch state {
            case "failed": step(.documentModel, from: 56, to: 10, failure: "the helper process ended with status 1")
            case "done": step(.documentModel, from: 56, to: 1)
            default: step(.documentModel, from: 56, to: nil)
            }
            return (g, t)
        }

        /// Reads during the initialization: the latency of each read in this process while the steps run (the Docs service compiles meanwhile).
        private func visionReads() async {
            let language = option("--src") ?? "ja"
            let limit = Double(option("--for") ?? "400") ?? 400
            let picture: CGImage? = option("--image").flatMap { NSImage(contentsOf: URL(fileURLWithPath: $0))?.cgImage(forProposedRect: nil, context: nil, hints: nil) } ?? TextRecognizer.probePicture
            guard let picture else { print("vision-reads: no picture"); return }
            let t0 = Trace.now
            func at() -> String { String(format: "%6.1f", Trace.now - t0) }
            Task.detached(priority: .utility) { await AppModel.loadVision(source: language) }
            var shown = ""
            var n = 0
            while Trace.now - t0 < limit {
                let gate = TextRecognizer.setupState
                let steps = SwiftVisionGate.Step.allCases.map { "\($0.rawValue)=\(gate.steps[$0].map(Self.describe) ?? "?")" }.joined(separator: " ")
                if steps != shown { shown = steps; print("[\(at())] steps: \(steps)") }
                if gate.running == nil, gate.allReady, !gate.steps.values.contains(.pending), n > 0 { break }
                let began = Trace.now
                n += 1
                do {
                    let blocks = try await TextRecognizer.blocks(in: picture, languages: [Locale.Language(identifier: language)])
                    print("[\(at())] read \(n): \(blocks.count) blocks in \(Int((Trace.now - began) * 1000)) ms")
                } catch {
                    print("[\(at())] read \(n): failed \(error) in \(Int((Trace.now - began) * 1000)) ms")
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            print("[\(at())] vision-reads: end, \(n) reads, \(TextRecognizer.setupState.steps.map { "\($0.key.rawValue)=\(Self.describe($0.value))" }.sorted().joined(separator: " "))")
        }

        private static func describe(_ s: SwiftVisionGate.StepState) -> String {
            switch s {
            case .pending: "pending"
            case .running: "running"
            case let .done(seconds): String(format: "done(%.1fs)", seconds)
            case let .failed(m): "failed(\(m))"
            }
        }

        private static var sample: ImageTranslationModel?

        /// The Translate Image window on `--image`, once the translation has settled (translated once per run, shown both ways).
        private func imageWindow(_ name: String, showOriginal: Bool) async {
            guard let path = option("--image") else { print("\(name): needs --image <picture>"); return }
            if Self.sample == nil {
                // Apple's translation needs the app's own host window, which a capture has not: the sample goes through the
                // mock (the local engine, ja → ko, as in the other scenarios).
                await seedEngines()
                // The text recognizers take tens of seconds to load; the app does it at launch, so does this.
                let loading = Date()
                await AppModel.loadVision()
                print("\(name): recognizers loaded in \(String(format: "%.1f", Date().timeIntervalSince(loading))) s")
                let picture = ImageTranslationModel()
                let started = Date()
                picture.open(url: URL(fileURLWithPath: path))
                for _ in 0..<2000 where picture.phase == .working || picture.phase == .empty { try? await Task.sleep(for: .milliseconds(100)) }
                print("\(name): \(picture.phase), \(picture.texts.count) lines in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
                if picture.texts.isEmpty, let still = NSImage(contentsOf: URL(fileURLWithPath: path)) {
                    // The text recognizer returned nothing (a busy Neural Engine): the toggle states are still worth a look.
                    print("\(name): nothing was read, showing the picture as its own translation")
                    picture.showSettled(still, lines: 0)
                }
                Self.sample = picture
            }
            guard let picture = Self.sample else { return }
            picture.showOriginal = showOriginal
            await shoot(name, ImageTranslationView(model: picture, onDrop: { _ in false }), CGSize(width: 1040, height: 760))
        }

        /// General settings after a person or an agent saved settings.json: untouched, or with an unknown key and a wrong value.
        private func settingsFileShot(_ name: String, withIssues: Bool) async {
            let url = model.settingsFile.url
            var text = String(decoding: SettingsFileFormat.render(model.settings), as: UTF8.self)
            if withIssues {
                text = text.replacingOccurrences(of: "\"lensStyle\"", with: "\"lenStyle\"")
                    .replacingOccurrences(of: "\"cacheSize\": \(model.settings.cacheSize)", with: "\"cacheSize\": \"big\"")
            }
            try? Data(text.utf8).write(to: url, options: .atomic)
            model.settingsFileChanged()
            await shoot(name, GeneralSettings(), CGSize(width: 560, height: 800))
        }

        /// The engine group's selection and the engine notice's dismissal, without a window.
        private func checkLogic() async {
            var failed = 0
            func check(_ what: String, _ ok: Bool) {
                print("check-logic: \(ok ? "PASS" : "FAIL") \(what)")
                if !ok { failed += 1 }
            }
            let cloud = engine("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai/", "gemini-3.1-flash-lite")
            let local = engine("Ollama", mock, "qwen3:8b")
            model.settings.engines = [cloud, local]
            model.selectEngine(nil)
            check("no added engine in use reads as the Apple choice", EngineSelection(model.settings) == .builtIn(model.settings.engine))
            model.select(.added(local.id))
            check("picking an added engine selects it", model.settings.customEngineID == local.id && EngineSelection(model.settings) == .added(local.id))
            model.select(.builtIn(.customModel))
            check("picking an Apple choice leaves the added engine", model.settings.customEngineID == nil && model.settings.engine == .customModel
                  && EngineSelection(model.settings) == .builtIn(.customModel))
            model.settings.engines = []
            model.settings.engine = .auto

            let a = TranslationIssue.engineUnavailable(name: "Gemini", reason: "The engine did not accept the key.")
            let b = TranslationIssue.engineUnavailable(name: "Ollama", reason: "It did not answer in time.")
            model.received(nil)
            model.received(a)
            check("an engine issue shows", model.shownIssue == a)
            model.dismissIssue()
            check("dismissed: hidden, still the current issue", model.shownIssue == nil && model.issue == a)
            model.received(a)
            check("dismiss, then the same issue again: hidden", model.shownIssue == nil)
            check("the same issue does not tell the lenses again", !AppModel.step(old: a, new: a, dismissed: a).tellLenses
                  && !AppModel.step(old: nil, new: a, dismissed: a).tellLenses)
            model.received(b)
            check("a different issue shows", model.shownIssue == b)
            check("a different issue tells the lenses once", AppModel.step(old: a, new: b, dismissed: a).tellLenses
                  && !AppModel.step(old: b, new: b, dismissed: nil).tellLenses)
            model.dismissIssue()
            model.received(nil)
            check("recovery clears the dismissed record", model.dismissedIssue == nil && model.shownIssue == nil)
            model.received(b)
            check("recovery, then the same issue: shown again", model.shownIssue == b)
            check("and it tells the lenses again", AppModel.step(old: nil, new: b, dismissed: nil).tellLenses)
            model.received(.timedOut)
            model.dismissIssue()
            check("only an engine notice can be dismissed", model.shownIssue == .timedOut)
            model.received(nil)

            model.recognitionNotice(.textRecognitionStarting(language: "ja"))
            check("the recognizer's notice shows", model.shownIssue == .textRecognitionStarting(language: "ja"))
            check("it never tells the lenses", !AppModel.step(old: nil, new: .textRecognitionStalled, dismissed: nil).tellLenses)
            model.recognitionNotice(.textRecognitionStalled)
            model.received(nil)
            check("a translation that went well does not end it", model.shownIssue == .textRecognitionStalled)
            model.dismissIssue()
            check("and it cannot be dismissed", model.shownIssue == .textRecognitionStalled)
            model.recognitionNotice(nil)
            check("only the recognizer ends it", model.shownIssue == nil)
            model.received(a)
            model.recognitionNotice(nil)
            check("its end leaves another issue alone", model.shownIssue == a)
            model.received(nil)

            // The lens window around a region, for each place of the name tag.
            let region = NSRect(x: 200, y: 300, width: 360, height: 200), moved = NSRect(x: 80, y: 120, width: 250, height: 90)
            let lens = RegionFrameWindow(region: region, name: "Safari")
            var places = region
            for position in LensTabPosition.allCases {
                lens.setAppearance(style: .glow, tint: .spectrum, tabVisibility: .automatic, tabPosition: position)
                let kept = lens.regionFrame == region && lens.frame == RegionFrameWindow.windowFrame(for: region, position: position)
                lens.setRegion(moved)
                let after = lens.regionFrame == moved
                lens.setRegion(region)
                places = lens.regionFrame
                check("lens window round-trips the region for \(position.rawValue)", kept && after && places == region)
            }

            // Settings saved before the lens looks existed, and a tint this build does not know.
            var saved = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings()))) as? [String: Any] ?? [:]
            for key in ["lensTint", "lensTabVisibility", "lensTabPosition"] { saved[key] = nil }
            let old = (try? JSONSerialization.data(withJSONObject: saved)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
            check("settings without the new keys decode to the defaults", old == AppSettings())
            saved["lensTint"] = "neon"
            saved["lensStyle"] = "corners"
            let unknown = (try? JSONSerialization.data(withJSONObject: saved)).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
            check("unknown tint decodes to spectrum", unknown?.lensTint == .spectrum && unknown?.lensStyle == .corners)
            check("the corners style sits between subtle and minimal", LensStyle.allCases == [.glow, .subtle, .corners, .minimal])
            failed += await firstRunChecks()
            failed += SettingsFileChecks.run(model)
            failed += SandboxDataChecks.run()
            failed += CodeKeepChecks.run()
            failed += await LensRobustChecks.run(model)
            failed += await ContextChecks.run()
            failed += await AppleGlossaryChecks.run()
            failed += DriftChecks.run()
            failed += await EnginePermissionChecks.run(model)
            failed += await EngineContextChecks.run(model)
            failed += await MemorySheetChecks.run(model)
            failed += await ProfileUIChecks.run(model)
            failed += await RewriteUIChecks.run(model)
            failed += await RestoreChecks.run(model)
            failed += await NamesLensChecks.run(model)
            failed += await LensRouteChecks.run(model)
            failed += await AccessibilityChecks.run(model)
            failed += await PressChecks.run(model)
            failed += await PackChecks.run(model)
            // The script service's timing checks first: one service serves every connection, and MCP's `test_rules` leaves it running (integration
            // 2026-10-21: after MCPChecks, "while(true) is cut within 250 ms" took 4.7 s; alone it passes).
            failed += await RewriteChecks.run()
            failed += MCPChecks.run(model)
            failed += await HideLensChecks.run(model)
            failed += await FitChecks.run(model)
            failed += await GameChecks.run(model)
            failed += await ProgramChecks.run()
            // Last: the checks before the script service's timing ones must not lengthen the gap between the Test button's use of the service (PressChecks) and
            // RewriteChecks, which counts on launchd's respawn throttle still holding (text117, 2026-10-22: with these before them, "a lens call is not queued behind a call
            // that is waiting out the restart" found the service restarted at once).
            failed += await TextChecks.run(model)
            report("check-logic", failed)
        }

        // MARK: synthetic clicks

        /// A new user is never left with a silent lens: what the session makes of the app's state (`LensHint`), the reads that say
        /// "already in <language>", a covered lens that reads nothing, a region of interest outside the picture. Returns the failures.
        private func firstRunChecks() async -> Int {
            var failures = 0
            func check(_ what: String, _ ok: Bool) {
                print("check-logic: \(ok ? "PASS" : "FAIL") \(what)")
                if !ok { failures += 1 }
            }
            func session(_ source: String, _ target: String) -> RegionSession {
                var config = RegionConfig(name: "Safari", rect: CGRect(x: 200, y: 300, width: 360, height: 200))
                config.follow(nil)
                var s = AppSettings()
                s.sourceLanguage = source
                s.targetLanguage = target
                return RegionSession(config: config, settings: s, translator: model.translator, inpainter: nil)
            }
            let ja = PackPair(source: "ja", target: "en")

            // The translator's missing pack reaches the lenses that translate that pair, and only them.
            model.received(.languagePackMissing(source: "ja", target: "en"))
            check("a missing pack is in the signals of a lens on Detect → English", session("auto", "en").hintSignals().missingPack == ja)
            check("and of a lens on Japanese → English", session("ja", "en").hintSignals().missingPack == ja)
            check("not of a lens that reads Korean", session("ko", "en").hintSignals().missingPack == nil)
            check("not of a lens that translates into Korean", session("auto", "ko").hintSignals().missingPack == nil)
            model.received(nil)
            check("a translation that went well takes it away", session("auto", "en").hintSignals().missingPack == nil)

            // The setup of the text recognizer (the menu panel's "Preparing text recognition…") is the same line on the lens.
            MenuPanel.fakeSetup = Self.fakeGate("running")
            check("the lens is told while the text recognizer sets up", session("auto", "en").hintSignals().recognitionPreparing)
            MenuPanel.fakeSetup = Self.fakeGate("done")
            check("and not once it is done", !session("auto", "en").hintSignals().recognitionPreparing)
            MenuPanel.fakeSetup = nil
            model.recognitionNotice(.textRecognitionStarting(language: "ja"))
            check("macOS preparing a recognizer for the language counts too", session("auto", "en").hintSignals().recognitionPreparing)
            model.recognitionNotice(nil)

            // "Already in <language>": two reads that agree, dropped by one block to translate.
            let lens = session("auto", "en")
            lens.read(ReadTally(inTarget: 3, needing: 0))
            check("one read of text in the target language says nothing yet", lens.hintSignals().alreadyInTarget == nil)
            lens.read(ReadTally(inTarget: 2, needing: 0))
            check("the second says it", lens.hintSignals().alreadyInTarget == "en")
            lens.read(ReadTally(inTarget: 2, needing: 1))
            check("a block to translate drops it", lens.hintSignals().alreadyInTarget == nil)

            // A covered lens reads nothing: its frames stop before the pipeline, once, and it says so in the counts.
            func frame(at time: TimeInterval) -> CapturedFrame? {
                let w = 8, h = 8, bytesPerRow = w * 4
                var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
                let image = pixels.withUnsafeMutableBytes { raw -> CGImage? in
                    CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)?.makeImage()
                }
                guard let image else { return nil }
                let gray = pixels.withUnsafeBytes { GrayImage(bgra: $0.baseAddress!, width: w, height: h, bytesPerRow: bytesPerRow, step: 2) }
                return CapturedFrame(image: image, gray: gray, grayStep: 2, scale: 1, rect: CGRect(x: 0, y: 0, width: 8, height: 8), time: time)
            }
            let covered = session("auto", "en")
            if let f = frame(at: 1) {
                _ = Trace.takeCounts()
                covered.frameSink?(f)
                check("an uncovered lens passes its frames on", Trace.takeCounts()["lens.dropped.occluded"] == nil)
                covered.setOccluded(true)
                covered.setOccluded(true)
                covered.frameSink?(f)
                covered.frameSink?(f)
                let counts = Trace.takeCounts()
                check("a covered lens drops its frames (lens.dropped.occluded)", counts["lens.dropped.occluded"] == 2)
                check("and counts the pause once (lens.paused.occluded)", counts["lens.paused.occluded"] == 1)
            } else {
                check("a test frame can be made", false)
            }

            // Vision's region of interest: outside the picture, or thinner than a pixel, no request is made.
            if let f = frame(at: 2) {
                _ = Trace.takeCounts()
                let outside = try? await TextRecognizer.lines(in: f.image, roi: CGRect(x: 4000, y: 4000, width: 40, height: 40), languages: [], fast: true)
                let thin = try? await TextRecognizer.lines(in: f.image, roi: CGRect(x: 0, y: 0, width: 0.3, height: 8), languages: [], fast: true)
                check("a region of interest outside the picture, or under a pixel wide, reads nothing and sends nothing to Vision",
                      outside?.isEmpty == true && thin?.isEmpty == true && Trace.takeCounts()["ocr.roi.empty"] == 2)
            }

            // What a block of text is to the lens.
            typealias V = TextRecognizer.Verdict
            check("a clock, a link and a formula stay as written",
                  ["12:45", "10:42 AM", "https://example.com/a", "O(n² · d)"].allSatisfy { TextRecognizer.verdict($0, target: "en") == V.literal })
            check("English text is already in English", TextRecognizer.verdict("The quick brown fox jumps over the lazy dog today.", target: "en") == V.inTarget)
            check("Japanese text needs translating into English", TextRecognizer.verdict("今日はとても良い天気ですね。散歩に行きましょう。", target: "en") == V.needs)
            check("Hangul is already Korean", TextRecognizer.verdict("오늘은 날씨가 정말 좋네요", target: "ko") == V.inTarget)
            check("a read counts the blocks worth a look only",
                  TextRecognizer.tally([V.literal, .inTarget, .needs, .inTarget]) == ReadTally(inTarget: 2, needing: 1))
            return failures
        }

        private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap { views($0) } }

        /// A left click on `window` at `point` (window coordinates), sent to the window alone (the real pointer stays put).
        private func click(_ window: NSWindow, at point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let e = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                window.sendEvent(e)
            }
        }

        /// Whether the ⋯ button on an added engine's row opens its menu without changing the selection, and a click on the row selects it.
        private func engineRowClick() async {
            var failed = 0
            func check(_ what: String, _ ok: Bool) {
                print("engine-row-click: \(ok ? "PASS" : "FAIL") \(what)")
                if !ok { failed += 1 }
            }
            await seedEngines()
            model.select(.builtIn(.auto))
            let apple = EngineSelection(model.settings)
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: 560, height: 820)), styleMask: [.titled], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: TranslationSettings().environment(model))
            w.contentView = host
            w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(delay))
            let all = views(host)
            if args.contains("--dump") {
                func walk(_ v: NSView, _ d: Int) {
                    print("  " + String(repeating: " ", count: d) + "\(type(of: v)) \(v.convert(v.bounds, to: nil)) title=\((v as? NSButton)?.title ?? "")")
                    v.subviews.forEach { walk($0, d + 1) }
                }
                walk(host, 0)
            }
            // The rows' ⋯ buttons are popup buttons, top to bottom in the order of the engines: Gemini, Ollama.
            let buttons = all.filter { String(describing: type(of: $0)).contains("PopupButton") }
                .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
            let more = buttons.count == 2 ? buttons[1] : nil
            check("the ⋯ buttons are found, one per added engine", buttons.count == 2)
            let before = model.settings.customEngineID
            nonisolated(unsafe) var opened = false
            nonisolated(unsafe) var tracked: NSMenu?
            let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                opened = true
                tracked = n.object as? NSMenu
            }
            if let more {
                let r = more.convert(more.bounds, to: nil)
                // The mouse-down blocks in menu tracking; a timer in common modes ends it.
                let t = Timer(timeInterval: 0.6, repeats: false) { _ in tracked?.cancelTrackingWithoutAnimation() }
                RunLoop.main.add(t, forMode: .common)
                click(w, at: NSPoint(x: r.midX, y: r.midY))
                t.invalidate()
            }
            NotificationCenter.default.removeObserver(token)
            try? await Task.sleep(for: .milliseconds(300))
            check("⋯ opens its menu", opened)
            check("selection unchanged after ⋯", model.settings.customEngineID == before && EngineSelection(model.settings) == apple)
            // Control: the row's own radio.
            // The radio sits at the row's left edge, level with its ⋯ button.
            if let more {
                let r = more.convert(more.bounds, to: nil)
                click(w, at: NSPoint(x: 38, y: r.midY))
            }
            try? await Task.sleep(for: .milliseconds(300))
            check("clicking the row text selects it", model.settings.customEngineID == model.settings.engines.first { $0.name == "Ollama" }?.id)
            w.orderOut(nil)
            report("engine-row-click", failed)
        }

        // MARK: the profile screens (round ui-all, design names-and-context §6, §9)

        /// The profiles of the captures: an app's (Emulator), a game in it (the app and a title), a paper reader, a web profile and presets picked by hand;
        /// `many` adds the rest of eight, one with a name of 40 characters. The game uses an engine on this Mac (the mock).
        private func profileFixtures(many: Bool = false) -> [AppProfile] {
            let emu = "com.example.emu"
            let local = engine("Local Qwen", mock, "qwen3:8b")
            model.settings.engines = [local]
            let hakuBoth = MemoryEntry(src: "ハク", dst: "하쿠", kind: .person, gender: .m, apply: .both)
            var list = [
                AppProfile(bundleID: emu, appName: "Emulator", source: "ja", target: "ko", note: "A game console; every game has its own cast.", entries: [hakuBoth]),
                AppProfile(bundleID: "", appName: "月涙譚", source: "ja", target: "ko", note: "Fantasy; formal speech.",
                           entries: [hakuBoth, MemoryEntry(src: "九十九", dst: "츠쿠모", kind: .person), MemoryEntry(src: "魔王城", dst: "마왕성", kind: .place)],
                           context: AppContextOverride(mode: .conversation, previousLines: 3), id: "tsukinamida", name: "月涙譚",
                           when: [ProfileCondition(app: emu, titleContains: "月涙譚")], engine: .added(local.id), useLearned: true),
                AppProfile(bundleID: "", appName: "Papers", source: "en", target: "ko", note: "Academic register; keep formulas.", id: "papers", name: "Papers",
                           when: [ProfileCondition(app: "com.example.pdf"), ProfileCondition(titleContains: "Preprint")]),
                AppProfile(bundleID: "", appName: "Anime", source: "ja", target: "ko", id: "anime", name: "Anime", when: [], engine: .apple),
            ]
            if many {
                // The name of 40 characters is the fifth row: the list shows six, and the long name is seen without "Show All".
                list += [AppProfile(bundleID: "", appName: "A profile whose name is as long as the field allows", source: "ja", target: "en", id: "long", name: "A profile whose name is as long as the field allows", when: []),
                         AppProfile(bundleID: "", appName: "Work", source: "en", target: "ko", note: "Formal.", id: "work", name: "Work", when: []),
                         AppProfile(bundleID: "com.apple.Safari", appName: "Safari", source: "auto", target: "ko"),
                         AppProfile(bundleID: "com.apple.MobileSMS", appName: "Messages", source: "en", target: "ko",
                                    entries: [MemoryEntry(src: "Alice", dst: "앨리스", kind: .person)])]
            }
            return list
        }

        private func profileScene(_ name: String) async {
            let saved = model.settings, savedFront = model.frontmostBundleID
            defer { model.settings = saved; model.frontmostBundleID = savedFront }
            let emu = LensWatch.Read(bundleID: "com.example.emu", appName: "Emulator", title: "月涙譚 — 第二章")
            // The screens at defaults are the defaults: no profile, no engine, no changed preference.
            model.settings = AppSettings()
            switch name {
            case "settings-translation": await shoot(name, TranslationSettings(), CGSize(width: 560, height: 900))
            case "settings-general": await shoot(name, GeneralSettings(), CGSize(width: 560, height: 1000))
            case "settings-appearance": await shoot(name, AppearanceSettings(), CGSize(width: 560, height: SettingsTab.appearance.height))
            case "settings-translation-changed":
                model.settings.cacheSize = 20000
                await shoot(name, TranslationSettings(), CGSize(width: 560, height: 900))
            case "settings-general-changed":
                model.settings.targetLanguage = Languages.targets.first { $0 != AppSettings().targetLanguage } ?? "ja"
                await shoot(name, GeneralSettings(), CGSize(width: 560, height: 1000))
            case "settings-appearance-changed":
                model.settings.lensTint = .ocean
                // Taller than the window: the Restore Defaults… button at the foot is in the shot.
                await shoot(name, AppearanceSettings(), CGSize(width: 560, height: SettingsTab.appearance.height + 120))
            case "settings-shortcuts-changed":
                model.settings.shortcuts[HotKeyAction.pause.rawValue] = KeyCombo(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey, display: "⌃⌥P")
                model.settingsTab = .shortcuts
                await shoot(name, SettingsView(), CGSize(width: 560, height: 760))
                model.settingsTab = .general
            case "restore-sheet", "restore-sheet-done":
                // General with two preferences changed, and a consent that stays: the sheet's Changes and Kept rows.
                model.settings.targetLanguage = Languages.targets.first { $0 != AppSettings().targetLanguage } ?? "ja"
                model.settings.framesPerSecond = 15
                model.settings.renderMode = .fast
                model.settings.savesTranscripts = true
                let sheet = RestoreDefaultsSheet(tab: .general, model: model, restoring: name == "restore-sheet-done")
                await shoot(name, sheet, CGSize(width: 420, height: name == "restore-sheet-done" ? 160 : 300))
            case "settings-profiles":
                model.settings.appProfiles = profileFixtures(many: true)
                await shoot(name, TranslationSettings(), CGSize(width: 560, height: 1500))
            case "sheet-row-details-use":
                model.settings.appProfiles = profileFixtures()
                let titles = await menuShot(name, AppMemorySheet(target: MemoryTarget(id: "com.example.emu", name: "Emulator", kind: .profile), model: model, openDetails: [0], customize: false),
                                            CGSize(width: 520, height: 640)) { _, windowTitle in await axPopUp(inWindowTitled: windowTitle, named: String(localized: "Use")) }
                print("\(name): \(titles ?? [])")
                print("\(name): \(titles?.count == EntryApply.allCases.count ? "PASS" : "FAIL") the Use pop-up holds \(EntryApply.allCases.count) items")
            case "sheet-l1", "sheet-row-details":
                model.settings.appProfiles = profileFixtures()
                let sheet = AppMemorySheet(target: MemoryTarget(id: "com.example.emu", name: "Emulator", kind: .profile), model: model,
                                           openDetails: name == "sheet-row-details" ? [0] : [], customize: false)
                await shoot(name, sheet, CGSize(width: 520, height: 640))
            case "sheet-l2":
                model.settings.appProfiles = profileFixtures()
                await shoot(name, AppMemorySheet(target: MemoryTarget(id: "tsukinamida", name: "月涙譚", kind: .profile), model: model, height: 1100, customize: true),
                            CGSize(width: 520, height: 1100), wait: 2)
            case "sheet-rewrites", "sheet-script", "sheet-script-test":
                // 月涙譚 with a rules table (a plain row, a pattern row, a fixed phrase, an After row) and, for the script, an `after`: sound for the Test, with a
                // syntax error (its line) for sheet-script. The sheet is the size a window has, scrolled to the section as a person scrolls there.
                var list = profileFixtures()
                if let i = list.firstIndex(where: { $0.id == "tsukinamida" }) {
                    list[i].rewrites = [RewriteRow(.before, "（[ぁ-ゖ]+）", "", regex: true), RewriteRow(.before, "▼", ""), RewriteRow(.before, "セーブしますか？", "Save?"),
                                        RewriteRow(.after, "...", "…")]
                    switch name {
                    case "sheet-script-test":
                        list[i].script = RewriteScript(source: "function after(src, dst, ctx) {\n  return ctx.target === \"ko\" ? dst.replace(/\\.\\.\\./g, \"…\") : dst\n}\n", on: true)
                    case "sheet-script":
                        list[i].script = RewriteScript(source: "function after(src, dst, ctx) {\n  return ctx.target === \"ko\" ? dst.replace(/\\.\\.\\./g, \"…\" : dst\n}\n", on: true)
                    default: break
                    }
                }
                model.settings.appProfiles = list
                let target = MemoryTarget(id: "tsukinamida", name: "月涙譚", kind: .profile, lensSource: "勇者（ゆうしゃ）は剣を抜いた...", lensTranslation: "용사는 검을 뽑았다...")
                let scripted = name != "sheet-rewrites"
                await shoot(name, AppMemorySheet(target: target, model: model, height: 640, customize: true, scriptOpen: scripted, runsTest: name == "sheet-script-test",
                                                 scrollTo: scripted ? "script" : "rewrites"),
                            CGSize(width: 520, height: 640), wait: 5)
            case "sheet-new-window":
                model.settings.appProfiles = profileFixtures()
                let phrase = ContextText.truncated(emu.title, toCharacters: ProfileCondition.maxTitleLength)
                let profileName = ContextText.truncated(emu.title, toCharacters: AppProfile.maxNameLength)
                let draft = AppProfile(bundleID: "", appName: profileName, source: "ja", target: "ko", id: ProfileIDs.fresh(named: profileName, in: model.settings.appProfiles),
                                       name: profileName, when: [ProfileCondition(app: emu.bundleID, titleContains: phrase)])
                let target = MemoryTarget(id: draft.id, name: profileName, kind: .new, draft: draft, focusesPhrase: true, lensBundleID: emu.bundleID,
                                          lensAppName: emu.appName, lensTitle: emu.title)
                await shoot(name, AppMemorySheet(target: target, model: model, height: 1100), CGSize(width: 520, height: 1100), wait: 2)
            case "lens-menu-l0":
                await lens(name, badge: nil, notice: nil, menu: true, app: emu)
            case "lens-menu-l1", "lens-menu-l1-sub":
                model.settings.appProfiles = profileFixtures()
                await lens(name, badge: nil, notice: nil, menu: true, app: emu, submenu: name.hasSuffix("-sub"))
            case "menu-l1", "menu-l1-pinned":
                model.settings.appProfiles = profileFixtures()
                model.frontmostBundleID = "com.example.emu"
                if name == "menu-l1-pinned" { model.settings.profilePin = "anime" }
                await shoot(name, MenuPanel(), CGSize(width: 340, height: 330))
            case "engine-cloud-context":
                await contextSheet(name)
            default: print("unknown profile scenario \(name)")
            }
        }

        // MARK: the app profile's memory

        /// The profile row, its ⋯ menu and the Memory sheet of an app (Messages: a real bundle, so the card has its category). The engine is
        /// the mock in `terms` mode, which teaches the app two names (one seen twice, one seen once); nothing leaves this Mac.
        private func memoryScene(_ name: String) async {
            let messages = "com.apple.MobileSMS"
            let saved = model.settings
            defer { model.settings = saved }
            guard let mock = ContextChecks.Mock(mode: "terms") else { print("\(name): the mock server did not start"); return }
            defer { mock.stop() }
            let engine = ContextChecks.engine("openai", base: mock.base, context: EngineContext(enabled: true, previousLines: 2, useLearned: true))
            let names = [MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f, note: "17, class rep", reading: nil,
                                     addressing: [Addressing(to: "the teacher", register: .polite)]),
                         MemoryEntry(src: "Bob", dst: "밥", kind: .person, gender: .m),
                         MemoryEntry(src: "Sakura High", dst: "사쿠라 고등학교", kind: .org)]
            let filled = name != "memory-sheet-empty"
            model.settings.engines = [engine]
            model.settings.customEngineID = engine.id
            model.settings.sourceLanguage = "en"
            model.settings.targetLanguage = "ko"
            model.settings.appProfiles = [
                AppProfile(bundleID: messages, appName: "Messages", source: "en", target: "ko",
                           note: filled ? "Friends in one class chatting after school; casual, a little teasing." : "",
                           entries: filled ? names : [], context: filled ? AppContextOverride(mode: .nearby) : nil),
                AppProfile(bundleID: "com.apple.Safari", appName: "Safari", source: "ja", target: "en"),
                AppProfile(bundleID: "com.example.vn", appName: "Visual Novel Reader With A Very Long Name", source: "ja", target: "en",
                           paragraphReader: .lineGrouping, note: "Fantasy setting, formal speech.", entries: Array(names.prefix(2)))]
            model.settings = model.settings.convertedFromOldFields()   // the engine above carries 1.1.4's `context`: the converter makes it the amount
            await model.translator.update(settings: model.effectiveSettings)
            if name.hasPrefix("memory-sheet"), filled {
                let lens = LensContext(bundleID: messages, appName: "Messages", categoryWord: "social", confirmedTitle: "Alice", lensID: "L1", screen: [])
                for text in ["Haruka wrote line one", "Haruka wrote line two", "Mika wrote line three"] {
                    _ = await model.translator.translate([text], context: lens)
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            switch name {
            case "memory-profile-row":
                await shoot(name, TranslationSettings(), CGSize(width: 560, height: 1000))
            case "memory-menu":
                await memoryMenu(name)
            case "memory-sheet-fresh":
                await shoot(name, AppMemorySheet(bundleID: messages, model: model, askingToStartFresh: true), CGSize(width: 520, height: 640))
            case "memory-sheet-tall":
                await shoot(name, AppMemorySheet(bundleID: messages, model: model, height: 820), CGSize(width: 520, height: 820))
            default:
                await shoot(name, AppMemorySheet(bundleID: messages, model: model, openDetails: filled ? [0] : []), CGSize(width: 520, height: 640))
            }
            await model.translator.forgetLearned(for: messages)
        }

        /// The ⋯ menu of the first profile row, open: the popup button is pressed in code (no pointer event), the window and the menu are
        /// captured while it tracks, and the order of its items is checked: Edit…, Duplicate, Use for Every Lens, Remove….
        /// The lens menu of an app that has a memory (Messages: three names, a note, languages other than the lens's own, two glossary pairs),
        /// and the alert its "Forget <App>…" asks.
        private func lensMemory(_ name: String) async {
            let messages = LensWatch.Read(bundleID: "com.apple.MobileSMS", appName: "Messages", title: "")
            let saved = model.settings
            defer { model.settings = saved }
            model.settings.engines = []
            model.settings.customEngineID = nil
            model.settings.sourceLanguage = "ja"
            model.settings.targetLanguage = "en"
            model.settings.glossary = "勇者 = Hero\n魔王 = Demon King"
            model.settings.appProfiles = [AppProfile(bundleID: messages.bundleID, appName: messages.appName, source: "en", target: "ko",
                                                     note: "Friends in one class chatting after school; casual.",
                                                     entries: [MemoryEntry(src: "Alice", dst: "앨리스", kind: .person), MemoryEntry(src: "Bob", dst: "밥", kind: .person),
                                                               MemoryEntry(src: "Sakura High", dst: "사쿠라 고등학교", kind: .org)])]
            if name == "lens-menu-memory" {
                await lens(name, badge: nil, notice: nil, menu: true, app: messages)
            } else if name == "memory-sheet-lens" {
                // What the lens's "Memory for <App>…" leaves behind (`AppModel.openMemory`): Settings with the sheet of an app that has no profile.
                model.settings.appProfiles = []
                let w = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: 560, height: 700)), styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = NSHostingView(rootView: TranslationSettings().environment(model))
                w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
                model.memoryTarget = MemoryTarget(id: messages.bundleID, name: messages.appName)
                try? await Task.sleep(for: .seconds(delay))
                let sheet = w.sheets.first
                print("\(name): \(sheet != nil && model.settings.appProfiles.isEmpty ? "PASS" : "FAIL") the Memory sheet of an app with no profile comes up, and opening it made no profile")
                if let sheet { await capture(window: sheet, as: name) }
                model.memoryTarget = nil
                w.orderOut(nil)
            } else {
                let alert = LensMemoryMenu.forgetAlert(app: messages.appName, names: 3)
                alert.layout()
                NSApp.activate(ignoringOtherApps: true)
                alert.window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(delay))
                await capture(window: alert.window, as: name)
                alert.window.orderOut(nil)
            }
        }

        private func memoryMenu(_ name: String) async {
            // The ⋯ buttons are popup buttons, top to bottom: the added engine's, All apps', then the profile rows' (Messages, Safari, Visual Novel).
            guard let titles = await menuShot(name, TranslationSettings(), CGSize(width: 560, height: 700), opener: { host, _ in
                let popups = views(host).filter { String(describing: type(of: $0)).contains("PopupButton") }
                    .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
                guard popups.count == 5, let button = popups[2] as? NSButton else { return nil }
                return { button.performClick(nil) }
            }) else {
                print("\(name): FAIL the ⋯ button of the Messages row was not found")
                return
            }
            // A profile row's ⋯ (design §6.2): Edit…, Duplicate, Use for Every Lens, then Remove… after a divider.
            let order = [String(localized: "Edit…"), String(localized: "Duplicate"), String(localized: "Use for Every Lens"), String(localized: "Remove…")]
                .map { titles.firstIndex(of: $0) }
            print("memory-menu: \(titles)")
            print("memory-menu: \(order.allSatisfy { $0 != nil } && zip(order.compactMap { $0 }, order.compactMap { $0 }.dropFirst()).allSatisfy { $0 < $1 } ? "PASS" : "FAIL") the profile row's menu reads Edit…, Duplicate, Use for Every Lens, Remove…")
        }

        /// A pop-up of the window titled `windowTitle` that SwiftUI draws itself (a Picker in a grouped Form is no AppKit button), found through the accessibility
        /// tree by its name; the closure presses it the way VoiceOver does (no pointer event).
        private func axPopUp(inWindowTitled windowTitle: String, named label: String) async -> (() -> Void)? {
            func text(_ e: AXUIElement, _ a: String) -> String? {
                var v: CFTypeRef?
                return AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success ? v as? String : nil
            }
            func named(_ e: AXUIElement) -> [String] {
                var titled: CFTypeRef?
                AXUIElementCopyAttributeValue(e, kAXTitleUIElementAttribute as CFString, &titled)
                return [text(e, kAXDescriptionAttribute), text(e, kAXTitleAttribute), titled.flatMap { text($0 as! AXUIElement, kAXValueAttribute) }].compactMap { $0 }
            }
            func find(_ e: AXUIElement, _ depth: Int) -> AXUIElement? {
                if depth > 40 { return nil }
                let role = text(e, kAXRoleAttribute) ?? ""
                if role == "AXPopUpButton" || role == "AXMenuButton", named(e).contains(label) { return e }
                var kids: CFTypeRef?
                guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &kids) == .success else { return nil }
                for k in (kids as? [AXUIElement]) ?? [] { if let hit = find(k, depth + 1) { return hit } }
                return nil
            }
            let app = AXUIElementCreateApplication(getpid())
            // SwiftUI builds its accessibility tree as it is asked, and keeps filling it for a moment: ask again until the pop-up is there.
            for _ in 0..<15 {
                var windows: CFTypeRef?
                AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
                for w in (windows as? [AXUIElement]) ?? [] where text(w, kAXTitleAttribute) == windowTitle {
                    if let hit = find(w, 0) { return { AXUIElementPerformAction(hit, kAXPressAction as CFString) } }
                }
                try? await Task.sleep(for: .milliseconds(400))
            }
            return nil
        }

        /// `view` in a window, with the pop-up `opener` finds (it returns the closure that opens it; it is given the hosting view and the window's title) opened:
        /// the window and the menu are captured while it tracks. Returns the menu's items, nil when `opener` found none.
        private func menuShot<V: View>(_ name: String, _ view: V, _ size: CGSize, opener: (NSView, String) async -> (() -> Void)?) async -> [String]? {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = name
            let host = NSHostingView(rootView: view.environment(model))
            w.contentView = host
            w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(delay))
            guard let open = await opener(host, w.title) else {
                print("\(name): the pop-up was not found")
                w.orderOut(nil)
                return nil
            }
            nonisolated(unsafe) var titles: [String] = []
            nonisolated(unsafe) var tracked: NSMenu?
            let token = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { n in
                tracked = n.object as? NSMenu
                titles = tracked?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
            }
            let frame = w.frame
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
            // A plain backdrop behind the window and the menu: the capture shows nothing of the desktop.
            let backdrop = NSWindow(contentRect: frame.insetBy(dx: -30, dy: -30).offsetBy(dx: 120, dy: 0).union(frame.insetBy(dx: -30, dy: -30)), styleMask: [.borderless],
                                    backing: .buffered, defer: false)
            backdrop.backgroundColor = NSColor(white: 0.55, alpha: 1)
            // Above other apps' windows (an alert of theirs must not show), below the menu, with the settings window over it.
            backdrop.level = NSWindow.Level(rawValue: 24)
            w.level = NSWindow.Level(rawValue: 25)
            backdrop.orderFrontRegardless()
            w.makeKeyAndOrderFront(nil)
            let path = out.appendingPathComponent("\(name).png").path
            // Menu tracking runs the run loop in its own mode: the capture is timed in common modes, then ends the tracking.
            let t = Timer(timeInterval: 0.8, repeats: false) { _ in
                MainActor.assumeIsolated {
                    let r = backdrop.frame
                    self.run("/usr/sbin/screencapture", ["-x", "-R", "\(Int(r.minX)),\(Int(screen.height - r.maxY)),\(Int(r.width)),\(Int(r.height))", path])
                    tracked?.cancelTrackingWithoutAnimation()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            open()
            // An accessibility press may return before the menu tracks: the run loop gets time for the timer.
            try? await Task.sleep(for: .seconds(2))
            t.invalidate()
            NotificationCenter.default.removeObserver(token)
            print("wrote \(path)")
            backdrop.orderOut(nil)
            w.orderOut(nil)
            return titles
        }

        // MARK: capture

        private func shoot<V: View>(_ name: String, _ view: V, _ size: CGSize, wait: Double? = nil) async {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = name
            w.contentView = NSHostingView(rootView: view.environment(model))
            w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
            // Key and active, as the real window is: a native radio or toggle shows its accent colour only then.
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(wait ?? delay))
            await capture(window: w, as: name)
            w.orderOut(nil)
        }

        private func capture(window w: NSWindow, as name: String) async {
            let path = out.appendingPathComponent("\(name).png").path
            run("/usr/sbin/screencapture", ["-x", "-o", "-l", "\(w.windowNumber)", path])
            print("wrote \(path)")
        }

        private func run(_ tool: String, _ arguments: [String]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = arguments
            try? p.run()
            p.waitUntilExit()
        }

        /// A lens pill over a page-like backdrop; the screen area around it is captured.
        /// - `app`: the app the menu's memory block is about (`RegionSession.appUnderLens`); the page is taller then, for the longer menu.
        private func lens(_ name: String, badge: String?, notice: String?, menu: Bool = false, app: LensWatch.Read? = nil, submenu: Bool = false) async {
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
            let region = NSRect(x: 200, y: screen.height - 520, width: 400, height: 150)
            var content = region.insetBy(dx: -40, dy: -70).offsetBy(dx: 0, dy: -10)
            if app != nil {
                content.origin.y -= 160
                content.size.height += 160
            }
            let page = NSWindow(contentRect: content, styleMask: [.borderless], backing: .buffered, defer: false)
            page.backgroundColor = NSColor(white: 0.96, alpha: 1)
            page.level = .normal
            page.orderFrontRegardless()
            let lens = RegionFrameWindow(region: region, name: "Safari")
            lens.setAppearance(style: .glow, tint: .spectrum, tabVisibility: .automatic, tabPosition: .topLeading)
            lens.setFollowing(true)
            lens.setDetail("English → Korean", badge: badge)
            lens.orderFrontRegardless()
            lens.setEmphasized(true)
            if let notice { lens.flash(notice, seconds: 30) }
            try? await Task.sleep(for: .seconds(delay))
            let r = page.frame
            let path = out.appendingPathComponent("\(name).png").path
            if menu {
                var config = RegionConfig(name: "Safari", rect: region)
                config.follow(nil)
                let session = RegionSession(config: config, settings: model.settings, translator: model.translator, inpainter: nil)
                if let app { session.appUnderLens = { _ in app } }
                var m = session.contextMenu()
                // The Profile item's submenu on its own, as it opens beside the item (a menu cannot be asked to open a submenu without a pointer).
                if submenu, let holder = m.items.first(where: { $0.submenu != nil }), let sub = holder.submenu {
                    holder.submenu = nil
                    m = sub
                }
                // Menu tracking runs the run loop in its own mode: the capture has to be timed in common modes.
                nonisolated(unsafe) let menu = m   // the timer fires on the main run loop, during menu tracking
                let t = Timer(timeInterval: 0.8, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        self.run("/usr/sbin/screencapture", ["-x", "-R", "\(Int(r.minX)),\(Int(screen.height - r.maxY)),\(Int(r.width)),\(Int(r.height))", path])
                        menu.cancelTracking()
                    }
                }
                RunLoop.main.add(t, forMode: .common)
                m.popUp(positioning: nil, at: NSPoint(x: region.minX + 30, y: region.maxY + 4), in: nil)
            } else {
                run("/usr/sbin/screencapture", ["-x", "-R", "\(Int(r.minX)),\(Int(screen.height - r.maxY)),\(Int(r.width)),\(Int(r.height))", path])
            }
            print("wrote \(path)")
            lens.orderOut(nil)
            page.orderOut(nil)
        }

        /// A lens (360 × 200) in one look over a plain dark or light backdrop; returns the PNG's path.
        @discardableResult
        private func lensShot(_ name: String, style: LensStyle = .glow, tint: LensTint = .spectrum, position: LensTabPosition = .topLeading,
                              dark: Bool, busy: Bool = false, emphasized: Bool = false, notice: String? = nil, hint: LensHint? = nil,
                              width: CGFloat = 360, wait: Double = 0.5) async -> String {
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
            let region = NSRect(x: 200, y: screen.height - 520, width: width, height: 200)
            let page = NSWindow(contentRect: region.insetBy(dx: -40, dy: -70).offsetBy(dx: 0, dy: -10), styleMask: [.borderless], backing: .buffered, defer: false)
            page.backgroundColor = NSColor(white: dark ? 0.12 : 0.96, alpha: 1)
            page.level = .normal
            page.orderFrontRegardless()
            let lens = RegionFrameWindow(region: region, name: "Safari")
            // The pointer of whoever uses the screen must not hover the lens: hovering brightens it.
            lens.ignoresMouseEvents = true
            lens.setAppearance(style: style, tint: tint, tabVisibility: .automatic, tabPosition: position)
            lens.setFollowing(true)
            lens.setDetail("English → Korean")
            lens.setBusy(busy)
            lens.setHint(hint.map(LensHintText.line), actionable: hint?.action != nil, forcesTab: hint?.showsTabAlways ?? false)
            lens.orderFrontRegardless()
            lens.setEmphasized(emphasized)
            if let notice { lens.flash(notice, seconds: 30) }
            try? await Task.sleep(for: .seconds(wait))
            let r = page.frame
            let path = out.appendingPathComponent("\(name).png").path
            run("/usr/sbin/screencapture", ["-x", "-R", "\(Int(r.minX)),\(Int(screen.height - r.maxY)),\(Int(r.width)),\(Int(r.height))", path])
            print("wrote \(path)")
            lens.orderOut(nil)
            page.orderOut(nil)
            return path
        }

        /// A lens pill with each hint (`LensHint`) over a dark and a light backdrop. `notice` shows a notice over a hint (it wins for its
        /// seconds); `narrow` a lens too small for the whole line.
        private func lensHints(_ name: String) async {
            let hint: LensHint = switch name {
            case "lens-hint-allow": .allowScreenRecording
            case "lens-hint-restart": .restartToFinish
            case "lens-hint-preparing": .preparingRecognition
            case "lens-hint-disk": .recognitionNeedsDiskSpace
            case "lens-hint-already": .alreadyInTarget(target: "en")
            case "lens-hint-pack-downloading": .downloadingPack(PackPair(source: "ja", target: "en"))
            case "lens-hint-pack-notfinished": .downloadNotFinished(PackPair(source: "ja", target: "en"))
            case "lens-hint-unsupported": .pairNotSupported(PackPair(source: "ko", target: "ko"))
            default: .downloadPack(PackPair(source: "ja", target: "en"))
            }
            for dark in [true, false] {
                await lensShot("\(name)-\(dark ? "dark" : "light")", dark: dark, notice: name == "lens-hint-notice" ? "Gemini unavailable · using Apple" : nil,
                               hint: hint, width: name == "lens-hint-narrow" ? 230 : 360)
            }
        }

        private static let packJa = PackPair(source: "ja", target: "en")

        /// The panel's lens rows with the line each language hint puts in the second line (the real `RegionRow`, a hint set on it without a
        /// running lens), over one row with none for the size line beside them.
        private func menuPackRows(_ name: String) async {
            let hints: [LensHint?] = [.downloadPack(Self.packJa), .downloadingPack(Self.packJa), .downloadNotFinished(Self.packJa),
                                      .pairNotSupported(PackPair(source: "ko", target: "ko")), nil]
            var rows: [RegionConfig] = []
            for (i, hint) in hints.enumerated() {
                var config = RegionConfig(name: "Screen", rect: CGRect(x: 100, y: 100, width: 520, height: 260))
                config.follow(nil)
                config.name = ["Safari", "Slack", "Preview", "Notes", "Terminal"][i]
                rows.append(config)
                model.capturedHints[config.id] = hint
            }
            defer { model.capturedHints = [:] }
            await shoot(name, VStack(spacing: 6) { ForEach(rows) { RegionRow(region: $0) } }.padding(16).frame(width: 340), CGSize(width: 340, height: 330))
        }

        /// The panel with the banner for a language trouble that no lens says in its row (all lenses off, or the image window's).
        private func menuPackBanner(_ name: String) async {
            let state = String(name.dropFirst("menu-pack-banner-".count))
            let download = PackDownload.shared
            switch state {
            case "unsupported": model.received(.unsupportedPair(source: "ko", target: "ko"))
            case "downloading":
                model.received(.languagePackMissing(source: "ja", target: "en"))
                download.request(Self.packJa, in: .image)
            case "notfinished":
                model.received(.languagePackMissing(source: "ja", target: "en"))
                download.status = { _ in .downloadable }
                download.request(Self.packJa, in: .image)
                await download.end(Self.packJa, in: .image)
            default: model.received(.languagePackMissing(source: "ja", target: "en"))
            }
            await shoot(name, MenuPanel(), CGSize(width: 340, height: 330))
            download.status = { _ in .installed }
            if download.image != nil { await download.end(Self.packJa, in: .image) }
            download.status = { pair in await AppModel.shared.translator.packStatus(source: pair.source, target: pair.target) }
            download.packsChanged()
            model.received(nil)
        }

        /// Settings › Translation with the list of packs in each state a row can be in: installed, to download, downloading, not finished, not
        /// supported (the fake status; the real list reads the system).
        private func packRowStates(_ name: String) async {
            let download = PackDownload.shared
            model.settings.sourceLanguage = "ja"
            model.settings.targetLanguage = "ko"
            download.status = { pair in
                switch pair.source {
                case "ja", "en": .installed
                case "th": .unsupported
                default: .downloadable
                }
            }
            let ko = { (s: String) in PackPair(source: s, target: "ko") }
            download.request(ko("fr"), in: .image)
            download.request(ko("de"), in: .settings)
            await download.end(ko("de"), in: .settings)   // not finished: the fake says it is still to download
            download.request(ko("vi"), in: .settings)     // downloading
            // The All Languages group, open, shows every row; the chosen pair is the first.
            await shoot(name, Form { Section("Apple Translation language packs") { LanguagePacksView(source: "ja", target: "ko", expanded: true) } }
                .formStyle(.grouped), CGSize(width: 560, height: 700))
            download.status = { _ in .installed }
            await download.end(ko("fr"), in: .image)
            await download.end(ko("vi"), in: .settings)
            download.status = { pair in await AppModel.shared.translator.packStatus(source: pair.source, target: pair.target) }
            download.packsChanged()
        }

        /// The Translate Image window's status line in each state a missing pack or an unsupported pair can leave a picture in, over a plain
        /// picture of its own (`--image` when given).
        /// The Translate Text window (round text117): empty, with a text translated (the call stubbed with a fixed sample: the picture is of the window, not of an
        /// engine), with an added engine chosen (the Translate button asks), and with a language pack missing; each in light and dark, `<name>-light|dark.png`.
        private func textWindow(_ name: String) async {
            let state = String(name.dropFirst("text-window-".count))
            let sample = "Hi Alice,\n\nThanks for sending the photos. I will look through them tonight and send my notes tomorrow morning.\n\nBest,\nBob"
            let korean = ["Hi Alice,": "앨리스 님께,",
                          "Thanks for sending the photos. I will look through them tonight and send my notes tomorrow morning.": "사진을 보내 주셔서 감사합니다. 오늘 밤에 살펴보고 내일 아침에 의견을 보내 드리겠습니다.",
                          "Best,": "그럼,", "Bob": "밥"]
            var settings = model.settings
            settings.sourceLanguage = "en"
            settings.targetLanguage = "ko"
            settings.engines = state == "added-engine" ? [EngineConfig(name: "OpenAI", kind: .openAICompatible(baseURL: URL(string: "https://api.openai.com/v1")!, model: "gpt-4o-mini", thinking: .off, extraHeaders: [:]))] : []
            settings.customEngineID = settings.engines.first?.id
            // The profile row shows only where a profile exists: the added-engine shot has all three pop-ups.
            if state == "added-engine" { settings.appProfiles = [AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "en", target: "ko")] }
            let translator = TextTranslator(settings: { settings }, secrets: { model.secrets })
            translator.call = { lines, _, _, _, onResult in
                if state == "pack" {
                    return TextTranslation.Answer(rows: lines.map { _ in .init(translation: nil, engine: nil) }, translated: false,
                                                  issue: .languagePackMissing(source: "en", target: "ko"), profile: nil, memory: nil)
                }
                for line in lines { if let t = korean[line] { onResult?(line, t) } }
                return TextTranslation.Answer(rows: lines.map { .init(translation: korean[$0], engine: state == "added-engine" ? "OpenAI" : "Apple") },
                                              translated: true, issue: nil, profile: nil, memory: nil)
            }
            let text = TextTranslationModel(translator: translator, settings: { settings }, pause: TypingPause(delay: 0))
            if state == "added-engine" { text.anchor(to: "com.example.chat") }
            if state != "empty" { text.source = sample }
            if state != "empty" { text.translateNow() }
            for _ in 0..<100 { if case .working = text.phase { try? await Task.sleep(for: .milliseconds(50)) } else { break } }
            let saved = model.settings
            model.settings = settings
            defer { model.settings = saved }
            for dark in [false, true] {
                let w = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: 840, height: 460)), styleMask: [.titled], backing: .buffered, defer: false)
                w.title = String(localized: "Translate Text")
                w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                w.contentView = NSHostingView(rootView: TextTranslationView(model: text).environment(model))
                w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
                NSApp.activate(ignoringOtherApps: true)
                w.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(delay))
                await capture(window: w, as: "\(name)-\(dark ? "dark" : "light")")
                w.orderOut(nil)
            }
        }

        private func imageWindowPackStates(_ name: String) async {
            let state = String(name.dropFirst("image-window-pack-".count))
            let download = PackDownload.shared
            let picture = option("--image").flatMap { NSImage(contentsOf: URL(fileURLWithPath: $0)) } ?? NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
                NSColor(white: 0.9, alpha: 1).setFill()
                rect.fill()
                return true
            }
            let sample = ImageTranslationModel()
            sample.showSettled(picture, lines: 0)
            switch state {
            case "unsupported": sample.showStatus(.unsupported(PackPair(source: "ko", target: "ko")))
            case "downloading":
                download.request(Self.packJa, in: .image)
                sample.showStatus(.needsPack(Self.packJa))
            case "notfinished":
                download.status = { _ in .downloadable }
                download.request(Self.packJa, in: .image)
                await download.end(Self.packJa, in: .image)
                sample.showStatus(.needsPack(Self.packJa))
            default: sample.showStatus(.needsPack(Self.packJa))
            }
            await shoot(name, ImageTranslationView(model: sample, onDrop: { _ in false }), CGSize(width: 1040, height: 520))
            download.status = { _ in .installed }
            if download.image != nil { await download.end(Self.packJa, in: .image) }
            download.status = { pair in await AppModel.shared.translator.packStatus(source: pair.source, target: pair.target) }
            download.packsChanged()
        }

        /// The image window over a picture whose translation cannot happen, run for real with `MWOYEO_FAKE_ENGINE=fail` (every call fails, as
        /// a missing pack does) and the issue the app would hold seeded: `needsPack` = a language pack is missing, `blocked` = the pair
        /// is not supported. Prints the phase and how long the window took to settle: the wait used to run to its 180 s ceiling.
        private func imageWindowBlocked(_ name: String) async {
            guard let path = option("--image") else { print("\(name): needs --image <picture> (and MWOYEO_FAKE_ENGINE=fail)"); return }
            let pack = name == "image-window-pack"
            model.settings.sourceLanguage = "auto"
            model.settings.targetLanguage = "ko"
            model.received(pack ? .languagePackMissing(source: "en", target: "ko") : .unsupportedPair(source: "en", target: "ko"))
            await AppModel.loadVision()
            let picture = ImageTranslationModel()
            let started = Date()
            picture.open(url: URL(fileURLWithPath: path))
            for _ in 0..<2000 where picture.phase == .working || picture.phase == .empty { try? await Task.sleep(for: .milliseconds(100)) }
            print("\(name): \(picture.phase) after \(String(format: "%.1f", Date().timeIntervalSince(started))) s, \(picture.texts.count) lines, "
                  + "\(picture.texts.filter { $0.translation != nil }.count) translated")
            await shoot(name, ImageTranslationView(model: picture, onDrop: { _ in false }), CGSize(width: 1040, height: 760))
            model.received(nil)
        }

        /// Every style in every tint, on both backdrops, and a grid of each backdrop (styles across, tints down).
        private func lensGallery() async {
            for dark in [true, false] {
                var rows: [[String]] = []
                for tint in LensTint.allCases {
                    var row: [String] = []
                    for style in LensStyle.allCases {
                        row.append(await lensShot("lens-\(style.rawValue)-\(tint.rawValue)-\(dark ? "dark" : "light")", style: style, tint: tint, dark: dark))
                    }
                    rows.append(row)
                }
                writeGrid("lens-gallery-\(dark ? "dark" : "light")", rows)
            }
        }

        /// The name tag in each of its four places; the last carries a notice.
        private func lensTabPositions() async {
            for (i, position) in LensTabPosition.allCases.enumerated() {
                await lensShot("lens-tab-\(position.rawValue)", position: position, dark: false, emphasized: i != 1,
                               notice: i == 3 ? "Copied" : nil)
            }
        }

        /// The captures in `rows` laid side by side at one point per pixel (the captures themselves are twice that).
        private func writeGrid(_ name: String, _ rows: [[String]]) {
            let images = rows.map { $0.map { NSImage(contentsOfFile: $0) } }
            guard let first = images.first?.first ?? nil else { return }
            let cell = first.size
            let w = Int(cell.width) * (rows.first?.count ?? 0), h = Int(cell.height) * rows.count
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            for (y, row) in images.enumerated() {
                for (x, image) in row.enumerated() {
                    image?.draw(in: NSRect(x: CGFloat(x) * cell.width, y: CGFloat(rows.count - 1 - y) * cell.height, width: cell.width, height: cell.height))
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let path = out.appendingPathComponent("\(name).png").path
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("wrote \(path)")
        }

        /// The add flow end to end: the sheet pastes a setup and a key, runs the sample and adds the engine.
        private func addFlow() async {
            let key = option("--key") ?? "sk-test-gate-\(UUID().uuidString)"
            let setup = EngineShare.encode(engine("Gate Engine", mock, "mock-model"))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: EngineSheet(autopilot: .init(setup: setup, key: key, commit: true)).environment(model))
            w.orderFrontRegardless()
            for _ in 0..<150 where model.settings.engines.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            guard let added = model.settings.engines.first else { print("add-flow: FAIL, no engine added"); return }
            let stored = ((try? model.secrets.secret(for: added.id)) ?? nil) == key
            let share = EngineShare.encode(added)
            print("add-flow: engine added \(added.name) \(added.id), key in secret store: \(stored), key in settings JSON: \(String(decoding: (try? JSONEncoder().encode(model.settings)) ?? Data(), as: UTF8.self).contains(key)), key in Copy Setup: \(share.contains(key))")
            // Select it and translate through it.
            model.selectEngine(added.id)
            try? await Task.sleep(for: .milliseconds(500))
            let outcome = await model.translator.translate(["こんにちは世界"])
            print("add-flow: translated \(outcome.translations)")
            // Written to the real Keychain unless MWOYEO_MEMORY_SECRETS is set: the caller greps for the key, then this removes it.
            if option("--keep-key") == nil { try? model.secrets.setSecret(nil, for: added.id) }
            w.orderOut(nil)
        }
    }
}
#endif
