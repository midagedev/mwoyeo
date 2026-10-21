import Foundation
import MwoyeoCore

/// One step on the way to a value in settings.json: an object key or an array index.
enum FieldStep: Equatable {
    case key(String)
    case index(Int)
}

/// `appProfiles[2].paragraphReader`: the path an issue names, and what `JSONLines` finds the line of.
struct FieldPath: Equatable {
    var steps: [FieldStep] = []

    func appending(_ step: FieldStep) -> FieldPath { FieldPath(steps: steps + [step]) }

    /// A key written as `["…"]` when it holds anything but letters, digits, `_`, `-` and `$`, so the text is unambiguous.
    var text: String {
        var out = ""
        for step in steps {
            switch step {
            case let .index(i):
                out += "[\(i)]"
            case let .key(k):
                if !k.isEmpty, k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "$" }) {
                    out += out.isEmpty ? k : ".\(k)"
                } else {
                    out += "[\"\(k.replacingOccurrences(of: "\"", with: "\\\""))\"]"
                }
            }
        }
        return out
    }
}

/// What a wrong value costs. A top-level setting keeps its current value; a field inside an item is ignored, as if it had
/// not been written; a row of a list of independent rows is dropped. The words are the end of the issue's message.
enum FieldFallout {
    case keep, ignore, drop

    var phrase: String {
        switch self {
        case .keep: "keeping the current value"
        case .ignore: "ignored"
        case .drop: "dropped"
        }
    }
}

/// A problem found in a value, at `path`. The message is complete, path first.
struct FieldProblem: Equatable {
    var path: FieldPath
    var message: String
}

/// The type and limits of a value in settings.json. One tree of these per setting drives both the schema an editor or an agent
/// reads (`schema()`) and the check of the file (`read`), so the two cannot drift.
indirect enum FieldKind {
    case string
    /// A string with limits; the length counts Unicode scalars, as JSON Schema's maxLength does.
    case text(maxLength: Int? = nil, minLength: Int = 0)
    case bool
    case number(ClosedRange<Double>)
    case integer(ClosedRange<Int>)
    /// One of these raw values.
    case choice([String])
    /// A UUID string.
    case uuid
    /// A UUID string, or null.
    case idOrNull
    /// What a profile is called in the file (design §5.1): 1 to 255 letters, digits, `.`, `-` and `_`, and never `all` (All apps' own id).
    case identifier
    /// An engine of a profile (design §5.1): an engine's id, `apple` (Apple's own translation), or null (follow All apps').
    case engineRef
    /// An http or https address.
    case url
    /// An array. `dropsBad`: its items are independent rows, so a bad one is reported and dropped and the rest apply;
    /// otherwise one bad item fails the list. Items past `maxItems` are reported and dropped.
    /// `uniqueBy` names a property of the items that no two may share: a later item with a value already taken is reported and dropped.
    case list(FieldKind, maxItems: Int? = nil, unique: Bool = false, dropsBad: Bool = false, uniqueBy: String? = nil)
    /// An object with these properties and no others. `needsOneOf` lists properties of which at least one must be there (a condition with
    /// neither `app` nor `titleContains` is no condition).
    case object([FieldSpec], needsOneOf: [String] = [])
    /// An object whose `tag` property picks which of `variants` it is: its other properties are `common` plus that variant's.
    case tagged(tag: String, tagDoc: String, common: [FieldSpec], variants: [FieldVariant])
    /// An object with any keys (or only `keys`, named `keyNoun`) whose values are all of one kind.
    case map(FieldKind, keys: [String]? = nil, keyNoun: String = "key")

    /// A list of these raw values, each once; a value not among them is dropped and the rest applies.
    static func choiceList(_ values: [String]) -> FieldKind { .list(.choice(values), unique: true, dropsBad: true) }
}

/// One property of an object: its name, kind and documentation.
struct FieldSpec {
    let name: String
    let kind: FieldKind
    let doc: String
    var required: Bool
    /// A realistic value, shown by editors (`examples` in the schema); it must pass the check.
    var example: Any?
    var defaultValue: Any?

    init(_ name: String, _ kind: FieldKind, _ doc: String, required: Bool = false, example: Any? = nil, default defaultValue: Any? = nil) {
        self.name = name
        self.kind = kind
        self.doc = doc
        self.required = required
        self.example = example
        self.defaultValue = defaultValue
    }
}

/// One shape of a `tagged` object: the tag value that selects it and the properties it takes besides the common ones.
struct FieldVariant {
    let tag: String
    let fields: [FieldSpec]
}

