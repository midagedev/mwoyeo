#if !MAS
import AppKit
import MwoyeoCore
import MwoyeoEngines

/// The checks of the Memory sheet's logic (`AppMemoryEditor`), run by `--capture-ui … check-logic`: the same calls the sheet makes, through
/// `AppModel`, so through settings.json. The request side is end to end against `tools/mock-openai` (its `terms` mode teaches the app).
///
/// Each check was shown FAIL on a mutation of the code it guards (the round report lists them). No line of text is printed: only counts
/// and names; the lines of the mock requests carry `ContextChecks.sentinel`.
@MainActor
enum MemorySheetChecks {
    static let app = ContextChecks.chat

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") memory sheet: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        let saved = model.settings
        defer { model.settings = saved }
        model.settings.appProfiles = [AppProfile(bundleID: app, appName: "Example Chat", source: "en", target: "ko")]
        model.settings.engines = []
        model.settings.customEngineID = nil
        func entries() -> [MemoryEntry] { model.profile(for: app)?.entries ?? [] }

        // MARK: the caps are enforced at the field
        let ed = AppMemoryEditor(bundleID: app, model: model)
        ed.setNote(String(repeating: "x", count: AppMemoryEditor.maxNote + 100))
        check("the note field keeps \(AppMemoryEditor.maxNote) characters, in the sheet and in settings.json's profile",
              ed.note.count == AppProfile.maxNoteLength && model.profile(for: app)?.note.count == AppProfile.maxNoteLength,
              "field \(ed.note.count), profile \(model.profile(for: app)?.note.count ?? -1)")
        ed.setNote("")
        check("an emptied note is gone from the profile", model.profile(for: app)?.note == "" && ed.note.isEmpty)

        let first = ed.addRow()!
        ed.edit(first) { $0.src = "Haruka"; $0.dst = "하루카"; $0.note = String(repeating: "n", count: MemoryEntry.maxEntryNote + 20) }
        check("a name's note field keeps \(MemoryEntry.maxEntryNote) characters", ed.row(first)?.note.count == MemoryEntry.maxEntryNote
              && entries().first?.note.count == MemoryEntry.maxEntryNote, "\(ed.row(first)?.note.count ?? -1)")
        ed.edit(first) { $0.note = "" }

        // MARK: rows: a name is stored when it is complete
        let second = ed.addRow()!
        ed.edit(second) { $0.src = "Kenji" }
        check("a name with no translation is not stored, and says so", entries().count == 1 && ed.row(second)?.problem == .incomplete && ed.row(second)?.stored == nil)
        ed.edit(second) { $0.dst = "켄지" }
        check("it is stored the moment both fields are filled", entries().map(\.src) == ["Haruka", "Kenji"] && ed.row(second)?.problem == nil)
        ed.edit(second) { $0.src = "Kenji-kun" }
        check("a changed source replaces the row, it does not add one", entries().map(\.src) == ["Haruka", "Kenji-kun"], "\(entries().map(\.src))")
        let third = ed.addRow()!
        ed.edit(third) { $0.src = "haruka"; $0.dst = "다른" }
        check("a name another row already has is not stored, and says so", entries().count == 2 && ed.row(third)?.problem == .duplicate
              && ed.row(first)?.stored?.dst == "하루카")
        ed.edit(third) { $0.src = "Mika" }
        check("fixing the name stores the row", entries().map(\.src) == ["Haruka", "Kenji-kun", "Mika"] && ed.row(third)?.problem == nil)
        ed.edit(third) { $0.dst = "" }
        check("clearing a translation takes the row out of the profile and keeps it on screen",
              entries().map(\.src) == ["Haruka", "Kenji-kun"] && ed.row(third) != nil && ed.row(third)?.problem == .incomplete)
        ed.removeRow(third)
        ed.removeRow(second)
        check("removing a row removes its name", entries().map(\.src) == ["Haruka"] && ed.rows.count == 1)
        ed.edit(first) { r in
            r.addressing.append(AppMemoryEditor.AddressDraft(to: "Mary ", register: .formal))
            r.addressing.append(AppMemoryEditor.AddressDraft(to: "", register: .casual))
        }
        check("an addressing row keeps the space being typed, and a row with no name yet is not stored",
              ed.row(first)?.addressing.first?.to == "Mary " && entries().first?.addressing.map(\.to) == ["Mary"] && ed.row(first)?.addressing.count == 2)
        ed.edit(first) { $0.addressing = [] }

        // The cap of rows: no 41st row, and the profile holds exactly the cap.
        for i in 0..<(AppMemoryEditor.maxRows - ed.rows.count) {
            let id = ed.addRow()!
            ed.edit(id) { $0.src = "Name\(i)"; $0.dst = "이름\(i)" }
        }
        check("the sheet stops adding rows at \(AppMemoryEditor.maxRows), and the profile holds that many",
              ed.rows.count == AppMemoryEditor.maxRows && !ed.canAddRow && ed.addRow() == nil && entries().count == AppProfile.maxEntries
              && AppMemoryEditor.maxRows == 40, "rows \(ed.rows.count), entries \(entries().count)")
        for r in ed.rows.dropFirst() { ed.removeRow(r.id) }

        // MARK: the sheet follows the file
        model.settings.appProfiles[0].entries = [MemoryEntry(src: "Alice", dst: "앨리스", kind: .person), MemoryEntry(src: "Haruka", dst: "하루카")]
        model.settings.appProfiles[0].note = "set from the file"
        let draft = ed.addRow()!
        ed.edit(draft) { $0.src = "Draft" }
        ed.reconcile()
        check("an edit of settings.json shows in the sheet, a row being typed stays", ed.rows.compactMap(\.stored).map(\.src) == ["Alice", "Haruka"]
              && ed.row(draft) != nil && ed.note == "set from the file", "\(ed.rows.map(\.src)) \(ed.note)")
        ed.removeRow(draft)
        ed.setNote("typed ")
        ed.reconcile()
        check("reading back what the sheet wrote changes nothing (the trailing space typed stays)", ed.note == "typed " && ed.rows.count == 2)

        // MARK: the context choice
        ed.setContext(.nearby)
        check("Nearby is written as an override of nearby", model.profile(for: app)?.context == AppContextOverride(mode: .nearby) && ed.contextChoice == .nearby)
        ed.setContext(.conversation)
        ed.setEarlierLines(5)
        check("Conversation takes its line count (0 to 8) from the sheet", model.profile(for: app)?.context == AppContextOverride(mode: .conversation, previousLines: 5)
              && ed.earlierLines == 5 && ed.contextChoice == .conversation)
        ed.setEarlierLines(20)
        check("the line count stops at \(AppContextOverride.maxPreviousLines)", ed.earlierLines == AppContextOverride.maxPreviousLines)
        ed.setContext(.off)
        check("Off is an override of off", model.profile(for: app)?.context == AppContextOverride(mode: .off))
        ed.setContext(.follow)
        check("Follow the engine removes the override", model.profile(for: app)?.context == nil && ed.contextChoice == .follow)

