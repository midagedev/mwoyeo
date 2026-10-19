import Foundation
import MwoyeoCore

/// One problem found in settings.json. The file is read leniently: an issue is reported, never thrown.
struct SettingsFileIssue: Equatable {
    /// Line in the file; nil when it is not about a place in the file.
    var line: Int?
    var message: String

    /// `settings.json:<line>: <message>`, the line the command-line check prints.
    func described(file: String) -> String { "\(file):\(line ?? 1): \(message)" }
}

/// What the file says about one setting: its documentation, type and limits. The one place that lists the keys of
/// settings.json, for `SettingsSchema` (what an editor or an agent reads) and for `SettingsFileCheck` (what is accepted).
/// A setting's `kind` is a `FieldKind` tree (`SettingsFieldSpec.swift`): the same tree gives the schema and the check, nested objects included.
/// `SettingsFileCheck.uncoveredKeys` fails a check when AppSettings writes a key this table lacks.
struct SettingSpec {
    let key: String
    let kind: FieldKind
    let doc: String
    /// Realistic values of the whole setting, for `examples` in the schema; each must pass the check.
    var examples: [Any] = []

    static let all: [SettingSpec] = [
        .init(key: "sourceLanguage", kind: .choice(Languages.sources),
              doc: "Language of the text on screen: a code such as ja or zh-Hans, or auto to detect it per line."),
        .init(key: "targetLanguage", kind: .choice(Languages.targets), doc: "Language to translate into, as a code such as en or ko."),
        .init(key: "engine", kind: .choice(TranslationEngineChoice.allCases.map(\.rawValue)),
              doc: "Apple's translation choice: auto (the language pack when installed), highFidelity (Apple Intelligence's translation model) or customModel (a prompted on-device model that follows the glossary)."),
        .init(key: "engines", kind: .engines,
              doc: "Translation engines you added, each with a name, a kind and its address. API keys are never stored here; they stay in the Keychain. Add engines in Settings > Translation.",
              examples: SettingExamples.engines),
        .init(key: "customEngineID", kind: .idOrNull, doc: "The id of the added engine in use, or null to use Apple's translation."),
        .init(key: "renderMode", kind: .choice(RenderMode.allCases.map(\.rawValue)),
              doc: "How translations are drawn: adaptive (boxes while things move, a rewrite in place once still), fast (always boxes) or seamless (always erase and rewrite)."),
        .init(key: "useInpaintingModel", kind: .bool,
              doc: "Erase the original text with the on-device model when rewriting in place; off fills with a flat colour."),
        .init(key: "glossary", kind: .string, doc: "Fixed translations for names and terms, one \"source = target\" pair per line."),
        .init(key: "framesPerSecond", kind: .number(1...30),
              doc: "How many times a second the screen is checked for changes. Settings offers 4, 8 and 15."),
        .init(key: "settleDelay", kind: .number(0.2...2),
              doc: "Seconds the screen must stay unchanged before the in-place rewrite runs in adaptive mode."),
        .init(key: "fontStyle", kind: .choice(FontStyleChoice.allCases.map(\.rawValue)), doc: "Typeface of the translated text."),
        .init(key: "boxOpacity", kind: .number(0.6...1), doc: "Opacity of the box behind translated text in fast mode."),
        .init(key: "lensStyle", kind: .choice(LensStyle.allCases.map(\.rawValue)),
              doc: "Look of the lens frame: glow (a ring with a soft glow), subtle (a thin line that glows while reading), corners (only the four corners) or minimal (a faint grey line)."),
        .init(key: "lensTint", kind: .choice(LensTint.allCases.map(\.rawValue)),
              doc: "Colours of the lens frame: spectrum, accent (the system accent colour), ocean, sunset, forest or mono. A minimal lens is grey whatever this says."),
        .init(key: "lensTabVisibility", kind: .choice(LensTabVisibility.allCases.map(\.rawValue)),
              doc: "When the lens shows its name tag: automatic (always, except under the pointer only on a minimal lens), always or onHover."),
        .init(key: "lensTabPosition", kind: .choice(LensTabPosition.allCases.map(\.rawValue)),
              doc: "Where the name tag sits: topLeading, topTrailing, bottomLeading or bottomTrailing."),
        .init(key: "cacheSize", kind: .integer(100...100_000), doc: "How many translations are kept in memory for reuse."),
        .init(key: "shortcuts", kind: .shortcuts,
              doc: "Global keyboard shortcuts by action name; an action left out has no shortcut. Each has a Carbon keyCode, a Carbon modifiers mask and a display text. Easier to set in Settings > Shortcuts."),
        .init(key: "checksForUpdates", kind: .bool, doc: "Ask GitHub once a day whether a newer version is out."),
        .init(key: "savesTranscripts", kind: .bool,
              doc: "Translation log: every lens writes what it read and its translation to <exportFolder>/Transcripts (Markdown and SRT, see transcriptFormats) while this is true."),
        .init(key: "exportFolder", kind: .string,
              doc: "Folder of the translation log (its Transcripts folder, while savesTranscripts is true) and of saved lens images. The App Store version shows the folder chosen in Settings; a path typed here does not open one there."),
        .init(key: "transcriptFormats", kind: .choiceList(TranscriptFileFormat.allCases.map(\.rawValue)),
              doc: "Files of the translation log: markdown, srt, and jsonl (one JSON line per translated line with time, lens, app, source, target, engine, original and translation, added as it happens so tail -f works)."),
        .init(key: "appProfiles", kind: .appProfiles,
              doc: "Languages, engine and paragraph reader remembered per app; the app in front decides which applies. Easier to set from a lens's menu. A profile can also carry a note for the translator, names and terms with their translations, and a context override for that app; the app uses them to translate while context is on for that app.",
              examples: SettingExamples.appProfiles),
        .init(key: "paragraphReader", kind: .choice(ParagraphReader.allCases.map(\.rawValue)),
              doc: "How text is cut into paragraphs: automatic, documentLayout (the macOS document model) or lineGrouping (the app's own line rules)."),
        .init(key: "appleUsesPinnedTerms", kind: .bool,
              doc: "Apple Translation follows the names and terms you pinned in an app's memory, by putting your translation into the source text. Off by default. Written to the file only when true; write false to turn it off."),
    ]

