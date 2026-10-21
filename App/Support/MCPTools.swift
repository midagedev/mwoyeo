import Foundation
import MwoyeoCore

/// The tools of `Mwoyeo --mcp`, one table: each case has its name, its description for the agent, its arguments and its handler.
/// The arguments are `FieldSpec`s, read by the very engine that reads settings.json (`FieldKind.read`), so a wrong argument is
/// reported with its path in the settings file's own words, and the memory's and the settings' fields are the settings file's own,
/// never a second copy.
enum MCPTool: String, CaseIterable {
    case listApps = "list_apps"
    case readTranslationLog = "read_translation_log"
    case termRenderings = "term_renderings"
    case getMemory = "get_memory"
    case setMemory = "set_memory"
    case translateText = "translate_text"
    case getSettings = "get_settings"
    case setSettings = "set_settings"
    case getSettingsSchema = "get_settings_schema"
    case resetSettings = "reset_settings"
    case testRules = "test_rules"

    var title: String {
        switch self {
        case .listApps: "List apps"
        case .readTranslationLog: "Read the translation log"
        case .termRenderings: "How names were translated"
        case .getMemory: "Get a profile's memory"
        case .setMemory: "Set a profile's memory"
        case .translateText: "Translate lines"
        case .getSettings: "Get settings"
        case .setSettings: "Set settings"
        case .getSettingsSchema: "Get the settings schema"
        case .resetSettings: "Restore a tab's defaults"
        case .testRules: "Test rewrite rules"
        }
    }

    /// What the tool is for and what it costs, written for an agent: one or two sentences, because a tool's description is read every time the tool is.
    var summary: String {
        switch self {
        case .listApps:
            "Lists the apps in the translation log (line count, last time) and the profiles (id, name, where each is used, language pair, engine, how many names, amount of context; no key when there is none) with the profile every lens is pinned to. Its bundle IDs are the app argument of the other tools and its profile ids their profile argument; the answer is small."
        case .readTranslationLog:
            "Reads the newest rows of the translation log, oldest first, as [id, time, original, translation] under a header that holds the app, languages and engine when they do not vary; it returns up to limit rows (default \(MCPLog.defaultLimit), max \(MCPLog.maxLimit)). With distinct (default) a row that a later read of the same lens within \(Int(MCPLogRows.foldWindow)) s starts with is folded into it (an OCR read of a line still being drawn) and an exact repeat is counted, not repeated; it needs Save transcripts on and jsonl among the transcript formats, and the error says how."
        case .termRenderings:
            "For names or terms (as they are written in the source) in one app's log, lists every distinct translation of the rows that contain each, as [count, translation, example row ids]: a cheap way to check a few names without reading the log. It returns up to \(MCPLog.maxRenderings) translations per term."
        case .getMemory:
            "Returns the memory of a profile (by its id, in the shape of settings.json) or of an app (by its bundle ID): the note for the translator, the names and terms and the profile's id; with a title, the whole chain a lens over that window uses (the profiles it meets, narrowest first, then All apps) with where each name comes from and the names learned. The glossary setting is for every app and is not part of it."
        case .setMemory:
            "Writes the memory of one profile or app, a note for the translator and names and terms with their translations (the glossary is for every app and is not set here), and with profile also its name, where it is used (when), languages, engine, context and learning; mode merge replaces names by src and keeps the rest, replace makes the note and names exactly what you give, remove deletes the profile. A wrong field rejects the whole call and writes nothing, and the running Mwoyeo applies a saved change within a second."
        case .translateText:
            "Translates up to \(MCPTranslate.maxLines) lines the way a lens does over a window (its app and title) or under a profile, with the engine, languages and memory of its chain, to check a memory you wrote; it returns each translation and the engine that made it. The text goes to that engine (a cloud one sees it), Apple Translation uses only the names a row writes into the text (apply replace or both), and command engines are not run."
        case .getSettings:
            "Returns Mwoyeo's settings as settings.json holds them: every setting, or the keys named. Engine API keys are not settings: they stay in the Keychain and are never returned."
        case .setSettings:
            "Changes settings, each value checked by the rules of its key (get_settings_schema with key gives them): one wrong value rejects the whole call and writes nothing, agentConnection and engines of kind command are the person's alone, and engine API keys stay in the Keychain. A list or object setting (engines, appProfiles, shortcuts) is given whole."
        case .getSettingsSchema:
            "Returns the JSON Schema of one setting when given key (its allowed values and limits), or of every setting without it, which is about 30 KB: give a key."
        case .testRules:
            "Runs the rewrite rules and script of the chain a lens over a window (app and title) or a profile uses, over up to \(MCPTranslate.maxLines) lines you give, without a screen: returns each line as the engine would be sent it, and the errors of the rules with their line and column. With translate it also translates the lines and returns what the lens would show; without it no engine is asked and nothing leaves this Mac."
        case .resetSettings:
            "Sets the preferences of one tab of Settings back to their defaults, as Restore Defaults does, and returns [key, value now, default] for each and the keys it keeps (consent and data, such as agentConnection, engines, glossary and profiles, are never changed here). With dryRun it only reports; the old file is kept as settings.json.before-restore."
        }
    }