        // MARK: the profile row's words, and the Apple switch that is gone (design §6.2, §10)
        let p = AppProfile(bundleID: "x", appName: "X", source: "en", target: "ko", note: "n",
                           entries: [MemoryEntry(src: "a", dst: "b"), MemoryEntry(src: "c", dst: "d"), MemoryEntry(src: "e", dst: "f")])
        // The words are the app's language (the plural is the catalog's); the structure is what is checked.
        let note = String(localized: "note"), names3 = String(localized: "\(3) names"), name1 = String(localized: "\(1) names")
        check("the profile row says 'note · 3 names' with a note, nothing without memory, and the tooltip holds the text",
              ProfileWords.memoryLine(p) == "\(note) · \(names3)" && ProfileWords.memoryLine(AppProfile(bundleID: "y", appName: "Y", source: "en", target: "ko")) == nil
              && ProfileWords.memoryLine(AppProfile(bundleID: "y", appName: "Y", source: "en", target: "ko", entries: [MemoryEntry(src: "a", dst: "b")])) == name1
              && ProfileWords.memoryLine(AppProfile(bundleID: "y", appName: "Y", source: "en", target: "ko", note: "n")) == note
              && ProfileWords.full(p)?.contains("a → b") == true && ProfileWords.full(p)?.hasPrefix("n\n") == true,
              "\(ProfileWords.memoryLine(p) ?? "nil")")
        // 2026-10-21 (round ui-all, design §6.2 and §10 A3): the two checks that stood here, "the Apple switch is offered only while a profile
        // exists" and "turning it on writes `appleUsesPinnedTerms: true`", guarded a switch the design removes ("The Apple switch goes"); a row's
        // `apply` and `glossaryApply` carry it now. Derivation: what they asserted is that the app never writes an old switch and writes the mode of a row
        // when it is not a hint; both are asserted below (the file has no `appleUsesPinnedTerms`, and `apply` is in the entry).
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-memsheet-\(getpid())-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func fileObject() -> [String: Any]? {
            SettingsFileStore(url: url).save(model.settings)
            return (try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any]
        }
        let applyRow = ed.addRow()!
        ed.edit(applyRow) { $0.src = "Aiko"; $0.dst = "아이코" }
        let file = fileObject()
        let fileRows = ((file?["profiles"] as? [[String: Any]])?.first?["entries"] as? [[String: Any]]) ?? []
        check("with Apple Translation in effect a new name of two characters is stored as Both and the file says so; the old switch key is never written",
              !ed.takesHints && ed.row(applyRow)?.apply == .both && fileRows.first { $0["src"] as? String == "Aiko" }?["apply"] as? String == "both"
              && file?["appleUsesPinnedTerms"] == nil,
              "apply \(String(describing: ed.row(applyRow)?.apply)), rows \(fileRows)")
        ed.removeRow(applyRow)

        // MARK: forgetting the app closes the sheet
        let forgotten = AppMemoryEditor(bundleID: app, model: model)
        model.forgetProfile(app)
        forgotten.reconcile()
        // 2026-10-21 (round nameslens, design names-and-context §3.2): this line used to add `&& model.setMemoryNote("x", for: app) == .noProfile`,
        // "an edit never makes a profile". The first edit makes it now (`AppSettings.ensuringProfile`), so the clause is gone with `.noProfile`;
        // the new rule is NamesLensChecks "a first edit creates a profile whose pair equals effective(frontmost:)". Derivation: the sheet
        // ends when the profile it showed is gone, which is what this still asserts.
        check("forgetting the app while its sheet is open ends the sheet",
              forgotten.gone && model.profile(for: app) == nil)