    static func spec(for key: String) -> SettingSpec? { all.first { $0.key == key } }

    /// `value` as this setting with the bad parts left out, or nil when it cannot stand (the setting then keeps its current
    /// value). What is wrong goes to `problems`, each with its path.
    func read(_ value: Any, problems: inout [FieldProblem]) -> Any? {
        kind.read(value, at: FieldPath(steps: [.key(key)]), fallout: .keep, problems: &problems)
    }

    // MARK: value helpers

    static func isBool(_ v: Any) -> Bool { (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false }
    static func number(_ v: Any) -> Double? { isBool(v) ? nil : (v as? NSNumber)?.doubleValue }
    static func shown(_ d: Double) -> String { d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d) }

    static func name(of v: Any) -> String {
        if v is NSNull { return "null" }
        if v is String { return "a string" }
        if isBool(v) { return "a boolean" }
        if v is NSNumber { return "a number" }
        if v is [Any] { return "an array" }
        return "an object"
    }
}

// MARK: the trees of the nested settings

/// The nested settings, each one a `FieldKind` tree. To add a nested field, add a `FieldSpec` here; the schema, the check
/// and its line numbers follow. Keep a field's JSON key equal to what its Codable type encodes.
extension FieldKind {
    /// Action name → key combo. An action left out has no shortcut.
    static let shortcuts: FieldKind = .map(
        .object([
            FieldSpec("keyCode", .integer(0...4_294_967_295), "Carbon virtual key code.", required: true, example: 37),
            FieldSpec("modifiers", .integer(0...4_294_967_295),
                      "Carbon modifier mask: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096, added together.", required: true, example: 6144),
            FieldSpec("display", .string, "How the shortcut is shown, such as ⌃⌥L.", required: true, example: "⌃⌥L"),
        ]),
        keys: HotKeyAction.allCases.map(\.rawValue), keyNoun: "action")

