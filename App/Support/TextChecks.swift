#if !MAS
import AppKit
import AppIntents
import MwoyeoCore
import MwoyeoEngines
import SwiftUI

/// The checks of Translate Text (round text117; docs/design/text-translation.md), run by `--capture-ui … check-logic` and alone by
/// `text-checks`: the window's model end to end through the mock engine (a profile's names reach the engine, the shape of the text comes
/// back, the picks and the triggers), the Services entry and the Shortcuts action, and the controls as an assistive app asks for them.
///
/// Apple Translation does not answer to a check that holds the main queue (`MCPChecks`), so where the engine is Apple the call to the service
/// is stubbed and what the window does around it is checked. Each check was shown FAIL on a stub or a mutation of the code it guards (the
/// round report lists the lines). Only counts and names are printed.
@MainActor
enum TextChecks {
    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            say(what, ok, ok ? "" : note())
            if !ok { failed += 1 }
        }
        let saved = model.settings, savedFront = model.frontmostBundleID
        defer {
            model.settings = saved
            model.frontmostBundleID = savedFront
            TextTranslationWindow.shared.close()
        }

        // MARK: the entries that need no engine
        check("Translate Text is a shortcut action with no default key, after the others (so the ids of the registered ones stay)",
              HotKeyAction.translateText.rawValue == "translateText" && HotKeyAction.defaults["translateText"] == nil && HotKeyAction.allCases.last == .translateText
              && HotKeyAction.addLens.id == "addLens" && HotKeyAction.allCases.firstIndex(of: .readAloud) == HotKeyAction.allCases.count - 2)
        let file = SettingsFileCheck.read(Data(#"{"shortcuts": {"translateText": {"keyCode": 17, "modifiers": 4096, "display": "⌃T"}}}"#.utf8), over: AppSettings())
        let wrong = SettingsFileCheck.read(Data(#"{"shortcuts": {"translateTxt": {"keyCode": 17, "modifiers": 4096, "display": "⌃T"}}}"#.utf8), over: AppSettings())
        check("settings.json takes shortcuts.translateText and refuses a name that is not an action",
              file.issues.isEmpty && file.settings.shortcuts["translateText"]?.display == "⌃T" && !wrong.issues.isEmpty, file.issues.map(\.message).joined(separator: "; "))
        check("a language is found by code, by name in English or in its own words, and a code without a region finds the region the app offers; a name that is none finds nothing",
              Languages.code(for: "ko") == "ko" && Languages.code(for: "Korean") == "ko" && Languages.code(for: "한국어") == "ko" && Languages.code(for: " JAPANESE ") == "ja"
              && Languages.code(for: "zh-Hant") == "zh-Hant" && Languages.code(for: "pt") == "pt-BR" && Languages.code(for: "Klingon") == nil && Languages.code(for: "") == nil)

        let info = Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]] ?? []
        let entry = info.first { ($0["NSMessage"] as? String) == ServicesProvider.message }
        check("the built Info.plist declares the Services entry: its title, its message, the app's port and plain text in",
              entry.map { ($0["NSMenuItem"] as? [String: String])?["default"] == "Translate with Mwoyeo" && ($0["NSPortName"] as? String) == "Mwoyeo"
                  && ($0["NSSendTypes"] as? [String])?.contains("NSStringPboardType") == true && ($0["NSSendTypes"] as? [String])?.contains("public.utf8-plain-text") == true } == true,
              "\(info)")
        ServicesProvider.register()
        check("the app's services provider answers the entry's message, and the app holds it",
              (NSApp.servicesProvider as AnyObject) === ServicesProvider.shared && ServicesProvider.shared.responds(to: NSSelectorFromString("\(ServicesProvider.message):userData:error:")))
        let titles = ["ko", "ja", "de"].compactMap { language in
            Bundle.main.path(forResource: "InfoPlist", ofType: "strings", inDirectory: nil, forLocalization: language)
                .flatMap { NSDictionary(contentsOfFile: $0) as? [String: String] }?["Translate with Mwoyeo"]
        }
        check("the service's title is translated in the Info.plist's own table", titles.count == 3 && titles.allSatisfy { $0 != "Translate with Mwoyeo" && !$0.isEmpty }, "\(titles)")

        // MARK: through the engine
        guard let mock = ContextChecks.Mock(mode: "ok", flags: "native") else {
            check("the mock server starts", false)
            return failed
        }
        defer { mock.stop() }
        let engine = ContextChecks.engine("openai", base: mock.base)
        let alice = MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f)
        let carol = MemoryEntry(src: "Carol", dst: "캐롤", kind: .person)
        let chat = ContextChecks.profile(ContextChecks.chat, entries: [alice], note: "casual chat between friends")
        let cast = AppProfile(bundleID: "cast", appName: "Cast", source: "en", target: "ko", note: "Formal cast.", entries: [carol], id: "cast", when: [])
        var live = ContextChecks.settings(engine, profiles: [chat, cast])
        let secrets = MemorySecrets([engine.id: "dummy"])
        let translator = TextTranslator(settings: { live }, secrets: { secrets })
        let window = TextTranslationModel(translator: translator, settings: { live }, pause: TypingPause(delay: 0))
        window.anchor(to: ContextChecks.chat)

        /// The model's state once it has stopped working: polled to a bound (a bound is no wait, the poll ends the moment it is settled).
        func settled(_ m: TextTranslationModel, bound: Double = 25) async {
            for _ in 0..<Int(bound * 50) {
                switch m.phase {
                case .working, .typing: try? await Task.sleep(for: .milliseconds(20))
                default: return
                }
            }
        }
        func sent(since count: Int) -> String { mock.bodies.dropFirst(count).joined(separator: "\n") }

        // The shape of the text, the names of the profile in front, and who is asked when.
        let text = "Alice sent a photo\n\n  Second paragraph here\nAlice sent a photo"
        var before = mock.bodies.count
        window.source = text
        check("with an added engine a typed text is not sent: the window waits for the person to ask",
              window.trigger == .onRequest && window.phase == .edited && mock.bodies.count == before, "\(window.phase) \(window.trigger)")
        window.translateNow()
        await settled(window)
        var lines = window.translation.components(separatedBy: "\n")
        var body = sent(since: before)
        check("asked, it translates each paragraph through the lens's path and puts the translations between the gaps of the source: the blank line, the indent and the repeated paragraph",
              window.phase == .done(engine: engine.name) && lines.count == 4 && lines[0].contains("Alice sent a photo") && lines[0].contains("번역") && lines[1].isEmpty
              && lines[2].hasPrefix("  ") && lines[2].contains("Second paragraph here") && lines[3] == lines[0], "\(window.phase) \(lines)")
        check("the profile of the app in front applies as on a lens: its names and its note went to the engine, with each paragraph once",
              body.contains("앨리스") && body.contains("casual chat between friends") && body.components(separatedBy: "Second paragraph here").count == 2, String(body.prefix(240)))

        before = mock.bodies.count
        window.source = "Carol waved"
        window.profile = "cast"
        check("picking a profile in the window waits to be asked, and shows the profile's own name", window.phase == .edited && window.resolved?.profile?.id == "cast")
        window.translateNow()
        await settled(window)
        body = sent(since: before)
        check("a profile picked by hand is a lens pinned to it: its names and note go to the engine, the app's own do not",
              window.phase == .done(engine: engine.name) && body.contains("캐롤") && body.contains("Formal cast.") && !body.contains("앨리스"), String(body.prefix(240)))
        window.profile = AppProfile.allAppsID
        check("All Apps Only is a pick too: the chain is All apps alone", window.resolved?.profile == nil && window.resolved?.target == "ko")
        let allApps = TextTranslation.Request(profile: AppProfile.allAppsID)
        check("`all` is a profile a person may pick and an agent may not: list_apps and test_rules have no such id",
              (try? TextTranslation.resolve(allApps, base: live, asker: .person, secrets: secrets)) != nil && (try? TextTranslation.resolve(allApps, base: live, asker: .agent, secrets: secrets)) == nil)

        window.profile = nil
        window.targetLanguage = "ja"
        before = mock.bodies.count
        window.translateNow()
        await settled(window)
        body = sent(since: before)
        check("a language picked in the window reaches the engine and is the window's own: the settings keep theirs",
              window.translation.contains("翻訳") && !window.translation.contains("번역") && body.contains("Japanese") && live.targetLanguage == "ko" && window.resolved?.target == "ja",
              "\(window.translation) \(body.prefix(200))")
        window.profile = "cast"
        check("a new profile takes the picked languages back to the profile's", window.targetLanguage == nil && window.sourceLanguage == nil && window.resolved?.target == "ko")
        window.profile = nil

        window.engineChoice = "apple"
        check("an Apple engine picked over an added one translates by itself again: the trigger follows the engine", window.trigger == .onPause && window.phase == .typing)
        window.source = ""
        check("emptying the source empties the window and ends the wait", window.phase == .empty && window.translation.isEmpty)
        window.engineChoice = nil

        // The window keeps and reuses one service while the settings are the same (the first call may make it: what came before was under others).
        window.source = "Alice sent a photo"
        window.translateNow()
        await settled(window)
        let made = translator.made, reused = translator.reused
        window.translateNow()
        await settled(window)
        check("the window keeps its service while the settings are equal: translating again makes none", translator.made == made && translator.reused == reused + 1, "\(made) \(translator.made) \(reused) \(translator.reused)")
        live.appProfiles[0].note = "a note written meanwhile"
        before = mock.bodies.count
        window.translateNow()
        await settled(window)
        check("a change of the profile's memory makes a new service, which the engine is sent the new note by",
              translator.made == made + 1 && sent(since: before).contains("a note written meanwhile"), "\(made) \(translator.made) \(sent(since: before).prefix(200))")
        live.appProfiles[0].note = "casual chat between friends"

        // A long text: the units, the progress, and the limits.
        let long = (1...60).map { "Paragraph number \($0) of the long text" }.joined(separator: "\n\n")
        before = mock.bodies.count
        window.source = long
        var steps: [Int] = []
        let outcome = try? await translator.translate(long, window.requestForChecks) { done, total, _ in if total == 60 { steps.append(done) } }
        check("sixty paragraphs are sixty units, each translated, with the blank lines kept, and progress is told as they come back",
              outcome?.units == 60 && outcome?.translatedUnits == 60 && outcome?.text.components(separatedBy: "\n\n").count == 60 && steps.contains(60) && (steps.max() ?? 0) <= 60,
              "\(String(describing: outcome?.units)) \(String(describing: outcome?.translatedUnits)) \(steps.count)")
        let sentences = (1...45).map { "This is sentence number \($0) of one very long line." }.joined(separator: " ")
        let one = try? await translator.translate(sentences, window.requestForChecks)
        check("one line over a thousand characters is cut at sentence ends: more than one unit, and its translations are put back with the spaces",
              sentences.count > 1_000 && (one?.units ?? 0) >= 2 && one?.translatedUnits == one?.units && one?.text.contains("sentence number 45") == true, "\(String(describing: one?.units))")
        before = mock.bodies.count
        window.source = String(repeating: "word ", count: 11_000)
        window.translateNow()
        check("a text over fifty thousand characters is not sent, and the window says so",
              window.phase == .tooLong(55_000) && mock.bodies.count == before, "\(window.phase)")
        window.source = ""

        // Packs and failures say what they are: the image window's states, on the same owner.
        let apple = ContextChecks.settings(nil)
        let stubbed = TextTranslator(settings: { apple }, secrets: { secrets })
        var calls: [[String]] = [], engines: [String?] = []
        var next: TextTranslation.Answer?
        stubbed.call = { lines, resolved, _, _, onResult in
            calls.append(lines)
            engines.append(resolved.engine?.name)
            if let next { return next }
            for line in lines { onResult?(line, "«\(line)»") }
            return TextTranslation.Answer(rows: lines.map { .init(translation: "«\($0)»", engine: "Apple") }, translated: true, issue: nil, profile: nil, memory: nil)
        }
        let typing = TextTranslationModel(translator: stubbed, settings: { apple }, pause: TypingPause(delay: 0))
        typing.source = "a"
        check("with Apple a typed text is waited for: the phase says so at once", typing.trigger == .onPause && typing.phase == .typing)
        typing.source = "ab"
        typing.source = "abc"
        await settled(typing)
        check("a burst of keystrokes is one translation of what was typed last, by the Apple engine, with no engine of the settings",
              calls == [["abc"]] && engines == [nil] && typing.translation == "«abc»" && typing.phase == .done(engine: "Apple"), "\(calls) \(typing.phase)")
        next = TextTranslation.Answer(rows: [.init(translation: nil, engine: nil)], translated: false, issue: .languagePackMissing(source: "en", target: "ko"), profile: nil, memory: nil)
        typing.source = "needs a pack"
        typing.translateNow()
        await settled(typing)
        check("a missing language pack is the window's state with the pair named, and nothing is shown as translated", typing.phase == .needsPack(PackPair(source: "en", target: "ko")) && typing.translation.isEmpty, "\(typing.phase)")
        next = TextTranslation.Answer(rows: [.init(translation: nil, engine: nil)], translated: false, issue: .unsupportedPair(source: "ko", target: "ko"), profile: nil, memory: nil)
        typing.translateNow()
        await settled(typing)
        check("a pair with no translation is its own state", typing.phase == .unsupported(PackPair(source: "ko", target: "ko")), "\(typing.phase)")
        next = TextTranslation.Answer(rows: [.init(translation: nil, engine: nil)], translated: false, issue: .failed("the engine said no"), profile: nil, memory: nil)
        typing.translateNow()
        await settled(typing)
        check("another failure says the service's words", typing.phase == .failed(TranslationIssue.failed("the engine said no").message), "\(typing.phase)")

        // MARK: Services and Shortcuts, in the app's own settings
        model.settings = live
        model.frontmostBundleID = ContextChecks.chat
        try? model.secrets.setSecret("dummy", for: engine.id)
        defer { try? model.secrets.setSecret(nil, for: engine.id) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.midagedev.mwoyeo.text-checks"))
        pasteboard.clearContents()
        pasteboard.setString("Alice sent a service photo", forType: .string)
        var failure: NSString = ""
        before = mock.bodies.count
        ServicesProvider.shared.translateSelection(pasteboard, userData: "", error: &failure)
        let shown = TextTranslationWindow.shared.model
        await settled(shown)
        for _ in 0..<500 where shown.phase == .edited || shown.phase == .empty { try? await Task.sleep(for: .milliseconds(20)); await settled(shown) }
        body = sent(since: before)
        check("the Services entry opens the window with the selection and translates it at once, with an added engine too, under the profile of the app it came from",
              TextTranslationWindow.shared.isShown && shown.source == "Alice sent a service photo" && shown.translation.contains("Alice sent a service photo") && shown.translation.contains("번역")
              && body.contains("앨리스"), "\(shown.phase) \(shown.translation)")
        TextTranslationWindow.shared.close()

        let viaTranslator = try? await TranslateTextIntent.translate("Alice sent an intent photo", into: "Japanese", with: translator)
        check("the Shortcuts action translates into the language it is given, by name", viaTranslator?.contains("Alice sent an intent photo") == true && viaTranslator?.contains("翻訳") == true, viaTranslator ?? "nil")
        var intent = TranslateTextIntent()
        intent.text = "Alice sent a shortcut photo"
        before = mock.bodies.count
        let performed = try? await intent.perform()
        check("with no language it is the settings' own, through the app's translator", performed?.value?.contains("번역") == true && performed?.value?.contains("Alice sent a shortcut photo") == true, "\(String(describing: performed?.value))")
        var unknown = false
        do { _ = try await TranslateTextIntent.translate("x", into: "Klingon", with: translator) } catch is TranslateTextIntent.Failure { unknown = true } catch {}
        check("a language the action does not know is an error in words, and nothing is sent", unknown && mock.bodies.count == before + 1, "\(mock.bodies.count - before)")

        failed += await controls(model, engine: engine)
        return failed
    }

    private static func say(_ what: String, _ ok: Bool, _ note: String) {
        print("check-logic: \(ok ? "PASS" : "FAIL") text: \(what)" + (ok || note.isEmpty ? "" : " [\(note)]"))
    }

    // MARK: the controls

    /// The window as an assistive app asks for it: every control is named and answers `AXPress`, the panes are named text areas, and pressing Translate and
    /// Copy does what a click does.
    private static func controls(_ model: AppModel, engine: EngineConfig) async -> Int {
        guard AccessibilityChecks.canAsk else {
            print("check-logic: SKIP text: the controls of the window (this process may not ask the accessibility server)")
            return 0
        }
        var failed = 0
        func verify(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            say(what, ok, ok ? "" : note())
            if !ok { failed += 1 }
        }
        let apple = ContextChecks.settings(nil)
        let secrets = MemorySecrets()
        let translator = TextTranslator(settings: { apple }, secrets: { secrets })
        var asked = 0
        translator.call = { lines, _, _, _, _ in
            asked += 1
            return TextTranslation.Answer(rows: lines.map { .init(translation: "«\($0)»", engine: "Apple") }, translated: true, issue: nil, profile: nil, memory: nil)
        }
        let saved = model.settings
        defer { model.settings = saved }
        model.settings.engines = [engine]
        model.settings.appProfiles = [ContextChecks.profile(ContextChecks.chat)]
        let window = TextTranslationModel(translator: translator, settings: { apple }, pause: TypingPause(delay: 60))
        let view = TextTranslationView(model: window)
        let w = AccessibilityChecks.window(view, size: CGSize(width: 840, height: 460), model: model, name: "text-window")
        defer { w.orderOut(nil) }
        let title = w.title
        func tree(until done: ([AccessibilityChecks.Item]) -> Bool) async -> [AccessibilityChecks.Item] {
            var items = await AccessibilityChecks.tree(ofWindowTitled: title)
            for _ in 0..<60 where !done(items) {
                try? await Task.sleep(for: .milliseconds(100))
                items = await AccessibilityChecks.tree(ofWindowTitled: title)
            }
            return items
        }
        func has(_ items: [AccessibilityChecks.Item], _ role: String, _ label: String) -> Bool { items.contains { $0.role == role && $0.label == label } }
        let translate = String(localized: "Translate"), copy = String(localized: "Copy")
        let source = String(localized: "Text to translate"), paneName = String(localized: "Translation")
        // The pane is not a button: in Korean "Translation" and the Translate button have the same word, so its name is looked for among what is not one.
        func pane(_ items: [AccessibilityChecks.Item]) -> Bool { items.contains { !["AXButton", "AXMenuButton", "AXPopUpButton"].contains($0.role) && $0.label == paneName } }
        let empty = await tree { has($0, "AXButton", translate) && has($0, "AXTextArea", source) }
        verify("the window's controls are named: the profile and the engine menus, the language bar, Copy, Translate, the source field and the translation pane",
               AccessibilityChecks.unlabeled(empty).isEmpty && has(empty, "AXButton", translate) && has(empty, "AXButton", copy) && has(empty, "AXTextArea", source)
               && pane(empty) && empty.contains { $0.label.hasPrefix(String(localized: "Profile: Auto").prefix(8)) }
               && (has(empty, "AXMenuButton", String(localized: "Translation engine")) || has(empty, "AXPopUpButton", String(localized: "Translation engine"))),
               empty.map { $0.line.trimmingCharacters(in: .whitespaces) }.joined(separator: " | "))
        verify("every button answers AXPress, and none is ambiguous with another", AccessibilityChecks.unpressable(empty).isEmpty && AccessibilityChecks.ambiguous(empty).isEmpty,
               "\(AccessibilityChecks.unpressable(empty).map(\.line)) \(AccessibilityChecks.ambiguous(empty))")
        verify("Copy and Translate are off while there is nothing to copy or translate",
               empty.first { $0.role == "AXButton" && $0.label == copy }?.enabled == false && empty.first { $0.role == "AXButton" && $0.label == translate }?.enabled == false)

        // Writes the source as an agent does (the field's value), then presses Translate.
        window.source = "Hello there"
        let ready = await tree { items in items.first { $0.role == "AXButton" && $0.label == translate }?.enabled == true }
        var answer: AXError?
        if let button = AccessibilityChecks.element(inWindowTitled: title, role: "AXButton", label: translate) {
            answer = AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
        for _ in 0..<200 where window.translation.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        verify("pressing Translate through the accessibility server translates the text: one call, the translation in the pane",
               ready.first { $0.label == translate }?.enabled == true && answer == .success && asked == 1 && window.translation == "«Hello there»", "\(String(describing: answer)) \(asked) \(window.translation)")
        let shown = await tree { items in items.contains { $0.role == "AXStaticText" && $0.value == "«Hello there»" } }
        verify("the translation pane is a named group that holds the translation as text a screen reader reads",
               shown.contains { $0.role == "AXStaticText" && $0.value == "«Hello there»" } && pane(shown),
               shown.map { $0.line.trimmingCharacters(in: .whitespaces) }.joined(separator: " | "))
        NSPasteboard.general.clearContents()
        var copied: AXError?
        if let button = AccessibilityChecks.element(inWindowTitled: title, role: "AXButton", label: copy) {
            copied = AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
        verify("pressing Copy puts the translation on the pasteboard", copied == .success && NSPasteboard.general.string(forType: .string) == "«Hello there»")
        NSPasteboard.general.clearContents()
        return failed
    }
}

extension TextTranslationModel {
    /// What the window asks for now, for the checks that ask the translator themselves.
    var requestForChecks: TextTranslation.Request { TextTranslation.Request(app: anchorApp) }
}
#endif