        failed += await learnedChecks(model)
        return failed
    }

    // MARK: learned rows, pin, start fresh, end to end

    private static func learnedChecks(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") memory sheet: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        guard let mock = ContextChecks.Mock(mode: "terms") else { check("the mock server starts", false); return failed }
        defer { mock.stop() }
        let line = ContextChecks.line
        let engine = ContextChecks.engine("openai", base: mock.base, context: EngineContext(enabled: true, previousLines: 2, useLearned: true))
        let note = "casual chat between friends"
        let alice = MemoryEntry(src: "Alice", dst: "앨리스", kind: .person, gender: .f)
        func setUp(note: String = note, entries: [MemoryEntry] = [alice]) async {
            model.settings.engines = [engine]
            model.settings.customEngineID = engine.id
            model.settings.sourceLanguage = "en"
            model.settings.targetLanguage = "ko"
            model.settings.appProfiles = [AppProfile(bundleID: app, appName: "Example Chat", source: "en", target: "ko", note: note, entries: entries)]
            model.settings = model.settings.convertedFromOldFields()   // the engine above carries 1.1.4's `context`: the converter makes it the amount (prof-file, 2026-10-21)
            await model.translator.update(settings: model.effectiveSettings)
        }
        func learn(_ names: [String]) async {
            for (i, name) in names.enumerated() {
                _ = await ContextChecks.send(mock, model.translator, [line("\(name) wrote line \(i)")], ContextChecks.lens(screen: []))
            }
        }
        func srcs(_ rows: [ContextMemory.LearnedRecord]) -> [String] { rows.map(\.entry.src).sorted() }

        await setUp()
        await model.translator.forgetLearned(for: app)
        let ed = AppMemoryEditor(bundleID: app, model: model)
        await learn(["Haruka", "Haruka", "Kenji"])
        await ed.refreshLearned()
        check("the sheet lists the learned rows, those seen twice usable and the one seen once waiting",
              srcs(ed.learned) == ["Haruka", "Kenji"] && ed.learned.first { $0.entry.src == "Haruka" }?.isUsable == true
              && ed.learned.first { $0.entry.src == "Kenji" }?.isUsable == false, "\(srcs(ed.learned))")

        // Pin: into settings.json's entries, out of the learned rows.
        let haruka = ed.learned.first { $0.entry.src == "Haruka" }!
        await ed.pin(haruka)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-memsheet-pin-\(getpid())-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        SettingsFileStore(url: url).save(model.settings)
        let read = SettingsFileCheck.read((try? Data(contentsOf: url)) ?? Data(), over: AppSettings())
        let inFile = read.settings.appProfiles.first { $0.bundleID == app }?.entries ?? []
        check("Pin moves a learned row into settings.json's entries as the user's own, and out of the learned rows",
              inFile.map(\.src).sorted() == ["Alice", "Haruka"] && inFile.allSatisfy { $0.origin == .user }
              && srcs(ed.learned) == ["Kenji"] && ed.rows.map(\.src).contains("Haruka"),
              "file \(inFile.map(\.src)), learned \(srcs(ed.learned)), rows \(ed.rows.map(\.src))")

        // Remove takes one row, Forget learned all of them; neither touches what the person wrote.
        await ed.removeLearned(ed.learned[0])
        check("Remove takes that learned row and nothing the person wrote", ed.learned.isEmpty && model.profile(for: app)?.entries.count == 2
              && model.profile(for: app)?.note == note)
        await learn(["Zed", "Zed", "Yuki", "Yuki", "Xena"])
        await ed.refreshLearned()
        let before = srcs(ed.learned)
        await ed.forgetLearned()
        check("Forget learned clears every learned row and keeps the note and the names",
              before == ["Xena", "Yuki", "Zed"] && ed.learned.isEmpty && model.profile(for: app)?.entries.count == 2 && model.profile(for: app)?.note == note,
              "before \(before)")

        // Pin at the cap says so and keeps the row.
        var full = (0..<AppProfile.maxEntries).map { MemoryEntry(src: "Fill\($0)", dst: "채움\($0)") }
        full[0] = alice
        await setUp(entries: full)
        await learn(["Wanda", "Wanda"])
        await ed.refreshLearned()
        let fullEditor = AppMemoryEditor(bundleID: app, model: model)
        await fullEditor.refreshLearned()
        await fullEditor.pin(fullEditor.learned[0])
        check("Pin at \(AppProfile.maxEntries) names says the profile is full and keeps the learned row",
              fullEditor.learnedNotice != nil && model.profile(for: app)?.entries.count == AppProfile.maxEntries && srcs(fullEditor.learned) == ["Wanda"],
              "\(fullEditor.learnedNotice ?? "nil")")
        await model.translator.forgetLearned(for: app)

        // Start fresh: the thread goes, the learned rows, the names and the note stay.
        await setUp()
        await learn(["Mika", "Mika"])
        let b1 = [line("Alice sent the first photo")], b2 = [line("Alice sent the second photo")]
        let screen = b1 + b2
        _ = await ContextChecks.send(mock, model.translator, b1, ContextChecks.lens(screen: screen))
        let (resumed, _, _) = await ContextChecks.send(mock, model.translator, b2, ContextChecks.lens(screen: screen))
        let fresh = AppMemoryEditor(bundleID: app, model: model)
        await fresh.refreshLearned()
        let learnedBefore = srcs(fresh.learned)
        fresh.confirmingFresh = true
        await fresh.startFresh()
        let (after, _, _) = await ContextChecks.send(mock, model.translator, [line("Alice sent the third photo")], ContextChecks.lens(screen: screen))
        await fresh.refreshLearned()
        check("Start fresh drops the conversation: the next request carries no earlier lines (it did before)",
              !resumed.before.isEmpty && after.before.isEmpty && !fresh.confirmingFresh, "before \(resumed.before.count), after \(after.before.count)")
        check("Start fresh keeps the learned rows, the names and the note", srcs(fresh.learned).contains("Mika") && learnedBefore.contains("Mika")
              && model.profile(for: app)?.entries == [alice] && model.profile(for: app)?.note == note && after.memory.first?.hasPrefix("Alice -> 앨리스") == true,
              "learned \(srcs(fresh.learned)), memory \(after.memory.count)")
        await model.translator.forgetLearned(for: app)

        // A profile the sheet emptied again sends the bytes of no profile (design §9: Off is today's request).
        let reference = ContextChecks.service(ContextChecks.settings(ContextChecks.engine("openai", base: mock.base), profiles: []))
        let (_, refBody, _) = await ContextChecks.send(mock, reference, b1, ContextChecks.lens(screen: screen))
        await setUp(note: "", entries: [])
        let emptied = AppMemoryEditor(bundleID: app, model: model)
        emptied.setNote("a note")
        let row = emptied.addRow()!
        emptied.edit(row) { $0.src = "Alice"; $0.dst = "앨리스" }
        emptied.setContext(.nearby)
        emptied.setNote("")
        emptied.removeRow(row)
        emptied.setContext(.follow)
        let off = ContextChecks.service(ContextChecks.settings(ContextChecks.engine("openai", base: mock.base), profiles: model.settings.appProfiles))
        let (_, offBody, _) = await ContextChecks.send(mock, off, b1, ContextChecks.lens(screen: screen))
        check("with a note, a name and a context choice written and then cleared in the sheet, and Context off, the request is byte-identical to no profile",
              refBody == offBody && model.profile(for: app)?.hasMemory == false && model.profile(for: app)?.context == nil && !offBody.contains("Document:"))
        return failed
    }
}

