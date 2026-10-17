import Foundation

public enum HTTPTemplateError: Error, Equatable, Sendable {
    /// The template does not validate; one human-readable problem per entry.
    case invalid([String])
    /// A result path segment that did not resolve, e.g. `segment: "translations"`, `reason: "missing key"`.
    case path(segment: String, reason: String)
    case countMismatch(expected: Int, got: Int)
    case malformed(String)
}

/// A user-defined HTTP engine for anything the built-in kinds do not cover (LibreTranslate, DeepLX, Papago, a home server).
///
/// Placeholders, written `{{name}}` in `url`, `headers` and `body`:
/// - `{{text}}` the line (`.perLine` only). In a JSON body it becomes a JSON string; write it with or without
///   surrounding quotes, both give valid JSON. In a form body (a body that does not start with `{` or `[`) and in the
///   URL it is percent-encoded. In a header it is inserted as is.
/// - `{{lines}}` all lines as a JSON array of strings (`.jsonArray`, body only).
/// - `{{source}}`, `{{target}}` the BCP-47 codes as the app has them (`{{source}}` is empty when unknown).
/// - `{{source_upper}}`, `{{target_upper}}` upper-case language codes, DeepL style (`EN`, `KO`, `ZH`).
/// - `{{key}}` the secret the app reads from the Keychain; Core only receives it as an argument.
/// An unknown placeholder is a validation error that names it.
///
/// `resultPath` picks the translations out of the JSON reply. Segments are dot keys and `[n]` indexes; `[*]` maps over
/// an array:
///
///     translatedText                        {"translatedText": "…"}
///     data.translations[0].translatedText   {"data": {"translations": [{"translatedText": "…"}]}}
///     translations[*].text                  {"translations": [{"text": "…"}, {"text": "…"}]}
///     result                                {"result": "…"}   (or an array of strings)
///
/// A path that resolves to something other than a string, or to the wrong number of strings, is a typed error naming
/// the segment that failed.
public struct HTTPTemplate: Codable, Equatable, Sendable {
    public enum Batching: String, Codable, Sendable {
        case perLine, jsonArray
    }

    public var method: String
    public var url: String
    public var headers: [String: String]
    public var body: String
    public var resultPath: String
    public var batching: Batching

