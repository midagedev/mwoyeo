import Foundation

/// `off` asks the server not to reason (see `ChatTranslation.requestBody`); `provider` sends nothing extra.
public enum Thinking: String, Codable, Sendable {
    case off, provider
}

public enum EngineConfigError: Error, Equatable, Sendable {
    /// The `kind` is not one this build knows ("This engine needs a newer Mwoyeo").
    case unknownKind(String)
    /// A shared payload carries a field named like a secret; the associated value is its key path.
    case secretField(String)
    case notAnEngineFile
    case malformed(String)
}

public enum EngineKind: Equatable, Sendable {
    case openAICompatible(baseURL: URL, model: String, thinking: Thinking, extraHeaders: [String: String])
    case anthropic(baseURL: URL, model: String, thinking: Thinking)
    case deepL(baseURL: URL, formality: String?)
    case httpTemplate(HTTPTemplate)
    case command(CommandSpec)

    public static let anthropicDefaultBaseURL = URL(string: "https://api.anthropic.com")!

    var tag: String {
        switch self {
        case .openAICompatible: "openAICompatible"
        case .anthropic: "anthropic"
        case .deepL: "deepL"
        case .httpTemplate: "httpTemplate"
        case .command: "command"
        }
    }
}

/// One translation engine the user attached. Secrets are never part of it: the app keeps the key in the Keychain under `id`.
/// Encoding is flat (`id`, `name`, `kind`, then the kind's fields) with sorted keys. Decoding ignores unknown fields,
/// defaults a missing optional field, and throws `EngineConfigError.unknownKind` for a kind it does not know.
public struct EngineConfig: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: EngineKind

    public init(id: UUID = UUID(), name: String, kind: EngineKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    private enum Key: String, CodingKey {
        case id, name, kind, baseURL, model, thinking, extraHeaders, formality, template, command
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        let tag = try c.decode(String.self, forKey: .kind)
        switch tag {
        case "openAICompatible":
            kind = .openAICompatible(
                baseURL: try c.decode(URL.self, forKey: .baseURL),
                model: try c.decodeIfPresent(String.self, forKey: .model) ?? "",
                thinking: (try? c.decodeIfPresent(Thinking.self, forKey: .thinking)) ?? .off,
                extraHeaders: try c.decodeIfPresent([String: String].self, forKey: .extraHeaders) ?? [:])
        case "anthropic":
            kind = .anthropic(
                baseURL: try c.decodeIfPresent(URL.self, forKey: .baseURL) ?? EngineKind.anthropicDefaultBaseURL,
                model: try c.decodeIfPresent(String.self, forKey: .model) ?? "",
                thinking: (try? c.decodeIfPresent(Thinking.self, forKey: .thinking)) ?? .off)
        case "deepL":
            kind = .deepL(baseURL: try c.decode(URL.self, forKey: .baseURL),
                          formality: try c.decodeIfPresent(String.self, forKey: .formality))
        case "httpTemplate":
            kind = .httpTemplate(try c.decode(HTTPTemplate.self, forKey: .template))
        case "command":
            kind = .command(try c.decode(CommandSpec.self, forKey: .command))
        default:
            throw EngineConfigError.unknownKind(tag)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(kind.tag, forKey: .kind)
        switch kind {
        case let .openAICompatible(baseURL, model, thinking, extraHeaders):
            try c.encode(baseURL, forKey: .baseURL)
            try c.encode(model, forKey: .model)
            try c.encode(thinking, forKey: .thinking)
            try c.encode(extraHeaders, forKey: .extraHeaders)
        case let .anthropic(baseURL, model, thinking):
            try c.encode(baseURL, forKey: .baseURL)
            try c.encode(model, forKey: .model)
            try c.encode(thinking, forKey: .thinking)
        case let .deepL(baseURL, formality):
            try c.encode(baseURL, forKey: .baseURL)
            try c.encodeIfPresent(formality, forKey: .formality)
        case let .httpTemplate(t):
            try c.encode(t, forKey: .template)
        case let .command(spec):
            try c.encode(spec, forKey: .command)
        }
    }
}

/// Export and import of one engine as JSON, without its key.
///
/// The file is `{"engine": {…}, "mwoyeoEngine": 1}`, pretty and key-sorted. The `id` is left out, and import assigns a
/// fresh one. Import rejects a field named `apiKey`, `key`, `token` or `authorization` (any case, any depth).
/// One exception: a header of an HTTP template or an OpenAI-compatible engine may be named like a secret as long as its
/// value is the `{{key}}` placeholder, because "Authorization: Bearer {{key}}" is how such an engine says where the key goes.
/// Export applies the same rule on the way out: a literal secret in a header is replaced by `{{key}}` (template) or dropped.
public enum EngineShare {
    public static let version = 1
    static let secretNames: Set<String> = ["apikey", "key", "token", "authorization", "x-api-key"]

    public static func encode(_ c: EngineConfig) -> String {
        var config = c
        switch c.kind {
        case let .openAICompatible(baseURL, model, thinking, headers):
            let kept = headers.filter { !isSecretName($0.key) || $0.value.contains("{{key}}") }
            config.kind = .openAICompatible(baseURL: baseURL, model: model, thinking: thinking, extraHeaders: kept)
        case var .httpTemplate(t):
            for (k, v) in t.headers where isSecretName(k) && !v.contains("{{key}}") { t.headers[k] = "{{key}}" }
            config.kind = .httpTemplate(t)
        default: break
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(config),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return "{}" }
        obj["id"] = nil
        let wrapped: [String: Any] = ["mwoyeoEngine": version, "engine": obj]
        let out = (try? JSONSerialization.data(withJSONObject: wrapped,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: out, as: UTF8.self)
    }

    public static func decode(_ s: String) throws -> EngineConfig {
        guard let root = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else {
            throw EngineConfigError.malformed("not a JSON object")
        }
        guard root["mwoyeoEngine"] is Int, var engine = root["engine"] as? [String: Any] else {
            throw EngineConfigError.notAnEngineFile
        }
        if let path = secretPath(in: engine, path: "engine") { throw EngineConfigError.secretField(path) }
        engine["id"] = UUID().uuidString
        let data = try JSONSerialization.data(withJSONObject: engine)
        return try JSONDecoder().decode(EngineConfig.self, from: data)
    }

    static func isSecretName(_ name: String) -> Bool { secretNames.contains(name.lowercased()) }

    /// The first key path whose last key is named like a secret, or nil.
    private static func secretPath(in value: Any, path: String, inHeaders: Bool = false) -> String? {
        if let obj = value as? [String: Any] {
            for k in obj.keys.sorted() {
                let here = "\(path).\(k)"
                if isSecretName(k) {
                    if inHeaders, let v = obj[k] as? String, v.contains("{{key}}") { continue }
                    return here
                }
                if let p = secretPath(in: obj[k]!, path: here, inHeaders: k == "headers" || k == "extraHeaders") { return p }
            }
        } else if let arr = value as? [Any] {
            for (i, v) in arr.enumerated() {
                if let p = secretPath(in: v, path: "\(path)[\(i)]") { return p }
            }
        }
        return nil
    }
}
