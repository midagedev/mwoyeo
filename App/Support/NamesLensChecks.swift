#if !MAS
import AppKit
import MwoyeoCore

/// The checks of the lens menu's memory block and of how an app's memory begins (round nameslens; design names-and-context §3.2, §3.3; gaps
/// G1 and G2), run by `--capture-ui … check-logic` and alone by `names-lens-checks`. The menu is the real one (`RegionSession.contextMenu`),
/// its items are fired the way a click does, and the Memory sheet is driven through `AppMemoryEditor`, so through settings.json's model.
///
/// Each check was shown FAIL on a mutation of the code it guards (the round report lists the lines). Only counts and names are printed.
@MainActor
enum NamesLensChecks {
    /// An app that is not installed: nothing else in the checks knows it.
    static let app = "com.example.nameslens"
    static let appName = "Example Game"

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") names lens: \(what)" + (ok || note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        let saved = model.settings, savedOpen = model.openSettingsAction, savedTab = model.settingsTab
        defer {
            model.settings = saved
            model.openSettingsAction = savedOpen
            model.settingsTab = savedTab
            model.memoryTarget = nil
        }
        func start(source: String = "ja", target: String = "ko", glossary: String = "", profiles: [AppProfile] = []) {
            model.settings.sourceLanguage = source
            model.settings.targetLanguage = target
            model.settings.customEngineID = nil
            model.settings.engines = []
            model.settings.glossary = glossary
            model.settings.appProfiles = profiles
            model.memoryTarget = nil
        }
        let names = [MemoryEntry(src: "九十九", dst: "츠쿠모", kind: .person), MemoryEntry(src: "魔王城", dst: "마왕성", kind: .place)]
        let rich = AppProfile(bundleID: app, appName: appName, source: "ja", target: "en", paragraphReader: .lineGrouping,
                              note: "Fantasy, formal speech.", entries: names, context: AppContextOverride(mode: .nearby))
        let read = LensWatch.Read(bundleID: app, appName: appName, title: "")

        /// The menu of a lens over `app` (nil: over nothing known), unanchored, as `contextMenu()` builds it. `confirm` answers the alert.
        func lensMenu(over app: LensWatch.Read?, confirm: @escaping @MainActor (String, Int, Bool) -> Bool = { _, _, _ in false }) -> NSMenu {
            var config = RegionConfig(name: "Safari", rect: CGRect(x: 200, y: 300, width: 360, height: 200))
            config.follow(nil)
            let session = RegionSession(config: config, settings: model.settings, translator: model.translator, inpainter: nil)
            session.appUnderLens = { _ in app }
            session.confirmsForgetting = confirm
            return session.contextMenu()
        }
        func item(_ menu: NSMenu, _ title: String) -> NSMenuItem? { menu.items.first { $0.title == title } }
        func click(_ item: NSMenuItem?) {
            if let item, let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) }
        }
        let remember = String(localized: "Remember Languages for \(appName)")
        let memory = String(localized: "Memory for \(appName)…")
        let forget = String(localized: "Forget \(appName)…")
        let forgetLanguages = String(localized: "Forget Languages for \(appName)")

        // MARK: G2: Memory for <App>… in every lens menu
        start()
        let plain = lensMenu(over: read)
        check("a lens that follows no window but covers a known app has Memory for <App>… (it used to need an anchored lens)",
              item(plain, memory) != nil && item(plain, remember) != nil && item(plain, forget) == nil && item(plain, forgetLanguages) == nil,
              plain.items.map(\.title).joined(separator: " | "))
        let unknown = lensMenu(over: nil)
        check("a lens over no known app has no memory items at all (the menu ends with Save Lens Image, as before)",
              item(unknown, memory) == nil && item(unknown, remember) == nil && unknown.items.last?.title == String(localized: "Save Lens Image")
              && unknown.items.count < plain.items.count)

        var opened = 0
        model.openSettingsAction = { opened += 1 }
        model.settingsTab = .general
        click(item(plain, memory))
        check("choosing it opens Settings at Translation with that app's Memory sheet, and makes no profile",
              opened == 1 && model.settingsTab == .translation && model.memoryTarget?.id == app && model.memoryTarget?.name == appName
              && model.settings.appProfiles.isEmpty, "opened \(opened), tab \(model.settingsTab), target \(model.memoryTarget?.id ?? "nil")")
        model.memoryTarget = nil
        model.openSettingsAction = nil
        click(item(plain, memory))
        check("with no way to open Settings nothing is left waiting for the next time it opens", model.memoryTarget == nil)
        model.openSettingsAction = savedOpen

        let long = LensWatch.Read(bundleID: app, appName: String(repeating: "あ", count: 20) + "-" + String(repeating: "x", count: 20), title: "")
        let cut = LensMemoryMenu.cut(long.appName)
        let longMenu = lensMenu(over: long)
        check("the app's name in the items is cut in the middle at 24 characters, a short one is not",
              cut.count == 24 && cut.hasPrefix(String(long.appName.prefix(12))) && cut.hasSuffix(String(long.appName.suffix(11))) && cut.contains("…")
              && item(longMenu, String(localized: "Memory for \(cut)…")) != nil && LensMemoryMenu.cut(appName) == appName
              && LensMemoryMenu.cut(String(repeating: "a", count: 24)).count == 24, cut)

        // MARK: G2: the info line
        let words = LensMemoryMenu.Words(names: { "Names: \($0)" }, allApps: { "all apps \($0)" })
        let wide = String(repeating: "W", count: 40)
        let line = LensMemoryMenu.infoLine(app: appName, appNames: 3, allApps: 2, words: words)
        check("the info line is \"Names: 5 — <App> 3 · all apps 2\", leaves a scope with no names out, and is nil when nothing applies",
              line == "Names: 5 — Example Game 3 · all apps 2"
              && LensMemoryMenu.infoLine(app: appName, appNames: 0, allApps: 2, words: words) == "Names: 2 — all apps 2"
              && LensMemoryMenu.infoLine(app: appName, appNames: 4, allApps: 0, words: words) == "Names: 4 — Example Game 4"
              && LensMemoryMenu.infoLine(app: appName, appNames: 0, allApps: 0, words: words) == nil, line ?? "nil")
        let capped = LensMemoryMenu.infoLine(app: wide, appNames: 40, allApps: 300, words: words)
        check("it is at most 48 characters, cut at the tail, and the app name in it is cut in the middle at 24",
              capped.map { $0.count == 48 && $0.hasSuffix("…") && $0.hasPrefix("Names: 340 — " + LensMemoryMenu.cut(wide)) } == true
              && LensMemoryMenu.infoLine(app: appName, appNames: 40, allApps: 40, words: words).map { $0.count <= 48 } == true, capped ?? "nil")

        start(glossary: "勇者 = 용사\n魔王 = 마왕\nbad line", profiles: [rich])
        let withNames = lensMenu(over: read)
        let infoAt = withNames.items.firstIndex { !$0.isEnabled && !$0.isSeparatorItem && $0.title == LensMemoryMenu.infoLine(app: appName, appNames: 2, allApps: 2, words: .current) }
        let memoryAt = withNames.items.firstIndex { $0.title == memory }
        check("the menu has the info line, disabled, right above Memory for <App>…, counting the app's names and the glossary's pairs",
              infoAt != nil && memoryAt != nil && infoAt.map { $0 + 1 } == memoryAt, "\(infoAt.map(String.init) ?? "nil") \(memoryAt.map(String.init) ?? "nil")")
        start(profiles: [AppProfile(bundleID: app, appName: appName, source: "ja", target: "ko", note: "only a note")])
        let nothing = lensMenu(over: read)
        let bareAt = nothing.items.firstIndex { $0.title == memory }
        check("with no name and no glossary pair the info line is not in the menu: the separator is right above Memory for <App>…",
              bareAt.map { $0 > 0 && nothing.items[$0 - 1].isSeparatorItem } == true)

        // MARK: G1: Remember Languages keeps the app's memory
        start(source: "ja", target: "ko", profiles: [rich])
        let differing = lensMenu(over: read)
        click(item(differing, remember))
        let after = model.profile(for: app)
        check("remembering languages keeps the app's memory: the pair changes, the note, the names, the context choice and the reader stay",
              after?.source == "ja" && after?.target == "ko" && after?.note == rich.note && after?.entries == names && after?.context == rich.context
              && after?.paragraphReader == rich.paragraphReader && model.settings.appProfiles.count == 1,
              "\(after?.source ?? "nil")→\(after?.target ?? "nil"), note \(after?.note.count ?? -1), names \(after?.entries.count ?? -1)")
        start(source: "ja", target: "ko", profiles: [AppProfile(bundleID: app, appName: appName, source: "ja", target: "ko", note: rich.note, entries: names)])
        let same = lensMenu(over: read)
        check("Remember Languages compares only the pair and the engine: an app with memory and the same pair is not offered it again",
              item(same, remember) == nil && item(same, memory) != nil)
        start(source: "ja", target: "ko", profiles: [])
        click(item(lensMenu(over: read), remember))
        check("for an app with no profile it makes one from the pair and the engine, as it did",
              model.profile(for: app) == AppProfile(bundleID: app, appName: appName, source: "ja", target: "ko"))

        // MARK: G1: Forget asks when there is a memory
        start(profiles: [rich])
        var asked: [(String, Int)] = []
        let cancelled = lensMenu(over: read) { a, n, _ in asked.append((a, n)); return false }
        click(item(cancelled, forget))
        check("Forget <App>… on an app with memory asks first, with the app and the count of its names; Cancel keeps everything",
              item(cancelled, forgetLanguages) == nil && asked.count == 1 && asked[0].0 == appName && asked[0].1 == 2 && model.profile(for: app) == rich,
              "asked \(asked)")
        let confirmed = lensMenu(over: read) { _, _, _ in true }
        click(item(confirmed, forget))
        check("and removes the profile with its memory when the answer is yes", model.profile(for: app) == nil)
        start(profiles: [AppProfile(bundleID: app, appName: appName, source: "ja", target: "en")])
        asked = []
        let bare = lensMenu(over: read) { a, n, _ in asked.append((a, n)); return true }
        check("an app with languages only keeps today's Forget Languages for <App>, with no alert",
              item(bare, forget) == nil && item(bare, forgetLanguages) != nil)
        click(item(bare, forgetLanguages))
        check("which removes the profile without asking", asked.isEmpty && model.profile(for: app) == nil)
        // 2026-10-21 (round ui-all, addendum A3): the alert says "Its note and n names" only for a profile that has a note; the lens tells it.
        var notes: [Bool] = []
        for profile in [AppProfile(bundleID: app, appName: appName, source: "ja", target: "en", entries: names), rich] {
            start(profiles: [profile])
            click(item(lensMenu(over: read) { _, _, hasNote in notes.append(hasNote); return false }, forget))
        }
        check("the Forget alert is told whether the profile has a note: no for names alone, yes for a note and names", notes == [false, true], "\(notes)")
        let alert = LensMemoryMenu.forgetAlert(app: appName, names: 12)
        check("the alert names the app and the count, has Forget (destructive) and Cancel",
              alert.messageText.contains(appName) && alert.informativeText.contains("12") && alert.buttons.count == 2
              && alert.buttons[0].hasDestructiveAction && !alert.buttons[1].hasDestructiveAction)

        // MARK: G2: the first edit makes the profile, once, with the pair in effect while the app is in front
        start()
        let opening = AppMemoryEditor(bundleID: app, model: model, appName: appName)
        opening.reconcile()
        opening.setNote("")
        _ = opening.addRow()
        check("opening the sheet of an app with no profile makes none, and the sheet is not 'gone'; an empty edit makes none either",
              model.settings.appProfiles.isEmpty && !opening.gone && opening.title == appName, "\(model.settings.appProfiles.count)")
        let engine = ContextChecks.engine("openai", base: URL(string: "http://127.0.0.1:1")!)
        for (label, source, target, custom) in [("the base pair", "ja", "ko", false), ("the base pair and engine", "en", "de", true)] {
            start(source: source, target: target)
            if custom {
                model.settings.engines = [engine]
                model.settings.customEngineID = engine.id
            }
            let before = model.settings.effective(frontmost: app)
            let editor = AppMemoryEditor(bundleID: app, model: model, appName: appName)
            editor.setNote("Fantasy")
            let made = model.profile(for: app)
            let now = model.settings.effective(frontmost: app)
            check("a first edit creates a profile whose pair equals effective(frontmost:) while the app is in front (\(label))",
                  made?.source == before.sourceLanguage && made?.target == before.targetLanguage && made?.appName == appName && made?.note == "Fantasy"
                  && made?.customEngineID == nil && model.settings.appProfiles.count == 1
                  && now.sourceLanguage == before.sourceLanguage && now.targetLanguage == before.targetLanguage && now.customEngineID == before.customEngineID,
                  "profile \(made?.source ?? "nil")→\(made?.target ?? "nil"), effective \(now.sourceLanguage)→\(now.targetLanguage)")
        }
        start(source: "en", target: "de")
        let second = AppMemoryEditor(bundleID: app, model: model, appName: appName)
        second.setNote("one")
        let again = model.profile(for: app)
        second.setNote("two")
        check("a second edit keeps the profile it made, and a name added later does not make another",
              model.settings.appProfiles.count == 1 && model.profile(for: app)?.source == again?.source && model.profile(for: app)?.note == "two")

        // MARK: G2: the sheet, Pin and MCP set_memory make the profile through one function
        start(source: "ja", target: "ko", glossary: "勇者 = 용사")
        let (sheetApp, mcpApp, pinApp) = ("com.example.nameslens.sheet", "com.example.nameslens.mcp", "com.example.nameslens.pin")
        AppMemoryEditor(bundleID: sheetApp, model: model, appName: "Sheet").setNote("n")
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-nameslens-\(getpid())-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: scratch) }
        SettingsFileStore(url: scratch).save(model.settings)
        let world = MCPWorld(settingsURL: scratch, saved: { model.settings }, appName: { _ in nil })
        let result = try? MCPMemory.set(["app": mcpApp, "note": "n"], world)
        let file = SettingsFileCheck.read((try? Data(contentsOf: scratch)) ?? Data(), over: AppSettings()).settings
        var pinned = model.settings.appProfiles
        let pin = AppProfiles.pin(MemoryEntry(src: "Alice", dst: "앨리스", origin: .learned), bundleID: pinApp, appName: "Pin",
                                  creatingWith: model.settings.newProfilePair(for: pinApp), in: &pinned)
        /// What a profile is made of before its own memory: the pair and the engine.
        func languages(_ p: AppProfile?) -> LanguageChoice? { p?.languages }
        let sheetMade = model.profile(for: sheetApp), mcpMade = AppProfiles.profile(for: mcpApp, in: file.appProfiles), pinMade = AppProfiles.profile(for: pinApp, in: pinned)
        let expected = model.settings.newProfilePair(for: sheetApp)
        check("MCP set_memory, the sheet and Pin create profiles through one function: the same pair and engine, the one effective(frontmost:) gives",
              result?["created"] as? Bool == true && pin == .pinned && languages(sheetMade) == expected && languages(mcpMade) == expected
              && languages(pinMade) == expected && expected == LanguageChoice(source: "ja", target: "ko", customEngineID: nil),
              "sheet \(String(describing: languages(sheetMade))), mcp \(String(describing: languages(mcpMade))), pin \(String(describing: languages(pinMade)))")
        check("and each of them adds one profile and leaves the others as they were",
              model.settings.appProfiles.map(\.bundleID) == [sheetApp] && file.appProfiles.map(\.bundleID) == [sheetApp, mcpApp]
              && pinned.map(\.bundleID) == [sheetApp, pinApp])
        return failed
    }
}
#endif