// MARK: reading a value against its kind

extension FieldKind {
    /// What is wrong with `value` as this scalar kind, or nil. The words of the top-level settings, kept as they were.
    func scalarProblem(with value: Any) -> String? {
        switch self {
        case .string:
            return value is String ? nil : "expected a string, got \(SettingSpec.name(of: value))"
        case let .text(maxLength, minLength):
            guard let s = value as? String else { return "expected a string, got \(SettingSpec.name(of: value))" }
            let n = s.unicodeScalars.count
            if let maxLength, n > maxLength { return "\(n) characters; the limit is \(maxLength)" }
            if n < minLength { return minLength == 1 ? "must not be empty" : "\(n) characters; at least \(minLength) needed" }
            return nil
        case .bool:
            return SettingSpec.isBool(value) ? nil : "expected true or false, got \(SettingSpec.name(of: value))"
        case let .number(range):
            guard let n = SettingSpec.number(value) else { return "expected a number, got \(SettingSpec.name(of: value))" }
            return range.contains(n) ? nil : "\(SettingSpec.shown(n)) is out of range \(SettingSpec.shown(range.lowerBound)) to \(SettingSpec.shown(range.upperBound))"
        case let .integer(range):
            guard let n = SettingSpec.number(value) else { return "expected a whole number, got \(SettingSpec.name(of: value))" }
            guard n == n.rounded(), abs(n) < 1e15 else { return "expected a whole number, got \(SettingSpec.shown(n))" }
            return range.contains(Int(n)) ? nil : "\(Int(n)) is out of range \(range.lowerBound) to \(range.upperBound)"
        case let .choice(allowed):
            guard let s = value as? String else { return "expected one of \(allowed.joined(separator: ", ")), got \(SettingSpec.name(of: value))" }
            return allowed.contains(s) ? nil : "\"\(s)\" is not allowed; use one of \(allowed.joined(separator: ", "))"
        case .uuid:
            guard let s = value as? String else { return "expected an id (a UUID string), got \(SettingSpec.name(of: value))" }
            return Self.isUUID(s) ? nil : "\"\(s)\" is not an id; expected a UUID such as \(Self.exampleUUID)"
        case .idOrNull:
            if value is NSNull { return nil }
            if let s = value as? String, Self.isUUID(s) { return nil }
            return "expected an engine id from engines, or null"
        case .identifier:
            guard let s = value as? String else { return "expected an id, got \(SettingSpec.name(of: value))" }
            if s == AppProfile.allAppsID { return "\"all\" is the id of All apps; a profile needs another" }
            return AppProfile.isValidID(s) ? nil : "\"\(s)\" is not an id; use 1 to 255 letters, digits, dots, hyphens or underscores"
        case .engineRef:
            if value is NSNull { return nil }
            if let s = value as? String, s == "apple" || Self.isUUID(s) { return nil }
            return "expected an engine id from engines, \"apple\", or null"
        case .url:
            guard let s = value as? String else { return "expected an http or https address, got \(SettingSpec.name(of: value))" }
            return Self.isHTTPAddress(s) ? nil : "\"\(s)\" is not an http or https address such as http://localhost:8765/v1"
        case .list, .object, .tagged, .map:
            return nil
        }
    }

    static let exampleUUID = "7B3F1C2E-5A4D-4E8B-9C21-3D6F0A1B2C3D"
    /// What the schema's `pattern` says for a UUID (so a validator that ignores `format` still checks it).
    static let uuidPattern = "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
    /// And for an engine's address: a scheme and a host.
    static let httpAddressPattern = "^[Hh][Tt][Tt][Pp][Ss]?://[^/\\s?#]+\\S*$"

    private static func isUUID(_ s: String) -> Bool { s.wholeMatch(of: /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/) != nil }

    private static func isHTTPAddress(_ s: String) -> Bool {
        guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        return u.host?.isEmpty == false
    }