    private static func baseURL(required: Bool) -> FieldSpec {
        FieldSpec("baseURL", .url,
                  "Where the engine's server answers, an http or https address such as http://localhost:8765/v1. An Anthropic engine without one uses https://api.anthropic.com.",
                  required: required, example: "http://localhost:8765/v1")
    }
    private static let model = FieldSpec("model", .string, "The model name the server expects, such as qwen3:8b. Left out, it is empty.", example: "qwen3:8b")
    private static let thinking = FieldSpec("thinking", .choice(["off", "provider"]),
                                            "off asks the server not to reason (faster, cleaner translations); provider sends nothing extra and lets a reasoning model think.",
                                            default: "off")
    private static let headers = FieldKind.map(.string)

    /// `engines[].context`: the keys, defaults and limits are those of `EngineContext` and `AppContextOverride`, never a copy.
    /// A field this object lacks would be dropped at the app's next save, and `SettingsFileChecks` fails when the two differ.
    private static let engineContext: FieldKind = .object([
        FieldSpec("enabled", .bool,
                  "Turn context on for this engine. Off, nothing below has an effect and requests are unchanged. On, each request also carries the app's name and kind, the lines around the text on screen, the earlier lines (previousLines) and the memory written for that app.",
                  example: true, default: false),
        FieldSpec("previousLines", .integer(0...AppContextOverride.maxPreviousLines),
                  "How many earlier lines go along with each line, 0 to \(AppContextOverride.maxPreviousLines). Counts only while enabled is true.",
                  example: 3, default: AppContextOverride.defaultPreviousLines),
        FieldSpec("includeTitle", .bool,
                  "Also send the title of the window. Off by default, because the title leaves this Mac when the engine is a cloud service; a server on this Mac gets it whenever enabled is true.",
                  example: false, default: false),
        FieldSpec("useLearned", .bool,
                  "Also send the names and terms the app picked up while translating, and record the terms the engine's reply names. Learned terms stay in memory and are never saved to this file.",
                  example: false, default: false),
        FieldSpec("deepLInstructions", .bool,
                  "DeepL only. Send custom_instructions and a formality that come from the memory written for the app. Other engine kinds ignore it.",
                  example: false, default: false),
    ])

    /// The engines you added. `kind` picks the shape: what the other fields are depends on it.
    static let engines: FieldKind = .list(.tagged(
        tag: "kind",
        tagDoc: "What the engine speaks: openAICompatible (Ollama, LM Studio and the like), anthropic, deepL, httpTemplate (any HTTP service you describe) or command (a program of your own). The other fields depend on it.",
        common: [
            FieldSpec("id", .uuid, "Identifies the engine; customEngineID and appProfiles refer to it.", example: exampleUUID),
            FieldSpec("name", .string, "The name shown in Settings.", required: true, example: "Local Qwen"),
            FieldSpec("context", engineContext,
                      "What this engine is sent besides the lines to translate. Everything here is off by default: left out, or with enabled false, every request is the one it always was. An app's own context (appProfiles[].context) is laid over these."),
        ],
        variants: [
            FieldVariant(tag: "openAICompatible", fields: [
                baseURL(required: true), model, thinking,
                FieldSpec("extraHeaders", headers,
                          "Extra HTTP headers, name to value. Never put a key here: a header that must carry it holds {{key}}, which the app fills in from the Keychain.",
                          example: ["X-Org": "team-a"]),
            ]),
            FieldVariant(tag: "anthropic", fields: [baseURL(required: false), model, thinking]),
            FieldVariant(tag: "deepL", fields: [
                baseURL(required: true),
                FieldSpec("formality", .string, "DeepL's formality: default, more, less, prefer_more or prefer_less. Left out, DeepL decides.", example: "prefer_more"),
            ]),
            FieldVariant(tag: "httpTemplate", fields: [
                FieldSpec("template", .object([
                    FieldSpec("method", .string, "GET, POST, PUT or PATCH.", default: "POST"),
                    FieldSpec("url", .string, "The request address. {{text}}, {{source}}, {{target}} and {{key}} are filled in.", required: true,
                              example: "http://localhost:5000/translate"),
                    FieldSpec("headers", headers, "HTTP headers, name to value; the same placeholders work in the values."),
                    FieldSpec("body", .string, "The request body, with the same placeholders. {{lines}} sends all lines as a JSON array (batching jsonArray).", default: ""),
                    FieldSpec("resultPath", .string,
                              "Where the translations are in the JSON reply: dot keys and [n] indexes, [*] maps over an array, such as translatedText or data.translations[0].translatedText.",
                              required: true, example: "translatedText"),
                    FieldSpec("batching", .choice(["perLine", "jsonArray"]),
                              "perLine sends one request per line ({{text}}); jsonArray sends all lines in one ({{lines}}).", default: "perLine"),
                ]), "How to call an HTTP service that is none of the built-in kinds (LibreTranslate, DeepLX, Papago, a server of your own).", required: true),
            ]),
            FieldVariant(tag: "command", fields: [
                FieldSpec("command", .object([
                    FieldSpec("executable", .string, "Path of the program to run.", required: true, example: "/usr/local/bin/translate-me"),
                    FieldSpec("arguments", .list(.string), "Arguments passed to the program.", example: ["--fast"]),
                ]), "A program of your own: the app writes one JSON line {source, target, lines} to its stdin and reads {translations} from its stdout.", required: true),
            ]),
        ]))

