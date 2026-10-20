import Foundation
import MwoyeoCore

/// The tools of `Mwoyeo --mcp`, one table: each case has its name, its description for the agent, its arguments and its handler.
/// The arguments are `FieldSpec`s, read by the very engine that reads settings.json (`FieldKind.read`), so a wrong argument is
/// reported with its path in the settings file's own words, and the memory's and the settings' fields are the settings file's own,
/// never a second copy.
enum MCPTool: String, CaseIterable {
    case listApps = "list_apps"
    case readTranslationLog = "read_translation_log"
    case getMemory = "get_memory"
    case setMemory = "set_memory"
    case getSettings = "get_settings"
    case setSettings = "set_settings"
    case getSettingsSchema = "get_settings_schema"

    var title: String {
        switch self {
        case .listApps: "List apps"
        case .readTranslationLog: "Read the translation log"
        case .getMemory: "Get an app's memory"
        case .setMemory: "Set an app's memory"
        case .getSettings: "Get settings"
        case .setSettings: "Set settings"
        case .getSettingsSchema: "Get the settings schema"
        }
    }

    /// What the tool is for, written for an agent.
    var summary: String {
        switch self {
        case .listApps:
            "Lists the apps Mwoyeo knows: the apps whose text is in the translation log (with their line counts and the time of the last line) and the apps that have a profile (whether it holds a memory, and how many names). Start here: the bundle IDs it lists are what the other tools take as app."
        case .readTranslationLog:
            "Reads the newest lines of the translation log, oldest first: what a lens read on the screen (original) and how it was translated (translation), with the time, the app's bundle ID, the languages and the engine. Use it to see which names and terms an app's text carries and how they came out. It needs Save transcripts on and jsonl among the transcript formats; the error says how to turn that on."
        case .getMemory:
            "Returns an app's memory: the note for the translator and the names and terms (entries) that app's text must keep, with the app's languages. Each app has its own memory, found by its bundle ID. The glossary in settings.json is for every app and is not part of it."
        case .setMemory:
            "Writes an app's memory: a note for the translator (who is talking, the setting, the register) and names and terms with how they are translated (entries). It is for the names and terms of one app, such as a game's cast or a show's places; the glossary is for every app and is not set here. An app without a profile gets one, on the base source and target languages. A wrong field rejects the whole call, names its path and writes nothing. The running Mwoyeo applies a saved change within a second."
        case .getSettings:
            "Returns Mwoyeo's settings as settings.json holds them: every setting, or the named keys. Engine API keys are not settings: they stay in the Keychain and are never returned."
        case .setSettings:
            "Changes settings: any key of settings.json except agentConnection, which only the person turns on or off. An engine of kind command (a program of your own) is added or changed by the person in Settings, never here; the other engine kinds can be set. Each value is checked by the rules of its key (get_settings_schema lists every key with its values and limits), written the way the app writes settings.json, and applied by the running Mwoyeo within a second. One wrong value rejects the whole call, names its path and writes nothing. A list or an object setting (engines, appProfiles, shortcuts) is given whole and replaces the one in the file. Engine API keys are not settings: they stay in the Keychain and cannot be set here. For the names and terms of one app, set_memory is the shorter way."
        case .getSettingsSchema:
            "Returns the JSON Schema of settings.json, the same one the app writes beside it: every key with what it does, its allowed values and its limits. Read it before set_settings."
        }
    }

    /// Changes nothing.
    var readOnly: Bool { self != .setMemory && self != .setSettings }

