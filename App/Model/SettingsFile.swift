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
/// `SettingsFileCheck.uncoveredKeys` fails a check when AppSettings writes a key this table lacks.
struct SettingSpec {
    enum Kind {
        case string, bool
        case number(ClosedRange<Double>)
        case integer(ClosedRange<Int>)
        /// One of these raw values.
        case choice([String])
        /// A UUID string, or null.
        case idOrNull
        /// A list of these raw values; a value not among them is reported and dropped, the rest applies.
        case choiceList([String])
        case shortcuts, engines, appProfiles
    }

    let key: String
    let kind: Kind
    let doc: String

    static let all: [SettingSpec] = [
        .init(key: "sourceLanguage", kind: .choice(Languages.sources),
              doc: "Language of the text on screen: a code such as ja or zh-Hans, or auto to detect it per line."),
        .init(key: "targetLanguage", kind: .choice(Languages.targets), doc: "Language to translate into, as a code such as en or ko."),
        .init(key: "engine", kind: .choice(TranslationEngineChoice.allCases.map(\.rawValue)),
              doc: "Apple's translation choice: auto (the language pack when installed), highFidelity (Apple Intelligence's translation model) or customModel (a prompted on-device model that follows the glossary)."),
        .init(key: "engines", kind: .engines,
              doc: "Translation engines you added, each with a name, a kind and its address. API keys are never stored here; they stay in the Keychain. Add engines in Settings > Translation."),
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
              doc: "Look of the lens frame: glow (spectrum ring with a glow), subtle (a thin line that glows while reading) or minimal (a faint grey line)."),
        .init(key: "cacheSize", kind: .integer(100...100_000), doc: "How many translations are kept in memory for reuse."),
        .init(key: "shortcuts", kind: .shortcuts,
              doc: "Global keyboard shortcuts by action name; an action left out has no shortcut. Each has a Carbon keyCode, a Carbon modifiers mask and a display text. Easier to set in Settings > Shortcuts."),
        .init(key: "checksForUpdates", kind: .bool, doc: "Ask GitHub once a day whether a newer version is out."),
        .init(key: "savesTranscripts", kind: .bool,
              doc: "Translation log: every lens writes what it read and its translation to <exportFolder>/Transcripts (Markdown and SRT, see transcriptFormats) while this is true."),
        .init(key: "exportFolder", kind: .string,
              doc: "Folder of the translation log (its Transcripts folder, while savesTranscripts is true) and of saved lens images."),
        .init(key: "transcriptFormats", kind: .choiceList(TranscriptFileFormat.allCases.map(\.rawValue)),
              doc: "Files of the translation log: markdown, srt, and jsonl (one JSON line per translated line with time, lens, app, source, target, engine, original and translation, added as it happens so tail -f works)."),
        .init(key: "appProfiles", kind: .appProfiles,
              doc: "Languages, engine and paragraph reader remembered per app; the app in front decides which applies. Easier to set from a lens's menu."),
        .init(key: "paragraphReader", kind: .choice(ParagraphReader.allCases.map(\.rawValue)),
              doc: "How text is cut into paragraphs: automatic, documentLayout (the macOS document model) or lineGrouping (the app's own line rules)."),
    ]

    static func spec(for key: String) -> SettingSpec? { all.first { $0.key == key } }

    /// What is wrong with `value` for this setting, or nil when it is fine.
    func problem(with value: Any) -> String? {
        switch kind {
        case .string:
            return value is String ? nil : "expected a string, got \(Self.name(of: value))"
        case .bool:
            return Self.isBool(value) ? nil : "expected true or false, got \(Self.name(of: value))"
        case let .number(range):
            guard let n = Self.number(value) else { return "expected a number, got \(Self.name(of: value))" }
            return range.contains(n) ? nil : "\(Self.shown(n)) is out of range \(Self.shown(range.lowerBound)) to \(Self.shown(range.upperBound))"
        case let .integer(range):
            guard let n = Self.number(value) else { return "expected a whole number, got \(Self.name(of: value))" }
            guard n == n.rounded(), abs(n) < 1e15 else { return "expected a whole number, got \(Self.shown(n))" }
            return range.contains(Int(n)) ? nil : "\(Int(n)) is out of range \(range.lowerBound) to \(range.upperBound)"
        case let .choice(allowed):
            guard let s = value as? String else { return "expected one of \(allowed.joined(separator: ", ")), got \(Self.name(of: value))" }
            return allowed.contains(s) ? nil : "\"\(s)\" is not allowed; use one of \(allowed.joined(separator: ", "))"
        case .idOrNull:
            if value is NSNull { return nil }
            if let s = value as? String, UUID(uuidString: s) != nil { return nil }
            return "expected an engine id from engines, or null"
        case let .choiceList(allowed):
            guard let list = value as? [Any] else { return "expected a list of \(allowed.joined(separator: ", ")), got \(Self.name(of: value))" }
            return list.allSatisfy { $0 is String } ? nil : "expected a list of strings (\(allowed.joined(separator: ", ")))"
        case .shortcuts:
            guard let d = value as? [String: Any] else { return "expected an object of action: shortcut, got \(Self.name(of: value))" }
            for (action, combo) in d.sorted(by: { $0.key < $1.key }) {
                guard HotKeyAction(rawValue: action) != nil else {
                    return "unknown action \"\(action)\"; use \(HotKeyAction.allCases.map(\.rawValue).joined(separator: ", "))"
                }
                if let e = Self.strict(KeyCombo.self, combo) { return "\(action): \(e)" }
            }
            return nil
        case .engines:
            return Self.strictElements(EngineConfig.self, value)
        case .appProfiles:
            return Self.strictElements(AppProfile.self, value)
        }
    }

    /// For a list setting: what stays of `value` (already a list of strings) and the entries dropped for not being allowed.
    func filtered(_ value: Any) -> (kept: [Any], dropped: [String])? {
        guard case let .choiceList(allowed) = kind, let list = value as? [String] else { return nil }
        return (list.filter(allowed.contains), list.filter { !allowed.contains($0) })
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

    /// nil when `value` decodes as T, else why not.
    private static func strict<T: Decodable>(_ type: T.Type, _ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return "not an object" }
        do {
            _ = try JSONDecoder().decode(T.self, from: data)
            return nil
        } catch { return describe(error) }
    }

    private static func strictElements<T: Decodable>(_ type: T.Type, _ value: Any) -> String? {
        guard let items = value as? [Any] else { return "expected an array, got \(name(of: value))" }
        for (i, item) in items.enumerated() {
            if let e = strict(T.self, item) { return "item \(i): \(e)" }
        }
        return nil
    }

    private static func describe(_ error: Error) -> String {
        guard let e = error as? DecodingError else { return error.localizedDescription }
        func path(_ c: DecodingError.Context) -> String { c.codingPath.map(\.stringValue).joined(separator: ".") }
        switch e {
        case let .keyNotFound(k, _): return "missing \"\(k.stringValue)\""
        case let .typeMismatch(_, c), let .valueNotFound(_, c): return "wrong type at \"\(path(c))\""
        case let .dataCorrupted(c): return c.codingPath.isEmpty ? c.debugDescription : "bad value at \"\(path(c))\""
        @unknown default: return "unreadable"
        }
    }
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
    static let notInFile: Set<String> = ["engineRejections", "hasCompletedOnboarding"]

    /// The file's own view of the settings: what AppSettings encodes, without the run-time state, plus an explicit null id.
    static func fileValues(_ s: AppSettings) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(s),
              var d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        for k in notInFile { d[k] = nil }
        if d["customEngineID"] == nil { d["customEngineID"] = NSNull() }
        return d
    }

    /// Keys AppSettings writes to the file that `SettingSpec.all` does not describe (the schema would lack them).
    static func uncoveredKeys() -> [String] {
        fileValues(AppSettings()).keys.filter { SettingSpec.spec(for: $0) == nil }.sorted()
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
        for (key, value) in object.sorted(by: { $0.key < $1.key }) where key != "$schema" {
            let line = lineOf(key: key, in: text)
            guard let spec = SettingSpec.spec(for: key) else {
                let hint = closest(to: key, in: SettingSpec.all.map(\.key)).map { " (did you mean \($0)?)" } ?? ""
                issues.append(.init(line: line, message: "unknown key \(key)\(hint)"))
                continue
            }
            if let why = spec.problem(with: value) {
                issues.append(.init(line: line, message: "\(key): \(why); keeping the current value"))
            } else if let (kept, dropped) = spec.filtered(value), !dropped.isEmpty, case let .choiceList(allowed) = spec.kind {
                let names = dropped.map { "\"\($0)\"" }.joined(separator: ", ")
                issues.append(.init(line: line, message: "\(key): \(names) not allowed, dropped; use \(allowed.joined(separator: ", "))"))
                accepted[key] = kept
            } else {
                accepted[key] = value
            }
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

    // MARK: positions and suggestions

    /// The "around line 3, column 7" of Foundation's JSON error.
    private static func position(in description: String) -> (line: Int, column: Int)? {
        guard let m = description.firstMatch(of: /line (\d+), column (\d+)/),
              let l = Int(m.1), let c = Int(m.2) else { return nil }
        return (l, c)
    }

    /// The line where the top-level `key` is written (the one with the fewest leading spaces when a nested key repeats it).
    static func lineOf(key: String, in text: String) -> Int? {
        var best: (line: Int, indent: Int)?
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let indent = raw.prefix { $0 == " " || $0 == "\t" }.count
            let rest = raw.dropFirst(indent)
            guard rest.hasPrefix("\"\(key)\""), rest.dropFirst(key.count + 2).drop(while: { $0 == " " }).first == ":" else { continue }
            if best == nil || indent < best!.indent { best = (i + 1, indent) }
        }
        return best?.line
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

/// settings.schema.json (JSON Schema 2020-12), generated from `SettingSpec.all` and AppSettings' defaults.
enum SettingsSchema {
    static func data() -> Data {
        let defaults = SettingsFileCheck.fileValues(AppSettings())
        var props: [String: Any] = ["$schema": ["type": "string", "description": "This schema, next to the file. Keep it as it is."]]
        for spec in SettingSpec.all {
            var p = typeEntries(spec.kind)
            p["description"] = spec.doc
            if let d = defaults[spec.key] { p["default"] = d }
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

    private static func typeEntries(_ kind: SettingSpec.Kind) -> [String: Any] {
        switch kind {
        case .string: return ["type": "string"]
        case .bool: return ["type": "boolean"]
        case let .number(r): return ["type": "number", "minimum": r.lowerBound, "maximum": r.upperBound]
        case let .integer(r): return ["type": "integer", "minimum": r.lowerBound, "maximum": r.upperBound]
        case let .choice(values): return ["type": "string", "enum": values]
        case let .choiceList(values): return ["type": "array", "items": ["enum": values], "uniqueItems": true]
        case .idOrNull: return ["type": ["string", "null"], "format": "uuid"]
        case .shortcuts:
            return ["type": "object",
                    "propertyNames": ["enum": HotKeyAction.allCases.map(\.rawValue)],
                    "additionalProperties": [
                        "type": "object",
                        "required": ["keyCode", "modifiers", "display"],
                        "properties": [
                            "keyCode": ["type": "integer", "minimum": 0, "description": "Carbon virtual key code."],
                            "modifiers": ["type": "integer", "minimum": 0, "description": "Carbon modifier mask: cmdKey 256, shiftKey 512, optionKey 2048, controlKey 4096, added together."],
                            "display": ["type": "string", "description": "How the shortcut is shown, such as ⌃⌥L."],
                        ],
                    ] as [String: Any]]
        case .engines:
            return ["type": "array",
                    "items": [
                        "type": "object",
                        "required": ["name", "kind"],
                        "properties": [
                            "id": ["type": "string", "format": "uuid", "description": "Identifies the engine; customEngineID and appProfiles refer to it."],
                            "name": ["type": "string", "description": "The name shown in Settings."],
                            "kind": ["enum": ["openAICompatible", "anthropic", "deepL", "httpTemplate", "command"],
                                     "description": "What the engine speaks. Other fields (baseURL, model, thinking, extraHeaders, formality, template, command) depend on it."],
                        ],
                    ] as [String: Any]]
        case .appProfiles:
            return ["type": "array",
                    "items": [
                        "type": "object",
                        "required": ["bundleID", "source", "target"],
                        "properties": [
                            "bundleID": ["type": "string", "description": "Bundle identifier of the app."],
                            "appName": ["type": "string", "description": "The app's name, for display."],
                            "source": ["type": "string", "description": "Source language code, or auto."],
                            "target": ["type": "string", "description": "Target language code."],
                            "customEngineID": ["type": ["string", "null"], "format": "uuid", "description": "Engine for this app; null keeps the base choice."],
                            "paragraphReader": ["enum": ParagraphReader.allCases.map(\.rawValue), "description": "Paragraph reader for this app; left out follows the default."],
                        ],
                    ] as [String: Any]]
        }
    }
}

/// The two commands an agent or a script uses; neither starts the app:
///   `Mwoyeo --settings-path`            prints where settings.json is.
///   `Mwoyeo --check-settings [path]`    prints `settings.json:<line>: <message>` per issue, or `ok`; exit 1 when there are issues.
enum SettingsFileCommand {
    static func run(_ args: [String]) -> Never {
        if args.first == "--settings-path" {
            print(SettingsFileStore.defaultURL.path)
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