    /// One name or term of an app's memory. The keys, enums and limits are those of `MemoryEntry` and `Addressing`: a field
    /// this row lacks would be dropped at the app's next save, and `SettingsFileChecks` fails when the two differ.
    private static let appEntries: FieldKind = .list(.object([
        FieldSpec("src", .text(maxLength: MemoryEntry.maxName, minLength: 1), "The name or term as it is written in the text.", required: true, example: "田中"),
        FieldSpec("dst", .text(maxLength: MemoryEntry.maxName, minLength: 1), "How it is translated.", required: true, example: "Tanaka"),
        FieldSpec("kind", .choice(EntryKind.allCases.map(\.rawValue)), "What it is. Left out, term.", example: "person"),
        FieldSpec("gender", .choice(Gender.allCases.map(\.rawValue)), "For a person: f, m or n (neutral), so pronouns and agreement come out right.", example: "m"),
        FieldSpec("note", .text(maxLength: MemoryEntry.maxEntryNote), "A short hint about it, up to \(MemoryEntry.maxEntryNote) characters.", example: "the speaker's older colleague"),
        FieldSpec("reading", .text(maxLength: MemoryEntry.maxName), "How src is pronounced, such as the kana of a kanji name.", example: "たなか"),
        FieldSpec("addressing", .list(.object([
            FieldSpec("to", .text(maxLength: MemoryEntry.maxName, minLength: 1), "Who is being spoken to, as written in that entry's src.", required: true, example: "Hana"),
            FieldSpec("register", .choice(Register.allCases.map(\.rawValue)), "How this person speaks to them.", required: true, example: "polite"),
        ]), maxItems: MemoryEntry.maxAddressing, dropsBad: true),
                  "How this person speaks to others: one row per listener, up to \(MemoryEntry.maxAddressing)."),
    ]), maxItems: AppProfile.maxEntries, dropsBad: true)

    /// What the app remembers per app. The memory fields (note, entries, context) are all optional; their limits are the
    /// constants of the Core types that keep them (`AppProfile`, `MemoryEntry`, `AppContextOverride`), never a second copy.
    static let appProfiles: FieldKind = .list(.object([
        FieldSpec("bundleID", .string, "Bundle identifier of the app.", required: true, example: "com.example.chat"),
        FieldSpec("appName", .string, "The app's name, for display.", example: "Example Chat"),
        FieldSpec("source", .choice(Languages.sources), "Source language code, or auto.", required: true, example: "ja"),
        FieldSpec("target", .choice(Languages.targets), "Target language code.", required: true, example: "en"),
        FieldSpec("customEngineID", .idOrNull, "Engine for this app; null keeps the base choice."),
        FieldSpec("paragraphReader", .choice(ParagraphReader.allCases.map(\.rawValue)), "Paragraph reader for this app; left out follows the default."),
        FieldSpec("note", .text(maxLength: AppProfile.maxNoteLength),
                  "A note for the translator about this app: who is talking, the setting, the register. Up to \(AppProfile.maxNoteLength) characters.",
                  example: "Casual chat between two friends. Keep it informal and short."),
        FieldSpec("entries", appEntries,
                  "Names and terms of this app with their translations, up to \(AppProfile.maxEntries) rows. A bad row is reported and dropped; the rest apply. A second row with the same src is left out."),
        FieldSpec("context", .object([
            FieldSpec("mode", .choice(AppContextOverride.Mode.allCases.map(\.rawValue)),
                      "How much surrounding text goes along with each line: off (none), nearby (the lines around it on screen) or conversation (also the lines read before).",
                      required: true, example: "nearby"),
            FieldSpec("previousLines", .integer(0...AppContextOverride.maxPreviousLines),
                      "How many earlier lines go along in conversation mode, 0 to \(AppContextOverride.maxPreviousLines).",
                      example: 3, default: AppContextOverride.defaultPreviousLines),
        ]), "Context for this app's translations. Left out, the app follows the default, which is off."),
    ]))
}