    var arguments: [FieldSpec] {
        switch self {
        case .listApps, .getSettingsSchema:
            []
        case .readTranslationLog:
            [Self.app(required: false, doc: "Only the lines of this app, by bundle ID such as com.example.chat. Left out, the lines of every app."),
             FieldSpec("limit", .integer(1...MCPLog.maxLimit), "How many lines at most: the newest ones. Default \(MCPLog.defaultLimit).", default: MCPLog.defaultLimit),
             FieldSpec("since", .string, "Only the lines from this time on, ISO 8601 with a zone, such as 2026-10-20T09:00:00+09:00.")]
        case .getMemory:
            [Self.app(required: true, doc: "The app's bundle ID, such as com.example.chat (the app field of a log line; list_apps lists them).")]
        case .setMemory:
            [Self.app(required: true, doc: "The app's bundle ID, such as com.example.chat (the app field of a log line; list_apps lists them)."),
             FieldSpec("appName", Self.profileKind("appName"), "The app's name, for display. Left out, a new profile takes the installed app's name and an existing one keeps its name."),
             FieldSpec("note", Self.profileKind("note"), "A note for the translator about this app: who is talking, the setting, the register. Up to \(AppProfile.maxNoteLength) characters. Left out, the note stays (mode merge) or is cleared (mode replace)."),
             FieldSpec("entries", Self.profileKind("entries"), "The names and terms of this app with their translations: the people, places and terms its text must keep. Up to \(AppProfile.maxEntries) rows. Two rows with the same src are one name: the later one wins."),
             FieldSpec("mode", .choice(MCPMemory.Mode.allCases.map(\.rawValue)), "merge adds the entries: one whose src is already in the memory is replaced, the others stay, and a note you leave out stays. replace makes the memory exactly this note and these entries: what you leave out is cleared.", default: MCPMemory.Mode.merge.rawValue)]
        case .getSettings:
            [FieldSpec("keys", .list(.choice(SettingSpec.all.map(\.key)), unique: true), "The settings to return, by key. Left out, every setting.")]
        case .setSettings:
            [FieldSpec("values", .object(SettingSpec.all.map { FieldSpec($0.key, $0.kind, $0.doc) }),
                       "The settings to change, key to value, each in the shape get_settings_schema gives it, such as {\"targetLanguage\": \"ko\", \"lensStyle\": \"subtle\"}. A key left out keeps its value.",
                       required: true)]
        }
    }

    /// Arguments `tools/list` shows in short and the call reads in full: the full schema of `values` is the whole settings schema, which
    /// is `get_settings_schema`'s to give, not a part of every session's tool list.
    private var shortInList: Set<String> { self == .setSettings ? ["values"] : [] }

    /// The entry of `tools/list`.
    var listing: [String: Any] {
        var schema = FieldKind.object(arguments).schema()
        var properties = schema["properties"] as? [String: Any] ?? [:]
        for spec in arguments where shortInList.contains(spec.name) { properties[spec.name] = Self.short(spec) }
        schema["properties"] = properties
        return ["name": rawValue, "title": title, "description": summary, "inputSchema": schema,
                "annotations": ["title": title, "readOnlyHint": readOnly, "idempotentHint": true, "openWorldHint": false] as [String: Any]]
    }

    private static func short(_ spec: FieldSpec) -> [String: Any] {
        guard case let .object(fields) = spec.kind else { return spec.schema() }
        return ["type": "object", "description": spec.doc, "propertyNames": ["enum": fields.map(\.name)]]
    }

    /// Runs the tool on the arguments the client sent: checked against `arguments` first, and the structured content comes back.
    @MainActor
    func run(_ given: [String: Any], in world: MCPWorld) throws -> [String: Any] {
        let a = try checked(given)
        switch self {
        case .listApps: return MCPLog.listApps(world)
        case .readTranslationLog: return try MCPLog.read(a, world)
        case .getMemory: return MCPMemory.get(a["app"] as? String ?? "", world)
        case .setMemory: return try MCPMemory.set(a, world)
        case .getSettings: return MCPSettings.get(a["keys"] as? [String], world)
        case .setSettings: return try MCPSettings.set(a["values"] as? [String: Any] ?? [:], world)
        case .getSettingsSchema: return MCPSettings.schema()
        }
    }

    /// The arguments read as an object of `arguments`. Any problem rejects the call, with the path of each in the arguments.
    private func checked(_ given: [String: Any]) throws -> [String: Any] {
        var problems: [FieldProblem] = []
        let kept = FieldKind.object(arguments).read(given, at: FieldPath(), fallout: .drop, problems: &problems)
        if !problems.isEmpty {
            let takes = arguments.isEmpty ? "no arguments" : arguments.map(\.name).joined(separator: ", ")
            throw MCPToolError("\(rawValue) was not run: " + problems.map(Self.plain).joined(separator: "; ") + ". It takes \(takes).")
        }
        return (kept as? [String: Any]) ?? [:]
    }