    /// Changes nothing.
    var readOnly: Bool { self != .setMemory && self != .setSettings && self != .resetSettings }

    /// Sends text beyond this Mac when the chosen engine is a cloud one (`test_rules` only with `translate`).
    var opensWorld: Bool { self == .translateText || self == .testRules }

    var arguments: [FieldSpec] {
        switch self {
        case .listApps:
            []
        case .readTranslationLog:
            [Self.app(required: false, doc: "Only the rows of this app, by bundle ID such as com.example.chat. Left out, every app."),
             FieldSpec("limit", .integer(1...MCPLog.maxLimit), "How many rows at most: the newest. Default \(MCPLog.defaultLimit).", default: MCPLog.defaultLimit),
             FieldSpec("since", .string, "Only rows from this time on, ISO 8601 with a zone, such as 2026-10-20T09:00:00+09:00."),
             FieldSpec("contains", .text(minLength: 1), "Only rows with this text in the original or the translation."),
             FieldSpec("distinct", .bool, "true folds the pieces of a line being read and counts exact repeats; false returns every logged line.", default: true)]
        case .termRenderings:
            [Self.app(required: true, doc: "The app's bundle ID (list_apps lists them)."),
             FieldSpec("terms", .list(.text(minLength: 1), maxItems: MCPLog.maxTerms, unique: true),
                       "The names or terms to check, as they are written in the source text; 1 to \(MCPLog.maxTerms).", required: true),
             FieldSpec("limit_examples", .integer(1...10), "How many example row ids for each translation. Default 2.", default: 2)]
        case .getMemory:
            [Self.app(required: false, doc: "The app's bundle ID, such as com.example.chat (the app field of a log line; list_apps lists them). Give this or profile."),
             Self.profile(doc: "The profile's id (list_apps lists them). Give this or app."),
             FieldSpec("title", .text(minLength: 1), "With app: the window title a lens over that app would have confirmed. The answer is then the whole chain for that window, the profiles whose conditions it meets.")]
        case .setMemory:
            [Self.app(required: false, doc: "The app's bundle ID, such as com.example.chat (list_apps lists them): its own profile, the one used for that app alone, made when it has none. Give this or profile."),
             Self.profile(doc: "The profile's id (list_apps lists them); an id no profile has makes one (1 to 255 letters, digits, dots, hyphens, underscores; not all). A new one with no when is a preset, used only when picked. Give this or app."),
             FieldSpec("name", Self.profileKind("name"), "The profile's name, for display. Left out, a new profile takes the installed app's name (with app) or its id, and an existing one keeps its name."),
             FieldSpec("appName", Self.profileKind("name"), "The same as name."),
             FieldSpec("note", Self.profileKind("note"), "A note for the translator: who is talking, the setting, the register. Up to \(AppProfile.maxNoteLength) characters. Left out, the note stays (mode merge) or is cleared (mode replace)."),
             FieldSpec("entries", Self.profileKind("entries"), "The names and terms with their translations: the people, places and terms its text must keep, each with apply (hint, replace or both). Up to \(AppProfile.maxEntries) rows. Two rows with the same src are one name: the later one wins."),
             FieldSpec("mode", .choice(MCPMemory.Mode.allCases.map(\.rawValue)), "merge adds the entries: one whose src is already in the memory is replaced, the others stay, and a note you leave out stays. replace makes the memory exactly this note and these entries: what you leave out is cleared.", default: MCPMemory.Mode.merge.rawValue),
             FieldSpec("when", Self.profileKind("when"), "With profile: where it is used, up to \(AppProfile.maxConditions) conditions {app, titleContains} (one or both each); replaces the old list; [] makes a preset."),
             FieldSpec("source", Self.profileKind("source"), "Source language code or auto; left out, the base languages (new) or its own."),
             FieldSpec("target", Self.profileKind("target"), "Target language code."),
             FieldSpec("customEngineID", Self.profileKind("customEngineID"), "An engine id, \"apple\", or null for All apps' engine."),
             FieldSpec("context", Self.profileKind("context"), "This profile's amount of context: {mode: off, memory, nearby or conversation, previousLines: 0 to \(AppContextOverride.maxPreviousLines)}."),
             FieldSpec("useLearned", Self.profileKind("useLearned"), "Learn names and terms for this profile."),
             FieldSpec("rewrites", Self.profileKind("rewrites"), "The profile's rewrite rows, the whole list (up to \(RewriteLimits.maxRows)): {stage: before or after, find, replace, regex?, on?}. Run on this Mac at no token cost; [] clears them."),
             FieldSpec("script", Self.profileKind("script"), "The profile's script {source, on?}: before(line, ctx) and/or after(src, dst, ctx) in JavaScript (docs/settings-for-agents.md); an empty source removes it."),
             FieldSpec("remove", .bool, "true deletes the profile (its learned-names file stays); give nothing else but app or profile. If every lens was pinned to it, they return to Auto.")]
        case .translateText:
            [FieldSpec("lines", .list(.text(maxLength: MCPTranslate.maxLineLength, minLength: 1), maxItems: MCPTranslate.maxLines),
                       "The lines to translate, 1 to \(MCPTranslate.maxLines), each up to \(MCPTranslate.maxLineLength) characters.", required: true),
             Self.app(required: false, doc: "The app whose profiles, languages, engine and memory apply, by bundle ID. Left out, the base settings."),
             Self.profile(doc: "Translate under this profile, as if every lens were pinned to it (list_apps lists them); it brings its languages, engine and memory."),
             FieldSpec("title", .text(minLength: 1), "The title of the window, as a lens would have confirmed it: the profiles with a title condition that it meets apply. The engine is sent it only when it is allowed the title."),
             FieldSpec("engine", .text(minLength: 1), "\"apple\" for Apple Translation, or the id of an added engine (get_settings engines). Left out, the engine the profile or app uses.")]
        case .getSettings:
            [FieldSpec("keys", .list(.choice(SettingSpec.all.map(\.key)), unique: true), "The settings to return, by key. Left out, every setting.")]
        case .setSettings:
            [FieldSpec("values", .object(SettingSpec.all.map { FieldSpec($0.key, $0.kind, $0.doc) }),
                       "The settings to change, key to value, each in the shape get_settings_schema gives it, such as {\"targetLanguage\": \"ko\", \"lensStyle\": \"subtle\"}. A key left out keeps its value.",
                       required: true)]
        case .getSettingsSchema:
            [FieldSpec("key", .choice(SettingSpec.all.map(\.key)), "The setting whose schema to return. Left out, the schema of every setting (about 30 KB).")]
        case .testRules:
            [Self.app(required: false, doc: "The app whose window the lines are for, by bundle ID: the chain is the profiles whose conditions it meets (with title), then All apps."),
             Self.profile(doc: "Test under this profile, as if every lens were pinned to it (list_apps lists them)."),
             FieldSpec("title", .text(minLength: 1), "The title of the window, as a lens would have confirmed it: the profiles with a title condition that it meets apply."),
             FieldSpec("lines", .list(.text(maxLength: MCPTranslate.maxLineLength, minLength: 1), maxItems: MCPTranslate.maxLines),
                       "The lines to run the rules over, 1 to \(MCPTranslate.maxLines), each up to \(MCPTranslate.maxLineLength) characters.", required: true),
             FieldSpec("translate", .bool, "true also translates the lines (the text goes to that engine, a cloud one sees it) and runs the after rules over the answer. Default false: nothing is translated.", default: false)]
        case .resetSettings:
            [FieldSpec("tab", .choice(MCPSettings.resetTabs.map(\.rawValue)), "The tab of Settings whose preferences go back to their defaults.", required: true),
             FieldSpec("dryRun", .bool, "true only reports what would change and writes nothing.", default: false)]
        }
    }