/// Realistic values for the schema's `examples`. check-logic reads each through the check, so they stay valid.
enum SettingExamples {
    static let engines: [Any] = [
        [["id": FieldKind.exampleUUID, "kind": "openAICompatible", "name": "Local Qwen", "baseURL": "http://localhost:8765/v1",
          "model": "qwen3:8b", "thinking": "off"] as [String: Any]],
        [["kind": "deepL", "name": "DeepL", "baseURL": "https://api.deepl.com", "formality": "prefer_more"] as [String: Any]],
        [["kind": "openAICompatible", "name": "Local Qwen with context", "baseURL": "http://localhost:8765/v1", "model": "qwen3:8b",
          "context": ["enabled": true, "previousLines": 3, "includeTitle": false, "useLearned": false, "deepLInstructions": false] as [String: Any]] as [String: Any]],
    ]

    /// One profile with a note, two entries that carry addressing, and a context override.
    static let appProfiles: [Any] = [
        [[
            "bundleID": "com.example.chat", "appName": "Example Chat", "source": "ja", "target": "en", "paragraphReader": "lineGrouping",
            "note": "Casual chat between two friends. Keep it informal and short.",
            "entries": [
                ["src": "田中", "dst": "Tanaka", "kind": "person", "gender": "m", "note": "the speaker's older colleague", "reading": "たなか",
                 "addressing": [["to": "Hana", "register": "polite"]]] as [String: Any],
                ["src": "花", "dst": "Hana", "kind": "person", "gender": "f",
                 "addressing": [["to": "Tanaka", "register": "casual"]]] as [String: Any],
            ],
            "context": ["mode": "nearby", "previousLines": 3] as [String: Any],
        ] as [String: Any]],
    ]
}

/// What reading settings.json gives: the settings to apply and the issues found.
struct SettingsFileResult {
    var settings: AppSettings
    var issues: [SettingsFileIssue]
    /// False when the text is not JSON at all (nothing in it was applied).
    var parsed = true
    /// The keys whose value differs from `current`.
    var changed: [String] = []
}

enum SettingsFileCheck {
    /// Settings kept in UserDefaults instead (run-time state, not a choice), so never in the file.
    static let notInFile: Set<String> = ["engineRejections", "hasCompletedOnboarding", "exportBookmark", "enginePermissions"]