/// The checks of the profile screens (design names-and-context §6, round ui-all R4): the default path (§8: no profile, no added engine: no Profiles
/// section, no Profile item, no caption), the lens menu's Profile submenu and its per-lens pin (addendum A1), the profile sheet's three levels, and
/// the words of the rows. The menu is the real one (`RegionSession.contextMenu`) and the sheets are read through the accessibility tree.
///
/// Each check was shown FAIL on a mutation of the code it guards (the round report lists the lines). Only counts and names are printed.
@MainActor
enum ProfileUIChecks {
    static let app = "com.example.profileui"
    static let appName = "Emulator"

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") profile ui: \(what)" + (ok || note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        let saved = model.settings, savedOpen = model.openSettingsAction, savedTab = model.settingsTab
        defer {
            model.settings = saved
            model.openSettingsAction = savedOpen
            model.settingsTab = savedTab
            model.memoryTarget = nil
        }
        func start(_ profiles: [AppProfile] = []) {
            model.settings.sourceLanguage = "ja"
            model.settings.targetLanguage = "ko"
            model.settings.customEngineID = nil
            model.settings.engines = []
            model.settings.glossary = ""
            model.settings.profilePin = nil
            model.settings.appProfiles = profiles
            model.memoryTarget = nil
        }
        let names = [MemoryEntry(src: "ハク", dst: "하쿠", kind: .person, apply: .both), MemoryEntry(src: "月涙", dst: "달눈물", kind: .place)]
        let emulator = AppProfile(bundleID: app, appName: appName, source: "ja", target: "ko", note: "A game console.", entries: names)
        let game = AppProfile(bundleID: "", appName: "月涙譚", source: "ja", target: "ko", id: "tsukinamida", name: "月涙譚",
                              when: [ProfileCondition(app: app, titleContains: "月涙譚")])
        let preset = AppProfile(bundleID: "", appName: "Anime", source: "ja", target: "ko", id: "anime", name: "Anime", when: [])
        let read = LensWatch.Read(bundleID: app, appName: appName, title: "月涙譚 — 第二章")

        /// A lens's session over `read`, unanchored, and its menu; the config the session reports is kept.
        final class Reported { var config: RegionConfig? }
        func session(over read: LensWatch.Read?, reported: Reported = Reported()) -> RegionSession {
            var config = RegionConfig(name: "Safari", rect: CGRect(x: 200, y: 300, width: 360, height: 200))
            config.follow(nil)
            let s = RegionSession(config: config, settings: model.settings, translator: model.translator, inpainter: nil)
            s.appUnderLens = { _ in read }
            s.onConfigChange = { reported.config = $0 }
            return s
        }
        /// The one item of a lens menu that holds a submenu: "Profile: …".
        func profileItem(_ menu: NSMenu) -> NSMenuItem? { menu.items.first { $0.submenu != nil } }
        func click(_ item: NSMenuItem?) {
            if let item, let action = item.action { _ = NSApp.sendAction(action, to: item.target, from: item) }
        }

        // MARK: the default path (§8): nothing set up shows nothing of profiles
        start()
        let plain = session(over: read).contextMenu()
        check("with no profile the lens menu has no Profile item and no submenu at all", profileItem(plain) == nil && !plain.items.contains { $0.submenu != nil },
              plain.items.map(\.title).joined(separator: " | "))

        // MARK: the lens menu at L1
        start([emulator, game, preset])
        let reported = Reported()
        let lens = session(over: read, reported: reported)
        let menu = lens.contextMenu()
        let item = profileItem(menu)
        let memoryAt = menu.items.firstIndex { $0.title == String(localized: "Memory for \(String(localized: "月涙譚"))…") }
        check("with a profile the lens menu has one \"Profile: …\" item after Memory for …, naming the head of the lens's chain (the title profile first)",
              item?.title == String(localized: "Profile: \("月涙譚")") && memoryAt.map { menu.items.firstIndex(of: item!) == $0 + 1 } == true && menu.items.filter { $0.submenu != nil }.count == 1,
              menu.items.map(\.title).joined(separator: " | "))
        let subTitles = item?.submenu?.items.map { $0.isSeparatorItem ? "-" : $0.title } ?? []
        let expected = [String(localized: "Auto picks \("月涙譚"): \(String(localized: "title has “\("月涙譚")”"))"), String(localized: "Auto"), "-",
                        String(localized: "All Apps Only"), appName, "月涙譚", "Anime", "-", String(localized: "New Profile for This Window…"), String(localized: "New Profile…")]
        check("its submenu is one level: what Auto picks (dimmed), Auto, All Apps Only, the profiles, then the two ways to make one",
              subTitles == expected && item?.submenu?.items.allSatisfy { $0.submenu == nil } == true && item?.submenu?.items.first?.isEnabled == false, "\(subTitles)")
        let menuTitles = menu.items.map(\.title) + subTitles
        let leaked = menuTitles.first { t in t.range(of: "\\b(hint|replace|apply|chain|head|regex|mode)\\b", options: [.regularExpression, .caseInsensitive]) != nil }
        check("the lens menu and its Profile submenu say none of the words that stay in settings.json (hint, replace, apply, chain, head, regex, mode)", leaked == nil, leaked ?? "")
        check("Auto is checked while no pin is set, and \"New Profile for This Window…\" is live once the title is known",
              item?.submenu?.items.first { $0.title == String(localized: "Auto") }?.state == .on
              && item?.submenu?.items.first { $0.title == String(localized: "New Profile for This Window…") }?.isEnabled == true
              && profileItem(session(over: LensWatch.Read(bundleID: app, appName: appName, title: "")).contextMenu())?.submenu?
                  .items.first { $0.title == String(localized: "New Profile for This Window…") }?.isEnabled == false)

        // Long names: no line of the menu is over 48 characters (checklist §4.6), the names in it cut in the middle at 24.
        let wide = String(repeating: "W", count: 60)
        start([AppProfile(bundleID: "", appName: wide, source: "ja", target: "ko", id: "wide", name: wide, when: [ProfileCondition(app: app, titleContains: wide)]), emulator])
        let wideMenu = session(over: LensWatch.Read(bundleID: app, appName: wide, title: wide)).contextMenu()
        let wideLines = wideMenu.items.flatMap { [$0] + ($0.submenu?.items ?? []) }.map(\.title)
        check("with names of 60 characters no line of the lens menu or its Profile submenu is over 48 characters", wideLines.allSatisfy { $0.count <= 48 } && wideLines.count > 8,
              "\(wideLines.filter { $0.count > 48 })")
        start([emulator, game, preset])

        // MARK: A1: a choice pins this lens alone, through its own config
        click(item?.submenu?.items.first { $0.title == "Anime" })
        check("choosing a profile pins that lens (its config says so, and the lens reports it to be kept), not the menu bar's pin",
              lens.config.profilePin == "anime" && reported.config?.profilePin == "anime" && model.settings.profilePin == nil,
              "lens \(lens.config.profilePin ?? "nil"), reported \(reported.config?.profilePin ?? "nil"), bar \(model.settings.profilePin ?? "nil")")
        let pinned = profileItem(lens.contextMenu())
        check("the pinned lens's item says so, and the choice is checked", pinned?.title == String(localized: "Profile: \("Anime") (pinned)")
              && pinned?.submenu?.items.first { $0.title == "Anime" }?.state == .on && pinned?.submenu?.items.first { $0.title == String(localized: "Auto") }?.state == .off,
              pinned?.title ?? "nil")
        click(pinned?.submenu?.items.first { $0.title == String(localized: "All Apps Only") })
        check("All Apps Only pins the lens to the base, and the item says so", lens.config.profilePin == AppProfile.allAppsID
              && profileItem(lens.contextMenu())?.title == String(localized: "Profile: All Apps Only"))
        click(profileItem(lens.contextMenu())?.submenu?.items.first { $0.title == String(localized: "Auto") })
        check("Auto takes the pin off the lens", lens.config.profilePin == nil && profileItem(lens.contextMenu())?.title == item?.title)

        // MARK: the menu bar pins every lens and clears their own
        model.pinEveryLens("tsukinamida")
        let unpinned = session(over: read)
        check("the menu bar's choice is the file's pin: a lens with no pin of its own says every lens (a lens's own pin is cleared by the same call, through its session; "
              + "AppModel has no headless region to check that through)",
              model.settings.profilePin == "tsukinamida" && profileItem(unpinned.contextMenu())?.title == String(localized: "Profile: \("月涙譚") (every lens)"),
              "bar \(model.settings.profilePin ?? "nil")")
        let underBar = profileItem(unpinned.contextMenu())?.submenu?.items.first { $0.title == String(localized: "Auto") }
        check("while the bar pins every lens a lens with no pin of its own has Auto dimmed (it would change nothing); its own pin wins over the bar's",
              underBar?.isEnabled == false && ProfileWords.head(model.settings, bundleID: app, title: nil, lensPin: "anime").id == "anime"
              && ProfileWords.head(model.settings, bundleID: app, title: nil).id == "tsukinamida")
        model.pinEveryLens(nil)
        check("the bar's Auto returns every lens to Auto", model.settings.profilePin == nil)

        // MARK: the words of a row
        check("a row says where a profile is used: the app, the title in the app, a title alone, several apps, or by hand",
              ProfileWords.whereLine(emulator, in: [emulator, game]) == String(localized: "In \(appName)")
              && ProfileWords.whereLine(game, in: [emulator, game]) == String(localized: "“\("月涙譚")” in \(appName)")
              && ProfileWords.whereLine(AppProfile(bundleID: "", appName: "P", source: "ja", target: "ko", id: "p", name: "P",
                                                  when: [ProfileCondition(titleContains: "Preprint")]), in: []) == String(localized: "Title has “\("Preprint")”")
              && ProfileWords.whereLine(preset, in: []) == String(localized: "Picked by hand"),
              ProfileWords.whereLine(game, in: [emulator, game]))
        let long = String(repeating: "あ", count: 20) + String(repeating: "x", count: 20)
        let cut = ProfileWords.cut(long, at: 32)
        check("a name is cut in the middle at 32 characters, and a short one is not", cut.count == 32 && cut.contains("…") && cut.hasPrefix(String(long.prefix(16)))
              && ProfileWords.cut("Anime", at: 32) == "Anime", cut)
        check("a profile's memory reads \"note · 2 names\", and what removing it takes with it names only what it holds",
              ProfileWords.memoryLine(emulator) == "\(String(localized: "note")) · \(String(localized: "\(2) names"))"
              && ProfileWords.removeDetail(names: 0, hasNote: false) == nil && ProfileWords.removeDetail(names: 3, hasNote: true) != nil)
        check("the sheet starts on Customize only for a profile that uses more than one app condition, or is made by hand",
              !AppMemoryEditor.startsOpen(emulator, kind: .app) && AppMemoryEditor.startsOpen(game, kind: .profile) && AppMemoryEditor.startsOpen(preset, kind: .profile)
              && AppMemoryEditor.startsOpen(emulator, kind: .new))

        // MARK: a name's details: Use, with what each way costs (design §10)
        let costEditor = AppMemoryEditor(target: MemoryTarget(id: emulator.id, name: appName, kind: .profile), model: model)
        let costRow = costEditor.rows[0]
        let costs = EntryApply.allCases.map { costEditor.cost(of: $0, row: costRow) }
        check("the Use pop-up's items read Tell the translator · ≈ n tokens, Swap into the text · free, Both · ≈ n tokens",
              costs.count == 3 && costs[0].hasPrefix(String(localized: "Tell the translator")) && costs[0].contains(where: \.isNumber) && costs[1] == String(localized: "Swap into the text · free")
              && costs[2].hasPrefix(String(localized: "Both")) && costs[2].contains(where: \.isNumber), "\(costs)")

        // MARK: what the tabs and sheets draw (the accessibility tree)
        guard AccessibilityChecks.canAsk else {
            print("check-logic: SKIP profile ui: the screens as the window draws them (this process may not ask the accessibility server)")
            return failed
        }
        func words(_ items: [AccessibilityChecks.Item]) -> [String] { items.flatMap { [$0.label, $0.value] }.filter { !$0.isEmpty } }
        /// Where an element is named `label` in the tree (exactly, or as the first part of a row's "name, where it is used" label).
        func place(_ items: [AccessibilityChecks.Item], _ label: String) -> Int? {
            items.firstIndex { $0.label == label || $0.value == label || $0.label.hasPrefix(label + ", ") }
        }
        let internalWords = try? NSRegularExpression(pattern: "\\b(hint|replace|apply|chain|head|regex|mode)\\b", options: .caseInsensitive)
        func internalWord(_ items: [AccessibilityChecks.Item]) -> String? {
            words(items).first { w in internalWords?.firstMatch(in: w, range: NSRange(w.startIndex..., in: w)) != nil }
        }
        start()
        let bare = await AccessibilityChecks.hostedTree(TranslationSettings(), size: CGSize(width: 560, height: 1500), model: model, name: "profileui-default")
        check("Settings › Translation with no profile and no added engine has no Profiles section, no All apps row, no New Profile…",
              [String(localized: "Profiles"), String(localized: "All apps"), String(localized: "New Profile…")].allSatisfy { place(bare, $0) == nil }
              && place(bare, String(localized: "Glossary")) != nil && bare.count > 2, "\(words(bare).prefix(12))")
        let bareBar = await AccessibilityChecks.hostedTree(MenuPanel(), size: CGSize(width: 340, height: 400), model: model, name: "profileui-menu-default")
        check("the menu bar panel with no profile has no Profile caption", !words(bareBar).contains { $0.hasPrefix(String(localized: "Profile: Auto")) } && bareBar.count > 2)

        start([emulator, game, preset])
        let listed = await AccessibilityChecks.hostedTree(TranslationSettings(), size: CGSize(width: 560, height: 1500), model: model, name: "profileui-list")
        check("with profiles the Translation tab has Profiles: All apps first, each profile, then New Profile…",
              [place(listed, String(localized: "Profiles")), place(listed, String(localized: "All apps")), place(listed, appName), place(listed, "月涙譚"), place(listed, "Anime"),
               place(listed, String(localized: "New Profile…"))].compactMap { $0 }.count == 6
              && zip([place(listed, String(localized: "All apps")), place(listed, appName), place(listed, "月涙譚"), place(listed, "Anime"), place(listed, String(localized: "New Profile…"))].compactMap { $0 },
                     [place(listed, appName), place(listed, "月涙譚"), place(listed, "Anime"), place(listed, String(localized: "New Profile…"))].compactMap { $0 }).allSatisfy { $0 < $1 },
              "\(words(listed).prefix(30))")
        let longName = String(repeating: "あ", count: 20) + String(repeating: "x", count: 20)
        let more = [("long", longName), ("p5", "Profile 5"), ("p6", "Profile 6"), ("p7", "Profile 7"), ("p8", "Profile 8")]
            .map { AppProfile(bundleID: "", appName: $0.1, source: "ja", target: "ko", id: $0.0, name: $0.1, when: []) }
        model.settings.appProfiles = [emulator, game, preset] + more
        let eight = await AccessibilityChecks.hostedTree(TranslationSettings(), size: CGSize(width: 560, height: 1700), model: model, name: "profileui-eight")
        let shown = [appName, "月涙譚", "Anime", ProfileWords.cut(longName, at: 32), "Profile 5", "Profile 6"].map { place(eight, $0) }
        check("with eight profiles the list shows six rows, the long name cut in the middle within 32 characters, then \"Show All 8 Profiles\"; the other two wait",
              shown.allSatisfy { $0 != nil } && place(eight, "Profile 7") == nil && place(eight, "Profile 8") == nil && ProfileWords.cut(longName, at: 32).count <= 32
              && eight.contains { $0.role == "AXButton" && $0.label == String(localized: "Show All \(8) Profiles") }, "\(shown), \(eight.map(\.label).filter { $0.contains("Show") })")
        model.settings.appProfiles = [emulator, game, preset]
        check("the profile list says none of the words that stay in settings.json (hint, replace, apply, chain, head, regex, mode)", internalWord(listed) == nil, internalWord(listed) ?? "")
        let bar = await AccessibilityChecks.hostedTree(MenuPanel(), size: CGSize(width: 340, height: 400), model: model, name: "profileui-menu")
        check("the menu bar panel with a profile has the caption \"Profile: Auto\" as one menu", bar.contains { $0.label == String(localized: "Profile: Auto") }, "\(bar.map(\.line))")

        let l1 = await AccessibilityChecks.hostedTree(AppMemorySheet(target: MemoryTarget(id: emulator.id, name: appName, kind: .profile), model: model),
                                                      size: CGSize(width: 520, height: 640), model: model, name: "profileui-sheet-l1", settle: 2)
        let drawn = [String(localized: "When it’s used"), String(localized: "Languages"), String(localized: "Context"), String(localized: "Rewrites"), String(localized: "Script")]
        check("the profile sheet at L1: Names and terms first, Customize one collapsed row with a summary, and no condition, language, context, rewrite or script control drawn",
              place(l1, String(localized: "Names and terms")) != nil && l1.first { $0.label == String(localized: "Customize") }?.value.isEmpty == false
              && drawn.allSatisfy { place(l1, $0) == nil } && place(l1, String(localized: "Customize")).map { $0 > place(l1, String(localized: "Names and terms"))! } == true,
              "\(words(l1).prefix(24))")
        check("its bottom bar holds Done alone (Start Fresh and Forget only while they can act)",
              l1.filter { $0.role == "AXButton" && [String(localized: "Done"), String(localized: "Start Fresh")].contains($0.label) }.map(\.label) == [String(localized: "Done")])
        check("the L1 sheet says none of the words that stay in settings.json", internalWord(l1) == nil, internalWord(l1) ?? "")
        let l2 = await AccessibilityChecks.hostedTree(AppMemorySheet(target: MemoryTarget(id: "tsukinamida", name: "月涙譚", kind: .profile), model: model),
                                                      size: CGSize(width: 520, height: 1500), model: model, name: "profileui-sheet-l2", settle: 2)
        let order = [String(localized: "When it’s used"), String(localized: "Languages"), String(localized: "Context"), String(localized: "Rewrites"), String(localized: "Script")]
            .map { place(l2, $0) }
        check("with Customize open the sections come in order: When it’s used, Languages, Context, Rewrites, Script",
              order.allSatisfy { $0 != nil } && zip(order.compactMap { $0 }, order.compactMap { $0 }.dropFirst()).allSatisfy { $0 < $1 }, "\(order)")
        // ui-audit-1-1-5 10.1: with Apple Translation in effect (no engine added) Context offers no choice: it says what is sent (the picker is not drawn).
        let apple = String(localized: "\(String(localized: "Apple Translation")) gets only the line.")
        check("with no added engine the open sheet's Context says Apple Translation gets only the line, and draws no Context picker (ui-audit 10.1)",
              l2.contains { $0.value == apple || $0.label == apple } && !l2.contains { $0.role == "AXPopUpButton" && $0.label == String(localized: "Context") },
              "\(words(l2).filter { $0.contains("only the line") })")
        let unnamed = AccessibilityChecks.unlabeled(l1) + AccessibilityChecks.unlabeled(l2)
        check("every control of both sheets has a name a screen reader can say", unnamed.isEmpty && AccessibilityChecks.ambiguous(l1).isEmpty && AccessibilityChecks.ambiguous(l2).isEmpty,
              unnamed.map(\.line).joined(separator: "; "))
        return failed
    }
}