    /// `value` as this kind with the bad parts left out, or nil when it cannot stand. What is wrong goes to `problems`;
    /// `fallout` is what a problem with this very value costs (see `FieldFallout`).
    func read(_ value: Any, at path: FieldPath, fallout: FieldFallout, problems: inout [FieldProblem]) -> Any? {
        func fail(_ why: String, at place: FieldPath? = nil, cost: FieldFallout? = nil) -> Any? {
            let here = place ?? path
            problems.append(FieldProblem(path: here, message: "\(here.text): \(why); \((cost ?? fallout).phrase)"))
            return nil
        }
        switch self {
        case let .list(element, maxItems, unique, dropsBad, uniqueBy):
            guard let items = value as? [Any] else { return fail("expected \(listNoun(element)), got \(SettingSpec.name(of: value))") }
            var kept: [Any] = []
            var taken: [String: Int] = [:]
            var failed = false
            for (i, item) in items.prefix(maxItems ?? items.count).enumerated() {
                let child = path.appending(.index(i))
                guard let ok = element.read(item, at: child, fallout: dropsBad ? .drop : fallout, problems: &problems) else {
                    if !dropsBad { failed = true }
                    continue
                }
                if unique, kept.contains(where: { ($0 as? NSObject)?.isEqual(ok as? NSObject) == true }) {
                    let shown = (ok as? String).map { "\"\($0)\"" } ?? "this value"
                    _ = fail("\(shown) is listed twice", at: child, cost: .drop)
                    continue
                }
                if let uniqueBy, let key = (ok as? [String: Any])?[uniqueBy] as? String {
                    if let first = taken[key] {
                        _ = fail("\(uniqueBy) \"\(key)\" is already used by item \(first)", at: child.appending(.key(uniqueBy)), cost: .drop)
                        continue
                    }
                    taken[key] = i
                }
                kept.append(ok)
            }
            if let maxItems, items.count > maxItems {
                problems.append(FieldProblem(path: path, message: "\(path.text): \(items.count) items; the limit is \(maxItems)" + (failed ? "" : "; the first \(maxItems) apply")))
            }
            return failed ? nil : kept

        case let .object(fields, needsOneOf):
            guard let object = value as? [String: Any] else { return fail("expected an object, got \(SettingSpec.name(of: value))") }
            let read = Self.readFields(object, fields: fields, foreign: [:], tagged: nil, at: path, fallout: fallout, problems: &problems)
            if let read, !needsOneOf.isEmpty, !needsOneOf.contains(where: { read[$0] != nil }) {
                return fail("needs \(needsOneOf.joined(separator: " or "))")
            }
            return read

        case let .tagged(tag, tagDoc, common, variants):
            guard let object = value as? [String: Any] else { return fail("expected an object, got \(SettingSpec.name(of: value))") }
            guard let tagValue = object[tag] else { return fail("missing \"\(tag)\"") }
            guard let name = tagValue as? String, let variant = variants.first(where: { $0.tag == name }) else {
                return FieldKind.choice(variants.map(\.tag)).read(tagValue, at: path.appending(.key(tag)), fallout: fallout, problems: &problems)
            }
            var foreign: [String: [String]] = [:]
            let own = Set(variant.fields.map(\.name))
            for other in variants where other.tag != name {
                for f in other.fields where !own.contains(f.name) { foreign[f.name, default: []].append(other.tag) }
            }
            let tagField = FieldSpec(tag, .choice(variants.map(\.tag)), tagDoc, required: true)
            return Self.readFields(object, fields: [tagField] + common + variant.fields, foreign: foreign, tagged: (tag, name),
                                   at: path, fallout: fallout, problems: &problems)

        case let .map(valueKind, keys, noun):
            guard let object = value as? [String: Any] else { return fail("expected an object, got \(SettingSpec.name(of: value))") }
            var result: [String: Any] = [:]
            var failed = false
            for (key, entry) in object.sorted(by: { $0.key < $1.key }) {
                let child = path.appending(.key(key))
                if let keys, !keys.contains(key) {
                    let hint = SettingsFileCheck.closest(to: key, in: keys).map { " (did you mean \($0)?)" } ?? ""
                    _ = fail("unknown \(noun) \"\(key)\"\(hint); use \(keys.joined(separator: ", "))", at: child)
                    failed = true
                } else if let ok = valueKind.read(entry, at: child, fallout: fallout, problems: &problems) {
                    result[key] = ok
                } else {
                    failed = true
                }
            }
            return failed ? nil : result

        default:
            if let why = scalarProblem(with: value) { return fail(why) }
            return value
        }
    }

