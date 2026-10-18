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
        // The per-app memory fields (note, entries, context) are not kept by the app yet, so each is an unknown key.
        let withNote = """
        {
          "appProfiles": [
            {
              "bundleID": "com.example.app",
              "note": "x",
              "source": "ja",
              "target": "en"
            }
          ]
        }
        """
        let noteRead = SettingsFileCheck.read(Data(withNote.utf8), over: changed)
        check("a profile's note is an unknown key: reported with its path and line, and the profile still applies",
              noteRead.issues == [SettingsFileIssue(line: 5, message: "unknown key appProfiles[0].note")]
              && noteRead.settings.appProfiles.map(\.bundleID) == ["com.example.app"] && noteRead.settings.appProfiles.first?.target == "en")
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

        // Schema, nested
        func at(_ root: Any?, _ path: String...) -> Any? {
            path.reduce(root) { node, key in (node as? [String: Any])?[key] }
        }
        let schemaObject = (try? JSONSerialization.jsonObject(with: SettingsSchema.data())) as? [String: Any]
        let profile = at(schemaObject, "properties", "appProfiles", "items")
        let engineItem = at(schemaObject, "properties", "engines", "items")
        check("schema: nested objects are closed, with enums and the uuid format",
              at(profile, "additionalProperties") as? Bool == false && at(engineItem, "additionalProperties") as? Bool == false
              && at(profile, "properties", "source", "enum") as? [String] == Languages.sources
              && at(profile, "properties", "paragraphReader", "enum") as? [String] == ParagraphReader.allCases.map(\.rawValue)
              && at(engineItem, "properties", "thinking", "enum") as? [String] == ["off", "provider"]
              && at(profile, "properties", "customEngineID", "format") as? String == "uuid"
              && at(profile, "required") as? [String] == ["bundleID", "source", "target"])
        // A field the schema describes but AppProfile does not keep would vanish at the app's next save of the file.
        let keptProfile = AppProfile(bundleID: "a", appName: "A", source: "ja", target: "en", customEngineID: engine.id, paragraphReader: .lineGrouping)
        let keptKeys = ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(keptProfile))) as? [String: Any]).map { Set($0.keys) }
        check("schema: a profile has exactly the fields AppProfile keeps",
              keptKeys != nil && Set((at(profile, "properties") as? [String: Any] ?? [:]).keys) == keptKeys)
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
        check("schema: engines and appProfiles carry examples",
              ((at(schemaObject, "properties", "engines", "examples") as? [Any])?.count ?? 0) >= 1
              && ((at(schemaObject, "properties", "appProfiles", "examples") as? [[[String: Any]]])?.first?.first?["bundleID"] as? String) == "com.example.chat")
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
        check("--settings-schema prints the schema and exits 0 (a run that does not end in time fails)", printed.0 == 0 && Data(printed.1.utf8) == schemaText)

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
        model.settings.checksForUpdates = true
        model.settings.lensStyle = .glow
        return failed
    }

    /// Runs this executable with `arguments`: (exit code, stdout). A run still going after `seconds` is ended and gives exit
    /// code -1, so a command that never exits (one the app does not dispatch starts the whole app) fails its check.
    private static func command(_ arguments: [String], within seconds: Double = 20) -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = Bundle.main.executableURL
        p.arguments = arguments
        p.standardOutput = pipe
        p.environment = ProcessInfo.processInfo.environment
        let exited = DispatchSemaphore(value: 0), read = DispatchSemaphore(value: 0)
        let out = Output()
        p.terminationHandler = { _ in exited.signal() }
        do { try p.run() } catch { return (-1, "") }
        DispatchQueue.global().async {
            out.data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.signal()
        }
        var timedOut = false
        if exited.wait(timeout: .now() + seconds) == .timedOut {
            timedOut = true
            p.terminate()
            _ = exited.wait(timeout: .now() + 5)
        }
        let complete = read.wait(timeout: .now() + 5) == .success
        return (timedOut ? -1 : p.terminationStatus, complete ? String(decoding: out.data, as: UTF8.self) : "")
    }

    /// What the reader thread of `command` collected; read only after it has signalled.
    private final class Output: @unchecked Sendable { var data = Data() }
}
