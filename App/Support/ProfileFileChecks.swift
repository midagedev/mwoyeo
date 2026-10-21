#if !MAS
import Foundation
import MwoyeoCore

/// The checks of the profiles in settings.json (round prof-file, design names-and-context §5, §8's R3 row), run from `SettingsFileChecks`:
/// the restore columns of every key (§9), the new shape's round trip (a row's `apply` included), the strict errors of §5.3, the file of 1.1.4
/// read through the converter and kept once beside the new one (§5.2), `--check-settings` on both, and R3's own default-path gate: every
/// (engine, app) request a 1.1.4 file made is made again by the converted file, except the cases §5.2 lists by name.
@MainActor
enum ProfileFileChecks {
    /// One PASS/FAIL line, counted.
    final class Check {
        var failures = 0
        func callAsFunction(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") profile file: \(what)" + (ok ? "" : note().isEmpty ? "" : " [\(note())]"))
            if !ok { failures += 1 }
        }
    }

    static func run(dir: URL) -> Int {
        let check = Check()
        columns(check)
        roundTrip(check)
        strictErrors(check)
        oldShape(dir, check)
        defaultPath(check)
        lensPin(check)
        learnedPerHead(check)
        copy(check)
        return check.failures
    }

    // MARK: fixtures

    private static func lines(_ data: Data, _ over: AppSettings = AppSettings()) -> [String] {
        SettingsFileCheck.read(data, over: over).issues.map { $0.described(file: "settings.json") }
    }

    private static func json(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    private static let profile: [String: Any] = ["id": "a.b", "name": "A", "source": "ja", "target": "ko"]

    // MARK: §9: the restore columns

    private static func columns(_ check: Check) {
        let all = SettingSpec.all
        check("every key of the file has a tab and a nature (§9)", SettingSpec.missingRestoreColumns(all).isEmpty,
              "missing \(SettingSpec.missingRestoreColumns(all))")
        // FAIL-first: a key without either is named; the table's rows are the ones of §9.
        var without = all
        without[0].tab = nil
        without[1].nature = nil
        check("a key without a tab or without a nature fails, and is named",
              SettingSpec.missingRestoreColumns(without) == [all[0].key, all[1].key])
        func column(_ key: String) -> String { SettingSpec.spec(for: key).map { "\($0.tab?.rawValue ?? "-")/\($0.nature?.rawValue ?? "-")" } ?? "no spec" }
        check("§9's table: profiles, glossaryApply and engines are translation data; context and useLearned translation consent; the pin a translation preference",
              ["profiles", "glossaryApply", "engines", "glossary"].allSatisfy { column($0) == "translation/data" }
              && column("context") == "translation/consent" && column("useLearned") == "translation/consent" && column("profilePin") == "translation/preference"
              && column("savesTranscripts") == "general/consent" && column("checksForUpdates") == "about/consent" && column("shortcuts") == "shortcuts/preference")
        // Every key the app writes has a row, and every row names a key of the file (a typo in the table would otherwise hide).
        let written = Set(SettingsFileCheck.fileValues(fullyWritten(), omittingUnset: false).keys)
        check("every key the app writes has a row of the table and a spec, and every row of the table is a spec",
              written.allSatisfy { SettingSpec.columns[$0] != nil && SettingSpec.spec(for: $0) != nil } && SettingSpec.columns.keys.allSatisfy { SettingSpec.spec(for: $0) != nil },
              "\(written.filter { SettingSpec.columns[$0] == nil || SettingSpec.spec(for: $0) == nil }.sorted())")
    }

    /// Settings with every optional key set, so the keys the app can write are all in the file's view.
    private static func fullyWritten() -> AppSettings {
        var s = AppSettings()
        s.context = AppContextOverride(mode: .conversation, previousLines: 3)
        s.profilePin = "all"
        s.useLearned = true
        s.glossaryApply = .both
        s.customEngineID = UUID()
        return s
    }

    // MARK: the new shape

    /// A profile of each kind, rows of each mode, an engine with its permissions: everything the new shape holds.
    private static func newShape() -> AppSettings {
        var s = AppSettings()
        s.sourceLanguage = "ja"
        s.targetLanguage = "ko"
        let engine = EngineConfig(name: "Cloud Chat", kind: .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "claude-haiku-5-5", thinking: .off),
                                  allow: EngineAllow(lines: false, title: true, deepLInstructions: true))
        s.engines = [engine]
        s.customEngineID = engine.id
        s.context = AppContextOverride(mode: .conversation, previousLines: 3)
        s.useLearned = true
        s.glossary = "勇者 = 용사"
        s.glossaryApply = .both
        let rows = [MemoryEntry(src: "ハク", dst: "하쿠", kind: .person, apply: .both), MemoryEntry(src: "魔王", dst: "마왕"),
                    MemoryEntry(src: "村人", dst: "무라", kind: .person, apply: .replace)]
        s.appProfiles = [
            AppProfile(bundleID: "com.example.emu", appName: "Emulator", source: "ja", target: "ko"),
            AppProfile(bundleID: "com.example.emu", appName: "月涙譚", source: "ja", target: "ko", customEngineID: engine.id, note: "Fantasy.", entries: rows,
                       context: AppContextOverride(mode: .memory), id: "profile-1", when: [ProfileCondition(app: "com.example.emu", titleContains: "月涙譚")],
                       useLearned: false),
            AppProfile(bundleID: "anime", appName: "Anime", source: "ja", target: "ko", id: "anime", when: [], engine: ProfileEngine.apple),
        ]
        s.profilePin = "anime"
        return s
    }

    private static func roundTrip(_ check: Check) {
        let s = newShape()
        let data = SettingsFileFormat.render(s)
        let back = SettingsFileCheck.read(data, over: AppSettings())
        check("the new shape round-trips: profiles with conditions, rows of each apply mode, the amount, learning, the pin, glossaryApply and an engine's allow",
              back.settings == s && back.issues.isEmpty && !back.convertedFromOldShape,
              "issues \(back.issues.map(\.message)) equal \(back.settings == s)")
        let rows = back.settings.appProfiles.first { $0.id == "profile-1" }?.entries.map(\.apply)
        check("a row's apply survives settings → file → settings (it was dropped while the schema lacked the key)", rows == [.both, .hint, .replace], "\(String(describing: rows))")
        let text = String(decoding: data, as: UTF8.self)
        check("the file says profiles, and none of the keys of 1.1.4 (appProfiles, appleUsesPinnedTerms, an engine's context)",
              text.contains("\"profiles\"") && !text.contains("appProfiles") && !text.contains("appleUsesPinnedTerms") && !text.contains("\"enabled\""))
        let plain = String(decoding: SettingsFileFormat.render(AppSettings()), as: UTF8.self)
        check("a default settings file holds no new key but profiles (context, useLearned, profilePin and glossaryApply are written only when set)",
              plain.contains("\"profiles\": []") && !plain.contains("\"context\"") && !plain.contains("useLearned") && !plain.contains("profilePin") && !plain.contains("glossaryApply"))
        check("the schema lists the new keys with their rows, and the keys of 1.1.4 as deprecated",
              { () -> Bool in
                  guard let schema = try? JSONSerialization.jsonObject(with: SettingsSchema.data()) as? [String: Any], let props = schema["properties"] as? [String: [String: Any]] else { return false }
                  return ["profiles", "context", "useLearned", "profilePin", "glossaryApply"].allSatisfy { props[$0] != nil && props[$0]?["deprecated"] == nil }
                      && props["appProfiles"]?["deprecated"] as? Bool == true && props["appleUsesPinnedTerms"]?["deprecated"] as? Bool == true
              }())
    }

    // MARK: a lens's own pin (addendum A4)

    /// Two lenses over the same app, one pinned and one on Auto, have two chains (design §1.3: Auto or pinned per lens); the lens's pin lays
    /// over the file's, an `all` pin is All apps alone, and a pin that names a gone profile is Auto.
    private static func lensPin(_ check: Check) {
        let app = "com.example.emu"
        var s = AppSettings()
        s.sourceLanguage = "en"
        s.targetLanguage = "ko"
        s.appProfiles = [AppProfile(bundleID: app, appName: "Emulator", source: "ja", target: "ko", note: "the app's note"),
                         AppProfile(bundleID: "preset", appName: "Preset", source: "en", target: "de", note: "the preset's note", id: "preset", when: [])]
        func chain(_ pin: String?, over base: AppSettings) -> (ids: [String], pair: String, note: String) {
            let route = LensRoute(base: base, over: app, pin: pin)
            let merged = ContextRoute.pair(settings: route.settings, lens: app).chain
            return (merged.links.map(\.id), "\(route.settings.sourceLanguage)>\(route.settings.targetLanguage)", merged.note)
        }
        let auto = chain(nil, over: s), pinned = chain("preset", over: s), allOnly = chain("all", over: s), gone = chain("no-such-profile", over: s)
        check("two lenses over one app, one Auto and one pinned to a profile, have different chains: the pinned one's languages and note",
              auto.ids == [app, "all"] && auto.pair == "ja>ko" && pinned.ids == ["preset", "all"] && pinned.pair == "en>de" && pinned.note == "the preset's note"
              && auto.note == "the app's note", "\(auto) \(pinned)")
        check("a lens pinned to all is All apps alone: no profile of the app is used", allOnly.ids == ["all"] && allOnly.pair == "en>ko" && allOnly.note.isEmpty, "\(allOnly)")
        check("a lens pinned to a profile that is gone follows Auto", gone == auto, "\(gone)")
        var filePinned = s
        filePinned.profilePin = "preset"
        check("the file's pin is every lens's pin, and a lens's own lays over it: no lens pin follows the file, `all` and another id win",
              chain(nil, over: filePinned).ids == ["preset", "all"] && chain("all", over: filePinned).ids == ["all"] && chain(app, over: filePinned).ids == [app, "all"])
        // The lens is kept with the lens, leniently: a lens saved before the key, or one that holds a pin of the wrong type, is Auto, never lost.
        var config = RegionConfig(name: "Lens", rect: CGRect(x: 1, y: 2, width: 30, height: 40))
        config.profilePin = "preset"
        let saved = try? JSONEncoder().encode(config)
        let back = saved.flatMap { try? JSONDecoder().decode(RegionConfig.self, from: $0) }
        var object = ((saved.flatMap { try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any]) ?? [:]
        object["profilePin"] = nil
        let without = (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(RegionConfig.self, from: $0) }
        object["profilePin"] = 7
        let wrong = (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(RegionConfig.self, from: $0) }
        check("a lens keeps its pin; one saved without it, or with one of the wrong type, is Auto and is not lost",
              back == config && without?.profilePin == nil && without?.name == "Lens" && wrong?.profilePin == nil && wrong?.name == "Lens",
              "\(String(describing: back)) \(String(describing: without)) \(String(describing: wrong))")
    }

    // MARK: learned rows per head (§2.1 rule 3, §8 P7)

    /// Two games in one emulator are two profiles of the same app: what the engine's replies teach under one is kept, sent and saved under its
    /// id, never under the other's or the app's. With All apps as the head the rows are the app's, as in 1.1.4.
    private final class Told: @unchecked Sendable {
        private let lock = NSLock()
        private var apps: [String] = []
        func note(_ app: String) { lock.withLock { apps.append(app) } }
        var all: [String] { lock.withLock { apps } }
    }

    private static func learnedPerHead(_ check: Check) {
        let app = "com.example.emu"
        var s = AppSettings()
        s.useLearned = true
        s.appProfiles = [AppProfile(bundleID: app, appName: "月涙譚", source: "ja", target: "ko", id: "tale", when: [ProfileCondition(app: app, titleContains: "月涙譚")]),
                         AppProfile(bundleID: app, appName: "Star Tale", source: "ja", target: "ko", id: "star", when: [ProfileCondition(app: app, titleContains: "スターテイル")])]
        func chain(_ title: String?) -> MergedChain { ContextRoute.merged(settings: s, lens: app, title: title) }
        let pair = LanguagePair("ja", "ko"), on = ContextOptions(enabled: true, includeLearned: true)
        let reply = TranslationReply(lines: ["⟦ko⟧ 하쿠"], terms: [TermHint(src: "ハク", dst: "하쿠")], usage: TokenUsage(prompt: 1, completion: 1, cached: 0))
        var book = ContextBook()
        let told = Told()
        let lens = ContextChecks.lens(app, title: "月涙譚 — 第二章", id: "L1")
        let tale = book.begin(lens, chain: chain("月涙譚 — 第二章"), pair: pair, engineID: "e", now: 0)
        for _ in 0..<2 { book.finish(lens, pass: tale, items: ["ハクが来た"], reply: reply, used: [], options: on, glossary: []) }
        check("a name learned under one game is kept under that profile's id: not under the other game, not under the app",
              book.learned(for: "tale").count == 1 && book.learned(for: "star").isEmpty && book.learned(for: app).isEmpty,
              "tale \(book.learned(for: "tale").count) star \(book.learned(for: "star").count) app \(book.learned(for: app).count)")
        let star = book.begin(ContextChecks.lens(app, title: "スターテイル", id: "L2"), chain: chain("スターテイル"), pair: pair, engineID: "e", now: 1)
        func sent(_ pass: ContextBook.Pass, _ context: LensContext) -> [String] {
            book.request(context, pass: pass, items: ["x"], source: nil, target: "ko", glossary: []).memory.map(\.src)
        }
        let again = book.begin(lens, chain: chain("月涙譚 — 第二章"), pair: pair, engineID: "e", now: 2)
        check("the other game's request carries none of them, and the first game's carries the name", sent(star, ContextChecks.lens(app, title: "スターテイル", id: "L2")).isEmpty && sent(again, lens) == ["ハク"],
              "\(sent(star, lens)) \(sent(again, lens))")
        // With no profile matching, All apps is the head and the rows are the app's.
        var plain = ContextBook()
        plain.learnedChanged = { told.note($0) }
        let bare = ContextChecks.lens(app, title: "Settings", id: "L3")
        let none = plain.begin(bare, chain: chain("Settings"), pair: pair, engineID: "e", now: 0)
        for _ in 0..<2 { plain.finish(bare, pass: none, items: ["ハクが来た"], reply: reply, used: [], options: on, glossary: []) }
        check("with All apps as the head the rows are the app's, as in 1.1.4, and the book tells the app's key",
              plain.learned(for: app).count == 1 && plain.learned(for: "tale").isEmpty && told.all.contains(app) && told.all.allSatisfy { $0 == app }, "\(told.all)")
        let file = LearnedMemoryFile.fileName(for: "tale")
        check("the learned-memory file of a profile is named by its id, and an app's profile (id = bundle id) keeps the name 1.1.4 gave it",
              file == "tale.json" && LearnedMemoryFile.fileName(for: app) == "\(app).json" && chain(nil).learnedKey == app && chain("月涙譚").learnedKey == "tale")
    }

    // MARK: copy changed by this round (ui-audit)

    private static func copy(_ check: Check) {
        // Compared as the app shows it, in the language of the run: the English words are the keys.
        check("the Foundation Models choice says Apple Intelligence follows the glossary exactly (ui-audit)",
              TranslationEngineChoice.customModel.detail == String(localized: "Apple Intelligence follows your glossary exactly · for names in games and stories"),
              TranslationEngineChoice.customModel.detail)
        let both = LensMemoryMenu.forgetDetail(names: 3, hasNote: true), onlyNote = LensMemoryMenu.forgetDetail(names: 0, hasNote: true)
        let onlyNames = LensMemoryMenu.forgetDetail(names: 3, hasNote: false)
        check("the Forget alert says what goes: a note and names, the note alone when there are no names, the names alone when there is no note",
              Set([both, onlyNote, onlyNames]).count == 3 && both.contains("3") && onlyNames.contains("3") && !onlyNote.contains("3") && !onlyNote.contains("0"),
              "\(both) | \(onlyNote) | \(onlyNames)")
    }

    // MARK: §5.3's errors

    private static func strictErrors(_ check: Check) {
        func one(_ what: String, _ object: [String: Any], contains expected: String) {
            let got = lines(json(object))
            check(what, got.contains { $0.contains(expected) } && got.count == 1, "\(got)")
        }
        let tooMany = (0..<9).map { ["titleContains": "t\($0)"] }
        one("a bad condition is an exact line: an empty one needs app or titleContains, and is dropped",
            ["profiles": [profile.merging(["when": [["app": "x.y"], [String: String]()]]) { $1 }]], contains: "profiles[0].when[1]: needs app or titleContains; dropped")
        one("a 9th condition is reported, the first 8 apply",
            ["profiles": [profile.merging(["when": tooMany]) { $1 }]], contains: "profiles[0].when: 9 items; the limit is 8; the first 8 apply")
        one("an unknown apply names the row and the values", ["profiles": [profile.merging(["entries": [["src": "a", "dst": "b", "apply": "swap"]]]) { $1 }]],
            contains: "profiles[0].entries[0].apply: \"swap\" is not allowed; use one of hint, replace, both; ignored")
        one("a duplicate id drops the later profile", ["profiles": [profile, profile.merging(["name": "B"]) { $1 }]],
            contains: "profiles[1].id: id \"a.b\" is already used by item 0; dropped")
        one("the id all is All apps', and the profile is dropped", ["profiles": [profile.merging(["id": "all"]) { $1 }]],
            contains: "profiles[0].id: \"all\" is the id of All apps; a profile needs another; dropped")
        one("an id with a slash is not an id", ["profiles": [profile.merging(["id": "a/b"]) { $1 }]], contains: "profiles[0].id: \"a/b\" is not an id")
        one("a pin to no profile is reported and the pin is not applied", ["profiles": [profile], "profilePin": "nobody"],
            contains: "profilePin: no profile has the id \"nobody\"; keeping the current value")
        let pinned = SettingsFileCheck.read(json(["profiles": [profile], "profilePin": "a.b"]), over: AppSettings())
        check("a pin to a profile of the file, and the pin all, are accepted",
              pinned.issues.isEmpty && pinned.settings.profilePin == "a.b"
              && SettingsFileCheck.read(json(["profilePin": "all"]), over: AppSettings()).settings.profilePin == "all")
        one("a profile's engine is an id, apple or null: another word is reported",
            ["profiles": [profile.merging(["customEngineID": "the-big-one"]) { $1 }]], contains: "profiles[0].customEngineID: expected an engine id from engines, \"apple\", or null")
        one("a 51st profile is reported", ["profiles": (0..<51).map { ["id": "p\($0)", "source": "ja", "target": "ko"] }],
            contains: "profiles: 51 items; the limit is 50; the first 50 apply")
        one("an engine's allow is checked as a nested object", ["engines": [["kind": "deepL", "name": "D", "baseURL": "https://api.deepl.com", "allow": ["lines": "yes"]]]],
            contains: "engines[0].allow.lines: expected true or false, got a string; ignored")
        one("the amount names its modes, memory among them", ["context": ["mode": "all"]], contains: "context.mode: \"all\" is not allowed; use one of off, memory, nearby, conversation")
        // The mode that is new is read: a profile of mode memory.
        let memory = SettingsFileCheck.read(json(["profiles": [profile.merging(["context": ["mode": "memory"]]) { $1 }]]), over: AppSettings())
        check("a context of mode memory is accepted and read", memory.issues.isEmpty && memory.settings.appProfiles.first?.context?.mode == .memory)
    }

    // MARK: the file of 1.1.4

    /// A file of 1.1.4: two engines with their own context, an app profile with an override and names, the Apple switch on.
    private static func oldFile(applePins: Bool = true) -> Data {
        let x = EngineConfig(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!, name: "X",
                             kind: .openAICompatible(baseURL: URL(string: "http://localhost:1/v1")!, model: "m", thinking: .off, extraHeaders: [:]),
                             context: EngineContext(enabled: true, previousLines: 3, includeTitle: false, useLearned: true))
        let y = EngineConfig(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!, name: "Y",
                             kind: .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "claude-haiku-5-5", thinking: .off))
        let chat = AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "ja", target: "ko", note: "casual",
                              entries: [MemoryEntry(src: "ハク", dst: "하쿠", kind: .person)], context: AppContextOverride(mode: .off))
        guard let engines = try? JSONSerialization.jsonObject(with: JSONEncoder().encode([x, y])),
              let profiles = try? JSONSerialization.jsonObject(with: JSONEncoder().encode([chat])) else { return Data() }
        var object: [String: Any] = ["engines": engines, "customEngineID": x.id.uuidString, "appProfiles": profiles, "targetLanguage": "ko"]
        if applePins { object["appleUsesPinnedTerms"] = true }
        return json(object)
    }

    private static func oldShape(_ dir: URL, _ check: Check) {
        let data = oldFile()
        let read = SettingsFileCheck.read(data, over: AppSettings())
        let s = read.settings
        check("a file of 1.1.4 is converted on read: no issue, and it says so", read.issues.isEmpty && read.convertedFromOldShape, "\(read.issues.map(\.message))")
        check("the conversion follows §5.2: profiles (id = bundle id, one app condition), the amount from the engine in use, learning, the engines' allow, the Apple switch as both",
              s.appProfiles.map(\.id) == ["com.example.chat"] && s.appProfiles[0].when == [ProfileCondition(app: "com.example.chat")]
              && s.context == AppContextOverride(mode: .conversation, previousLines: 3) && s.useLearned
              && s.engines.allSatisfy { $0.context == nil } && s.glossaryApply == .both && s.appProfiles[0].entries.map(\.apply) == [.both],
              "context \(String(describing: s.context)) learned \(s.useLearned) apply \(s.glossaryApply)")
        let rendered = String(decoding: SettingsFileFormat.render(s), as: UTF8.self)
        check("what it writes back has none of the old keys", !rendered.contains("appProfiles") && !rendered.contains("appleUsesPinnedTerms") && !rendered.contains("\"enabled\""))
        check("a file in the new shape is not converted, and a file with no old key at all is not either",
              !SettingsFileCheck.read(SettingsFileFormat.render(s), over: AppSettings()).convertedFromOldShape && !SettingsFileCheck.read(json(["targetLanguage": "ko"]), over: AppSettings()).convertedFromOldShape)

        // --check-settings: the note, and the exit code of the issues.
        let folder = dir.appendingPathComponent("oldshape")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("settings.json")
        try? data.write(to: url)
        let (oldLines, oldCode) = SettingsFileCommand.check(url)
        check("--check-settings says a 1.1.4 file is converted on the next save, then ok, exit 0",
              oldLines.count == 2 && oldLines[0].contains("converted on the next save") && oldLines[0].contains(SettingsFileStore.oldShapeName) && oldLines[1] == "ok" && oldCode == 0,
              "\(oldLines) \(oldCode)")
        let fresh = folder.appendingPathComponent("new.json")
        try? SettingsFileFormat.render(newShape()).write(to: fresh)
        check("--check-settings on a file in the new shape is clean: ok", SettingsFileCommand.check(fresh).lines == ["ok"] && SettingsFileCommand.check(fresh).code == 0)
        let broken = folder.appendingPathComponent("bad.json")
        try? json(["profiles": [profile.merging(["when": [[String: String]()], "entries": [["src": "a", "dst": "b", "apply": "swap"]]]) { $1 }]]).write(to: broken)
        let (badLines, badCode) = SettingsFileCommand.check(broken)
        check("--check-settings on a bad profile prints one precise line per problem and exits 1",
              badCode == 1 && badLines.count == 2 && badLines.contains { $0.contains("when[0]: needs app or titleContains") } && badLines.contains { $0.contains("entries[0].apply: \"swap\" is not allowed") },
              "\(badLines)")

        // The first save in the new shape keeps the file of 1.1.4 beside it, once.
        let store = SettingsFileStore(url: url)
        let loaded = store.startup(fallback: AppSettings())
        let backup = folder.appendingPathComponent(SettingsFileStore.oldShapeName)
        check("the app reads the file of 1.1.4 and writes nothing yet", loaded.appProfiles.count == 1 && ((try? Data(contentsOf: url)) == data) && !FileManager.default.fileExists(atPath: backup.path))
        var edited = loaded
        edited.targetLanguage = "ja"
        store.save(edited)
        check("the first save writes the new shape and copies the old file beside it, byte for byte",
              (try? Data(contentsOf: backup)) == data && !SettingsFileCheck.isOldShape((try? Data(contentsOf: url)) ?? Data()) && String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self).contains("\"profiles\""))
        // The copy is kept as it is: a later save, and a file that is in the old shape again, do not overwrite it.
        try? data.write(to: url)
        try? json(["marker": 1]).write(to: backup)
        edited.targetLanguage = "en"
        let again = SettingsFileStore(url: url)
        _ = again.startup(fallback: AppSettings())
        again.save(edited)
        check("the copy is made once: an existing settings-1.1.4.json is never overwritten", (try? Data(contentsOf: backup)) == json(["marker": 1]))
        // A file that is already in the new shape copies nothing.
        let clean = dir.appendingPathComponent("clean")
        try? FileManager.default.createDirectory(at: clean, withIntermediateDirectories: true)
        let cleanURL = clean.appendingPathComponent("settings.json")
        try? SettingsFileFormat.render(newShape()).write(to: cleanURL)
        let cleanStore = SettingsFileStore(url: cleanURL)
        var changed = cleanStore.startup(fallback: AppSettings())
        changed.targetLanguage = "en"
        cleanStore.save(changed)
        check("a file already in the new shape is saved with no copy", !FileManager.default.fileExists(atPath: clean.appendingPathComponent(SettingsFileStore.oldShapeName).path))
    }

    // MARK: R3's default-path gate (§8): every (engine, app) request of a 1.1.4 file is made again, but for the cases §5.2 lists

    /// 1.1.4's engines: X on (3 earlier lines, learning, no title), Y off, Z DeepL off, T a template that owns its body.
    private static func engines(spareDeepL: Bool = false) -> [EngineConfig] {
        func id(_ n: Int) -> UUID { UUID(uuidString: "00000000-0000-0000-0000-0000000000B\(n)")! }
        return [
            EngineConfig(id: id(1), name: "X", kind: .openAICompatible(baseURL: URL(string: "http://localhost:1/v1")!, model: "m", thinking: .off, extraHeaders: [:]),
                         context: EngineContext(enabled: true, previousLines: 3, useLearned: true)),
            EngineConfig(id: id(2), name: "Y", kind: .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "claude-haiku-5-5", thinking: .off)),
            EngineConfig(id: id(3), name: "Z", kind: .deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil),
                         context: spareDeepL ? EngineContext(enabled: true, previousLines: 0, deepLInstructions: true) : nil),
            EngineConfig(id: id(4), name: "T", kind: .httpTemplate(HTTPTemplate(url: "http://localhost:2/t", body: "{}", resultPath: "t")),
                         context: EngineContext(enabled: true)),
        ]
    }

    /// The apps of the fixture: one with an override of off, one with a note and names, one with a name and its own engine, one with no profile.
    private static func apps(_ engines: [EngineConfig]) -> [AppProfile] {
        [AppProfile(bundleID: "com.example.quiet", appName: "Quiet", source: "ja", target: "ko", context: AppContextOverride(mode: .off)),
         AppProfile(bundleID: "com.example.notes", appName: "Notes", source: "ja", target: "ko", note: "formal",
                    entries: [MemoryEntry(src: "ハク", dst: "하쿠", kind: .person)]),
         AppProfile(bundleID: "com.example.own", appName: "Own", source: "en", target: "ko", customEngineID: engines[1].id,
                    entries: [MemoryEntry(src: "token", dst: "토큰")])]
    }

    /// The file of 1.1.4 as the app reads it, and 1.1.4's own answer to "what is this (engine, app) request built with".
    private static func oldAndNew(engines: [EngineConfig], profiles: [AppProfile], inUse: EngineConfig, applePins: Bool) -> (old: (EngineConfig, AppProfile?) -> ContextOptions,
                                                                                                                             new: AppSettings, exceptions: [MigrationException]) {
        var object: [String: Any] = ["customEngineID": inUse.id.uuidString]
        object["engines"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(engines))) ?? []
        object["appProfiles"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(profiles))) ?? []
        if applePins { object["appleUsesPinnedTerms"] = true }
        let data = json(object)
        let legacy = (try? JSONDecoder().decode(LegacySettings.self, from: data)) ?? LegacySettings()
        let read = SettingsFileCheck.read(data, over: AppSettings())
        return ({ e, p in ContextOptions.requestOptions(engine: e, profile: p) }, read.settings, ProfileMigration.convert(legacy).exceptions)
    }

    private static func defaultPath(_ check: Check) {
        let all = engines()
        let profiles = apps(all)
        let (old, new, exceptions) = oldAndNew(engines: all, profiles: profiles, inUse: all[0], applePins: false)
        // The request of one (engine, app): 1.1.4's options of the engine and the app's profile, and the converted file's, for the same two.
        var pairs = 0, equal = 0
        var different: [String] = []
        let lensApps: [String?] = profiles.map(\.bundleID) + ["com.example.none"]
        for engine in all {
            let converted = new.engines.first { $0.id == engine.id } ?? engine
            for app in lensApps {
                let profile = profiles.first { $0.bundleID == app }
                var s = new
                s.customEngineID = engine.id
                let now = ContextRoute.pair(settings: s, lens: app).options
                let was = old(engine, profile)
                pairs += 1
                // A template or a command owns its body, and takes no options: what must hold is that neither path puts context in it.
                // Disabled options are one request whatever else they hold (the layout sends today's body); enabled ones must be equal.
                let same = LayoutKind.engine(converted.kind).tier == nil ? (!now.enabled && converted.context == nil) : (now.enabled == was.enabled && (!now.enabled || now == was))
                if same { equal += 1 } else { different.append("\(engine.name)/\(app ?? "-")") }
            }
        }
        check("1.1.4 fixture: every (engine, app) request is the one 1.1.4 made, for \(pairs) pairs of 4 engines and 4 apps",
              different.isEmpty && equal == pairs && pairs == 16 && exceptions == [.lensUsesItsOwnProfile],
              "differ \(different) exceptions \(exceptions)")

        // Bytes, not options: the layout's body of each kind for the same request, under the old and the new options.
        let request = ContextRequest(items: ["Hello"], before: [ContextLine(source: "Earlier")], after: ["Later"], memory: [MemoryEntry(src: "Hello", dst: "안녕")],
                                     card: DocumentCard(appName: "App", domain: "social", title: "T"), note: "casual", target: "ko")
        var sameBytes = true
        for engine in all where LayoutKind.engine(engine.kind).tier != nil {
            for app in lensApps {
                var s = new
                s.customEngineID = engine.id
                let nowBody = RequestLayout.body(kind: engine.kind, request: request, options: ContextRoute.pair(settings: s, lens: app).options)
                let wasBody = RequestLayout.body(kind: engine.kind, request: request, options: old(engine, profiles.first { $0.bundleID == app }))
                if nowBody != wasBody { sameBytes = false }
            }
        }
        check("1.1.4 fixture: and the bytes of every request body are the ones 1.1.4 sent", sameBytes)

        // A file with no profile, no engine context and the Apple switch off: every engine, nothing set, the bytes of main.
        let bare = engines().map { EngineConfig(id: $0.id, name: $0.name, kind: $0.kind) }
        let (bareOld, bareNew, bareExceptions) = oldAndNew(engines: bare, profiles: [], inUse: bare[0], applePins: false)
        var bareSame = true
        for engine in bare where LayoutKind.engine(engine.kind).tier != nil {
            var s = bareNew
            s.customEngineID = engine.id
            let options = ContextRoute.pair(settings: s, lens: "com.example.any").options
            bareSame = bareSame && options == bareOld(engine, nil) && options == .off
                && RequestLayout.body(kind: engine.kind, request: request, options: options) == RequestLayout.body(kind: engine.kind, request: request, options: ContextOptions())
        }
        check("a file with no profile, no engine context and the Apple switch off renders byte-identical for every kind (and no exception applies)",
              bareSame && bareExceptions.isEmpty && ContextPlan.needsWindow(bareNew) == false)

        // The cases §5.2 lists by name, each seen in a fixture that has it.
        let spare = engines(spareDeepL: true)
        let (spareOld, spareNew, spareExceptions) = oldAndNew(engines: spare, profiles: apps(spare), inUse: spare[0], applePins: false)
        var spareDiffers = false
        for app in lensApps {
            var s = spareNew
            s.customEngineID = spare[2].id
            let was = spareOld(spare[2], apps(spare).first { $0.bundleID == app })
            if ContextRoute.pair(settings: s, lens: app).options != was { spareDiffers = true }
        }
        check("exception (b), a spare engine's own previousLines follows the amount: listed, and the spare DeepL's request is the one that changes",
              spareExceptions.contains(.spareEnginePreviousLines) && spareDiffers)
        let (_, switchNew, switchExceptions) = oldAndNew(engines: all, profiles: profiles, inUse: all[0], applePins: true)
        let aRow = switchNew.appProfiles.first { $0.bundleID == "com.example.notes" }?.entries.map(\.apply)
        let planned = ContextPlan.decide(settings: switchNew, engine: nil, engineRests: false,
                                         chain: ContextRoute.pair(settings: switchNew, lens: "com.example.notes").chain)
        check("exception (d), the Apple switch on: listed, every row is both, and Apple's plan carries the row as the 1.1.4 plan did (its source and translation)",
              switchExceptions.contains(.applePinsBecomeBoth) && aRow == [.both]
              && { if case let .replaceOnly(rows)? = planned { rows.map(\.src) == ["ハク"] && rows.map(\.dst) == ["하쿠"] } else { false } }(),
              "\(String(describing: planned))")
        // 1.1.4 with the switch OFF: a plan of nothing for Apple, whatever the profiles hold (and a hint row is no replace row).
        let offPlan = ContextPlan.decide(settings: new, engine: nil, engineRests: false, chain: ContextRoute.pair(settings: new, lens: "com.example.notes").chain)
        check("1.1.4 with the switch off: Apple's plan is nothing, so its request is today's", offPlan == nil)
        check("the four cases are the ones the converter can name", Set(MigrationException.allCases) == [.lensUsesItsOwnProfile, .spareEnginePreviousLines, .engineOffWithAppOverride, .applePinsBecomeBoth])
    }
}
#endif
