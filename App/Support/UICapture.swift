import AppKit
import MwoyeoCore
import MwoyeoEngines
import SwiftUI

/// Window captures of the engine UI, for checking a look without clicking through the app:
///   Mwoyeo --capture-ui outdir scenario… [--mock http://host:port/v1] [--delay s]
/// Scenarios: translation-default, translation-engines, general-saving, menu-default, menu-switcher, menu-notice,
/// sheet-pick, sheet-config, sheet-config-remote, lens-badge, lens-notice, lens-menu, add-flow (adds an engine through the sheet, prints
/// where the key is). Run it with `MWOYEO_MEMORY_SECRETS=1` and `CFFIXED_USER_HOME=<empty dir>` so it touches neither
/// the Keychain nor the real preferences. `--mock` is a tools/mock-openai server the sample translations go to.
enum UICapture {
    static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await Runner(args: args).go()
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
                if a == "--mock" || a == "--delay" || a == "--key" { skip = true; continue }
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
            case "general-saving": await shoot(name, GeneralSettings(), CGSize(width: 560, height: 520))
            case "menu-default": await shoot(name, MenuPanel(), CGSize(width: 340, height: 330))
            case "translation-engines":
                await seedEngines()
                await shoot(name, TranslationSettings(), CGSize(width: 560, height: 820))
            case "menu-switcher":
                await seedEngines()
                await shoot(name, MenuPanel(), CGSize(width: 340, height: 330))
            case "menu-notice":
                await seedEngines()
                model.received(.engineUnavailable(name: "Gemini", reason: "The engine did not accept the key."))
                await shoot(name, MenuPanel(), CGSize(width: 340, height: 400))
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

        // MARK: capture

        private func shoot<V: View>(_ name: String, _ view: V, _ size: CGSize, wait: Double? = nil) async {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            w.title = name
            w.contentView = NSHostingView(rootView: view.environment(model))
            w.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.frame.height ?? 900) - 60))
            w.orderFrontRegardless()
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