    /// A problem without the settings file's closing words ("dropped", "ignored"): a call is rejected whole, nothing is left out.
    /// A problem at the root of the arguments has an empty path, which the message opens with a colon.
    private static func plain(_ problem: FieldProblem) -> String {
        var text = problem.message
        if text.hasPrefix(": ") { text.removeFirst(2) }
        for fallout in [FieldFallout.keep, .ignore, .drop] where text.hasSuffix("; \(fallout.phrase)") {
            return String(text.dropLast(fallout.phrase.count + 2))
        }
        return text
    }

    private static func app(required: Bool, doc: String) -> FieldSpec {
        FieldSpec("app", .text(minLength: 1), doc, required: required)
    }

    /// The kind of one field of an app profile, from the settings file's own tree: its limits are the file's.
    private static func profileKind(_ name: String) -> FieldKind {
        guard case let .list(.object(fields), _, _, _) = FieldKind.appProfiles else { return .string }
        return fields.first { $0.name == name }?.kind ?? .string
    }
}

// MARK: - the translation log

/// One line of the translation log, as `TranscriptFormat.jsonlLine` writes it.
struct MCPLogLine {
    var time: Date
    var timeText: String
    var app: String?
    var source: String
    var target: String
    var engine: String
    var original: String
    var translation: String

    init?(jsonLine: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: jsonLine)) as? [String: Any],
              let timeText = object["time"] as? String, let time = MCPLog.parseTime(timeText),
              let original = object["original"] as? String, let translation = object["translation"] as? String else { return nil }
        self.time = time
        self.timeText = timeText
        app = object["app"] as? String
        source = object["source"] as? String ?? ""
        target = object["target"] as? String ?? ""
        engine = object["engine"] as? String ?? ""
        self.original = original
        self.translation = translation
    }

    var json: [String: Any] {
        ["time": timeText, "app": app ?? NSNull(), "source": source, "target": target, "engine": engine, "original": original, "translation": translation]
    }
}

/// Why there is no log to read, and what to do about it. The words an agent hands on to the person.
enum MCPLogGap {
    /// No folder was chosen (the App Store version has none until the person does), or the one chosen no longer opens.
    case needsFolder(stale: Bool)
    case off
    case noJSONL
    case empty

    var message: String {
        switch self {
        case let .needsFolder(stale):
            (stale ? "Mwoyeo can no longer open the folder of its translation log. " : "No folder is chosen for the translation log. ")
                + "Ask the person to open Mwoyeo > Settings > General and choose the folder under Saving; the log is written there."
        case .off:
            "The translation log is off. Ask the person to turn on Save transcripts in Mwoyeo > Settings > General, and to add \"jsonl\" to transcriptFormats in settings.json (Settings has no row for it). Each lens then appends one line per translated line."
        case .noJSONL:
            "The translation log has no JSON lines: transcriptFormats in settings.json does not include \"jsonl\". Ask the person to add it, for example [\"markdown\", \"srt\", \"jsonl\"]; each lens then appends one line per translated line."
        case .empty:
            "The translation log is on but has no lines yet. A lens writes a line when it translates one: ask the person to put a lens over some text, then read again."
        }
    }
}

/// The JSON Lines files the lenses write to `<folder>/Transcripts` (`TranscriptWriter`).
enum MCPLog {
    static let defaultLimit = 200
    static let maxLimit = 2000

    /// Every line of the log, oldest first, and how many lines could not be read (one being written when the file was read).
    struct Loaded {
        var lines: [MCPLogLine] = []
        var skipped = 0
        var gap: MCPLogGap?
    }

