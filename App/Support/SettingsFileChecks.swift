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

    /// Runs this executable with `arguments`: (exit code, stdout).
    private static func command(_ arguments: [String]) -> (Int32, String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = Bundle.main.executableURL
        p.arguments = arguments
        p.standardOutput = pipe
        p.environment = ProcessInfo.processInfo.environment
        do { try p.run() } catch { return (-1, "") }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self))
    }
}