    public init(method: String = "POST", url: String, headers: [String: String] = [:], body: String = "",
                resultPath: String, batching: Batching = .perLine) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.resultPath = resultPath
        self.batching = batching
    }

    private enum CodingKeys: String, CodingKey { case method, url, headers, body, resultPath, batching }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decodeIfPresent(String.self, forKey: .method) ?? "POST"
        url = try c.decode(String.self, forKey: .url)
        headers = try c.decodeIfPresent([String: String].self, forKey: .headers) ?? [:]
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        resultPath = try c.decode(String.self, forKey: .resultPath)
        batching = (try? c.decodeIfPresent(Batching.self, forKey: .batching)) ?? .perLine
    }

    /// One HTTP request, ready to send.
    public struct Request: Equatable, Sendable {
        public var method: String
        public var url: String
        public var headers: [String: String]
        public var body: Data?
    }

    static let knownPlaceholders: Set<String> = ["text", "lines", "source", "target", "source_upper", "target_upper", "key"]
    static let methods: Set<String> = ["GET", "POST", "PUT", "PATCH"]
    private static let placeholderPattern = #"\{\{\s*([^{}\s]*)\s*\}\}"#

    // MARK: validation

    /// Human-readable problems; empty when the template is fine.
    public static func validate(_ t: HTTPTemplate) -> [String] {
        var problems: [String] = []
        if !methods.contains(t.method.uppercased()) {
            problems.append("Method \"\(t.method)\" is not one of GET, POST, PUT, PATCH.")
        }
        var fields: [(String, String)] = [("url", t.url)]
        fields += t.headers.sorted(by: { $0.key < $1.key }).map { ("header \($0.key)", $0.value) }
        fields.append(("body", t.body))
        var seen = Set<String>()
        for (field, text) in fields {
            for name in placeholders(in: text) {
                if !knownPlaceholders.contains(name) {
                    if seen.insert("unknown:\(name)").inserted { problems.append("Unknown placeholder {{\(name)}} in \(field).") }
                } else if name == "lines" {
                    if t.batching != .jsonArray, seen.insert("lines-batch").inserted {
                        problems.append("{{lines}} needs batching \"jsonArray\".")
                    }
                    if field != "body", seen.insert("lines-\(field)").inserted {
                        problems.append("{{lines}} works only in the body, not in \(field).")
                    }
                } else if name == "text", t.batching == .jsonArray, seen.insert("text-batch").inserted {
                    problems.append("{{text}} needs batching \"perLine\"; use {{lines}} with \"jsonArray\".")
                }
            }
        }
        let inBody = placeholders(in: t.body)
        if t.batching == .jsonArray, !inBody.contains("lines") {
            problems.append("Batching \"jsonArray\" needs {{lines}} in the body.")
        }
        if t.batching == .perLine, !(inBody + placeholders(in: t.url)).contains("text") {
            problems.append("Batching \"perLine\" needs {{text}} in the url or the body.")
        }
        if let sample = try? render(t, lines: ["a"], source: "en", target: "ko", key: "k") {
            let u = URL(string: sample.url)
            if u == nil || !["http", "https"].contains(u?.scheme?.lowercased() ?? "") || u?.host == nil {
                problems.append("The url is not an http or https address.")
            }
            if let b = sample.body, isJSONBody(t.body),
               (try? JSONSerialization.jsonObject(with: b, options: [.fragmentsAllowed])) == nil {
                problems.append("The body is not valid JSON once the placeholders are filled in.")
            }
        }
        if let e = parsePath(t.resultPath).error { problems.append("resultPath: \(e)") }
        return problems
    }

    static func placeholders(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: placeholderPattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    // MARK: requests

    /// One request per line for `.perLine`, one for the whole batch for `.jsonArray`.
    public static func requests(_ t: HTTPTemplate, lines: [String], source: String?, target: String,
                                key: String?) throws(HTTPTemplateError) -> [Request] {
        let problems = validate(t)
        guard problems.isEmpty else { throw .invalid(problems) }
        switch t.batching {
        case .perLine:
            var out: [Request] = []
            for line in lines { out.append(try render(t, lines: [line], source: source, target: target, key: key)) }
            return out
        case .jsonArray:
            return [try render(t, lines: lines, source: source, target: target, key: key)]
        }
    }

    static func render(_ t: HTTPTemplate, lines: [String], source: String?, target: String,
                       key: String?) throws(HTTPTemplateError) -> Request {
        let values: [String: String] = [
            "text": lines.first ?? "", "source": source ?? "", "target": target,
            "source_upper": source.map(DeepLTranslation.upper) ?? "", "target_upper": DeepLTranslation.upper(target),
            "key": key ?? "",
        ]
        let linesJSON = (try? JSONSerialization.data(withJSONObject: lines, options: [.withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let jsonBody = isJSONBody(t.body)
        guard let re = try? NSRegularExpression(pattern: placeholderPattern) else { throw .malformed("regex") }

        func fill(_ text: String, _ mode: (String, Bool) -> String) -> String {
            let ns = text as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let name = ns.substring(with: m.range(at: 1))
                let end = m.range.location + m.range.length
                let quoted = m.range.location > 0 && ns.character(at: m.range.location - 1) == 0x22
                    && end < ns.length && ns.character(at: end) == 0x22
                out += name == "lines" ? linesJSON : mode(values[name] ?? "", quoted)
                last = end
            }
            return out + ns.substring(from: last)
        }
        let url = fill(t.url) { v, _ in percentEncode(v) }
        var headers: [String: String] = [:]
        for (k, v) in t.headers {
            headers[k] = fill(v) { v, _ in v.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        }
        let body = fill(t.body) { v, quoted in
            guard jsonBody else { return percentEncode(v) }
            let escaped = jsonEscaped(v)
            return quoted ? escaped : "\"\(escaped)\""
        }
        return Request(method: t.method.uppercased(), url: url, headers: headers,
                       body: t.body.isEmpty ? nil : Data(body.utf8))
    }

    static func isJSONBody(_ body: String) -> Bool {
        let s = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.hasPrefix("{") || s.hasPrefix("[")
    }

    /// The inside of a JSON string literal, without the quotes.
    static func jsonEscaped(_ s: String) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes]) else { return s }
        return String(String(decoding: d, as: UTF8.self).dropFirst(2).dropLast(2))
    }

    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: result path

    enum Segment: Equatable {
        case key(String), index(Int), all

        var text: String {
            switch self {
            case let .key(k): k
            case let .index(i): "[\(i)]"
            case .all: "[*]"
            }
        }
    }

    static func parsePath(_ path: String) -> (segments: [Segment], error: String?) {
        var segments: [Segment] = []
        var key = ""
        var chars = Array(path)[...]
        while let ch = chars.popFirst() {
            switch ch {
            case ".":
                if !key.isEmpty { segments.append(.key(key)); key = "" }
            case "[":
                if !key.isEmpty { segments.append(.key(key)); key = "" }
                var inner = ""
                var closed = false
                while let c2 = chars.popFirst() {
                    if c2 == "]" { closed = true; break }
                    inner.append(c2)
                }
                if !closed { return (segments, "missing ] in \"\(path)\"") }
                if inner == "*" { segments.append(.all) }
                else if let n = Int(inner), n >= 0 { segments.append(.index(n)) }
                else { return (segments, "\"[\(inner)]\" is not an index or [*]") }
            default:
                key.append(ch)
            }
        }
        if !key.isEmpty { segments.append(.key(key)) }
        return segments.isEmpty ? (segments, "the path is empty") : (segments, nil)
    }

    /// The translations in a reply, expected to number `count`.
    public static func parseResponse(_ t: HTTPTemplate, data: Data, count: Int) throws(HTTPTemplateError) -> [String] {
        let parsed = parsePath(t.resultPath)
        if let e = parsed.error { throw .invalid(["resultPath: \(e)"]) }
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw .malformed("response is not JSON")
        }
        var current: [Any] = [root]
        var mapped = false
        for seg in parsed.segments {
            var next: [Any] = []
            for value in current {
                switch seg {
                case let .key(k):
                    guard let o = value as? [String: Any] else { throw .path(segment: seg.text, reason: "not an object") }
                    guard let v = o[k] else { throw .path(segment: seg.text, reason: "missing key") }
                    next.append(v)
                case let .index(i):
                    guard let a = value as? [Any] else { throw .path(segment: seg.text, reason: "not an array") }
                    guard i < a.count else { throw .path(segment: seg.text, reason: "index out of range (\(a.count) items)") }
                    next.append(a[i])
                case .all:
                    guard let a = value as? [Any] else { throw .path(segment: seg.text, reason: "not an array") }
                    next.append(contentsOf: a)
                    mapped = true
                }
            }
            current = next
        }
        let last = parsed.segments[parsed.segments.count - 1].text
        var strings: [String] = []
        for v in current {
            if let s = v as? String { strings.append(s) }
            else if !mapped, let a = v as? [String] { strings.append(contentsOf: a) }
            else { throw .path(segment: last, reason: "not a string") }
        }
        guard strings.count == count else { throw .countMismatch(expected: count, got: strings.count) }
        return strings
    }
}