    /// Arguments of which at least one must be given (a tool that takes an app or a profile).
    private var needsOneOf: [String] { self == .getMemory || self == .setMemory ? ["app", "profile"] : [] }

    /// Arguments `tools/list` shows in short and the call reads in full: the full schema of `values` is the whole settings schema, which
    /// is `get_settings_schema`'s to give, not a part of every session's tool list.
    /// `set_memory`'s `when` and `context` are shown the same way: their keys, not the nested schema, which `get_settings_schema` key profiles gives.
    private var shortInList: Set<String> { self == .setSettings ? ["values"] : self == .setMemory ? ["when", "context", "rewrites", "script"] : [] }

    /// The entry of `tools/list`.
    var listing: [String: Any] {
        var schema = FieldKind.object(arguments, needsOneOf: needsOneOf).schema()
        var properties = schema["properties"] as? [String: Any] ?? [:]
        for spec in arguments where shortInList.contains(spec.name) { properties[spec.name] = Self.short(spec) }
        schema["properties"] = properties
        return ["name": rawValue, "title": title, "description": summary, "inputSchema": schema,
                "annotations": ["title": title, "readOnlyHint": readOnly, "idempotentHint": true, "openWorldHint": opensWorld] as [String: Any]]
    }

    private static func short(_ spec: FieldSpec) -> [String: Any] {
        switch spec.kind {
        case let .object(fields, _):
            return ["type": "object", "description": spec.doc, "propertyNames": ["enum": fields.map(\.name)]]
        case let .list(.object(fields, _), _, _, _, _):
            return ["type": "array", "description": spec.doc, "items": ["type": "object", "propertyNames": ["enum": fields.map(\.name)]]]
        default:
            return spec.schema()
        }
    }