    /// The log as the settings say it is kept. The folder is opened the way the app opens it (a bookmark in the sandbox).
    static func load(_ settings: AppSettings) -> Loaded {
        let resolution = ExportFolder.resolve(settings)
        let access = ExportFolder.begin(resolution)
        defer { access?.end() }
        var loaded = access.map { lines(in: LensExport.transcriptsFolder($0.url)) } ?? Loaded()
        if loaded.lines.isEmpty { loaded.gap = gap(settings, resolution) }
        return loaded
    }

    private static func gap(_ settings: AppSettings, _ resolution: ExportFolder.Resolution) -> MCPLogGap {
        if case let .needsChoice(stale) = resolution { return .needsFolder(stale: stale) }
        if !settings.savesTranscripts { return .off }
        if !settings.transcriptFormats.contains(.jsonl) { return .noJSONL }
        return .empty
    }

    static func lines(in transcripts: URL) -> Loaded {
        let files = ((try? FileManager.default.contentsOfDirectory(at: transcripts, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "jsonl" }
        var read: [MCPLogLine] = []
        var loaded = Loaded()
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file) else { continue }
            for raw in data.split(separator: UInt8(ascii: "\n")) where !raw.allSatisfy({ $0 == 32 || $0 == 13 }) {
                if let line = MCPLogLine(jsonLine: Data(raw)) { read.append(line) } else { loaded.skipped += 1 }
            }
        }
        // Ties keep the order of the files, which `sorted` alone does not promise.
        loaded.lines = read.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
        return loaded
    }

    // MARK: time

    /// The forms a time is written in, the log's own first: with fractions of a second, then without.
    private static let timeFormats: [ISO8601DateFormatter] = {
        let forms: [ISO8601DateFormatter.Options] = [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]]
        return forms.map { options in
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            return f
        }
    }()

    static func parseTime(_ text: String) -> Date? {
        for f in timeFormats { if let d = f.date(from: text) { return d } }
        return nil
    }

    // MARK: the tools

    static func listApps(_ world: MCPWorld) -> [String: Any] {
        let settings = world.settings()
        let log = load(settings)
        let profiles = settings.appProfiles
        func name(_ bundleID: String) -> Any {
            if let known = profiles.first(where: { $0.bundleID == bundleID && $0.appName != bundleID })?.appName ?? world.appName(bundleID) { return known }
            return NSNull()
        }
        var logged: [String: (lines: Int, last: MCPLogLine)] = [:]
        for line in log.lines {
            guard let app = line.app else { continue }
            logged[app] = (logged[app].map { $0.lines + 1 } ?? 1, line)
        }
        let loggedApps = logged.sorted { ($1.value.last.time, $1.key) < ($0.value.last.time, $0.key) }.map { app, seen -> [String: Any] in
            ["bundleID": app, "appName": name(app), "lines": seen.lines, "last": seen.last.timeText]
        }
        let withProfile = profiles.sorted { ($0.appName, $0.bundleID) < ($1.appName, $1.bundleID) }.map { p -> [String: Any] in
            ["bundleID": p.bundleID, "appName": p.appName, "hasMemory": p.hasMemory, "entries": p.entries.count, "source": p.source, "target": p.target]
        }
        var info: [String: Any] = ["available": log.gap == nil, "lines": log.lines.count, "withoutApp": log.lines.filter { $0.app == nil }.count]
        if let gap = log.gap { info["reason"] = gap.message }
        return ["log": info, "loggedApps": loggedApps, "profiles": withProfile]
    }

    static func read(_ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        let settings = world.settings()
        let log = load(settings)
        if let gap = log.gap { throw MCPToolError(gap.message) }
        var since: Date?
        if let text = a["since"] as? String {
            guard let date = parseTime(text) else {
                throw MCPToolError("read_translation_log was not run: since: \"\(text)\" is not an ISO 8601 time with a zone, such as 2026-10-20T09:00:00+09:00")
            }
            since = date
        }
        let app = a["app"] as? String
        let limit = (a["limit"] as? NSNumber)?.intValue ?? defaultLimit
        let matching = log.lines.filter { (app == nil || $0.app == app) && $0.time >= (since ?? .distantPast) }
        let newest = matching.suffix(limit)
        var result: [String: Any] = ["lines": newest.map(\.json), "returned": newest.count, "matching": matching.count, "skipped": log.skipped]
        if !settings.savesTranscripts { result["note"] = "Save transcripts is off now: these lines were written earlier." }
        return result
    }
}