/// The checks of the rewrite editor (design rewrite-rules §7, round ui-all R9): the profile without rewrites shows one "Add Rewrite" and a collapsed Script
/// row (the round's gate), a row is stored only when it has something to find, the caps are at the field, the service is asked only while a pattern or a
/// script is there, errors come out with their line, and the Test turns a script the time limit cut off. The service is a fake here (the real one is
/// `RewriteChecks`'s, round R8); the editor's logic is the one the sheet calls.
///
/// Each check was shown FAIL on a mutation of the code it guards (the round report lists the lines). Only counts and names are printed.
@MainActor
enum RewriteUIChecks {
    /// A stand-in for `ScriptConnection`: counts what it is asked, answers what the check says.
    final class FakeService: RewriteService, @unchecked Sendable {
        var checks = 0
        var runs = 0
        var issues: [RewriteIssue] = []
        var outcome: @Sendable (RewriteStage, String, String) -> RewriteRun.Outcome = { _, text, _ in .text(text) }

        func regex(_ row: RewriteRow, on text: String, budgetMs: Double, waits: Bool) async -> RewriteRun { runs += 1; return RewriteRun(.text(text)) }
        func script(_ script: RewriteScript, stage: RewriteStage, text: String, src: String, context: RewriteContext, budgetMs: Double, waits: Bool) async -> RewriteRun {
            runs += 1
            return RewriteRun(outcome(stage, text, src))
        }
        func check(rows: [RewriteRow], script: RewriteScript?) async -> RewriteCheckResult { checks += 1; return RewriteCheckResult(issues: issues, defines: []) }
    }