    /// Runs the tool on the arguments the client sent: checked against `arguments` first, and the structured content comes back.
    @MainActor
    func run(_ given: [String: Any], in world: MCPWorld) throws -> [String: Any] {
        let a = try checked(given)
        switch self {
        case .listApps: return MCPLog.listApps(world)
        case .readTranslationLog: return try MCPLog.read(a, world)
        case .termRenderings: return try MCPLog.termRenderings(a, world)
        case .getMemory: return try MCPMemory.get(a, world)
        case .setMemory: return try MCPMemory.set(a, world)
        case .translateText: return try MCPTranslate.run(a, world)
        case .getSettings: return MCPSettings.get(a["keys"] as? [String], world)
        case .setSettings: return try MCPSettings.set(a["values"] as? [String: Any] ?? [:], world)
        case .getSettingsSchema: return MCPSettings.schema(key: a["key"] as? String)
        case .resetSettings: return try MCPSettings.reset(a, world)
        case .testRules: return try MCPRules.test(a, world)
        }
    }

    /// The arguments read as an object of `arguments`. Any problem rejects the call, with the path of each in the arguments.
    private func checked(_ given: [String: Any]) throws -> [String: Any] {
        var problems: [FieldProblem] = []
        let kept = FieldKind.object(arguments, needsOneOf: needsOneOf).read(given, at: FieldPath(), fallout: .drop, problems: &problems)
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

    private static func profile(doc: String) -> FieldSpec {
        FieldSpec("profile", .text(minLength: 1), doc)
    }

    /// The kind of one field of an app profile, from the settings file's own tree: its limits are the file's.
    private static func profileKind(_ name: String) -> FieldKind {
        guard case let .list(.object(fields, _), _, _, _, _) = FieldKind.profiles else { return .string }
        return fields.first { $0.name == name }?.kind ?? .string
    }
}

// MARK: - the translation log

/// One line of the translation log, as `TranscriptFormat.jsonlLine` writes it.
struct MCPLogLine {
    /// Where the line stands in the whole log, oldest first, from 1: the same number in every tool, so a row read in one can be named in another.
    var id = 0
    var time: Date
    var timeText: String
    var lens: String
    var app: String?
    /// The profile that decided the line's languages (design names-and-context §2.2, §7); nil in a line written without a chain.
    var profile: String?
    var source: String
    var target: String
    var engine: String
    var original: String
    var translation: String
    /// `[src, dst, from]` of each row of the memory that occurs in the line; empty when none does (the line has no `names` key then).
    var names: [[String]] = []

    init?(jsonLine: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: jsonLine)) as? [String: Any],
              let timeText = object["time"] as? String, let time = MCPLog.parseTime(timeText),
              let original = object["original"] as? String, let translation = object["translation"] as? String else { return nil }
        self.time = time
        self.timeText = timeText
        lens = object["lens"] as? String ?? ""
        app = object["app"] as? String
        profile = object["profile"] as? String
        names = (object["names"] as? [[Any]])?.map { $0.compactMap { $0 as? String } } ?? []
        source = object["source"] as? String ?? ""
        target = object["target"] as? String ?? ""
        engine = object["engine"] as? String ?? ""
        self.original = original
        self.translation = translation
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
    static let defaultLimit = 50
    static let maxLimit = 500
    /// The most terms `term_renderings` takes in one call.
    static let maxTerms = 50

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
        for i in loaded.lines.indices { loaded.lines[i].id = i + 1 }
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
        var info: [String: Any] = ["available": log.gap == nil, "lines": log.lines.count, "withoutApp": log.lines.filter { $0.app == nil }.count]
        if let gap = log.gap { info["reason"] = gap.message }
        var result: [String: Any] = ["log": info, "loggedApps": loggedApps]
        // Design §7: the profiles as a table, in the order of the file (a tie of two conditions goes to the earlier one), and what every lens is pinned
        // to. With no profile there is neither key: the answer of a Mac with nothing set up is what it was.
        if !profiles.isEmpty {
            result["profiles"] = ["columns": MCPProfiles.columns, "rows": profiles.map { MCPProfiles.row($0, settings) }]
            if let pin = MCPProfiles.pin(settings) { result["pin"] = pin }
        }
        return result
    }
}

// MARK: - profiles as an agent reads them

/// How a profile is told in a result (design names-and-context §7): one owner for the `list_apps` table and `get_memory`'s chain.
enum MCPProfiles {
    static let columns = ["id", "name", "when", "pair", "engine", "names", "context"]

    /// `[id, name, when, pair, engine, names, context]`: where it is used (empty: a preset), `ja>ko`, the engine it names (null follows All apps),
    /// how many names it holds, the amount of context it sets (null follows All apps).
    static func row(_ p: AppProfile, _ settings: AppSettings) -> [Any] {
        [p.id, p.name, p.when.map(condition), pair(p), engine(p, settings) ?? NSNull(), p.entries.count, p.context.map(context) ?? NSNull()]
    }

    static func condition(_ c: ProfileCondition) -> String {
        [c.app.map { "app \($0)" }, c.titleContains.map { "title \($0)" }].compactMap { $0 }.joined(separator: " ")
    }

    static func pair(_ p: AppProfile) -> String { "\(p.source)>\(p.target)" }

    static func context(_ c: AppContextOverride) -> String {
        c.mode == .conversation ? "conversation \(c.previousLines)" : c.mode.rawValue
    }