    /// The properties of one object. A key that is not a property is reported and left out; a bad optional property is
    /// reported and left out (the item still applies); a bad or missing required one fails the object.
    private static func readFields(_ object: [String: Any], fields: [FieldSpec], foreign: [String: [String]], tagged: (tag: String, name: String)?,
                                   at path: FieldPath, fallout: FieldFallout, problems: inout [FieldProblem]) -> [String: Any]? {
        let known = Dictionary(fields.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var result: [String: Any] = [:]
        var failed = false
        for (key, entry) in object.sorted(by: { $0.key < $1.key }) {
            let child = path.appending(.key(key))
            if let field = known[key] {
                if let ok = field.kind.read(entry, at: child, fallout: field.required ? fallout : .ignore, problems: &problems) {
                    result[key] = ok
                } else if field.required {
                    failed = true
                }
            } else if let owners = foreign[key], let tagged {
                problems.append(FieldProblem(path: child, message: "\(child.text): used by \(tagged.tag) \(owners.joined(separator: " or ")), not by \(tagged.tag) \(tagged.name); ignored"))
            } else {
                let hint = SettingsFileCheck.closest(to: key, in: Array(known.keys.sorted()) + foreign.keys.sorted()).map { " (did you mean \($0)?)" } ?? ""
                problems.append(FieldProblem(path: child, message: "unknown key \(child.text)\(hint)"))
            }
        }
        for field in fields where field.required && object[field.name] == nil {
            problems.append(FieldProblem(path: path, message: "\(path.text): missing \"\(field.name)\"; \(fallout.phrase)"))
            failed = true
        }
        return failed ? nil : result
    }

    /// Every `FieldSpec` in the tree below this kind, depth first (for checks that walk the whole tree).
    var fields: [FieldSpec] {
        switch self {
        case let .list(element, _, _, _, _): element.fields
        case let .object(fields, _): fields.flatMap { [$0] + $0.kind.fields }
        case let .tagged(_, _, common, variants): (common + variants.flatMap(\.fields)).flatMap { [$0] + $0.kind.fields }
        case let .map(value, _, _): value.fields
        default: []
        }
    }

    private func listNoun(_ element: FieldKind) -> String {
        switch element {
        case let .choice(allowed): "a list of \(allowed.joined(separator: ", "))"
        case .string, .text: "a list of strings"
        default: "an array"
        }
    }
}

// MARK: the schema

extension FieldSpec {
    /// The property's schema: its kind's, plus description, default and example.
    func schema() -> [String: Any] {
        var s = kind.schema()
        s["description"] = doc
        if let defaultValue { s["default"] = defaultValue }
        if let example { s["examples"] = [example] }
        return s
    }
}

extension FieldKind {
    /// JSON Schema (2020-12) of this kind: `additionalProperties: false` on objects, `enum`, `minimum`/`maximum`,
    /// `maxLength`/`maxItems` and `format: uuid` wherever the check enforces them.
    func schema() -> [String: Any] {
        switch self {
        case .string:
            return ["type": "string"]
        case let .text(maxLength, minLength):
            var s: [String: Any] = ["type": "string"]
            if let maxLength { s["maxLength"] = maxLength }
            if minLength > 0 { s["minLength"] = minLength }
            return s
        case .bool:
            return ["type": "boolean"]
        case let .number(r):
            return ["type": "number", "minimum": r.lowerBound, "maximum": r.upperBound]
        case let .integer(r):
            return ["type": "integer", "minimum": r.lowerBound, "maximum": r.upperBound]
        case let .choice(values):
            return ["type": "string", "enum": values]
        case .uuid:
            return ["type": "string", "format": "uuid", "pattern": Self.uuidPattern]
        case .idOrNull:
            return ["type": ["string", "null"], "format": "uuid", "pattern": Self.uuidPattern]
        case .identifier:
            return ["type": "string", "minLength": 1, "maxLength": 255, "pattern": "^(?!all$)[\\p{L}\\p{N}._-]+$"]
        case .engineRef:
            return ["type": ["string", "null"], "pattern": "^(apple|\(Self.uuidPattern.dropFirst().dropLast()))$"]
        case .url:
            return ["type": "string", "format": "uri", "pattern": Self.httpAddressPattern]
        case let .list(element, maxItems, unique, _, _):
            var s: [String: Any] = ["type": "array", "items": element.schema()]
            if let maxItems { s["maxItems"] = maxItems }
            if unique { s["uniqueItems"] = true }
            return s
        case let .object(fields, needsOneOf):
            var s = Self.objectSchema(fields)
            if !needsOneOf.isEmpty { s["anyOf"] = needsOneOf.map { ["required": [$0]] } }
            return s
        case let .tagged(tag, tagDoc, common, variants):
            // Only the tag and the common properties are required everywhere; a variant's own required ones are in its `then`.
            let head = common + [FieldSpec(tag, .choice(variants.map(\.tag)), tagDoc, required: true)]
            var all = head
            for v in variants {
                for f in v.fields where !all.contains(where: { $0.name == f.name }) {
                    var optional = f
                    optional.required = false
                    all.append(optional)
                }
            }
            var s = Self.objectSchema(all)
            s["allOf"] = variants.map { v -> [String: Any] in
                var then: [String: Any] = [:]
                let required = v.fields.filter(\.required).map(\.name)
                if !required.isEmpty { then["required"] = required }
                let unused = all.map(\.name).filter { n in !v.fields.contains { $0.name == n } && !head.contains { $0.name == n } }
                if !unused.isEmpty { then["properties"] = Dictionary(uniqueKeysWithValues: unused.map { ($0, false as Any) }) }
                return ["if": ["properties": [tag: ["const": v.tag]], "required": [tag]] as [String: Any], "then": then]
            }
            return s
        case let .map(valueKind, keys, _):
            var s: [String: Any] = ["type": "object", "additionalProperties": valueKind.schema()]
            if let keys { s["propertyNames"] = ["enum": keys] }
            return s
        }
    }