    static let app = "com.example.rewriteui"

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") rewrite ui: \(what)" + (ok || note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        let saved = model.settings
        defer { model.settings = saved }
        model.settings.engines = []
        model.settings.customEngineID = nil
        model.settings.sourceLanguage = "ja"
        model.settings.targetLanguage = "ko"
        let profile = AppProfile(bundleID: app, appName: "Rewrite UI", source: "ja", target: "ko", entries: [MemoryEntry(src: "ハク", dst: "하쿠", apply: .both)])
        model.settings.appProfiles = [profile]
        model.settings.rewrites = []
        model.settings.script = nil
        func stored() -> AppProfile? { model.settings.appProfiles.first { $0.id == app } }
        func editor(_ fake: FakeService = FakeService(), target: MemoryTarget? = nil) -> AppMemoryEditor {
            let e = AppMemoryEditor(target: target ?? MemoryTarget(id: app, name: "Rewrite UI", kind: .profile), model: model)
            e.service = fake
            return e
        }

        // MARK: the table
        let fake = FakeService()
        let ed = editor(fake)
        check("a profile without rewrites has none, no pending row, no script, and its script row says Off",
              ed.rewrites.isEmpty && ed.pendingRewrite == nil && ed.script == nil && ed.scriptState == .off)
        await ed.check()
        check("the checks of a profile with no pattern and no script never ask the service", fake.checks == 0 && fake.runs == 0 && ed.rewriteIssues.isEmpty, "\(fake.checks)")
        ed.addRewrite()
        check("Add Rewrite makes one draft on the original, and stores nothing yet (an empty Find is not a row of the file)",
              ed.pendingRewrite?.stage == .before && ed.rewriteRows.count == 1 && stored()?.rewrites.isEmpty == true)
        ed.updateRewrite(at: 0) { $0.stage = .after }
        check("changing a draft's stage keeps it a draft: nothing is stored until it has something to find", ed.pendingRewrite?.stage == .after && stored()?.rewrites.isEmpty == true)
        ed.updateRewrite(at: 0) { $0.stage = .before }
        ed.updateRewrite(at: 0) { $0.find = "▼" }
        check("a draft is stored the moment its Find holds a character: plain, on, replacing with nothing",
              ed.pendingRewrite == nil && stored()?.rewrites == [RewriteRow(.before, "▼")] && ed.rewrites.count == 1)
        ed.updateRewrite(at: 0) { $0.stage = .after; $0.replace = String(repeating: "x", count: RewriteLimits.maxReplace + 30); $0.find = String(repeating: "f", count: RewriteLimits.findLength.upperBound + 30) }
        check("Find and Replace with are cut at 200 characters at the field, and the stage can change", stored()?.rewrites.first?.find.count == RewriteLimits.findLength.upperBound
              && stored()?.rewrites.first?.replace.count == RewriteLimits.maxReplace && stored()?.rewrites.first?.stage == .after)
        check("a row on the translation brings the particle caption, a table of originals does not", ed.rewritesTouchTranslation)
        ed.updateRewrite(at: 0) { $0.stage = .before }
        check("and it goes with the last Translation row", !ed.rewritesTouchTranslation)
        ed.updateRewrite(at: 0) { $0.find = "" }
        check("emptying a stored row's Find takes it out of the file and keeps it on screen as the draft", stored()?.rewrites.isEmpty == true && ed.pendingRewrite != nil && ed.rewriteRows.count == 1)
        ed.removeRewrite(at: 0)
        check("minus on a draft drops it", ed.pendingRewrite == nil && ed.rewriteRows.isEmpty)
        for n in 0..<RewriteLimits.maxRows {
            ed.addRewrite()
            ed.updateRewrite(at: n) { $0.find = "row\(n)" }
        }
        check("the table keeps \(RewriteLimits.maxRows) rows, and at the cap Add Rewrite is dimmed and adds none", ed.rewrites.count == RewriteLimits.maxRows && !ed.canAddRewrite
              && { ed.addRewrite(); return ed.pendingRewrite == nil && ed.rewriteRows.count == RewriteLimits.maxRows }(), "\(ed.rewrites.count)")
        ed.removeRewrite(at: 5)
        check("minus on a stored row removes that row and no other", ed.rewrites.count == RewriteLimits.maxRows - 1 && !ed.rewrites.contains { $0.find == "row5" } && ed.rewrites[5].find == "row6")
        for _ in 0..<ed.rewrites.count { ed.removeRewrite(at: 0) }

        // MARK: the checks come out under their row and the script
        ed.addRewrite()
        ed.updateRewrite(at: 0) { $0.find = "（[ぁ-ゖ]+"; $0.regex = true }
        fake.issues = [RewriteIssue(stage: .before, item: 0, message: "Invalid regular expression: missing )")]
        await ed.check()
        check("a regex row asks the service once, and a pattern that does not compile reads \"Pattern error: …\" under its row (no position: JavaScriptCore gives none)",
              fake.checks == 1 && ed.issueLine(forRow: 0) == String(localized: "Pattern error: \("Invalid regular expression: missing )")"), ed.issueLine(forRow: 0) ?? "nil")
        ed.updateRewrite(at: 0) { $0.regex = false }
        fake.issues = []
        await ed.check()
        check("turned plain again, the row asks nothing more and the error is gone", fake.checks == 1 && ed.issueLine(forRow: 0) == nil)
        ed.removeRewrite(at: 0)

