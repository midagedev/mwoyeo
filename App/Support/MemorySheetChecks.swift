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

        // MARK: the profile row, and the one global switch
        let p = AppProfile(bundleID: "x", appName: "X", source: "en", target: "ko", note: "n",
                           entries: [MemoryEntry(src: "a", dst: "b"), MemoryEntry(src: "c", dst: "d"), MemoryEntry(src: "e", dst: "f")])
        // The words are the app's language (the plural is the catalog's); the structure is what is checked.
        let note = String(localized: "note"), names3 = String(localized: "\(3) names"), name1 = String(localized: "\(1) names")
        check("the profile row says ' · 3 names' with a note, nothing without memory, and the tooltip holds the text",
              AppMemorySummary.short(p) == "\(note) · \(names3)" && AppMemorySummary.short(AppProfile(bundleID: "y", appName: "Y", source: "en", target: "ko")) == nil
              && AppMemorySummary.short(AppProfile(bundleID: "y", appName: "Y", source: "en", target: "ko", entries: [MemoryEntry(src: "a", dst: "b")])) == name1
              && AppMemorySummary.short(AppProfile(bundleID: "y", appName: "Y", source: "en", target: "ko", note: "n")) == note
              && AppMemorySummary.full(p)?.contains("a → b") == true && AppMemorySummary.full(p)?.hasPrefix("n\n") == true,
              "\(AppMemorySummary.short(p) ?? "nil")")
        check("the Apple switch is offered only while a profile exists", !AppMemorySummary.showsAppleToggle(AppSettings())
              && AppMemorySummary.showsAppleToggle(model.settings))
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-memsheet-\(getpid())-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func fileKey() -> Bool? {
            SettingsFileStore(url: url).save(model.settings)
            return ((try? JSONSerialization.jsonObject(with: Data(contentsOf: url))) as? [String: Any])?["appleUsesPinnedTerms"] as? Bool
        }
        let toggle = AppMemorySummary.appleToggle(model)
        model.settings.appleUsesPinnedTerms = false
        check("the Apple switch is off by default and not in the file", toggle.wrappedValue == false && fileKey() == nil)
        toggle.wrappedValue = true
        check("turning it on writes `appleUsesPinnedTerms: true` to settings.json", model.settings.appleUsesPinnedTerms && fileKey() == true)
        toggle.wrappedValue = false
        check("turning it off takes the key out again", !model.settings.appleUsesPinnedTerms && fileKey() == nil)

        // MARK: forgetting the app closes the sheet
        let forgotten = AppMemoryEditor(bundleID: app, model: model)
        model.forgetProfile(app)
        forgotten.reconcile()
        check("forgetting the app while its sheet is open ends the sheet, and an edit never makes a profile",
              forgotten.gone && model.setMemoryNote("x", for: app) == .noProfile && model.profile(for: app) == nil)

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
#endif