// MARK: - changing settings.json

/// The one way the server changes settings.json: the file read as the app reads it at launch, changed, written by `SettingsFileStore`
/// (the old file kept as settings.json.broken when it had problems, the new one replaced atomically) and read back, so that what a
/// tool reports is what is stored. A file that is not JSON is left alone: nothing could be merged into it.
enum MCPSettingsWrite {
    @MainActor
    static func change(_ world: MCPWorld, tool: String, _ edit: (inout AppSettings) throws -> Void) throws -> (stored: AppSettings, issues: [String]) {
        if let data = try? Data(contentsOf: world.settingsURL) {
            let file = SettingsFileCheck.read(data, over: AppSettings())
            if !file.parsed {
                throw MCPToolError("\(tool) was not run: settings.json is not valid JSON, so nothing can be merged into it (\(file.issues.first?.message ?? "invalid JSON")). Ask the person to fix it; Mwoyeo --check-settings names the line.")
            }
        }
        let store = SettingsFileStore(url: world.settingsURL)
        var settings = store.startup(fallback: world.saved())
        try edit(&settings)
        store.save(settings)
        guard let written = try? Data(contentsOf: world.settingsURL) else { throw MCPToolError("\(tool) could not write \(world.settingsURL.path)") }
        let stored = SettingsFileCheck.read(written, over: AppSettings()).settings
        guard SettingsFileCheck.changedKeys(stored, settings).isEmpty else {
            throw MCPToolError("\(tool) could not write \(world.settingsURL.path) as intended; read back, it differs in \(SettingsFileCheck.changedKeys(stored, settings).joined(separator: ", "))")
        }
        return (stored, store.issues.map(\.message))
    }
}

// MARK: - settings

enum MCPSettings {
    /// What only the person changes, one row per rule. A rule sees the values the agent sent, the settings before and the settings those
    /// values would make; when it holds, the call is refused with `says` and nothing is written.
    struct PersonOnly {
        let says: String
        let touches: (_ values: [String: Any], _ before: AppSettings, _ after: AppSettings) -> Bool
    }

    static let personOnly: [PersonOnly] = [
        PersonOnly(says: "agentConnection cannot be changed through MCP; only the person turns it on or off, in Mwoyeo Settings → \(switchLabel).") { values, _, _ in
            values["agentConnection"] != nil
        },
        // The app runs a command engine's executable with its own permissions: one the person did not have already is theirs to add.
        PersonOnly(says: "Command engines are added by the person in Settings.") { _, before, after in
            let known = commandEngines(before)
            return commandEngines(after).contains { !known.contains($0) }
        },
    ]

    private static func commandEngines(_ settings: AppSettings) -> [EngineConfig] {
        settings.engines.filter { if case .command = $0.kind { true } else { false } }
    }

    /// The row of Settings that holds the switch, in the words the person sees.
    static var switchLabel: String { String(localized: "Connect an agent (MCP)") }

    static func get(_ keys: [String]?, _ world: MCPWorld) -> [String: Any] {
        let all = SettingsFileCheck.fileValues(world.settings(), omittingUnset: false)
        let wanted = keys ?? SettingSpec.all.map(\.key)
        return ["settings": Dictionary(wanted.compactMap { key in all[key].map { (key, $0) } }, uniquingKeysWith: { first, _ in first })]
    }