        // MARK: the script
        ed.setScriptSource("function before(line, ctx) { return line }")
        check("a first draft of a script is written off: nothing runs until the person turns it on", stored()?.script == RewriteScript(source: "function before(line, ctx) { return line }", on: false)
              && ed.scriptState == .off)
        ed.setScriptOn(true)
        check("Run this script turns it on, and the row says On", stored()?.script?.on == true && ed.scriptState == .on)
        fake.issues = [RewriteIssue(stage: nil, item: RewriteIssue.script, line: 3, message: "Unexpected token '}'")]
        await ed.check()
        check("a script with a syntax error asks the service, reads \"Line 3: …\" under the editor, and the row says Error",
              fake.checks == 2 && ed.scriptIssueLine == String(localized: "Line \(3): \("Unexpected token '}'")") && ed.scriptState == .error, ed.scriptIssueLine ?? "nil")
        ed.setScriptSource(String(repeating: "x", count: RewriteLimits.maxScript + 50))
        check("the script is cut at 8,000 characters at the field", ed.script?.source.count == RewriteLimits.maxScript && ed.script?.on == true)
        ed.setScriptSource("")
        check("an emptied script is gone from the profile", stored()?.script == nil && ed.script == nil && ed.scriptState == .off)

        // MARK: Test: the sample goes through the script alone; a script the time limit cuts is turned off
        fake.issues = []
        ed.setScriptSource("function after(src, dst, ctx) { return dst + '!' }")
        ed.setScriptOn(true)
        fake.outcome = { stage, text, _ in .text(stage == .before ? text + "<" : text + ">") }
        ed.sample = "line"
        await ed.runTest()
        check("Test shows what before makes of the sample and what after makes of it (no translation: the sample itself), and runs nothing that is not the script",
              ed.testResult == ScriptTestResult(before: "line<", after: "line>", issue: nil) && fake.runs == 2, "\(String(describing: ed.testResult)), runs \(fake.runs)")
        fake.outcome = { _, _, _ in .timedOut }
        await ed.runTest()
        check("a script cut by the time limit is turned off, and the Test says so", stored()?.script?.on == false && ed.testResult?.issue == ScriptWords.turnedOff
              && ed.testResult?.issue != nil, "\(String(describing: ed.testResult))")
        fake.outcome = { _, _, _ in .failed(RewriteFailure("boom is not defined", line: 4, column: 7)) }
        ed.setScriptOn(true)
        await ed.runTest()
        check("a throw leaves the sample as it was, the script stays on, and the Test reads its line", stored()?.script?.on == true && ed.testResult?.before == "line"
              && ed.testResult?.issue == String(localized: "Line \(4): \("boom is not defined")"), "\(String(describing: ed.testResult))")
        fake.outcome = { stage, text, _ in .text(stage == .before ? text + "<" : text + ">") }
        let translated = editor(fake, target: MemoryTarget(id: app, name: "Rewrite UI", kind: .profile, lensSource: "src", lensTranslation: "shown"))
        await translated.runTest()
        check("with the lens's last translation the after side works on it, not on the sample", translated.testResult == ScriptTestResult(before: "src<", after: "shown>", issue: nil),
              "\(String(describing: translated.testResult))")
        let lensed = editor(fake, target: MemoryTarget(id: app, name: "Rewrite UI", kind: .profile, lensSource: "勇者（ゆうしゃ）", lensTranslation: "용사"))
        check("the Test's sample starts as the opening lens's last line", lensed.sample == "勇者（ゆうしゃ）")
        ed.setScriptSource("")