    /// The name of the engine a profile uses: `apple`, an added engine's name, or its id when the engine is gone; nil follows All apps.
    static func engine(_ p: AppProfile, _ settings: AppSettings) -> String? {
        switch p.engine {
        case nil: nil
        case .apple?: "apple"
        case let .added(id)?: settings.engines.first { $0.id == id }?.name ?? id.uuidString
        }
    }

    /// What every lens is pinned to, as the file says it, when it is a profile that exists or `all`; nil is Auto (a pin to a profile that is gone
    /// falls back to Auto, `ProfileChain.chain`).
    static func pin(_ settings: AppSettings) -> String? {
        guard let pin = settings.profilePin, pin == AppProfile.allAppsID || settings.appProfiles.contains(where: { $0.id == pin }) else { return nil }
        return pin
    }

    /// The profile with this id.
    static func profile(_ id: String, in settings: AppSettings) -> AppProfile? { settings.appProfiles.first { $0.id == id } }
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

    /// The tabs of Settings with a preference to restore (design §9: About has only consent, and the keys of no tab are never reset).
    static let resetTabs = SettingSpec.Tab.allCases.filter { tab in SettingSpec.all.contains { $0.tab == tab && $0.nature == .preference } }

    /// `reset_settings`: `RestorePlan`, the one owner the Restore sheet reads too. Preferences of the tab that differ from their defaults are set
    /// back (the old file kept as settings.json.before-restore); its consent and data keys are named in `kept` and never written.
    @MainActor
    static func reset(_ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        guard let tab = (a["tab"] as? String).flatMap(SettingSpec.Tab.init(rawValue:)) else { throw MCPToolError("reset_settings was not run: tab names none") }
        let dryRun = a["dryRun"] as? Bool == true
        var plan = RestorePlan.make(tab: tab, now: world.settings())
        if !dryRun, !plan.isEmpty {
            _ = try MCPSettingsWrite.change(world, tool: "reset_settings") { settings in
                plan = RestorePlan.make(tab: tab, now: settings)
                try plan.apply(to: &settings, file: world.settingsURL)
            }
        }
        var result: [String: Any] = ["tab": tab.rawValue, "changed": plan.changes.map { [$0.key, $0.now, $0.default] as [Any] }, "kept": plan.kept]
        if dryRun { result["dryRun"] = true } else if !plan.isEmpty { result["backup"] = RestorePlan.backupURL(for: world.settingsURL).lastPathComponent }
        return result
    }

    static func get(_ keys: [String]?, _ world: MCPWorld) -> [String: Any] {
        let all = SettingsFileCheck.fileValues(world.settings(), omittingUnset: false)
        let wanted = keys ?? SettingSpec.all.map(\.key)
        return ["settings": Dictionary(wanted.compactMap { key in all[key].map { (key, $0) } }, uniquingKeysWith: { first, _ in first })]
    }