    /// The file's own view of the settings: what AppSettings encodes, without the run-time state, plus an explicit null id.
    static func fileValues(_ s: AppSettings, omittingUnset: Bool = true) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(s),
              var d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        for k in notInFile { d[k] = nil }
        if omittingUnset { for k in writtenOnlyWhenTrue where d[k] as? Bool == false { d[k] = nil } }
        if d["customEngineID"] == nil { d["customEngineID"] = NSNull() }
        return d
    }

    /// Switches added after 1.1.2 that are off by default. The file holds one only while it is true, so a file from before
    /// the key re-saves byte for byte. The schema still lists it, with its default.
    static let writtenOnlyWhenTrue: Set<String> = ["appleUsesPinnedTerms"]

    /// Keys AppSettings writes to the file that `SettingSpec.all` does not describe (the schema would lack them). Every
    /// switch counts, also one the file leaves out while it is off.
    static func uncoveredKeys() -> [String] {
        fileValues(AppSettings(), omittingUnset: false).keys.filter { SettingSpec.spec(for: $0) == nil }.sorted()
    }

    /// Reads the file's `data` over `current`. A key the file lacks keeps its current value; so does a key that is
    /// wrong, which is reported. Text that is not JSON changes nothing.
    static func read(_ data: Data, over current: AppSettings) -> SettingsFileResult {
        let text = String(decoding: data, as: UTF8.self)
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            let desc = ((error as NSError).userInfo["NSDebugDescription"] as? String) ?? error.localizedDescription
            let line = position(in: desc)?.line ?? 1
            return SettingsFileResult(settings: current, issues: [.init(line: line, message: "invalid JSON: \(desc) Nothing was applied; a change made in Settings would keep this file as settings.json.broken.")],
                                      parsed: false)
        }
        guard let object = root as? [String: Any] else {
            return SettingsFileResult(settings: current, issues: [.init(line: 1, message: "invalid settings: the file must hold one JSON object. Nothing was applied.")], parsed: false)
        }
        var issues: [SettingsFileIssue] = []
        var accepted: [String: Any] = [:]
        let lines = JSONLines.index(text)
        for (key, value) in object.sorted(by: { $0.key < $1.key }) {
            let path = FieldPath(steps: [.key(key)])
            if key == "$schema" {
                var problems: [FieldProblem] = []
                _ = FieldKind.string.read(value, at: path, fallout: .ignore, problems: &problems)
                issues += problems.map { SettingsFileIssue(line: lines.line(of: $0.path), message: $0.message) }
                continue
            }
            guard let spec = SettingSpec.spec(for: key) else {
                let hint = closest(to: key, in: SettingSpec.all.map(\.key)).map { " (did you mean \($0)?)" } ?? ""
                issues.append(.init(line: lines.line(of: path), message: "unknown key \(key)\(hint)"))
                continue
            }
            var problems: [FieldProblem] = []
            let kept = spec.read(value, problems: &problems)
            issues += problems.map { SettingsFileIssue(line: lines.line(of: $0.path), message: $0.message) }
            if let kept { accepted[key] = kept }
        }
        for line in lines.trailingCommas {
            issues.append(.init(line: line, message: "trailing comma: JSON does not allow a comma before } or ]; the app reads it, other tools will not"))
        }
        issues.sort { ($0.line ?? .max, $0.message) < ($1.line ?? .max, $1.message) }

        var merged = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(current))) as? [String: Any] ?? [:]
        for (k, v) in accepted {
            if v is NSNull { merged[k] = nil } else { merged[k] = v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: merged),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return SettingsFileResult(settings: current, issues: issues + [.init(line: 1, message: "the settings could not be applied")])
        }
        return SettingsFileResult(settings: settings, issues: issues, parsed: true, changed: changedKeys(current, settings))
    }

    static func changedKeys(_ a: AppSettings, _ b: AppSettings) -> [String] {
        let x = fileValues(a), y = fileValues(b)
        return Set(x.keys).union(y.keys).filter { k in
            guard let p = x[k] as? NSObject, let q = y[k] as? NSObject else { return true }
            return !p.isEqual(q)
        }.sorted()
    }

    // MARK: positions and suggestions (the line of every value is `JSONLines`)

    /// The "around line 3, column 7" of Foundation's JSON error.
    private static func position(in description: String) -> (line: Int, column: Int)? {
        guard let m = description.firstMatch(of: /line (\d+), column (\d+)/),
              let l = Int(m.1), let c = Int(m.2) else { return nil }
        return (l, c)
    }

    /// The known key nearest to `key` (ignoring case), if it is near enough to be a typo of it.
    static func closest(to key: String, in known: [String]) -> String? {
        let k = key.lowercased()
        let scored = known.map { ($0, distance(k, $0.lowercased())) }.min { $0.1 < $1.1 }
        guard let (name, d) = scored, d <= max(2, key.count / 3) else { return nil }
        return name
    }

    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var prev = row[0]
            row[0] = i
            for j in 1...b.count {
                let t = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                prev = t
            }
        }
        return row[b.count]
    }
}