    private static func objectSchema(_ fields: [FieldSpec]) -> [String: Any] {
        var s: [String: Any] = ["type": "object", "additionalProperties": false,
                                "properties": Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.schema()) })]
        let required = fields.filter(\.required).map(\.name)
        if !required.isEmpty { s["required"] = required }
        return s
    }
}

// MARK: lines of values

/// Where each value is written in the text of settings.json, found by one pass over it. The file has already parsed as JSON,
/// so this only follows its shape: an object member is at the line of its key, an array element at the line it starts on.
enum JSONLines {
    struct Index {
        fileprivate var lines: [String: Int] = [:]
        /// Lines of a comma before a closing `}` or `]`: Foundation reads it, strict JSON (and every other tool) does not.
        var trailingCommas: [Int] = []

        /// The line of `path`, or of the nearest enclosing value the file has.
        func line(of path: FieldPath) -> Int? {
            var p = path
            while true {
                if let l = lines[p.text] { return l }
                if p.steps.isEmpty { return nil }
                p.steps.removeLast()
            }
        }
    }

    static func index(_ text: String) -> Index {
        var scan = Scan(bytes: Array(text.utf8))
        scan.value(FieldPath())
        return Index(lines: scan.lines, trailingCommas: scan.trailingCommas)
    }

    private struct Scan {
        let bytes: [UInt8]
        var i = 0
        var line = 1
        var lines: [String: Int] = [:]
        var trailingCommas: [Int] = []

        private func at(_ c: Character) -> Bool { i < bytes.count && bytes[i] == c.asciiValue }

        private mutating func skipSpace() {
            while i < bytes.count {
                switch bytes[i] {
                case 10: line += 1; i += 1
                case 9, 13, 32: i += 1
                default: return
                }
            }
        }

        private mutating func comma() {
            let commaLine = line
            i += 1
            skipSpace()
            if at("}") || at("]") { trailingCommas.append(commaLine) }
        }

        mutating func value(_ path: FieldPath) {
            skipSpace()
            if at("{") { object(path) } else if at("[") { array(path) } else if at("\"") { _ = string() } else {
                while i < bytes.count, ![44, 93, 125, 10, 13, 9, 32].contains(bytes[i]) { i += 1 }
            }
        }

        private mutating func object(_ path: FieldPath) {
            i += 1
            while true {
                skipSpace()
                if at("}") { i += 1; return }
                if at(",") { comma(); continue }
                guard at("\"") else { return }
                let keyLine = line
                let key = string()
                skipSpace()
                guard at(":") else { return }
                i += 1
                let child = path.appending(.key(key))
                lines[child.text] = keyLine
                value(child)
            }
        }

        private mutating func array(_ path: FieldPath) {
            i += 1
            var n = 0
            while true {
                skipSpace()
                if at("]") { i += 1; return }
                if at(",") { comma(); continue }
                guard i < bytes.count else { return }
                let child = path.appending(.index(n))
                n += 1
                lines[child.text] = line
                value(child)
            }
        }

        /// The string at `i` (on its opening quote), decoded by Foundation so escapes come out right.
        private mutating func string() -> String {
            let start = i
            i += 1
            while i < bytes.count, bytes[i] != 34 { i += bytes[i] == 92 ? 2 : 1 }
            i = min(i + 1, bytes.count)
            let raw = Data(bytes[start..<i])
            return (try? JSONSerialization.jsonObject(with: raw, options: .fragmentsAllowed)) as? String ?? String(decoding: raw, as: UTF8.self)
        }
    }
}
