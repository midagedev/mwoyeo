#if !MAS
import Foundation
import MwoyeoCore

/// The checks of settings.json, run by `--capture-ui … check-logic` (PASS/FAIL lines). Files live in a scratch folder; the
/// `AppModel` checks use the scratch file `UICapture` points `MWOYEO_SETTINGS_FILE` at.
@MainActor
enum SettingsFileChecks {
    static func run(_ model: AppModel) -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool) {
            print("check-logic: \(ok ? "PASS" : "FAIL") settings file: \(what)")
            if !ok { failed += 1 }
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mwoyeo-settings-checks-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func text(_ u: URL) -> String { (try? String(contentsOf: u, encoding: .utf8)) ?? "" }

        var changed = AppSettings()
        let engine = EngineConfig(name: "Local", kind: .openAICompatible(baseURL: URL(string: "http://localhost:8765/v1")!, model: "qwen3:8b",
                                                                        thinking: .off, extraHeaders: ["X-Test": "1"]))
        changed.engines = [engine]
        changed.customEngineID = engine.id
        changed.targetLanguage = "ko"
        changed.glossary = "Tarou = タロウ\nHana = 花"
        changed.exportFolder = "/Users/test/Documents/Mwoyeo"
        changed.lensStyle = .minimal
        changed.boxOpacity = 0.75
        changed.shortcuts["pause"] = KeyCombo(keyCode: 35, modifiers: 6144, display: "⌃⌥P")
        changed.appProfiles = [AppProfile(bundleID: "com.example.app", appName: "Example", source: "ja", target: "en",
                                          customEngineID: engine.id, paragraphReader: .lineGrouping)]
        changed.paragraphReader = .documentLayout
        changed.transcriptFormats = [.markdown, .jsonl]

        // Format and round trip
        let rendered = SettingsFileFormat.render(changed)
        let body = String(decoding: rendered, as: UTF8.self)
        check("the file starts with $schema, has sorted keys, \"key\": value, a trailing newline",
              body.hasPrefix("{\n  \"$schema\": \"settings.schema.json\",\n") && body.hasSuffix("}\n") && body.contains("\"lensStyle\": \"minimal\""))
        let back = SettingsFileCheck.read(rendered, over: AppSettings())
        check("round trip: settings → file → settings are equal, no issues", back.settings == changed && back.issues.isEmpty)
        var withState = changed
        withState.hasCompletedOnboarding = true
        withState.engineRejections = [engine.id: ["temperature"]]
        check("run-time state is not in the file, and a reload keeps it",
              !body.contains("hasCompletedOnboarding") && !body.contains("engineRejections")
              && SettingsFileCheck.read(SettingsFileFormat.render(withState), over: withState).settings == withState)

        // Migration
        let migrated = dir.appendingPathComponent("migrate/settings.json")
        let store = SettingsFileStore(url: migrated)
        let first = store.startup(fallback: changed)
        check("migration: no file → the preferences' settings are kept and written as the file",
              first == changed && SettingsFileCheck.read((try? Data(contentsOf: migrated)) ?? Data(), over: AppSettings()).settings == changed)
        check("the schema is written next to the file",
              FileManager.default.fileExists(atPath: migrated.deletingLastPathComponent().appendingPathComponent("settings.schema.json").path))

        // Downgrade to 1.1.0 and back: what the older version changed in the preferences wins over the file, nothing else.
        let mirrored = Data(#"{"lensStyle":"glow","targetLanguage":"ko","shortcuts":{"a":1,"b":2},"lensTint":"ocean"}"#.utf8)
        let reencoded = Data(#"{"shortcuts":{"b":2,"a":1},"targetLanguage":"ko","lensStyle":"glow"}"#.utf8)
        let changedByOld = Data(#"{"shortcuts":{"b":2,"a":1},"targetLanguage":"ja","lensStyle":"glow"}"#.utf8)
        check("downgrade: an older version's re-encoding alone changes nothing",
              AppModel.olderVersionChanges(blob: reencoded, mirror: mirrored).isEmpty)
        check("downgrade: a value the older version changed is taken, keys it does not know are kept",
              Set(AppModel.olderVersionChanges(blob: changedByOld, mirror: mirrored).keys) == ["targetLanguage"])
        check("downgrade: no mirror yet (first launch after 1.1.0) changes nothing",
              AppModel.olderVersionChanges(blob: changedByOld, mirror: nil).isEmpty)

        // Self-write echo, external edit
        store.save(changed)
        check("an event for the bytes the app wrote is ignored", store.fileChanged(current: changed) == nil)
        var edited = body.replacingOccurrences(of: "\"lensStyle\": \"minimal\"", with: "\"lensStyle\": \"subtle\"")
            .replacingOccurrences(of: "\"targetLanguage\": \"ko\"", with: "\"targetLanguage\": \"ja\"")
        try? Data(edited.utf8).write(to: migrated, options: .atomic)
        let reload = store.fileChanged(current: changed)
        check("an edit applies, and names the changed keys",
              reload?.settings.lensStyle == .subtle && reload?.settings.targetLanguage == "ja" && reload?.changed == ["lensStyle", "targetLanguage"])
        check("an edit leaves the file as the person wrote it", text(migrated) == edited)

        // Issues
        let typo = SettingsFileCheck.read(Data("{\n  \"lenStyle\": \"glow\"\n}\n".utf8), over: changed)
        check("unknown key: reported with the line and the closest known key",
              typo.issues == [SettingsFileIssue(line: 2, message: "unknown key lenStyle (did you mean lensStyle?)")] && typo.settings == changed)
        let wrong = SettingsFileCheck.read(Data("""
        {
          "cacheSize": "big",
          "lensStyle": "neon",
          "boxOpacity": 3,
          "framesPerSecond": true,
          "renderMode": "fast",
          "customEngineID": "not-a-uuid"
        }
        """.utf8), over: changed)
        check("wrong type or value: the key keeps its value and is named; valid keys still apply",
              wrong.settings.cacheSize == changed.cacheSize && wrong.settings.lensStyle == .minimal && wrong.settings.boxOpacity == 0.75
              && wrong.settings.framesPerSecond == changed.framesPerSecond && wrong.settings.customEngineID == engine.id
              && wrong.settings.renderMode == .fast && wrong.issues.count == 5)
        // The allowed styles come from LensStyle (corners joined them on 2026-10-18), not a copy of them.
        check("a value not among the allowed ones lists them",
              wrong.issues.contains { $0.message.contains("lensStyle") && $0.message.contains("\"neon\"") && $0.message.contains(LensStyle.allCases.map(\.rawValue).joined(separator: ", ")) })
        check("a number out of range names the range", wrong.issues.contains { $0.message.contains("boxOpacity") && $0.message.contains("0.6 to 1") })
        let nested = SettingsFileCheck.read(Data("{\"engines\": [{\"name\": \"x\"}], \"shortcuts\": {\"pasuse\": {}}}".utf8), over: changed)
        check("a bad engine and an unknown shortcut action are reported", nested.issues.count == 2 && nested.settings == changed)
        check("a null engine id means Apple", SettingsFileCheck.read(Data("{\"customEngineID\": null}".utf8), over: changed).settings.customEngineID == nil)

        // Nested fields (round S1, 2026-10-18): the same spec tree drives the schema and the check, so a problem inside
        // appProfiles, engines or shortcuts carries its path and the line of that value.
        func lineNumber(of needle: String, in s: String) -> Int? { s.components(separatedBy: "\n").firstIndex { $0.contains(needle) }.map { $0 + 1 } }
        let misspelt = """
        {
          "appProfiles": [
            {
              "bundleID": "com.example.app",
              "paragraphReadr": "lineGrouping",
              "source": "ja",
              "target": "en"
            }
          ]
        }
        """
        let misspeltRead = SettingsFileCheck.read(Data(misspelt.utf8), over: changed)
        check("nested unknown key: reported with its path, its line and the closest known key",
              misspeltRead.issues == [SettingsFileIssue(line: 5, message: "unknown key appProfiles[0].paragraphReadr (did you mean paragraphReader?)")])
        check("nested unknown key: the rest of the profile applies",
              misspeltRead.settings.appProfiles.map(\.bundleID) == ["com.example.app"] && misspeltRead.settings.appProfiles.first?.target == "en")
        // The per-app memory (note, entries, context) is kept by the app (design §10), so the file may carry it. The limits
        // are the Core constants, never a second copy of the numbers.
        let badGender = """
        {
          "appProfiles": [
            {
              "bundleID": "com.example.app",
              "source": "ja",
              "target": "en",
              "entries": [
                {
                  "src": "田中",
                  "dst": "Tanaka",
                  "gender": "x"
                }
              ]
            }
          ]
        }
        """
        let allowedGenders = Gender.allCases.map(\.rawValue).joined(separator: ", ")
        let genderRead = SettingsFileCheck.read(Data(badGender.utf8), over: changed)
        check("nested enum: entries[0].gender \"x\" is reported with its path, its line and the allowed values; the entry still applies",
              genderRead.issues == [SettingsFileIssue(line: 11, message: "appProfiles[0].entries[0].gender: \"x\" is not allowed; use one of \(allowedGenders); ignored")]
              && genderRead.settings.appProfiles.first?.entries.map(\.src) == ["田中"] && genderRead.settings.appProfiles.first?.entries.first?.gender == nil)
        let capped: [String: Any] = ["appProfiles": [["bundleID": "com.example.app", "source": "ja", "target": "en",
                                                    "note": String(repeating: "a", count: AppProfile.maxNoteLength + 1),
                                                    "entries": (0...AppProfile.maxEntries).map { ["src": "s\($0)", "dst": "d\($0)"] }]]]
        let cappedText = SettingsFileFormat.pretty(capped) + "\n"
        let cappedRead = SettingsFileCheck.read(Data(cappedText.utf8), over: changed)
        check("caps: a note one character over and one entry too many are reported at their lines",
              cappedRead.issues.sorted { ($0.line ?? 0) < ($1.line ?? 0) } == [
                  SettingsFileIssue(line: lineNumber(of: "\"entries\"", in: cappedText),
                                    message: "appProfiles[0].entries: \(AppProfile.maxEntries + 1) items; the limit is \(AppProfile.maxEntries); the first \(AppProfile.maxEntries) apply"),
                  SettingsFileIssue(line: lineNumber(of: "\"note\"", in: cappedText),
                                    message: "appProfiles[0].note: \(AppProfile.maxNoteLength + 1) characters; the limit is \(AppProfile.maxNoteLength); ignored"),
              ].sorted { ($0.line ?? 0) < ($1.line ?? 0) })
        var memoryAtCap = capped
        memoryAtCap["appProfiles"] = [["bundleID": "com.example.app", "source": "ja", "target": "en", "note": String(repeating: "a", count: AppProfile.maxNoteLength),
                                 "entries": (0..<AppProfile.maxEntries).map { ["src": "s\($0)", "dst": "d\($0)"] }]]
        let atCapRead = SettingsFileCheck.read(Data((SettingsFileFormat.pretty(memoryAtCap) + "\n").utf8), over: changed)
        check("caps: exactly the note limit and the entry limit are fine, and all of them apply",
              atCapRead.issues.isEmpty && atCapRead.settings.appProfiles.first?.entries.count == AppProfile.maxEntries
              && atCapRead.settings.appProfiles.first?.note.count == AppProfile.maxNoteLength)
        let rowCaps: [String: Any] = ["appProfiles": [["bundleID": "com.example.app", "source": "ja", "target": "en", "entries": [[
            "src": "田中", "dst": "Tanaka", "note": String(repeating: "n", count: MemoryEntry.maxEntryNote + 1),
            "addressing": (0...MemoryEntry.maxAddressing).map { ["to": "p\($0)", "register": "casual"] },
        ] as [String: Any]]]]]
        let rowCapsText = SettingsFileFormat.pretty(rowCaps) + "\n"
        let rowCapsRead = SettingsFileCheck.read(Data(rowCapsText.utf8), over: changed)
        check("caps: an entry's note over its limit and a fifth addressing row are reported at their lines",
              rowCapsRead.issues.sorted { ($0.line ?? 0) < ($1.line ?? 0) } == [
                  SettingsFileIssue(line: lineNumber(of: "\"addressing\"", in: rowCapsText),
                                    message: "appProfiles[0].entries[0].addressing: \(MemoryEntry.maxAddressing + 1) items; the limit is \(MemoryEntry.maxAddressing); the first \(MemoryEntry.maxAddressing) apply"),
                  SettingsFileIssue(line: lineNumber(of: "\"note\"", in: rowCapsText),
                                    message: "appProfiles[0].entries[0].note: \(MemoryEntry.maxEntryNote + 1) characters; the limit is \(MemoryEntry.maxEntryNote); ignored"),
              ].sorted { ($0.line ?? 0) < ($1.line ?? 0) }
              && rowCapsRead.settings.appProfiles.first?.entries.first?.addressing.count == MemoryEntry.maxAddressing)
        let badThinking = """
        {
          "engines": [
            {
              "kind": "anthropic",
              "name": "Claude",
              "thinking": "maybe"
            }
          ]
        }
        """
        let thinkingRead = SettingsFileCheck.read(Data(badThinking.utf8), over: changed)
        check("nested enum: engines[0].thinking \"maybe\" is reported with its path, its line and the allowed values",
              thinkingRead.issues == [SettingsFileIssue(line: 6, message: "engines[0].thinking: \"maybe\" is not allowed; use one of off, provider; ignored")]
              && thinkingRead.settings.engines.map(\.name) == ["Claude"])
        let engineTypo = SettingsFileCheck.read(Data("""
        {
          "engines": [
            {
              "kind": "openAICompatible",
              "baseURL": "http://localhost:8765/v1",
              "modle": "qwen3:8b",
              "name": "Local"
            }
          ]
        }
        """.utf8), over: changed)
        check("nested unknown key in engines[0]: reported with its line and the closest known key",
              engineTypo.issues == [SettingsFileIssue(line: 6, message: "unknown key engines[0].modle (did you mean model?)")])
        // No setting of 1.1.2 has a text or list cap, so a synthetic tree keeps the validator's caps (and the schema's) tested.
        let capKind: FieldKind = .list(.object([
            FieldSpec("src", .text(minLength: 1), "Required text.", required: true),
            FieldSpec("note", .text(maxLength: 5), "Optional text, up to 5 characters."),
        ]), maxItems: 3, dropsBad: true)
        func readRows(_ json: String) -> (rows: [[String: Any]]?, messages: [String]) {
            var problems: [FieldProblem] = []
            let kept = capKind.read((try? JSONSerialization.jsonObject(with: Data(json.utf8))) ?? [], at: FieldPath(steps: [.key("rows")]),
                                    fallout: .keep, problems: &problems) as? [[String: Any]]
            return (kept, problems.map(\.message))
        }
        let overCap = readRows(#"[{"src": "a", "note": "123456"}, {"src": "b"}, {"src": ""}, {"src": "d"}]"#)
        check("caps: a 6-character text is ignored, a row with an empty required text is dropped, the 4th row is past the 3-row limit",
              overCap.messages == ["rows[0].note: 6 characters; the limit is 5; ignored", "rows[2].src: must not be empty; dropped",
                                   "rows: 4 items; the limit is 3; the first 3 apply"]
              && overCap.rows?.map { $0["src"] as? String ?? "" } == ["a", "b"] && overCap.rows?.first?["note"] == nil)
        let atCap = readRows(#"[{"src": "a", "note": "12345"}, {"src": "b"}, {"src": "c"}]"#)
        check("caps: exactly 5 characters and 3 rows are fine", atCap.messages.isEmpty && atCap.rows?.count == 3 && atCap.rows?.first?["note"] as? String == "12345")
        let capSchema = capKind.schema()
        let rowSchema = capSchema["items"] as? [String: Any]
        let rowProperties = rowSchema?["properties"] as? [String: Any]
        check("schema: a text's maxLength and minLength and a list's maxItems are written",
              capSchema["maxItems"] as? Int == 3 && (rowProperties?["note"] as? [String: Any])?["maxLength"] as? Int == 5
              && (rowProperties?["src"] as? [String: Any])?["minLength"] as? Int == 1)
        // An agent's file, in the app's own format (sorted keys, two-space indent): an engine and an app profile that uses it.
        let agentFile = """
        {
          "appProfiles": [
            {
              "appName": "Example Chat",
              "bundleID": "com.example.chat",
              "customEngineID": "\(FieldKind.exampleUUID)",
              "paragraphReader": "lineGrouping",
              "source": "ja",
              "target": "en"
            }
          ],
          "engines": [
            {
              "baseURL": "http://localhost:8765/v1",
              "id": "\(FieldKind.exampleUUID)",
              "kind": "openAICompatible",
              "model": "qwen3:8b",
              "name": "Local Qwen",
              "thinking": "off"
            }
          ]
        }
        """
        let agent = SettingsFileCheck.read(Data(agentFile.utf8), over: AppSettings())
        let agentObject = (try? JSONSerialization.jsonObject(with: Data(agentFile.utf8))) as? [String: Any] ?? [:]
        func describedByTheSchema(_ value: Any, _ schema: [String: Any]) -> Bool {
            if let object = value as? [String: Any] {
                let known = schema["properties"] as? [String: Any] ?? [:]
                return object.allSatisfy { k, v in (known[k] as? [String: Any]).map { describedByTheSchema(v, $0) } ?? false }
            }
            if let list = value as? [Any] { return list.allSatisfy { describedByTheSchema($0, schema["items"] as? [String: Any] ?? [:]) } }
            return true
        }
        let agentSchema = ((try? JSONSerialization.jsonObject(with: SettingsSchema.data())) as? [String: Any])?["properties"] as? [String: Any]
        check("agent-written file: a valid file reads without issues, applies, and the schema describes every field in it",
              agent.issues.isEmpty && agent.settings.engines.map(\.name) == ["Local Qwen"]
              && agent.settings.appProfiles.map(\.bundleID) == ["com.example.chat"]
              && agent.settings.appProfiles.first?.paragraphReader == .lineGrouping
              && agent.settings.appProfiles.first?.customEngineID == agent.settings.engines.first?.id
              && describedByTheSchema(agentObject, ["properties": agentSchema ?? [:]]))
        check("agent-written file: the file text is the app's own format, so a reload leaves it as written",
              SettingsFileFormat.pretty(agentObject) + "\n" == agentFile + "\n")
        let afterAgent = SettingsFileCheck.read(SettingsFileFormat.render(agent.settings), over: AppSettings())
        check("agent-written file: settings → file → settings is stable", afterAgent.settings == agent.settings && afterAgent.issues.isEmpty)
        // The default path: a file as 1.1.2 wrote it (the agent fixture above is main's own, a profile with no memory fields) is read
        // and saved again as the same bytes. The app adds no key to a profile that has no memory.
        let v112 = SettingsFileFormat.render(agent.settings)
        let v112Read = SettingsFileCheck.read(v112, over: AppSettings())
        let v112Object = (try? JSONSerialization.jsonObject(with: v112)) as? [String: Any] ?? [:]
        let v112Profile = v112Read.settings.appProfiles.first
        check("1.1.2 file, no memory fields: read and saved again it is the same bytes, the fixture's profile comes out as written, and no memory key appears",
              v112Read.issues.isEmpty && SettingsFileFormat.render(v112Read.settings) == v112
              // 2026-10-21, prof-file: the profiles are `profiles` now (id = the bundle id); each keeps its pair, engine and reader as written.
              && { () -> Bool in
                  let migrated = (v112Object["profiles"] as? [[String: Any]]) ?? [], legacyItems = (agentObject["appProfiles"] as? [[String: Any]]) ?? []
                  return !migrated.isEmpty && migrated.count == legacyItems.count && zip(migrated, legacyItems).allSatisfy { new, old in
                      new["id"] as? String == old["bundleID"] as? String && new["source"] as? String == old["source"] as? String
                          && new["target"] as? String == old["target"] as? String
                          && ["customEngineID", "paragraphReader"].allSatisfy { (new[$0] as? NSObject)?.isEqual(old[$0] as? NSObject) ?? (old[$0] == nil) }
                  }
              }()
              && v112Profile?.note == "" && v112Profile?.entries.isEmpty == true && v112Profile?.context == nil
              && ["\"note\"", "\"entries\"", "\"context\""].allSatisfy { !String(decoding: v112, as: UTF8.self).contains($0) })

        // An agent's memory for an app, written the way docs/settings-for-agents.md shows it: a note, two entries that carry
        // addressing, and a context override. It reads without an issue, the schema describes every field, and the file text is
        // the app's own format.
        let memoryFile = """
        {
          "appProfiles": [
            {
              "appName": "Example Chat",
              "bundleID": "com.example.chat",
              "context": {
                "mode": "nearby",
                "previousLines": 3
              },
              "entries": [
                {
                  "addressing": [
                    {
                      "register": "polite",
                      "to": "Hana"
                    }
                  ],
                  "dst": "Tanaka",
                  "gender": "m",
                  "kind": "person",
                  "note": "the speaker's older colleague",
                  "reading": "たなか",
                  "src": "田中"
                },
                {
                  "addressing": [
                    {
                      "register": "casual",
                      "to": "Tanaka"
                    }
                  ],
                  "dst": "Hana",
                  "gender": "f",
                  "kind": "person",
                  "src": "花"
                }
              ],
              "note": "Casual chat between two friends. Keep it informal and short.",
              "paragraphReader": "lineGrouping",
              "source": "ja",
              "target": "en"
            }
          ]
        }
        """
        let memory = SettingsFileCheck.read(Data(memoryFile.utf8), over: AppSettings())
        let memoryObject = (try? JSONSerialization.jsonObject(with: Data(memoryFile.utf8))) as? [String: Any] ?? [:]
        let memoryProfile = memory.settings.appProfiles.first
        check("memory fields: a valid file reads without issues, the app keeps all three, and the schema describes every field in it",
              memory.issues.isEmpty && memoryProfile?.bundleID == "com.example.chat" && memoryProfile?.paragraphReader == .lineGrouping
              && memoryProfile?.note == "Casual chat between two friends. Keep it informal and short."
              && memoryProfile?.entries.map(\.src) == ["田中", "花"] && memoryProfile?.entries.first?.addressing == [Addressing(to: "Hana", register: .polite)]
              && memoryProfile?.entries.first?.reading == "たなか" && memoryProfile?.entries.first?.gender == .m
              && memoryProfile?.context == AppContextOverride(mode: .nearby, previousLines: 3)
              && describedByTheSchema(memoryObject["appProfiles"] ?? [], agentSchema?["appProfiles"] as? [String: Any] ?? [:]))
        check("memory fields: the file text is the app's own format, so a reload leaves it as written",
              SettingsFileFormat.pretty(memoryObject) + "\n" == memoryFile + "\n")
        let afterMemory = SettingsFileCheck.read(SettingsFileFormat.render(memory.settings), over: AppSettings())
        check("memory fields: settings → file → settings is stable", afterMemory.settings == memory.settings && afterMemory.issues.isEmpty)
        // One rule for a context in a file: the validator and the Core decode give the same `AppProfile.context` for the same
        // profile text, out-of-range, fractional, wrong-typed, missing and unknown values included (the validator is the contract:
        // a `previousLines` it ignores is the default, never a clamp).
        let contextTexts = [
            #"{"mode":"conversation","previousLines":12}"#, #"{"mode":"conversation","previousLines":9}"#, #"{"mode":"conversation","previousLines":-1}"#,
            #"{"mode":"conversation","previousLines":5.5}"#, #"{"mode":"conversation","previousLines":"many"}"#, #"{"mode":"conversation","previousLines":true}"#,
            #"{"mode":"conversation","previousLines":null}"#, #"{"mode":"conversation","previousLines":0}"#, #"{"mode":"conversation","previousLines":8}"#,
            #"{"mode":"conversation"}"#, #"{"mode":"nearby","previousLines":6}"#, #"{"mode":"off"}"#,
            #"{"previousLines":3}"#, #"{"mode":"full","previousLines":3}"#, #"{}"#,
        ]
        let contextAgreement = contextTexts.map { context -> (text: String, viaFile: AppContextOverride?, direct: AppContextOverride?) in
            let file = #"{"appProfiles":[{"bundleID":"com.example.ctx","source":"ja","target":"en","context":\#(context)}]}"#
            let viaFile = SettingsFileCheck.read(Data(file.utf8), over: AppSettings()).settings.appProfiles.first?.context
            let profileObject = ((try? JSONSerialization.jsonObject(with: Data(file.utf8))) as? [String: Any])?["appProfiles"] as? [[String: Any]]
            let direct = profileObject?.first.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(AppProfile.self, from: $0) }?.context
            return (context, viaFile, direct)
        }
        for row in contextAgreement where row.viaFile != row.direct {
            print("check-logic: context \(row.text): the file check gives \(String(describing: row.viaFile)), the Core decode \(String(describing: row.direct))")
        }
        check("a context in a file reads the same through the file check and through a direct Core decode, in every case that disagreed before",
              contextAgreement.allSatisfy { $0.viaFile == $0.direct }
              && contextAgreement[0].viaFile == AppContextOverride(mode: .conversation, previousLines: AppContextOverride.defaultPreviousLines)
              && contextAgreement[8].viaFile == AppContextOverride(mode: .conversation, previousLines: AppContextOverride.maxPreviousLines)
              && contextAgreement[12].viaFile == nil && contextAgreement[14].viaFile == nil)
        // The save path: the app starts on this file, a change is made in Settings, and the app's own writer saves it. The note,
        // the entries with their addressing and the context must come out the same (1.1.2 re-saved the file from AppSettings
        // and dropped them).
        let saveFolder = dir.appendingPathComponent("memory-save")
        try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let saveURL = saveFolder.appendingPathComponent("settings.json")
        try? Data(memoryFile.utf8).write(to: saveURL)
        let saveStore = SettingsFileStore(url: saveURL)
        var started = saveStore.startup(fallback: AppSettings())
        started.boxOpacity = 0.9
        saveStore.save(started)
        let savedRead = SettingsFileCheck.read((try? Data(contentsOf: saveURL)) ?? Data(), over: AppSettings())
        let savedObject = (try? JSONSerialization.jsonObject(with: Data(text(saveURL).utf8))) as? [String: Any] ?? [:]
        let savedProfile = savedRead.settings.appProfiles.first
        check("memory fields survive the app's save: start on the file, change a setting, save, read again; the note, entries with addressing and context are the same",
              savedRead.issues.isEmpty && started.boxOpacity == 0.9 && savedRead.settings.boxOpacity == 0.9
              && savedProfile?.note == memoryProfile?.note && savedProfile?.entries == memoryProfile?.entries && savedProfile?.context == memoryProfile?.context
              && memoryProfile?.note.isEmpty == false && memoryProfile?.entries.count == 2 && memoryProfile?.context != nil
              && ((savedObject["profiles"] as? [[String: Any]])?.first).map { item in ["note", "entries", "context"].allSatisfy {
                  (item[$0] as? NSObject)?.isEqual((memoryObject["appProfiles"] as? [[String: Any]])?.first?[$0] as? NSObject) == true } } == true)
        // Every value of the enums, the most rows, the most addressing and the longest conversation come back as they went in.
        let everyEntry = EntryKind.allCases.flatMap { kind in Gender.allCases.map { gender in
            MemoryEntry(src: "\(kind)-\(gender)", dst: "d", kind: kind, gender: gender, note: String(repeating: "n", count: MemoryEntry.maxEntryNote),
                        reading: "r", addressing: Register.allCases.map { Addressing(to: "to-\($0)", register: $0) }) } }
        var everyValue = AppSettings()
        everyValue.appProfiles = [AppProfile(bundleID: "com.example.every", appName: "Every", source: "ja", target: "ko", note: String(repeating: "n", count: AppProfile.maxNoteLength),
                                             entries: everyEntry, context: AppContextOverride(mode: .conversation, previousLines: AppContextOverride.maxPreviousLines)),
                                  AppProfile(bundleID: "com.example.off", appName: "Off", source: "auto", target: "en", context: AppContextOverride(mode: .off, previousLines: 0))]
        let everyValueRead = SettingsFileCheck.read(SettingsFileFormat.render(everyValue), over: AppSettings())
        check("memory fields: every enum value, the largest note, entry and addressing sets and both ends of the context survive settings → file → settings",
              everyValueRead.settings == everyValue && everyValueRead.issues.isEmpty
              && everyValueRead.settings.appProfiles.first?.entries.count == EntryKind.allCases.count * Gender.allCases.count
              && everyValueRead.settings.appProfiles.first?.entries.allSatisfy { $0.addressing.count == Register.allCases.count } == true)

        // Lines and what applies
        let minified = SettingsFileCheck.read(Data("{\"engines\":[{\"name\":\"x\",\"kind\":\"command\",\"command\":{\"executable\":\"/bin/x\",\"arguements\":[]}}],\"lenStyle\":1}".utf8), over: changed)
        check("minified file: every issue is on line 1, nested ones with their path",
              minified.issues.map(\.line) == [1, 1] && minified.issues.contains { $0.message == "unknown key engines[0].command.arguements (did you mean arguments?)" })
        let spread = SettingsFileCheck.read(Data("""
        {
          "engines": [
            { "kind": "deepL", "name": "A", "baseURL": "https://api.deepl.com" },
            {
              "kind": "anthropic",
              "name": "B",
              "thinking": "maybe"
            },
            { "kind": "deepL", "baseURL": "https://api.deepl.com" }
          ]
        }
        """.utf8), over: changed)
        check("lines: a bad optional field is on its own line, a missing required field on the line of its item",
              spread.issues.map(\.line) == [7, 9] && spread.issues[0].message.hasPrefix("engines[1].thinking:")
              && spread.issues[1].message == "engines[2]: missing \"name\"; keeping the current value")
        var engineProblems: [FieldProblem] = []
        let engineKept = SettingSpec.spec(for: "engines")?.kind.read((try? JSONSerialization.jsonObject(with: Data("""
        [{"kind": "anthropic", "name": "C", "model": "m", "thinking": "maybe"}]
        """.utf8))) ?? [], at: FieldPath(steps: [.key("engines")]), fallout: .keep, problems: &engineProblems) as? [[String: Any]]
        check("a bad optional field of an engine is left out, the rest of the engine applies",
              engineProblems.count == 1 && engineKept?.first?["thinking"] == nil
              && engineKept?.first?["name"] as? String == "C" && engineKept?.first?["model"] as? String == "m")
        let spreadMemory = SettingsFileCheck.read(Data("""
        {
          "appProfiles": [
            { "bundleID": "a", "source": "ja", "target": "en" },
            {
              "bundleID": "b",
              "source": "ja",
              "target": "en",
              "entries": [
                { "src": "x", "dst": "y" },
                { "src": "x", "dst": "y", "kind": "company" },
                { "dst": "y" }
              ],
              "context": { "previousLines": 3 }
            }
          ]
        }
        """.utf8), over: changed)
        check("lines: a bad entry field is on its own line, an entry without src is dropped, a context without a mode is left out",
              spreadMemory.issues.map(\.line) == [10, 11, 13] && spreadMemory.issues[0].message.hasPrefix("appProfiles[1].entries[1].kind:")
              && spreadMemory.issues[1].message == "appProfiles[1].entries[2]: missing \"src\"; dropped"
              && spreadMemory.issues[2].message == "appProfiles[1].context: missing \"mode\"; ignored"
              && spreadMemory.settings.appProfiles.map(\.bundleID) == ["a", "b"] && spreadMemory.settings.appProfiles.last?.context == nil
              && spreadMemory.settings.appProfiles.last?.entries.map(\.src) == ["x"])
        var rowProblems: [FieldProblem] = []
        let rowKept = SettingSpec.spec(for: "appProfiles")?.kind.read((try? JSONSerialization.jsonObject(with: Data("""
        [{"bundleID": "a", "source": "ja", "target": "en", "entries": [
          {"src": "1", "dst": "1", "gender": "x", "addressing": [{"to": "p", "register": "polite"}, {"to": "q", "register": "rude"}]},
          {"src": "2"},
          {"src": "3", "dst": "3"}]}]
        """.utf8))) ?? [], at: FieldPath(steps: [.key("appProfiles")]), fallout: .keep, problems: &rowProblems) as? [[String: Any]]
        let keptEntries = rowKept?.first?["entries"] as? [[String: Any]]
        check("a bad field is left out, a bad row is dropped, the rest of the profile applies",
              rowProblems.count == 3 && keptEntries?.map { $0["src"] as? String ?? "" } == ["1", "3"]
              && keptEntries?.first?["gender"] == nil && (keptEntries?.first?["addressing"] as? [[String: Any]])?.count == 1)
        check("a bad required field of a profile keeps the current profiles, as before",
              SettingsFileCheck.read(Data("{\"appProfiles\": [{\"bundleID\": 7, \"source\": \"ja\", \"target\": \"en\"}]}".utf8), over: changed).settings == changed)
        check("an engine's unknown field is left out and the engine applies",
              engineTypo.settings.engines.map(\.name) == ["Local"])
        check("a field of another engine kind is reported and left out",
              SettingsFileCheck.read(Data("{\"engines\": [{\"kind\": \"anthropic\", \"name\": \"C\", \"formality\": \"more\"}]}".utf8), over: AppSettings()).issues.map(\.message)
              == ["engines[0].formality: used by kind deepL, not by kind anthropic; ignored"])
        let dupes = SettingsFileCheck.read(Data("{\"transcriptFormats\": [\"jsonl\", \"srt\", \"jsonl\"]}".utf8), over: AppSettings())
        check("a duplicate in a list the schema says is unique is reported and dropped",
              dupes.settings.transcriptFormats == [.jsonl, .srt] && dupes.issues.count == 1 && dupes.issues[0].message.hasPrefix("transcriptFormats[2]:"))
        let trailing = SettingsFileCheck.read(Data("{\n  \"lensStyle\": \"minimal\",\n}\n".utf8), over: AppSettings())
        check("a trailing comma applies but is reported with its line, as other tools cannot read it",
              trailing.settings.lensStyle == .minimal && trailing.issues.map(\.line) == [2] && trailing.issues[0].message.hasPrefix("trailing comma"))
        check("$schema must be a string", SettingsFileCheck.read(Data("{\"$schema\": 5}".utf8), over: AppSettings()).issues.count == 1)

        // Every engine kind the app writes reads back without an issue
        var everyKind = AppSettings()
        everyKind.engines = [
            engine,
            EngineConfig(name: "Claude", kind: .anthropic(baseURL: URL(string: "https://api.anthropic.com")!, model: "claude-haiku-5-5", thinking: .provider)),
            EngineConfig(name: "DeepL", kind: .deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: "more")),
            EngineConfig(name: "Libre", kind: .httpTemplate(HTTPTemplate(url: "http://localhost:5000/translate", headers: ["Content-Type": "application/json"],
                                                                         body: "{\"q\": {{text}}}", resultPath: "translatedText"))),
            EngineConfig(name: "Mine", kind: .command(CommandSpec(executable: "/usr/local/bin/translate-me", arguments: ["--fast"]))),
        ]
        let everyRead = SettingsFileCheck.read(SettingsFileFormat.render(everyKind), over: AppSettings())
        check("engines of all five kinds: written by the app, read back equal with no issue", everyRead.settings == everyKind && everyRead.issues.isEmpty)

        // Engine context (round T3a-1, 2026-10-19): engines[].context and appleUsesPinnedTerms, the keys of 1.1.4. Round prof-file (2026-10-21,
        // design names-and-context §5.2) reads and converts them (the amount, learning and permissions, the rows' mode) and never writes them;
        // these are the checks of the old keys, ported: each says what it says now. The fixture is 1.1.4's, unchanged.
        let secondID = "8C4A2D3F-6B5E-4F9C-8D32-4E7A1B2C3D4E"
        let engineContextFile = """
        {
          "appleUsesPinnedTerms": true,
          "engines": [
            {
              "baseURL": "http://localhost:8765/v1",
              "context": {
                "deepLInstructions": false,
                "enabled": true,
                "includeTitle": true,
                "previousLines": 6,
                "useLearned": true
              },
              "extraHeaders": {},
              "id": "\(FieldKind.exampleUUID)",
              "kind": "openAICompatible",
              "model": "qwen3:8b",
              "name": "Local Qwen",
              "thinking": "off"
            },
            {
              "baseURL": "https://api.deepl.com",
              "context": {
                "deepLInstructions": true,
                "enabled": true,
                "includeTitle": false,
                "previousLines": 0,
                "useLearned": false
              },
              "id": "\(secondID)",
              "kind": "deepL",
              "name": "DeepL"
            }
          ]
        }
        """
        let engineContext = SettingsFileCheck.read(Data(engineContextFile.utf8), over: AppSettings())
        let engineContextObject = (try? JSONSerialization.jsonObject(with: Data(engineContextFile.utf8))) as? [String: Any] ?? [:]
        let qwenContext = EngineContext(enabled: true, previousLines: 6, includeTitle: true, useLearned: true, deepLInstructions: false)
        let deepLContext = EngineContext(enabled: true, previousLines: 0, includeTitle: false, useLearned: false, deepLInstructions: true)
        let qwenAllow = EngineAllow(lines: true, title: true, deepLInstructions: false)
        let deepLAllow = EngineAllow(lines: true, title: false, deepLInstructions: true)
        let amountSix = AppContextOverride(mode: .conversation, previousLines: 6)
        let converted = engineContext.settings
        check("engine context: a file of 1.1.4 reads without issues and is converted (the amount of the first engine that was on, its learning, each engine's allow, the Apple switch as both), and the schema still describes every old field in it",
              engineContext.issues.isEmpty && engineContext.convertedFromOldShape
              && converted.context == amountSix && converted.useLearned && converted.engines.map(\.allow) == [qwenAllow, deepLAllow]
              && converted.engines.allSatisfy { $0.context == nil } && converted.glossaryApply == .both
              && describedByTheSchema(engineContextObject, ["properties": agentSchema ?? [:]]))
        check("engine context: the file text is the app's own format, so a reload leaves it as written",
              SettingsFileFormat.pretty(engineContextObject) + "\n" == engineContextFile + "\n")
        let convertedRender = SettingsFileFormat.render(converted)
        let convertedObject = (try? JSONSerialization.jsonObject(with: convertedRender)) as? [String: Any]
        check("engine context: settings → file → settings is stable, and the render writes the new keys (context, useLearned, glossaryApply, each engine's allow) and none of the old ones",
              SettingsFileCheck.read(convertedRender, over: AppSettings()).settings == converted
              && SettingsFileCheck.read(convertedRender, over: AppSettings()).issues.isEmpty
              && (convertedObject?["context"] as? [String: Any])?["previousLines"] as? Int == 6 && convertedObject?["useLearned"] as? Bool == true
              && convertedObject?["glossaryApply"] as? String == "both" && convertedObject?["appleUsesPinnedTerms"] == nil
              && ((convertedObject?["engines"] as? [[String: Any]]) ?? []).allSatisfy { $0["context"] == nil && $0["allow"] != nil })
        // The save path: start on this file, change a setting, save with the app's writer, read again.
        let contextSaveURL = dir.appendingPathComponent("context-save/settings.json")
        try? FileManager.default.createDirectory(at: contextSaveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(engineContextFile.utf8).write(to: contextSaveURL)
        let contextStore = SettingsFileStore(url: contextSaveURL)
        var contextStarted = contextStore.startup(fallback: AppSettings())
        contextStarted.boxOpacity = 0.9
        contextStore.save(contextStarted)
        let contextSaved = SettingsFileCheck.read((try? Data(contentsOf: contextSaveURL)) ?? Data(), over: AppSettings())
        check("engine context survives the app's save: start on the file, change a setting, save, read again; the converted amount, learning, permissions and rows are the same, and the old file is kept beside it",
              contextSaved.issues.isEmpty && contextSaved.settings.boxOpacity == 0.9 && !contextSaved.convertedFromOldShape
              && contextSaved.settings.context == amountSix && contextSaved.settings.useLearned && contextSaved.settings.engines.map(\.allow) == [qwenAllow, deepLAllow]
              && contextSaved.settings.glossaryApply == .both
              && (try? Data(contentsOf: contextSaveURL.deletingLastPathComponent().appendingPathComponent(SettingsFileStore.oldShapeName))) == Data(engineContextFile.utf8))
        // All five kinds, each with its permissions.
        var everyKindAllow = everyKind
        everyKindAllow.engines = everyKind.engines.enumerated().map { i, e in
            var c = e
            c.allow = EngineAllow(lines: i % 2 != 0, title: true, deepLInstructions: i % 2 == 0)
            return c
        }
        let everyKindAllowRead = SettingsFileCheck.read(SettingsFileFormat.render(everyKindAllow), over: AppSettings())
        check("engine allow: engines of all five kinds, each with its permissions, are written by the app and read back equal with no issue",
              everyKindAllowRead.settings == everyKindAllow && everyKindAllowRead.issues.isEmpty && everyKindAllowRead.settings.engines.allSatisfy { $0.allow != .default })
        // The model: a file of 1.1.4 is applied, and a change in Settings writes the new shape.
        let enginesBefore = model.settings.engines
        let flagBefore = model.settings.appleUsesPinnedTerms
        let contextBefore = model.settings.context, learnedBefore = model.settings.useLearned, applyBefore = model.settings.glossaryApply
        try? Data(engineContextFile.utf8).write(to: model.settingsFile.url, options: .atomic)
        model.settingsFileChanged()
        let appliedAllows = model.settings.engines.map(\.allow)
        model.settings.lensStyle = .subtle
        let contextResaved = (try? JSONSerialization.jsonObject(with: Data(text(model.settingsFile.url).utf8))) as? [String: Any]
        check("engine context: the file of 1.1.4 applies to the app and a change in Settings writes it in the new shape (no engines[].context, no appleUsesPinnedTerms)",
              model.settingsIssues.isEmpty && appliedAllows == [qwenAllow, deepLAllow] && model.settings.context == amountSix && model.settings.appleUsesPinnedTerms
              && contextResaved?["appleUsesPinnedTerms"] == nil && (contextResaved?["context"] as? [String: Any])?["previousLines"] as? Int == 6
              && ((contextResaved?["engines"] as? [[String: Any]]) ?? []).allSatisfy { $0["context"] == nil })
        // Editing an engine in Settings (the sheet builds the engine from its own fields, so it has no permissions) keeps the stored ones.
        if let edited = model.settings.engines.first {
            model.updateEngine(EngineConfig(id: edited.id, name: "Renamed in Settings", kind: edited.kind))
            let afterEdit = model.settings.engines.first
            model.duplicateEngine(edited.id)
            let copy = model.settings.engines.last
            check("engine allow: editing the engine in Settings (updateEngine) keeps its permissions, the name changes; a duplicate carries them under a new id",
                  afterEdit?.name == "Renamed in Settings" && afterEdit?.allow == qwenAllow && afterEdit?.id == edited.id
                  && model.settings.engines.count == 3 && copy?.id != edited.id && copy?.allow == qwenAllow)
        } else {
            check("engine allow: editing the engine in Settings keeps its permissions (the file's engines were not applied)", false)
        }
        model.settings.engines = enginesBefore
        model.settings.appleUsesPinnedTerms = flagBefore
        (model.settings.context, model.settings.useLearned, model.settings.glossaryApply) = (contextBefore, learnedBefore, applyBefore)
        model.settings.lensStyle = .glow

        // The check: a wrong value inside an engine's context is reported with its path and line, ends in "ignored", and the rest applies.
        let tooManyFile = """
        {
          "engines": [
            {
              "baseURL": "http://localhost:8765/v1",
              "context": {
                "enabled": true,
                "previousLines": 12
              },
              "kind": "openAICompatible",
              "name": "Local"
            }
          ]
        }
        """
        let tooMany = SettingsFileCheck.read(Data(tooManyFile.utf8), over: AppSettings())
        let previousLinesIssue = "engines[0].context.previousLines: 12 is out of range 0 to \(AppContextOverride.maxPreviousLines); ignored"
        check("engine context: \"previousLines\": 12 is reported with its path and line and ends in ignored; the engine applies with the default lines",
              tooMany.issues == [SettingsFileIssue(line: 7, message: previousLinesIssue)]
              && tooMany.settings.engines.map(\.name) == ["Local"]
              && tooMany.settings.context == AppContextOverride(mode: .conversation, previousLines: AppContextOverride.defaultPreviousLines))
        let mistakes = SettingsFileCheck.read(Data("""
        {
          "engines": [
            {
              "baseURL": "https://api.deepl.com",
              "context": {
                "enabled": "yes",
                "includeTitel": true,
                "useLearned": true
              },
              "kind": "deepL",
              "name": "D"
            },
            {
              "baseURL": "https://api.deepl.com",
              "context": 5,
              "kind": "deepL",
              "name": "E"
            }
          ]
        }
        """.utf8), over: AppSettings())
        check("engine context: a wrong type, a misspelt key and a context that is not an object are each reported with their line; the engines apply",
              mistakes.issues == [
                  SettingsFileIssue(line: 6, message: "engines[0].context.enabled: expected true or false, got a string; ignored"),
                  SettingsFileIssue(line: 7, message: "unknown key engines[0].context.includeTitel (did you mean includeTitle?)"),
                  SettingsFileIssue(line: 15, message: "engines[1].context: expected an object, got a number; ignored"),
              ]
              && mistakes.settings.engines.map(\.name) == ["D", "E"] && mistakes.settings.engines.allSatisfy { $0.context == nil && $0.allow == .default }
              && mistakes.settings.context == nil && !mistakes.settings.useLearned)
        // One rule for an engine's context in a file: the file check and the Core converter give the same new-shape values for the same text.
        let engineContextTexts = [
            #"{"enabled":true,"previousLines":12}"#, #"{"enabled":true,"previousLines":9}"#, #"{"enabled":true,"previousLines":-1}"#,
            #"{"enabled":true,"previousLines":5.5}"#, #"{"enabled":true,"previousLines":"many"}"#, #"{"enabled":true,"previousLines":true}"#,
            #"{"enabled":true,"previousLines":null}"#, #"{"enabled":true,"previousLines":0}"#, #"{"enabled":true,"previousLines":8}"#,
            #"{"enabled":true}"#, #"{"enabled":"yes","useLearned":true}"#, #"{"enabled":1}"#, #"{"enabled":null,"includeTitle":true}"#,
            #"{"includeTitle":true,"useLearned":false,"deepLInstructions":true}"#, #"{"future":1,"enabled":true}"#, #"{}"#, #"5"#, #""on""#, #"[true]"#, #"null"#,
        ]
        struct Converted: Equatable { var context: AppContextOverride?; var learned: Bool; var allow: EngineAllow? }
        let engineContextAgreement = engineContextTexts.map { context -> (text: String, viaFile: Converted, direct: Converted) in
            let engine = #"{"baseURL":"https://api.deepl.com","kind":"deepL","name":"D","context":\#(context)}"#
            let file = SettingsFileCheck.read(Data(#"{"engines":[\#(engine)]}"#.utf8), over: AppSettings()).settings
            let legacy = (try? JSONDecoder().decode(LegacySettings.self, from: Data(#"{"engines":[\#(engine)]}"#.utf8))) ?? LegacySettings()
            let direct = ProfileMigration.convert(legacy).value
            return (context, Converted(context: file.context, learned: file.useLearned, allow: file.engines.first?.allow),
                    Converted(context: direct.context, learned: direct.useLearned ?? false, allow: direct.engines?.first?.allow))
        }
        for row in engineContextAgreement where row.viaFile != row.direct {
            print("check-logic: engine context \(row.text): the file check gives \(row.viaFile), the Core converter \(row.direct)")
        }
        check("engine context: a context in a file converts the same through the file check and through the Core converter, out-of-range, fractional, wrong-typed and missing values included",
              engineContextAgreement.allSatisfy { $0.viaFile == $0.direct }
              && engineContextAgreement[0].viaFile.context == AppContextOverride(mode: .conversation, previousLines: AppContextOverride.defaultPreviousLines)
              && engineContextAgreement[8].viaFile.context == AppContextOverride(mode: .conversation, previousLines: AppContextOverride.maxPreviousLines)
              && engineContextAgreement[15].viaFile.context == nil && engineContextAgreement[15].viaFile.allow == .default)
        // And the command: an agent running --check-settings sees the documented line.
        let tooManyFileURL = dir.appendingPathComponent("too-many.json")
        try? Data((tooManyFile + "\n").utf8).write(to: tooManyFileURL)
        let tooManyCommand = command(["--check-settings", tooManyFileURL.path])
        check("engine context: --check-settings prints the previousLines line and exits 1 (after the note that the file is converted on the next save)",
              tooManyCommand.0 == 1 && tooManyCommand.1.hasSuffix("too-many.json:7: \(previousLinesIssue)\n")
              && tooManyCommand.1.contains("converted on the next save") && tooManyCommand.1.split(separator: "\n").count == 2)

        // The Apple switch of 1.1.4 is a glossary mode and each row's mode now; the key is read, never written.
        var pinned = AppSettings()
        pinned.glossaryApply = .both
        let renderedOff = String(decoding: SettingsFileFormat.render(AppSettings()), as: UTF8.self)
        let renderedOn = String(decoding: SettingsFileFormat.render(pinned), as: UTF8.self)
        check("appleUsesPinnedTerms is off by default (a view of the glossary's and the rows' mode)", AppSettings().glossaryApply == .hint && AppSettings().appleUsesPinnedTerms == false
              && AppSettings().effective(frontmost: "x").appleUsesPinnedTerms == false && pinned.appleUsesPinnedTerms)
        check("glossaryApply: the file leaves it out while it is hint, writes it while it is not, and never writes appleUsesPinnedTerms",
              !renderedOff.contains("glossaryApply") && renderedOn.contains("\n  \"glossaryApply\": \"both\",\n") && !renderedOn.contains("appleUsesPinnedTerms"))
        check("glossaryApply: on → file → on, and a 1.1.4 file with the switch false turns it off",
              SettingsFileCheck.read(SettingsFileFormat.render(pinned), over: AppSettings()).settings.glossaryApply == .both
              && SettingsFileCheck.read(Data(#"{"appleUsesPinnedTerms": false}"#.utf8), over: pinned).settings.glossaryApply == .hint
              && SettingsFileCheck.read(Data(#"{"appleUsesPinnedTerms": false}"#.utf8), over: pinned).issues.isEmpty
              && SettingsFileCheck.read(Data(#"{"appleUsesPinnedTerms": true}"#.utf8), over: AppSettings()).settings.glossaryApply == .both)
        let pinnedWrong = SettingsFileCheck.read(Data("{\n  \"appleUsesPinnedTerms\": \"yes\"\n}\n".utf8), over: pinned)
        check("appleUsesPinnedTerms: a wrong type is reported with its line and keeps the current value",
              pinnedWrong.issues == [SettingsFileIssue(line: 2, message: "appleUsesPinnedTerms: expected true or false, got a string; keeping the current value")]
              && pinnedWrong.settings.appleUsesPinnedTerms)
        check("glossaryApply: a key the file leaves out keeps the current value, like every other key",
              SettingsFileCheck.read(Data("{}".utf8), over: pinned).settings.glossaryApply == .both
              && SettingsFileCheck.changedKeys(AppSettings(), pinned) == ["glossaryApply"])
        check("the schema lists glossaryApply with its default, and appleUsesPinnedTerms as deprecated: read, never written", {
            let properties = ((try? JSONSerialization.jsonObject(with: SettingsSchema.data())) as? [String: Any])?["properties"] as? [String: Any]
            let apply = properties?["glossaryApply"] as? [String: Any], old = properties?["appleUsesPinnedTerms"] as? [String: Any]
            return SettingSpec.spec(for: "glossaryApply") != nil && apply?["enum"] as? [String] == ["hint", "replace", "both"] && apply?["default"] as? String == "hint"
                && old?["type"] as? String == "boolean" && old?["deprecated"] as? Bool == true && (old?["description"] as? String)?.contains("never written") == true
        }())
        // A 1.1.2 settings.json: all 24 keys 1.1.2 wrote and none of the later ones. Read, it is converted (`appProfiles` is `profiles`); saved
        // again it is the same file with that one key renamed, and the old file is kept beside it (1.1.2 and 1.1.4 wrote the same keys).
        let v112File = """
        {
          "$schema": "settings.schema.json",
          "appProfiles": [],
          "boxOpacity": 0.94,
          "cacheSize": 5000,
          "checksForUpdates": true,
          "customEngineID": null,
          "engine": "auto",
          "engines": [],
          "exportFolder": "/Users/test/Documents/Mwoyeo",
          "fontStyle": "system",
          "framesPerSecond": 8,
          "glossary": "",
          "lensStyle": "glow",
          "lensTabPosition": "topLeading",
          "lensTabVisibility": "automatic",
          "lensTint": "spectrum",
          "paragraphReader": "automatic",
          "renderMode": "adaptive",
          "savesTranscripts": false,
          "settleDelay": 0.5,
          "shortcuts": {},
          "sourceLanguage": "auto",
          "targetLanguage": "en",
          "transcriptFormats": [
            "markdown",
            "srt"
          ],
          "useInpaintingModel": true
        }
        """ + "\n"
        let v112Real = SettingsFileCheck.read(Data(v112File.utf8), over: AppSettings())
        let v112Disk = dir.appendingPathComponent("v112-real/settings.json")
        try? FileManager.default.createDirectory(at: v112Disk.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(v112File.utf8).write(to: v112Disk)
        let v112Store = SettingsFileStore(url: v112Disk)
        v112Store.save(v112Store.startup(fallback: AppSettings()))
        // The same file with `appProfiles` renamed `profiles` (sorted: after paragraphReader, before renderMode).
        var renamedLines = v112File.components(separatedBy: "\n").filter { $0 != "  \"appProfiles\": []," }
        if let at = renamedLines.firstIndex(of: "  \"renderMode\": \"adaptive\",") { renamedLines.insert("  \"profiles\": [],", at: at) }
        let v112Renamed = renamedLines.joined(separator: "\n")
        check("a 1.1.2 settings.json (the 24 keys of 1.1.2 and no later one) is read without issues and saved again as the same file with appProfiles renamed profiles, by the renderer and by the store; the old file is kept",
              v112Real.issues.isEmpty && v112Real.convertedFromOldShape && String(decoding: SettingsFileFormat.render(v112Real.settings), as: UTF8.self) == v112Renamed
              && text(v112Disk) == v112Renamed && Set(((try? JSONSerialization.jsonObject(with: Data(v112File.utf8))) as? [String: Any] ?? [:]).keys).count == 25
              && (try? String(contentsOf: v112Disk.deletingLastPathComponent().appendingPathComponent(SettingsFileStore.oldShapeName), encoding: .utf8)) == v112File
              && v112Real.settings.engines.isEmpty && v112Real.settings.appleUsesPinnedTerms == false)

        // Schema, nested
        func at(_ root: Any?, _ path: String...) -> Any? {
            path.reduce(root) { node, key in (node as? [String: Any])?[key] }
        }
        let schemaObject = (try? JSONSerialization.jsonObject(with: SettingsSchema.data())) as? [String: Any]
        let profile = at(schemaObject, "properties", "appProfiles", "items")
        let engineItem = at(schemaObject, "properties", "engines", "items")
        let entryItem = at(profile, "properties", "entries", "items")
        let addressingItem = at(entryItem, "properties", "addressing", "items")
        check("schema: nested objects are closed, with enums, ranges, length and item caps from the Core types, and the uuid format",
              at(profile, "additionalProperties") as? Bool == false && at(engineItem, "additionalProperties") as? Bool == false
              && at(entryItem, "additionalProperties") as? Bool == false && at(addressingItem, "additionalProperties") as? Bool == false
              && at(profile, "properties", "context", "additionalProperties") as? Bool == false
              && at(profile, "properties", "source", "enum") as? [String] == Languages.sources
              && at(profile, "properties", "paragraphReader", "enum") as? [String] == ParagraphReader.allCases.map(\.rawValue)
              && at(engineItem, "properties", "thinking", "enum") as? [String] == ["off", "provider"]
              && at(entryItem, "properties", "kind", "enum") as? [String] == EntryKind.allCases.map(\.rawValue)
              && at(entryItem, "properties", "gender", "enum") as? [String] == Gender.allCases.map(\.rawValue)
              && at(addressingItem, "properties", "register", "enum") as? [String] == Register.allCases.map(\.rawValue)
              && at(profile, "properties", "context", "properties", "mode", "enum") as? [String] == AppContextOverride.Mode.allCases.map(\.rawValue)
              && at(profile, "properties", "context", "properties", "previousLines", "minimum") as? Int == 0
              && at(profile, "properties", "context", "properties", "previousLines", "maximum") as? Int == AppContextOverride.maxPreviousLines
              && at(profile, "properties", "context", "properties", "previousLines", "default") as? Int == AppContextOverride.defaultPreviousLines
              && at(profile, "properties", "context", "required") as? [String] == ["mode"]
              && at(profile, "properties", "note", "maxLength") as? Int == AppProfile.maxNoteLength
              && at(profile, "properties", "entries", "maxItems") as? Int == AppProfile.maxEntries
              && at(entryItem, "properties", "note", "maxLength") as? Int == MemoryEntry.maxEntryNote
              && at(entryItem, "properties", "src", "maxLength") as? Int == MemoryEntry.maxName
              && at(entryItem, "properties", "addressing", "maxItems") as? Int == MemoryEntry.maxAddressing
              && at(entryItem, "required") as? [String] == ["src", "dst"] && at(addressingItem, "required") as? [String] == ["to", "register"]
              && at(profile, "properties", "customEngineID", "format") as? String == "uuid"
              && at(profile, "required") as? [String] == ["bundleID", "source", "target"])
        // The schema's fields against the app's, at every level (the failure mode: the schema describes a field the app drops
        // on save, or the app keeps a field the schema never mentions). The app's keys are those a fully populated value
        // encodes; a new field of a Core type that this value leaves empty is caught by AppProfileTests, which compares the
        // same encoded keys with the type's CodingKeys.
        let populated = AppProfile(
            bundleID: "a", appName: "A", source: "ja", target: "en", customEngineID: engine.id, paragraphReader: .lineGrouping, note: "n",
            entries: [MemoryEntry(src: "s", dst: "d", kind: .person, gender: .f, note: "n", reading: "r",
                                  addressing: [Addressing(to: "t", register: .polite)], apply: .both)],
            context: AppContextOverride(mode: .conversation, previousLines: 5))
        let populatedKeys = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(populated))) as? [String: Any] ?? [:]
        let populatedEntry = (populatedKeys["entries"] as? [[String: Any]])?.first ?? [:]
        let populatedAddressing = (populatedEntry["addressing"] as? [[String: Any]])?.first ?? [:]
        func schemaKeys(_ object: Any?) -> Set<String> { Set((at(object, "properties") as? [String: Any] ?? [:]).keys) }
        // The engines: one fully populated engine of each of the five kinds, each with a full context. The schema of `engines[]` is
        // the union of the kinds' fields, so the union of the encoded keys must equal it, and `engines[].context` must equal the
        // encoded context.
        let populatedContext = EngineContext(enabled: true, previousLines: 5, includeTitle: true, useLearned: true, deepLInstructions: true)
        let populatedAllow = EngineAllow(lines: false, title: true, deepLInstructions: true)
        let populatedEngines = [
            EngineConfig(id: engine.id, name: "a", kind: .openAICompatible(baseURL: URL(string: "http://localhost:8765/v1")!, model: "m", thinking: .provider, extraHeaders: ["X": "1"]), context: populatedContext, allow: populatedAllow),
            EngineConfig(name: "b", kind: .anthropic(baseURL: URL(string: "https://api.anthropic.com")!, model: "m", thinking: .provider), context: populatedContext, allow: populatedAllow),
            EngineConfig(name: "c", kind: .deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: "more"), context: populatedContext, allow: populatedAllow),
            EngineConfig(name: "d", kind: .httpTemplate(HTTPTemplate(url: "http://h/t", resultPath: "r")), context: populatedContext, allow: populatedAllow),
            EngineConfig(name: "e", kind: .command(CommandSpec(executable: "/bin/x")), context: populatedContext, allow: populatedAllow),
        ]
        let populatedEngineObjects = populatedEngines.compactMap { (try? JSONSerialization.jsonObject(with: JSONEncoder().encode($0))) as? [String: Any] }
        let populatedContextObject = populatedEngineObjects.first?["context"] as? [String: Any] ?? [:]
        let populatedAllowObject = populatedEngineObjects.first?["allow"] as? [String: Any] ?? [:]
        // The new shape's profile: the file's own type (`ProfileFile`), fully populated, against the schema of `profiles[]`.
        var populatedProfile = AppProfile(bundleID: "a", appName: "A", source: "ja", target: "en", customEngineID: engine.id, paragraphReader: .lineGrouping, note: "n",
                                          entries: populated.entries, context: AppContextOverride(mode: .conversation, previousLines: 5), id: "a",
                                          when: [ProfileCondition(app: "a", titleContains: "t")], useLearned: true)
        // A row with every key it writes (`regex` only when true, `on` only when false), and a script that is off.
        populatedProfile.rewrites = [RewriteRow(.before, "f", "r", regex: true, on: false)]
        populatedProfile.script = RewriteScript(source: "s", on: false)
        let populatedFile = ProfileFile(populatedProfile)
        let populatedFileKeys = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(populatedFile))) as? [String: Any] ?? [:]
        let fileProfile = at(schemaObject, "properties", "profiles", "items")
        let levels: [(name: String, app: Set<String>, schema: Set<String>)] = [
            ("appProfiles[]", Set(populatedKeys.keys), schemaKeys(profile)),
            ("appProfiles[].entries[]", Set(populatedEntry.keys), schemaKeys(entryItem)),
            ("appProfiles[].entries[].addressing[]", Set(populatedAddressing.keys), schemaKeys(addressingItem)),
            ("appProfiles[].context", Set((populatedKeys["context"] as? [String: Any] ?? [:]).keys), schemaKeys(at(profile, "properties", "context"))),
            ("engines[]", populatedEngineObjects.reduce(into: Set<String>()) { $0.formUnion($1.keys) }, schemaKeys(engineItem)),
            ("engines[].context", Set(populatedContextObject.keys), schemaKeys(at(engineItem, "properties", "context"))),
            ("engines[].allow", Set(populatedAllowObject.keys), schemaKeys(at(engineItem, "properties", "allow"))),
            ("profiles[]", Set(populatedFileKeys.keys), schemaKeys(fileProfile)),
            ("profiles[].entries[]", Set(((populatedFileKeys["entries"] as? [[String: Any]])?.first ?? [:]).keys), schemaKeys(at(fileProfile, "properties", "entries", "items"))),
            ("profiles[].when[]", Set(((populatedFileKeys["when"] as? [[String: Any]])?.first ?? [:]).keys), schemaKeys(at(fileProfile, "properties", "when", "items"))),
            ("profiles[].context", Set((populatedFileKeys["context"] as? [String: Any] ?? [:]).keys), schemaKeys(at(fileProfile, "properties", "context"))),
            ("profiles[].rewrites[]", Set(((populatedFileKeys["rewrites"] as? [[String: Any]])?.first ?? [:]).keys), schemaKeys(at(fileProfile, "properties", "rewrites", "items"))),
            ("profiles[].script", Set((populatedFileKeys["script"] as? [String: Any] ?? [:]).keys), schemaKeys(at(fileProfile, "properties", "script"))),
        ]
        for level in levels {
            check("schema: \(level.name) has exactly the fields the app keeps", !level.app.isEmpty && level.app == level.schema)
            if level.app != level.schema {
                print("check-logic: \(level.name): only the app keeps \(level.app.subtracting(level.schema).sorted()); only the schema describes \(level.schema.subtracting(level.app).sorted())")
            }
        }
        func undocumented(_ node: Any?, _ path: String) -> [String] {
            guard let object = node as? [String: Any] else { return [] }
            var missing: [String] = []
            for (name, child) in (object["properties"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                guard let c = child as? [String: Any] else { continue }
                if !(c["description"] is String) { missing.append("\(path).\(name)") }
                missing += undocumented(c, "\(path).\(name)")
            }
            for key in ["items", "additionalProperties"] { missing += undocumented(object[key], "\(path).\(key)") }
            for branch in object["allOf"] as? [[String: Any]] ?? [] { missing += undocumented(branch["then"], "\(path).then") }
            return missing
        }
        let undocumentedProperties = undocumented(schemaObject, "")
        check("schema: every property, nested ones too, has a description", undocumentedProperties.isEmpty)
        if !undocumentedProperties.isEmpty { print("check-logic: without a description: \(undocumentedProperties)") }
        check("schema: engines and profiles carry examples, the profile one with a note, two entries with addressing and a context",
              ((at(schemaObject, "properties", "engines", "examples") as? [Any])?.count ?? 0) >= 1
              && ((at(schemaObject, "properties", "profiles", "examples") as? [[[String: Any]]])?.first?.first).map { p in
                  p["id"] as? String == "com.example.chat" && p["note"] is String && (p["entries"] as? [[String: Any]])?.count == 2
                  && (p["entries"] as? [[String: Any]])?.allSatisfy { ($0["addressing"] as? [Any])?.isEmpty == false } == true && p["context"] != nil
              } == true)
        let badExamples = SettingSpec.all.flatMap { spec in
            spec.examples.compactMap { example -> String? in
                var problems: [FieldProblem] = []
                _ = spec.read(example, problems: &problems)
                return problems.isEmpty ? nil : "\(spec.key): \(problems.map(\.message))"
            }
        } + SettingSpec.all.flatMap { spec in
            spec.kind.fields.compactMap { field -> String? in
                guard let example = field.example else { return nil }
                var problems: [FieldProblem] = []
                _ = field.kind.read(example, at: FieldPath(steps: [.key(field.name)]), fallout: .keep, problems: &problems)
                return problems.isEmpty ? nil : "\(spec.key).\(field.name): \(problems.map(\.message))"
            }
        }
        check("every example in the spec trees passes the check", badExamples.isEmpty)
        if !badExamples.isEmpty { print("check-logic: bad examples: \(badExamples)") }
        let schemaText = SettingsSchema.data()
        check("schema: the output is deterministic and in the app's own format (sorted keys, two-space indent)",
              schemaText == SettingsSchema.data() && schemaObject.map { Data((SettingsFileFormat.pretty($0) + "\n").utf8) == schemaText } == true)
        check("schema: the file next to settings.json is the schema --settings-schema prints",
              (try? Data(contentsOf: migrated.deletingLastPathComponent().appendingPathComponent("settings.schema.json"))) == schemaText)

        // Invalid JSON: nothing applied, file untouched, a UI change keeps the broken file first
        edited = "{\n  \"lensStyle\": \"glow\",\n  \"cacheSize\": ,\n}\n"
        try? Data(edited.utf8).write(to: migrated, options: .atomic)
        let broken = store.fileChanged(current: reload?.settings ?? changed)
        check("invalid JSON: nothing is applied and the line is reported",
              broken == nil && store.issues.count == 1 && store.issues[0].line == 3 && store.issues[0].message.hasPrefix("invalid JSON"))
        check("invalid JSON: the file is not overwritten by a reload", text(migrated) == edited)
        var current = reload?.settings ?? changed
        current.boxOpacity = 0.9
        store.save(current)
        let brokenCopy = migrated.appendingPathExtension("broken")
        check("a change made while it is broken first copies it to settings.json.broken", text(brokenCopy) == edited)
        check("…then writes the file, and the issue says so",
              SettingsFileCheck.read((try? Data(contentsOf: migrated)) ?? Data(), over: AppSettings()).settings == current
              && store.issues.count == 1 && store.issues[0].message.contains("settings.json.broken"))
        current.boxOpacity = 0.8
        store.save(current)
        check("a second change keeps the broken copy as typed and clears the notice",
              text(brokenCopy) == edited && store.issues.isEmpty)
        try? FileManager.default.removeItem(at: migrated)
        _ = store.fileChanged(current: current)
        check("a deleted file is written again", FileManager.default.fileExists(atPath: migrated.path))

        // Schema
        check("the schema covers every key the file holds", SettingsFileCheck.uncoveredKeys().isEmpty)
        if !SettingsFileCheck.uncoveredKeys().isEmpty { print("check-logic: missing from the schema: \(SettingsFileCheck.uncoveredKeys())") }
        let schema = (try? JSONSerialization.jsonObject(with: SettingsSchema.data())) as? [String: Any]
        let props = schema?["properties"] as? [String: Any] ?? [:]
        let keys = Set(SettingsFileCheck.fileValues(AppSettings()).keys)
        check("the schema is JSON, draft 2020-12, with a description and type for each key",
              (schema?["$schema"] as? String)?.contains("2020-12") == true && keys.isSubset(of: Set(props.keys))
              && keys.allSatisfy { k in
                  let p = props[k] as? [String: Any]
                  return p?["description"] is String && (p?["type"] != nil)
              })
        check("the schema carries enums, ranges and defaults",
              ((props["lensStyle"] as? [String: Any])?["enum"] as? [String]) == LensStyle.allCases.map(\.rawValue)
              && (props["boxOpacity"] as? [String: Any])?["minimum"] as? Double == 0.6
              && (props["lensStyle"] as? [String: Any])?["default"] as? String == "glow")

        // The translation log
        let formats = SettingsFileCheck.read(Data("{\n  \"transcriptFormats\": [\"jsonl\", \"csv\", \"srt\"]\n}\n".utf8), over: AppSettings())
        check("transcriptFormats: an unknown format is reported with its line and dropped, the others apply",
              formats.settings.transcriptFormats == [.jsonl, .srt] && formats.issues.count == 1 && formats.issues[0].line == 2
              && formats.issues[0].message.contains("\"csv\"") && formats.issues[0].message.contains("markdown, srt, jsonl"))
        check("transcriptFormats: not a list is reported and keeps the value",
              SettingsFileCheck.read(Data("{\"transcriptFormats\": \"jsonl\"}".utf8), over: changed).settings == changed)
        check("transcriptFormats defaults to markdown and srt, as before", AppSettings().transcriptFormats == [.markdown, .srt]
              && ((props["transcriptFormats"] as? [String: Any])?["default"] as? [String]) == ["markdown", "srt"])
        let logDir = dir.appendingPathComponent("log")
        let writer = TranscriptWriter(directory: logDir, lens: "Chat", sourceCode: "auto", targetCode: "ko", formats: [.jsonl], engine: "Ollama", onError: {})
        writer.setApp("com.example.app")
        writer.observe(time: 1, lines: [.init(source: "こんにちは", translation: "안녕하세요", inLens: true)])
        writer.observe(time: 3, lines: [.init(source: "こんにちは", translation: "안녕하세요", inLens: true), .init(source: "ありがとう", translation: "고마워", inLens: true)])
        writer.finishAndWait(time: 2)
        let written = ((try? FileManager.default.contentsOfDirectory(atPath: logDir.path)) ?? []).sorted()
        let jsonl = written.first { $0.hasSuffix(".jsonl") }.map { text(logDir.appendingPathComponent($0)) } ?? ""
        jsonl.split(separator: "\n").forEach { print("check-logic: jsonl line: \($0)") }
        let firstLine = jsonl.split(separator: "\n").first.map(String.init) ?? ""
        let row = (try? JSONSerialization.jsonObject(with: Data(firstLine.utf8))) as? [String: Any]
        check("jsonl only: one .jsonl file and no Markdown or SRT, one line with the agreed fields",
              written.count == 1 && jsonl.hasSuffix("}\n") && jsonl.split(separator: "\n").count == 2 && row?["original"] as? String == "こんにちは" && row?["translation"] as? String == "안녕하세요"
              && row?["app"] as? String == "com.example.app" && row?["engine"] as? String == "Ollama" && row?["source"] as? String == "auto"
              && row?["target"] as? String == "ko" && row?["lens"] as? String == "Chat" && (row?["time"] as? String)?.contains(".") == true)

        // The command line
        let good = dir.appendingPathComponent("good.json"), bad = dir.appendingPathComponent("bad.json")
        try? rendered.write(to: good)
        try? Data("{\n  \"lenStyle\": \"glow\",\n  \"cacheSize\": \"big\"\n}\n".utf8).write(to: bad)
        let g = command(["--check-settings", good.path]), b = command(["--check-settings", bad.path])
        check("--check-settings: ok and exit 0 on a good file", g.0 == 0 && g.1 == "ok\n")
        check("--check-settings: one line per issue and exit 1 on a bad file",
              b.0 == 1 && b.1.contains("bad.json:2: unknown key lenStyle (did you mean lensStyle?)") && b.1.contains("bad.json:3: cacheSize:"))
        let p = command(["--settings-path"])
        check("--settings-path prints the file path", p.0 == 0 && p.1 == model.settingsFile.url.path + "\n")
        let printed = command(["--settings-schema"])
        if printed.0 == 0, Data(printed.1.utf8) != schemaText {
            let ours = String(decoding: schemaText, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            let theirs = printed.1.split(separator: "\n", omittingEmptySubsequences: false)
            for (i, (x, y)) in zip(ours, theirs).enumerated() where x != y {
                print("check-logic: --settings-schema differs at line \(i + 1): this run \(x.trimmingCharacters(in: .whitespaces)) | the command \(y.trimmingCharacters(in: .whitespaces))")
                break
            }
        }
        check("--settings-schema prints the schema and exits 0 (a run that does not end in time fails)", printed.0 == 0 && Data(printed.1.utf8) == schemaText)
        // A flag that is in no row of the usage text starts nothing (round text2, F3: on 3a2e86a it opened the app, on the settings path of whoever ran it).
        let scratch = dir.appendingPathComponent("unknown-flag", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        var quiet = ProcessInfo.processInfo.environment
        quiet["HOME"] = scratch.path
        quiet["MWOYEO_SETTINGS_FILE"] = scratch.appendingPathComponent("settings.json").path
        quiet["MWOYEO_DEFAULTS_SUITE"] = "dev.midagedev.mwoyeo.unknown-flag-check"
        for flag in ["--help", "-h", "--bogus"] {
            let r = launch([flag], environment: quiet, within: 10, captureError: true)
            let written = (try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? ["unreadable"]
            let refused = r.status == 64 && r.err.hasPrefix("Mwoyeo: unknown option \(flag)\n") && r.err.contains("usage: Mwoyeo") && r.out.isEmpty && written.isEmpty
            if !refused { print("check-logic: note: \(flag) exit \(r.status) stderr \(r.err.prefix(80)) written \(written)") }
            check("\(flag): usage naming it on stderr, exit 64, nothing on stdout, the app not started, and no file written (home and settings path point at an empty folder)", refused)
            if r.status != 64 { break }   // the app was started (and ended after the wait): once is enough
        }
        let usage = CommandLineUsage.text(for: "--x")
        check("every flag the app reads is known, and the usage text lists each one of them",
              CommandLineUsage.flags.allSatisfy { CommandLineUsage.unknown(in: [$0.name]) == nil && usage.contains($0.name) }
              && CommandLineUsage.unknown(in: ["--relaunched", "123"]) == nil && CommandLineUsage.unknown(in: ["--x"]) == "--x")

        // The app: a change in Settings writes the file; an edit of the file applies
        let url = model.settingsFile.url
        model.settings.lensStyle = .subtle
        check("a change in Settings writes the file", text(url).contains("\"lensStyle\": \"subtle\""))
        let appEdit = text(url).replacingOccurrences(of: "\"lensStyle\": \"subtle\"", with: "\"lensStyle\": \"minimal\"")
            .replacingOccurrences(of: "\"checksForUpdates\": true", with: "\"checksForUpdates\": false")
        try? Data(appEdit.utf8).write(to: url, options: .atomic)
        model.settingsFileChanged()
        check("an edit of the file applies to the app and is not written back",
              model.settings.lensStyle == .minimal && model.settings.checksForUpdates == false && text(url) == appEdit
              && model.settingsIssues.isEmpty)
        // The same through the model: a file with the memory fields is applied, a change in Settings saves the file, and the
        // memory is still in it (the 1.1.2 save dropped it).
        let profilesBefore = model.settings.appProfiles
        try? Data(memoryFile.utf8).write(to: url, options: .atomic)
        model.settingsFileChanged()
        let appliedProfile = model.settings.appProfiles.first
        model.settings.lensStyle = .subtle
        let resaved = (try? JSONSerialization.jsonObject(with: Data(text(url).utf8))) as? [String: Any]
        check("the memory fields apply to the app and a change in Settings keeps them in the file",
              model.settingsIssues.isEmpty && appliedProfile?.note == memoryProfile?.note && appliedProfile?.entries == memoryProfile?.entries
              && appliedProfile?.context == memoryProfile?.context && appliedProfile?.context != nil
              && text(url).contains("\"lensStyle\": \"subtle\"")
              && ((resaved?["profiles"] as? [[String: Any]])?.first).map { item in ["note", "entries", "context"].allSatisfy {
                  (item[$0] as? NSObject)?.isEqual((memoryObject["appProfiles"] as? [[String: Any]])?.first?[$0] as? NSObject) == true } } == true)
        model.settings.appProfiles = profilesBefore
        model.settings.checksForUpdates = true
        model.settings.lensStyle = .glow
        failed += ProfileFileChecks.run(dir: dir)
        return failed
    }

    /// `rewrites` and `script`, top level and in a profile (rewrite-rules §1-§3, §9; round rewrite-run part B), and `profilePin` taking null (addendum A5).
    /// Run by `RewriteChecks.run`, so the quick `rewrite-checks` mode has them too.
    static func rewriteKeys() -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") settings file: \(what)" + (ok || detail().isEmpty ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
        func read(_ json: String, over current: AppSettings = AppSettings()) -> SettingsFileResult { SettingsFileCheck.read(Data(json.utf8), over: current) }

        // Nothing set: the file is the file it was, byte for byte (the key is not even listed).
        let plain = String(decoding: SettingsFileFormat.render(AppSettings()), as: UTF8.self)
        check("nothing set: neither rewrites nor script is written", !plain.contains("\"rewrites\"") && !plain.contains("\"script\""))

        var set = AppSettings()
        set.rewrites = [RewriteRow(.before, "▼"), RewriteRow(.before, "（[ぁ-ゖ]+）", regex: true), RewriteRow(.after, "...", "…", on: false)]
        set.script = RewriteScript(source: "function before(line, ctx) { return line }")
        set.appProfiles = [AppProfile(bundleID: "com.example.app", appName: "Example", source: "ja", target: "en")]
        set.appProfiles[0].rewrites = [RewriteRow(.after, "a", "b", regex: true)]
        set.appProfiles[0].script = RewriteScript(source: "function after(s, d, c) { return d }", on: false)
        let rendered = SettingsFileFormat.render(set)
        let back = SettingsFileCheck.read(rendered, over: AppSettings())
        let body = String(decoding: rendered, as: UTF8.self)
        check("rows and a script, All apps' and a profile's, survive the file; `regex` is written only when true and `on` only when false",
              back.settings == set && back.issues.isEmpty && !body.contains("\"regex\": false") && !body.contains("\"on\": true") && body.contains("\"on\": false"), "\(back.issues)")

        // The strict check: a bad row is reported and dropped, the others stay in order.
        let rows = """
        {"rewrites": [{"stage":"before","find":"a"},{"stage":"during","find":"b"},{"stage":"before","find":""},{"stage":"before","find":"\(String(repeating: "x", count: 201))"},
                      {"stage":"after","find":"c","replace":"\(String(repeating: "y", count: 201))"},{"stage":"after","find":"d","regex":"yes"},{"find":"e"},{"stage":"after","find":"f","replace":"g","on":false}]}
        """
        let dropped = read(rows)
        check("a row with a stage that is not one, an empty find, a find or a replace over 200, a regex that is not true or false, or no stage is reported and dropped; the rest stay",
              dropped.settings.rewrites == [RewriteRow(.before, "a"), RewriteRow(.after, "f", "g", on: false)] && dropped.issues.count >= 6
              && dropped.issues.contains { $0.message.contains("rewrites[1]") } && dropped.issues.contains { $0.message.contains("rewrites[2]") }, "\(dropped.settings.rewrites) \(dropped.issues.map(\.message))")
        let many = "{\"rewrites\": [" + (0..<(RewriteLimits.maxRows + 1)).map { "{\"stage\":\"before\",\"find\":\"f\($0)\"}" }.joined(separator: ",") + "]}"
        let capped = read(many)
        check("a 33rd row is reported and the first 32 apply", capped.settings.rewrites.count == RewriteLimits.maxRows && capped.issues.contains { $0.message.contains("33 items") && $0.message.contains("32") }, "\(capped.issues.map(\.message))")
        let longScript = read("{\"script\": {\"source\": \"\(String(repeating: "a", count: RewriteLimits.maxScript + 1))\"}}", over: set)
        check("a script over 8,000 characters is reported and the current one stays", longScript.settings.script == set.script && longScript.issues.contains { $0.message.contains("script") && $0.message.contains("8000") }, "\(longScript.issues.map(\.message))")
        let noSource = read("{\"script\": {\"on\": false}}", over: set)
        check("a script without a source is reported and the current one stays", noSource.settings.script == set.script && !noSource.issues.isEmpty)

        // In a profile: the same rows, dropped one by one, and the profile itself is kept.
        let inProfile = read("""
        {"profiles": [{"id": "p", "name": "P", "source": "ja", "target": "en", "rewrites": [{"stage":"before","find":"a"},{"stage":"sideways","find":"b"}], "script": {"source": "function after(s, d) { return d }"}}]}
        """)
        check("in a profile a bad row is reported with its place and dropped, and the profile with its script is kept",
              inProfile.settings.appProfiles.first?.rewrites == [RewriteRow(.before, "a")] && inProfile.settings.appProfiles.first?.script?.source == "function after(s, d) { return d }"
              && inProfile.issues.contains { $0.message.contains("profiles[0].rewrites[1]") }, "\(inProfile.issues.map(\.message))")
        check("the schema lists both keys with their limits and their examples pass, in All apps and in a profile",
              SettingSpec.spec(for: "rewrites") != nil && SettingSpec.spec(for: "script") != nil && SettingsFileCheck.uncoveredKeys().isEmpty
              && SettingSpec.missingRestoreColumns(SettingSpec.all).isEmpty)

        // profilePin: null is Auto (addendum A5, FAIL-first on the kind `.text`, which rejects null).
        var pinned = AppSettings()
        pinned.profilePin = "all"
        let cleared = read("{\"profilePin\": null}", over: pinned)
        check("profilePin accepts null: the pin goes and each lens is on Auto, with no issue", cleared.settings.profilePin == nil && cleared.issues.isEmpty, "\(cleared.issues.map(\.message))")
        let badPin = read("{\"profilePin\": \"\"}", over: pinned)
        check("profilePin still rejects an empty id and keeps the pin", badPin.settings.profilePin == "all" && !badPin.issues.isEmpty)
        let schemaPin = (SettingSpec.spec(for: "profilePin")?.kind.schema()["type"] as? [String]) ?? []
        check("the schema says profilePin may be a string or null", Set(schemaPin) == ["string", "null"], "\(schemaPin)")
        return failed
    }

    /// Runs this executable with `arguments`: (exit code, stdout). A run still going after `seconds` is ended and gives exit
    /// code -1, so a command that never exits (one the app does not dispatch starts the whole app) fails its check.
    /// The run speaks this process's language: `--lang` sets it in memory only, which a child does not inherit, and the schema's
    /// default for `targetLanguage` follows it (a 2026-10-19 English run printed "ko" against this run's "en").
    private static func command(_ arguments: [String], within seconds: Double = 20) -> (Int32, String) {
        let r = launch(arguments, within: seconds)
        return (r.status, r.out)
    }

    /// `command` with the environment it is given (this process's by default) and, when `captureError`, what the run wrote to stderr.
    private static func launch(_ arguments: [String], environment: [String: String]? = nil, within seconds: Double = 20, captureError: Bool = false)
        -> (status: Int32, out: String, err: String) {
        let p = Process(), pipe = Pipe(), errors = Pipe()
        p.executableURL = Bundle.main.executableURL
        p.arguments = arguments + ["-AppleLanguages", "(" + Locale.preferredLanguages.map { "\"\($0)\"" }.joined(separator: ", ") + ")"]
        p.standardOutput = pipe
        if captureError { p.standardError = errors }
        p.environment = environment ?? ProcessInfo.processInfo.environment
        let exited = DispatchSemaphore(value: 0), read = DispatchSemaphore(value: 0), readErrors = DispatchSemaphore(value: 0)
        let out = Output(), err = Output()
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, "", "") }
        DispatchQueue.global().async {
            out.data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        DispatchQueue.global().async {
            if captureError { err.data = errors.fileHandleForReading.readDataToEndOfFile() }
            readErrors.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + seconds) == .timedOut {
            timedOut = true
            p.terminate()
            _ = exited.wait(timeout: .now() + 5)
        }
        let complete = read.wait(timeout: .now() + 5) == .success
        let completeErrors = readErrors.wait(timeout: .now() + 5) == .success
        return (timedOut ? -1 : p.terminationStatus, complete ? String(decoding: out.data, as: UTF8.self) : "", completeErrors ? String(decoding: err.data, as: UTF8.self) : "")
    }

    /// What the reader thread of `command` collected; read only after it has signalled.
    private final class Output: @unchecked Sendable { var data = Data() }
}
#endif