/// How the file is written: sorted keys, two-space indent, `"key": value`, a trailing newline.
enum SettingsFileFormat {
    static let schemaName = "settings.schema.json"

    static func render(_ s: AppSettings) -> Data {
        var d = SettingsFileCheck.fileValues(s)
        d["$schema"] = schemaName
        return Data((pretty(d) + "\n").utf8)
    }

    /// `$schema` sorts first, so an editor finds the schema before it reads a key.
    static func pretty(_ v: Any, depth: Int = 0) -> String {
        let pad = String(repeating: "  ", count: depth + 1), end = String(repeating: "  ", count: depth)
        if let d = v as? [String: Any] {
            if d.isEmpty { return "{}" }
            return "{\n" + d.keys.sorted().map { "\(pad)\(leaf($0)): \(pretty(d[$0]!, depth: depth + 1))" }.joined(separator: ",\n") + "\n\(end)}"
        }
        if let a = v as? [Any] {
            if a.isEmpty { return "[]" }
            return "[\n" + a.map { pad + pretty($0, depth: depth + 1) }.joined(separator: ",\n") + "\n\(end)]"
        }
        return leaf(v)
    }

    private static func leaf(_ v: Any) -> String {
        if v is NSNull { return "null" }
        // Foundation prints a double with 17 digits (0.94 as 0.93999999999999995); Swift's description is the shortest that reads back.
        if let n = v as? NSNumber, !SettingSpec.isBool(v) {
            if CFNumberIsFloatType(n) { return SettingSpec.shown(n.doubleValue) }
            return String(n.int64Value)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .withoutEscapingSlashes]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}

/// settings.schema.json (JSON Schema 2020-12), generated from `SettingSpec.all` and AppSettings' defaults. Nested objects come
/// from the same `FieldKind` trees the check walks, so the schema says exactly what `--check-settings` accepts.
enum SettingsSchema {
    static func data() -> Data {
        let defaults = SettingsFileCheck.fileValues(AppSettings(), omittingUnset: false)
        var props: [String: Any] = ["$schema": ["type": "string", "description": "This schema, next to the file. Keep it as it is."]]
        for spec in SettingSpec.all {
            var p = spec.kind.schema()
            p["description"] = spec.doc
            if let d = defaults[spec.key] { p["default"] = d }
            if !spec.examples.isEmpty { p["examples"] = spec.examples }
            props[spec.key] = p
        }
        let schema: [String: Any] = [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "title": "Mwoyeo settings",
            "description": "Mwoyeo's settings. The app watches this file and applies a saved change within a second. Keys left out keep their value.",
            "type": "object",
            "properties": props,
            "additionalProperties": false,
        ]
        return Data((SettingsFileFormat.pretty(schema) + "\n").utf8)
    }
}

/// The three commands an agent or a script uses; none starts the app:
///   `Mwoyeo --settings-path`            prints where settings.json is.
///   `Mwoyeo --settings-schema`          prints the schema (the settings.schema.json next to the file) to stdout.
///   `Mwoyeo --check-settings [path]`    prints `settings.json:<line>: <message>` per issue, or `ok`; exit 1 when there are issues.
enum SettingsFileCommand {
    static func run(_ args: [String]) -> Never {
        if args.first == "--settings-path" {
            print(SettingsFileStore.defaultURL.path)
            exit(0)
        }
        if args.first == "--settings-schema" {
            FileHandle.standardOutput.write(SettingsSchema.data())
            exit(0)
        }
        let url = args.dropFirst().first.map { URL(fileURLWithPath: $0) } ?? SettingsFileStore.defaultURL
        let (lines, code) = check(url)
        lines.forEach { print($0) }
        exit(code)
    }

    static func check(_ url: URL) -> (lines: [String], code: Int32) {
        guard let data = try? Data(contentsOf: url) else { return (["\(url.lastPathComponent):1: cannot read \(url.path)"], 1) }
        let issues = SettingsFileCheck.read(data, over: AppSettings()).issues
        return issues.isEmpty ? (["ok"], 0) : (issues.map { $0.described(file: url.lastPathComponent) }, 1)
    }
}