    static func schema() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: SettingsSchema.data())) as? [String: Any] ?? [:]
    }

    /// `values` has been read against the settings' own kinds already. The file reader then applies it over the file, the way the app's
    /// watcher does, and the keys that changed are reported with their stored values.
    @MainActor
    static func set(_ values: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        if values.isEmpty { throw MCPToolError("set_settings was not run: values holds no setting") }
        let data = (try? JSONSerialization.data(withJSONObject: values)) ?? Data()
        var changed: [String] = []
        let (stored, issues) = try MCPSettingsWrite.change(world, tool: "set_settings") { settings in
            let result = SettingsFileCheck.read(data, over: settings)
            if let rule = personOnly.first(where: { $0.touches(values, settings, result.settings) }) {
                throw MCPToolError("set_settings was not run: " + rule.says)
            }
            if !result.issues.isEmpty {
                throw MCPToolError("set_settings was not run: " + result.issues.map(\.message).joined(separator: "; "))
            }
            settings = result.settings
            changed = result.changed
        }
        let now = SettingsFileCheck.fileValues(stored, omittingUnset: false)
        return ["applied": Dictionary(changed.compactMap { key in now[key].map { (key, $0) } }, uniquingKeysWith: { first, _ in first }),
                "unchanged": values.keys.filter { !changed.contains($0) }.sorted(), "issues": issues]
    }
}

// MARK: - an app's memory

enum MCPMemory {
    enum Mode: String, CaseIterable { case merge, replace }

    /// The memory of a profile in the shape of the settings file.
    static func json(_ p: AppProfile) -> [String: Any] {
        ["app": p.bundleID, "exists": true, "appName": p.appName, "source": p.source, "target": p.target, "note": p.note,
         "entries": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(p.entries))) ?? []]
    }

    static func get(_ bundleID: String, _ world: MCPWorld) -> [String: Any] {
        guard let profile = AppProfiles.profile(for: bundleID, in: world.settings().appProfiles) else {
            return ["app": bundleID, "exists": false, "note": "No memory for this app yet. set_memory creates it."]
        }
        return json(profile)
    }

    /// `a` has been read against the tool's arguments (the settings file's rules for the note and the entries).
    @MainActor
    static func set(_ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        let bundleID = a["app"] as? String ?? ""
        let mode = Mode(rawValue: a["mode"] as? String ?? "") ?? .merge
        let note = a["note"] as? String, appName = a["appName"] as? String
        let incoming = try ((a["entries"] as? [Any]).map { try JSONDecoder().decode([MemoryEntry].self, from: JSONSerialization.data(withJSONObject: $0)) }) ?? []
        if mode == .merge, note == nil, appName == nil, incoming.isEmpty {
            throw MCPToolError("set_memory was not run: give a note, entries or an appName (mode replace with none of them clears the memory)")
        }

        var existing: AppProfile?
        var before: [MemoryEntry] = []
        let (stored, issues) = try MCPSettingsWrite.change(world, tool: "set_memory") { settings in
            existing = AppProfiles.profile(for: bundleID, in: settings.appProfiles)
            var profile = existing ?? AppProfile(bundleID: bundleID, appName: world.appName(bundleID) ?? bundleID,
                                                 source: settings.sourceLanguage, target: settings.targetLanguage)
            before = profile.entries
            if let appName { profile.appName = appName }
            if mode == .replace {
                profile.note = ""
                profile.entries = []
            }
            if let note { profile.note = note }
            for entry in incoming {
                switch profile.setEntry(entry) {
                case .saved: break
                case .full:
                    throw MCPToolError("set_memory was not run: the memory of \(bundleID) would hold more than \(AppProfile.maxEntries) names, the most it keeps; use mode replace with the names that should stay")
                case .invalid:
                    throw MCPToolError("set_memory was not run: entries: \"\(entry.src)\" has no src or no dst once cleaned")
                }
            }
            settings.appProfiles = AppProfiles.remembering(profile, in: settings.appProfiles)
        }
        guard let profile = AppProfiles.profile(for: bundleID, in: stored.appProfiles) else {
            throw MCPToolError("set_memory could not write \(world.settingsURL.path); nothing changed")
        }

        let was = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(profile.entries.map(\.id))
        var result = json(profile)
        result["created"] = existing == nil
        result["mode"] = mode.rawValue
        result["added"] = profile.entries.filter { was[$0.id] == nil }.map(\.src)
        result["updated"] = profile.entries.filter { e in was[e.id].map { $0 != e } ?? false }.map(\.src)
        result["removed"] = before.filter { !kept.contains($0.id) }.map(\.src)
        result["issues"] = issues
        return result
    }
}