        // MARK: All apps keeps its own rules, in the settings
        let all = editor(target: .allApps)
        all.addRewrite()
        all.updateRewrite(at: 0) { $0.find = "..."; $0.replace = "…"; $0.stage = .after }
        all.setScriptSource("function before(l) { return l }")
        check("All apps' rows and script are the settings', and no profile gets them", model.settings.rewrites == [RewriteRow(.after, "...", "…")] && model.settings.script?.on == false
              && stored()?.rewrites.isEmpty == true && stored()?.script == nil)
        model.settings.rewrites = []
        model.settings.script = nil

        // MARK: the words
        var withRules = profile
        withRules.note = "n"
        withRules.rewrites = [RewriteRow(.before, "a"), RewriteRow(.after, "b")]
        withRules.script = RewriteScript(source: "x")
        check("a profile's row says \"note · 1 names · 2 rewrites · script\", and Customize's summary names the rules once set",
              ProfileWords.memoryLine(withRules) == [String(localized: "note"), String(localized: "\(1) names"), String(localized: "\(2) rewrites"), String(localized: "script")].joined(separator: " · ")
              && ProfileWords.rulesLine(rewrites: 0, script: false) == nil && ProfileWords.rulesLine(rewrites: 2, script: true) == "\(String(localized: "\(2) rewrites")) · \(String(localized: "script"))")
        check("a profile with rules starts with Customize open, one with none (and one app) does not", AppMemoryEditor.startsOpen(withRules, kind: .profile) && !AppMemoryEditor.startsOpen(profile, kind: .app))

        // MARK: what the sheet draws (the accessibility tree)
        guard AccessibilityChecks.canAsk else {
            print("check-logic: SKIP rewrite ui: the sheet as the window draws it (this process may not ask the accessibility server)")
            return failed
        }
        func buttons(_ items: [AccessibilityChecks.Item], _ label: String) -> Int { items.filter { $0.role == "AXButton" && $0.label == label }.count }
        let add = String(localized: "Add Rewrite")
        let target = MemoryTarget(id: app, name: "Rewrite UI", kind: .profile)
        let empty = await AccessibilityChecks.hostedTree(AppMemorySheet(target: target, model: model, height: 1100, customize: true), size: CGSize(width: 520, height: 1100), model: model,
                                                         name: "rewriteui-empty", settle: 2)
        let script = empty.first { $0.role == "AXButton" && $0.label == String(localized: "Script") }
        check("R9's gate: a profile without rewrites shows, inside Customize, one Add Rewrite button and the collapsed Script row (Off), and no editor",
              buttons(empty, add) == 1 && script?.value == String(localized: "Off") && !empty.contains { $0.label == String(localized: "Script text") }
              && !empty.contains { $0.label.contains(String(localized: "Text to find")) }, "\(buttons(empty, add)) add buttons, script \(script?.value ?? "nil")")
        let closed = await AccessibilityChecks.hostedTree(AppMemorySheet(target: target, model: model, customize: false), size: CGSize(width: 520, height: 640), model: model,
                                                          name: "rewriteui-closed", settle: 2)
        check("with Customize closed neither the button nor the Script row is drawn", buttons(closed, add) == 0 && !closed.contains { $0.label == String(localized: "Script") })

        var filled = withRules
        filled.rewrites = [RewriteRow(.before, "（[ぁ-ゖ]+）", "", regex: true), RewriteRow(.after, "...", "…")]
        model.settings.appProfiles = [filled]
        let table = await AccessibilityChecks.hostedTree(AppMemorySheet(target: target, model: model, height: 1300, customize: true, scriptOpen: true), size: CGSize(width: 520, height: 1300),
                                                         model: model, name: "rewriteui-filled", settle: 2)
        let finds = table.filter { $0.role == "AXTextField" && $0.label.contains(String(localized: "Text to find")) }.count
        let replaces = table.filter { $0.role == "AXTextField" && $0.label.contains(String(localized: "Replacement")) }.count
        let particle = String(localized: "Changing the translation can leave a wrong particle (은/는, 이/가) after a replaced word. Prefer “Swap into the text” on the name’s row.")
        check("a table with an After row: each row has Find and Replace with fields, a pattern switch and a minus, and the orange particle caption is there",
              finds == 2 && replaces == 2 && table.filter { $0.label == String(localized: "Pattern") }.count == 2
              && table.filter { $0.label == String(localized: "Remove this rewrite") }.count == 2 && table.contains { $0.value == particle || $0.label == particle },
              "finds \(finds), replaces \(replaces): \(table.map(\.line).filter { $0.contains("Find") || $0.contains("Replace") || $0.contains("Pattern") })")
        // ui-all A4 (vision pass, 2026-10-21): Find's layout priority left "Replace with" 12 pt and the ".*" switch clipped its label.
        func widths(_ label: String, role: String? = nil) -> [CGFloat] { table.filter { $0.label.contains(label) && (role == nil || $0.role == role) }.map(\.size.width) }
        let findWidths = widths(String(localized: "Text to find"), role: "AXTextField"), replaceWidths = widths(String(localized: "Replacement"), role: "AXTextField")
        let patternWidths = widths(String(localized: "Pattern"))
        check("a row's Find and Replace with share the width (within 4 pt, neither under 100 pt) and the pattern switch is 26 to 30 pt wide",
              findWidths.count == 2 && replaceWidths.count == 2 && zip(findWidths, replaceWidths).allSatisfy { abs($0 - $1) <= 4 && $0 >= 100 && $1 >= 100 }
              && !patternWidths.isEmpty && patternWidths.allSatisfy { (26...30).contains($0) }, "Find \(findWidths), Replace with \(replaceWidths), pattern \(patternWidths)")
        check("the open Script editor has its text area, the switch, the counter \"n / 8,000\", the sample line and Test",
              table.contains { $0.label == String(localized: "Script text") } && table.contains { $0.label == String(localized: "Run this script") }
              && table.contains { ($0.value + $0.label).contains("1 / \(RewriteLimits.maxScript.formatted())") }
              && table.contains { $0.label == String(localized: "A line to test") } && buttons(table, String(localized: "Test")) == 1,
              "\(table.map(\.line).filter { $0.contains("Script") || $0.contains("Test") })")
        let area = table.first { $0.label == String(localized: "Script text") }
        check("the Script editor is at least 120 pt tall", (area?.size.height ?? 0) >= 120, "\(area?.size ?? .zero)")
        let unnamed = AccessibilityChecks.unlabeled(table) + AccessibilityChecks.unlabeled(empty)
        let words = table.flatMap { [$0.label, $0.value] }.filter { !$0.isEmpty }
        let regexWord = words.first { $0.range(of: "\\bregex\\b", options: [.regularExpression, .caseInsensitive]) != nil && !$0.contains("regular expression") }
        check("every control of the editor has a name, none is indistinguishable from another, and no label says regex (it is in help only)",
              unnamed.isEmpty && AccessibilityChecks.ambiguous(table).isEmpty && regexWord == nil, unnamed.map(\.line).joined(separator: "; ") + (regexWord ?? ""))
        return failed
    }
}
#endif
