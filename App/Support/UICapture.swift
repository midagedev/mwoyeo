import AppKit
import MwoyeoCore
import MwoyeoEngines
import SwiftUI

/// Window captures of the engine UI, for checking a look without clicking through the app:
///   Mwoyeo --capture-ui outdir scenario… [--mock http://host:port/v1] [--delay s] [--image picture]
/// Scenarios: translation-default, translation-engines, general-saving, menu-default, menu-switcher, menu-notice,
/// menu-profile, image-window and image-window-original (the Translate Image window on `--image`, translated through the
/// mock, then with Show Original on; when the text recognizer reads nothing the picture stands in for its translation, which
/// still shows the toggle's two states), sheet-pick, sheet-config, sheet-config-remote, lens-badge, lens-notice, lens-menu, add-flow (adds an
/// engine through the sheet, prints where the key is), check-logic (prints PASS/FAIL for the engine selection and the
/// engine notice's dismissal; no window). Run it with `MWOYEO_MEMORY_SECRETS=1` so it does not touch the Keychain. It keeps its
/// preferences in a scratch suite of its own (deleted at exit; `MWOYEO_DEFAULTS_SUITE` names one to keep), never the app's real
/// ones; `CFFIXED_USER_HOME` does not move those. `--mock` is a tools/mock-openai server the sample translations go to.
enum UICapture {
    static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        // Scratch preferences (AppModel reads the suite when it is first used): a capture never writes the app's real ones.
        // CFFIXED_USER_HOME does not move them. A suite named in the environment is kept.
        let suite = "dev.midagedev.mwoyeo.capture-\(getpid())"
        let ownSuite = ProcessInfo.processInfo.environment["MWOYEO_DEFAULTS_SUITE"] == nil
        if ownSuite { setenv("MWOYEO_DEFAULTS_SUITE", suite, 1) }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await Runner(args: args).go()
            if ownSuite {
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
                // The preferences daemon leaves the emptied file behind, in the real home.
                try? FileManager.default.removeItem(atPath: NSHomeDirectoryForUser(NSUserName())! + "/Library/Preferences/\(suite).plist")
            }
            exit(0)
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
                if a == "--mock" || a == "--delay" || a == "--key" || a == "--image" { skip = true; continue }
                if a == "--keep-key" { continue }
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
            let cloud = engine("Gemini", "https://generativelanguage.googleapis.com/v1beta/openai/", "gemini-3.1-flash-lite")
            let local = engine("Ollama", mock, "qwen3:8b")
            model.settings.sourceLanguage = "ja"
            model.settings.targetLanguage = "ko"
            model.settings.engines = [cloud, local]
            model.settings.customEngineID = local.id
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
            case "general-saving": await shoot(name, GeneralSettings(), CGSize(width: 560, height: 800))
            case "menu-default": await shoot(name, MenuPanel(), CGSize(width: 340, height: 330))
            case "translation-engines":
                await seedEngines()
                await shoot(name, TranslationSettings(), CGSize(width: 560, height: 820))
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
            case "image-window": await imageWindow(name, showOriginal: false)
            case "image-window-original": await imageWindow(name, showOriginal: true)
            case "check-logic": await checkLogic()
            case "sheet-pick": await shoot(name, EngineSheet(), CGSize(width: 480, height: 560))
            case "sheet-config":
                let setup = EngineShare.encode(engine("Gemini", mock, "mock-model"))
                await shoot(name, EngineSheet(autopilot: .init(setup: setup, key: "sk-test-capture")), CGSize(width: 480, height: 560), wait: 5)
            case "sheet-config-remote":
                let setup = EngineShare.encode(engine("Gemini", "https://gemini.example.invalid/v1beta/openai/", "gemini-3.1-flash-lite"))
                await shoot(name, EngineSheet(autopilot: .init(setup: setup, key: "sk-test-capture")), CGSize(width: 480, height: 560), wait: 5)
            case "lens-badge": await lens(name, badge: "cloud", notice: nil)
            case "lens-notice": await lens(name, badge: "cloud", notice: "Gemini unavailable · using Apple")
            case "lens-menu": await lens(name, badge: nil, notice: nil, menu: true)
            case "add-flow": await addFlow()
            default: print("unknown scenario \(name)")
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
                // The Swift models too (a child loads them), so that the picture is read as the app reads it once it is warm.
                _ = await TextRecognizer.untilSwiftReady([Locale.Language(identifier: "ja")], seconds: 600)
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
            print("check-logic: \(failed == 0 ? "all passed" : "\(failed) FAILED")")
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
        private func lens(_ name: String, badge: String?, notice: String?, menu: Bool = false) async {
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
            let region = NSRect(x: 200, y: screen.height - 520, width: 400, height: 150)
            let page = NSWindow(contentRect: region.insetBy(dx: -40, dy: -70).offsetBy(dx: 0, dy: -10), styleMask: [.borderless], backing: .buffered, defer: false)
            page.backgroundColor = NSColor(white: 0.96, alpha: 1)
            page.level = .normal
            page.orderFrontRegardless()
            let lens = RegionFrameWindow(region: region, name: "Safari")
            lens.setStyle(.glow)
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
                let m = RegionSession(config: config, settings: model.settings, translator: model.translator, inpainter: nil).contextMenu()
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