    /// The schema of settings.json, or with a key the schema of that setting alone (each is self-contained: the file's schema has no references).
    static func schema(key: String? = nil) -> [String: Any] {
        let whole = (try? JSONSerialization.jsonObject(with: SettingsSchema.data())) as? [String: Any] ?? [:]
        guard let key else { return whole }
        return ["key": key, "schema": (whole["properties"] as? [String: Any])?[key] ?? NSNull()]
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

// MARK: - a profile's memory

enum MCPMemory {
    enum Mode: String, CaseIterable { case merge, replace }

    /// The memory of a profile as `get_memory` with an app says it: the keys 1.1.4 gave, and `profile` (design §7, R5's gate).
    static func json(_ p: AppProfile) -> [String: Any] {
        ["app": p.bundleID, "profile": p.id, "exists": true, "appName": p.appName, "source": p.source, "target": p.target, "note": p.note,
         "entries": (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(p.entries))) ?? []]
    }

    /// A profile as the settings file holds it (design §7: "a profile in file shape").
    static func fileShape(_ p: AppProfile) -> [String: Any] {
        var shape = ((try? JSONSerialization.jsonObject(with: JSONEncoder().encode(ProfileFile(p)))) as? [String: Any]) ?? [:]
        shape["exists"] = true
        return shape
    }

    /// `get_memory`: a profile by its id; an app by its bundle ID, which with a window title is the whole chain a lens over that window uses.
    static func get(_ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        let app = a["app"] as? String, id = a["profile"] as? String, title = a["title"] as? String
        if id != nil, app != nil || title != nil {
            throw MCPToolError("get_memory was not run: profile is given alone; with app (and title) it is the chain of that window")
        }
        let settings = world.settings()
        if let id {
            guard let profile = MCPProfiles.profile(id, in: settings) else {
                return ["profile": id, "exists": false, "note": "No profile has this id. set_memory with profile creates it."]
            }
            return fileShape(profile)
        }
        let bundleID = app ?? ""
        if let title { return chain(of: bundleID, title: title, settings) }
        guard let profile = AppProfiles.profile(for: bundleID, in: settings.appProfiles) else {
            return ["app": bundleID, "exists": false, "note": "No memory for this app yet. set_memory creates it."]
        }
        return json(profile)
    }

    /// The chain a lens over `title` of `bundleID` uses (design §1.3, §7): which profile is selected and why, the chain, the names with where
    /// each comes from, the names a narrower row hid, and the names learned (`Memory/<id>.json` beside the transcripts).
    static func chain(of bundleID: String, title: String, _ settings: AppSettings) -> [String: Any] {
        let merged = ContextRoute.merged(settings: settings, lens: bundleID, title: title)
        func table(_ columns: [String], _ rows: [[Any]]) -> [String: Any] { ["columns": columns, "rows": rows] }
        var result: [String: Any] = ["app": bundleID, "title": title, "selected": merged.head.id, "why": why(merged, bundleID, title, settings),
                                     "chain": merged.links.map(\.id), "pair": "\(merged.pair.source)>\(merged.pair.target)"]
        if !merged.note.isEmpty { result["note"] = merged.note }
        result["rows"] = table(["src", "dst", "kind", "apply", "from"], merged.rows.map { [$0.entry.src, $0.entry.dst, $0.entry.kind.rawValue, $0.entry.apply.rawValue, $0.from] })
        let hidden = merged.rows.flatMap { row in row.shadows.map { [row.entry.src, $0.entry.dst, $0.from] as [Any] } }
        if !hidden.isEmpty { result["shadowed"] = table(["src", "dst", "from"], hidden) }
        let taken = Set(merged.rows.map(\.entry.id))
        let learned = learnedRows(of: merged.learnedKey, settings).filter { !taken.contains(MemoryEntry.id(forSource: $0.src)) }
        if !learned.isEmpty { result["learned"] = table(["src", "dst", "kind"], learned.map { [$0.src, $0.dst, $0.kind.rawValue] }) }
        return result
    }

    /// Why the chain starts where it does: a pin, or the narrowest condition of the first profile that the window meets.
    private static func why(_ merged: MergedChain, _ bundleID: String, _ title: String, _ settings: AppSettings) -> String {
        if let pin = MCPProfiles.pin(settings) { return pin == AppProfile.allAppsID ? "pinned to All apps only" : "pinned to \(pin)" }
        guard let head = merged.head.profile else { return "no profile has a condition this window meets" }
        let met = head.when.filter { $0.matches(app: bundleID, title: title) }.max { ($0.narrowness, $0.phraseLength) < ($1.narrowness, $1.phraseLength) }
        return "auto: " + (met.map(MCPProfiles.condition) ?? "")
    }

    /// The learned names under `key`, read the way the lens writes them (`LearnedMemoryFile`): only while Save transcripts is on and a folder is
    /// chosen, so that file may not exist; none is then not an error.
    private static func learnedRows(of key: String?, _ settings: AppSettings) -> [MemoryEntry] {
        guard let key, settings.savesTranscripts else { return [] }
        let resolution = ExportFolder.resolve(settings)
        let access = ExportFolder.begin(resolution)
        defer { access?.end() }
        guard let access, let data = try? Data(contentsOf: LearnedMemoryFile.folder(access.url).appendingPathComponent(LearnedMemoryFile.fileName(for: key))),
              let rows = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["rows"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let src = row["src"] as? String, let dst = row["dst"] as? String else { return nil }
            return MemoryEntry(src: src, dst: dst, kind: (row["kind"] as? String).flatMap(EntryKind.init(rawValue:)) ?? .term, origin: .learned)
        }
    }

    /// `a` has been read against the tool's arguments (the settings file's rules for each field of a profile).
    @MainActor
    static func set(_ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        let app = a["app"] as? String, profileID = a["profile"] as? String
        if app != nil, profileID != nil { throw MCPToolError("set_memory was not run: give app or profile, not both") }
        if let profileID, !AppProfile.isValidID(profileID) {
            throw MCPToolError("set_memory was not run: profile: \"\(profileID)\" is not an id; use 1 to 255 letters, digits, dots, hyphens or underscores, and not all")
        }
        if app != nil, a["when"] != nil {
            throw MCPToolError("set_memory was not run: when is for a profile; with app the profile is the app's own (its condition is the app)")
        }
        let key = profileID ?? app ?? ""
        if a["remove"] as? Bool == true { return try remove(key, asProfile: profileID != nil, a, world) }

        let mode = Mode(rawValue: a["mode"] as? String ?? "") ?? .merge
        let note = a["note"] as? String, name = (a["name"] ?? a["appName"]) as? String
        let incoming = try ((a["entries"] as? [Any]).map { try JSONDecoder().decode([MemoryEntry].self, from: JSONSerialization.data(withJSONObject: $0)) }) ?? []
        let sets = ["when", "source", "target", "customEngineID", "context", "useLearned", "rewrites", "script"].filter { a[$0] != nil }
        if mode == .merge, note == nil, name == nil, incoming.isEmpty, sets.isEmpty {
            throw MCPToolError("set_memory was not run: give a note, entries, a name or another field to set (mode replace with none of them clears the memory)")
        }

        let rules = try checkedRules(a)
        var existing: AppProfile?
        var before: [MemoryEntry] = []
        var id = key
        let (stored, issues) = try MCPSettingsWrite.change(world, tool: "set_memory") { settings in
            existing = profileID != nil ? MCPProfiles.profile(key, in: settings) : AppProfiles.profile(for: key, in: settings.appProfiles)
            if existing == nil, settings.appProfiles.count >= AppProfile.maxProfiles {
                throw MCPToolError("set_memory was not run: there are \(AppProfile.maxProfiles) profiles, the most the file keeps; remove one first")
            }
            let i: Int
            if let app {
                // The one function that makes an app's profile (the Memory sheet's first edit and Pin come here too).
                i = settings.ensuringProfile(for: app, appName: world.appName(app) ?? app)
            } else if let at = settings.appProfiles.firstIndex(where: { $0.id == key }) {
                i = at
            } else {
                // A new one with no `when` is a preset: used only when it is picked. It takes the base languages, as a new app profile does.
                settings.appProfiles.append(AppProfile(bundleID: key, appName: key, source: settings.sourceLanguage, target: settings.targetLanguage, id: key, when: []))
                i = settings.appProfiles.count - 1
            }
            var profile = settings.appProfiles[i]
            id = profile.id
            before = profile.entries
            if let name { profile.name = name }
            if mode == .replace {
                profile.note = ""
                profile.entries = []
            }
            if let note { profile.note = note }
            for entry in incoming {
                switch profile.setEntry(entry) {
                case .saved: break
                case .full:
                    throw MCPToolError("set_memory was not run: the memory of \(key) would hold more than \(AppProfile.maxEntries) names, the most it keeps; use mode replace with the names that should stay")
                case .invalid:
                    throw MCPToolError("set_memory was not run: entries: \"\(entry.src)\" has no src or no dst once cleaned")
                }
            }
            try apply(a, rules: rules, to: &profile, in: settings)
            settings.appProfiles[i] = profile
        }
        guard let profile = MCPProfiles.profile(id, in: stored) else {
            throw MCPToolError("set_memory could not write \(world.settingsURL.path); nothing changed")
        }

        // What changed, by name, and how many names the memory holds now: the agent has the rows it sent, and get_memory returns the memory.
        let was = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = Set(profile.entries.map(\.id))
        var result: [String: Any] = ["profile": id, "created": existing == nil, "names": profile.entries.count]
        if existing == nil { result["pair"] = MCPProfiles.pair(profile) }
        let changes = [("added", profile.entries.filter { was[$0.id] == nil }.map(\.src)),
                       ("updated", profile.entries.filter { e in was[e.id].map { $0 != e } ?? false }.map(\.src)),
                       ("removed", before.filter { !kept.contains($0.id) }.map(\.src))]
        for (key, names) in changes where !names.isEmpty { result[key] = names }
        if !issues.isEmpty { result["issues"] = issues }
        return result
    }

    private static func decoded<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed))
    }

    /// The call's rewrite rows and script, checked the way the file's strict check does them (rewrite-rules §2, §3, §8): the arguments' own kinds have
    /// passed the lengths and the stage, and the script service compiles each regex row's pattern (never runs it) and parses the script. Any issue, or a
    /// service that cannot be asked, is a tool error that names the place, the line when the engine of JavaScript gave one and never a made-up column;
    /// nothing is written. The service is asked only when there is a regex row or a script, so a plain table starts nothing.
    private static func checkedRules(_ a: [String: Any]) throws -> (rows: [RewriteRow]?, script: RewriteScript?) {
        let rows = try a["rewrites"].map { try decoded($0, as: [RewriteRow].self) }
        let script = try a["script"].map { try decoded($0, as: RewriteScript.self) }
        guard rows != nil || script != nil else { return (nil, nil) }
        let checked = MCPAsync.wait { await ScriptConnection.shared.check(rows: rows ?? [], script: script) }
        if !checked.issues.isEmpty { throw MCPToolError("set_memory was not run: " + checked.issues.map(\.description).joined(separator: "; ")) }
        if let script, !script.source.isEmpty, checked.defines.isEmpty {
            throw MCPToolError("set_memory was not run: script defines neither before(line, ctx) nor after(src, dst, ctx)")
        }
        return (rows, script)
    }

    /// The fields of a profile beyond its memory (design §7), read against the settings file's own kinds by the tool's arguments already.
    private static func apply(_ a: [String: Any], rules: (rows: [RewriteRow]?, script: RewriteScript?), to profile: inout AppProfile, in settings: AppSettings) throws {
        if let rows = rules.rows { profile.rewrites = rows }
        if let script = rules.script { profile.script = script.source.isEmpty ? nil : script }
        if let when = a["when"] { profile.when = try decoded(when, as: [ProfileCondition].self) }
        if let source = a["source"] as? String { profile.source = source }
        if let target = a["target"] as? String { profile.target = target }
        if let raw = a["customEngineID"] {
            let engine = (raw as? String).flatMap(ProfileEngine.named)
            if let id = engine?.id, !settings.engines.contains(where: { $0.id == id }) {
                throw MCPToolError("set_memory was not run: customEngineID: no engine has the id \(id.uuidString); get_settings engines lists them, or use \"apple\" or null")
            }
            profile.engine = engine
        }
        if let context = a["context"] { profile.context = try decoded(context, as: AppContextOverride.self) }
        if let learn = a["useLearned"] as? Bool { profile.useLearned = learn }
    }

    /// `remove: true`: the profile goes (its learned-names file stays). A pin to it goes too, which the file does not allow to stand.
    @MainActor
    private static func remove(_ key: String, asProfile: Bool, _ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        if let other = a.keys.sorted().first(where: { !["app", "profile", "remove"].contains($0) }) {
            throw MCPToolError("set_memory was not run: remove deletes the profile and takes nothing else, but \(other) was given")
        }
        var found: AppProfile?
        _ = try MCPSettingsWrite.change(world, tool: "set_memory") { settings in
            found = asProfile ? MCPProfiles.profile(key, in: settings) : AppProfiles.profile(for: key, in: settings.appProfiles)
            guard let found else { throw MCPToolError("set_memory was not run: \(asProfile ? "no profile has the id" : "no profile for the app") \(key)") }
            settings.appProfiles.removeAll { $0.id == found.id }
            if settings.profilePin == found.id { settings.profilePin = nil }
        }
        return ["profile": found?.id ?? key, "deleted": true]
    }
}

// MARK: - rewrite rules

/// `test_rules` (rewrite-rules §8): the rewrites of the chain a lens over a window, or under a profile, would run, over lines the agent gives, with no
/// screen. The plan is `RewritePlan` over the chain (the order of §4: `before` broad to narrow, `after` narrow to broad) and the session is `RewriteSession`
/// over the app's own `ScriptConnection`, so what the agent sees is what a lens gets, the time limit included. It is a dry run: a unit the limit turns off is
/// reported in `errors` and nothing is written to the file. With no regex row and no script in the chain the connection is never asked, so no service starts.
enum MCPRules {
    /// `[line, source]` for each line (`line` is the index among the lines given; `source` is what `before` leaves, what the engine would be sent), and with
    /// `translate` also `translation` (the engine's answer to `source`, null for a line the service left as it was) and `shown` (`after` over the answer).
    static func test(_ a: [String: Any], _ world: MCPWorld) throws -> [String: Any] {
        let lines = a["lines"] as? [String] ?? []
        if lines.isEmpty { throw MCPToolError("test_rules was not run: lines holds no line") }
        let app = a["app"] as? String, profile = a["profile"] as? String, title = a["title"] as? String
        var settings = world.settings()
        if let profile {
            guard MCPProfiles.profile(profile, in: settings) != nil else {
                throw MCPToolError("test_rules was not run: profile: no profile has the id \(profile); list_apps lists them")
            }
            // As if every lens were pinned to it: the chain is that profile and All apps, and no condition is asked (design §1.3).
            settings.profilePin = profile
        }
        let chain = ContextRoute.merged(settings: settings, lens: app, title: title)
        let plan = RewritePlan(chain: chain.links.map { link in
            switch link {
            case let .profile(p): RewriteLayer(profile: p.id, rows: p.rewrites, script: p.script)
            case .allApps: RewriteLayer(profile: link.id, rows: settings.rewrites, script: settings.script)
            }
        })
        let context = RewriteContext(app: app ?? "", profile: chain.head.id, source: chain.pair.source, target: chain.pair.target)
        var session = RewriteSession(plan: plan, context: context, runner: ScriptConnection.shared)
        let sources: [String]
        (sources, session) = MCPAsync.wait { [session] in
            var running = session
            var out: [String] = []
            for line in lines { out.append(await running.before(line)) }
            return (out, running)
        }

        var columns = ["line", "source"]
        var rows: [[Any]] = sources.enumerated().map { [$0.offset, $0.element] }
        var result: [String: Any] = ["profile": chain.head.id]
        if a["translate"] as? Bool == true {
            let done = try MCPTranslate.translate(sources, a, world, tool: "test_rules", withRewrites: false)
            let answers = done.rows.map { $0[0] as? String }
            let shown: [String?]
            (shown, session) = MCPAsync.wait { [session] in
                var running = session
                var out: [String?] = []
                for (src, dst) in zip(sources, answers) { out.append(dst == nil ? nil : await running.after(src: src, dst: dst ?? "")) }
                return (out, running)
            }
            columns += ["translation", "shown"]
            rows = rows.indices.map { rows[$0] + [answers[$0] ?? NSNull(), shown[$0] ?? NSNull()] }
            if let issue = done.extra["issue"] { result["issue"] = issue }
        }
        result["columns"] = columns
        result["rows"] = rows
        if !session.issues.isEmpty { result["errors"] = session.issues.map(error) }
        return result
    }

    /// `{stage, item, line, column, message}`: `item` is the row's index, or -1 for the script; the line and column only when known.
    static func error(_ issue: RewriteIssue) -> [String: Any] {
        var out: [String: Any] = ["item": issue.item, "message": issue.message]
        if let stage = issue.stage { out["stage"] = stage.rawValue }
        if let line = issue.line { out["line"] = line }
        if let column = issue.column { out["column"] = column }
        return out
    }
}
