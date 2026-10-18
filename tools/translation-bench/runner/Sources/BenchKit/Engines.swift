import Foundation
import MwoyeoCore

public struct Usage: Codable, Sendable, Equatable {
    /// Prompt tokens, cached and cache-write tokens included.
    public var input: Int?
    public var output: Int?
    public var cached: Int?
    public var cacheWrite: Int?
    /// DeepL bills characters.
    public var chars: Int?
    /// The numbers are the bench's own estimate (the oracle engine, Apple Foundation Models).
    public var estimated: Bool?

    enum CodingKeys: String, CodingKey { case input = "in", output = "out", cached, cacheWrite = "cache_write", chars, estimated }

    public init(input: Int? = nil, output: Int? = nil, cached: Int? = nil, cacheWrite: Int? = nil, chars: Int? = nil, estimated: Bool? = nil) {
        self.input = input
        self.output = output
        self.cached = cached
        self.cacheWrite = cacheWrite
        self.chars = chars
        self.estimated = estimated
    }

    /// `usage` of an OpenAI-style reply. `prompt_tokens_details.cached_tokens` (OpenAI, Groq, OpenRouter, newer
    /// llama.cpp), else llama-server's `timings.cache_n`.
    public static func openAI(_ root: [String: Any]) -> Usage? {
        guard let u = root["usage"] as? [String: Any] else { return nil }
        let details = u["prompt_tokens_details"] as? [String: Any]
        let timings = root["timings"] as? [String: Any]
        return Usage(input: u["prompt_tokens"] as? Int, output: u["completion_tokens"] as? Int,
                     cached: details?["cached_tokens"] as? Int ?? timings?["cache_n"] as? Int,
                     cacheWrite: details?["cache_write_tokens"] as? Int)
    }

    /// Anthropic's `input_tokens` counts only what comes after the last breakpoint; the total adds both cache fields.
    public static func anthropic(_ root: [String: Any]) -> Usage? {
        guard let u = root["usage"] as? [String: Any] else { return nil }
        let fresh = u["input_tokens"] as? Int ?? 0
        let read = u["cache_read_input_tokens"] as? Int ?? 0
        let write = u["cache_creation_input_tokens"] as? Int ?? 0
        return Usage(input: fresh + read + write, output: u["output_tokens"] as? Int, cached: read, cacheWrite: write)
    }
}

public struct Wire: Sendable, Equatable {
    public var system: String
    public var user: String
}

public struct EngineRequest: Sendable {
    public var items: [BenchLine]
    public var source: String
    public var target: String
    public var prompt: Prompt
    public var sequenceID: String
}

public struct EngineReply: Sendable {
    /// One translation per item; nil when the attempt failed (HTTP, parse, count).
    public var translations: [String]?
    /// The model's text (the content of the first choice, the joined text blocks).
    public var text: String
    public var usage: Usage?
    public var latencyMs: Int
    public var retries: Int
    public var error: String?
    public var wire: Wire
}

public protocol BenchEngine: Sendable {
    var label: String { get }
    var model: String { get }
    var kindName: String { get }
    var price: String? { get }
    /// A reason this engine cannot run (a missing key), nil when it can.
    func preflight() -> String?
    func translate(_ request: EngineRequest) async -> EngineReply
}

/// An engine config file: Mwoyeo's flat shape (`kind`, `baseURL`, `model`, `thinking`, `formality`) plus `keyEnv` (the
/// environment variable that holds the key; the key itself never appears in a file), `price` (a key of prices.json),
/// `cache` (`anthropic-auto` or `openai-key`) and `timeoutSeconds`. Extra kinds: `oracle` (replays the `ref` lines,
/// for tests and size accounting) and `appleFoundationModels`.
public struct EngineFile: Decodable, Sendable {
    public var name: String
    public var kind: String
    public var baseURL: URL?
    public var model: String?
    public var thinking: Thinking?
    public var formality: String?
    public var keyEnv: String?
    public var price: String?
    public var cache: String?
    public var extraHeaders: [String: String]?
    public var timeoutSeconds: Double?

    public static func load(_ url: URL) throws -> EngineFile {
        try JSONDecoder().decode(EngineFile.self, from: Data(contentsOf: url))
    }
}

public enum EngineFactory {
    public static func make(_ file: EngineFile, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> any BenchEngine {
        let key = file.keyEnv.flatMap { environment[$0] }.flatMap { $0.isEmpty ? nil : $0 }
        switch file.kind {
        case "openAICompatible":
            guard let base = file.baseURL else { throw EngineSetupError.missing("baseURL") }
            return ChatEngine(file: file, baseURL: base, key: key)
        case "anthropic":
            return AnthropicEngine(file: file, baseURL: file.baseURL ?? EngineKind.anthropicDefaultBaseURL, key: key)
        case "deepL":
            guard let base = file.baseURL else { throw EngineSetupError.missing("baseURL") }
            return DeepLEngine(file: file, baseURL: base, key: key)
        case "oracle":
            return OracleEngine(name: file.name)
        case "appleFoundationModels":
            #if canImport(FoundationModels)
            return AppleFMEngine(name: file.name)
            #else
            throw EngineSetupError.unsupported("this build has no FoundationModels")
            #endif
        default:
            throw EngineSetupError.unsupported("engine kind \(file.kind)")
        }
    }
}

public enum EngineSetupError: Error, CustomStringConvertible {
    case missing(String)
    case unsupported(String)
    public var description: String {
        switch self {
        case let .missing(f): "engine file has no \(f)"
        case let .unsupported(s): "unsupported: \(s)"
        }
    }
}

// MARK: - shared plumbing

enum Wiring {
    static func encode(_ obj: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
    }

    /// Today's system prompt with the layout's additions; the user message the layout chose, else today's.
    static func compose(system: String, user: String, prompt: Prompt) -> Wire {
        var s = system
        if prompt.askForTerms {
            if s.contains(ReferenceLayout.replyFormat) {
                s = s.replacingOccurrences(of: ReferenceLayout.replyFormat, with: ReferenceLayout.replyFormatWithTerms)
            } else {
                s += "\n" + ReferenceLayout.replyFormatWithTerms
            }
        }
        if !prompt.systemAddition.isEmpty { s += "\n" + prompt.systemAddition }
        return Wire(system: s, user: prompt.user ?? user)
    }

    static func describe(_ error: Error) -> String {
        guard let e = error as? ChatTranslationError else { return String(describing: error) }
        switch e {
        case let .server(m): return "server: \(m)"
        case let .countMismatch(expected, got): return "count mismatch: expected \(expected), got \(got)"
        case let .malformed(m): return "malformed: \(m)"
        }
    }

    static func errorMessage(_ data: Data) -> String {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = root["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = root["error"] as? String { return m }
            if let m = root["message"] as? String { return m }
        }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

struct HTTPReply {
    var status: Int
    var data: Data
    var ms: Int
    var retries: Int
    var error: String?
}

enum HTTP {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.timeoutIntervalForRequest = 300
        return URLSession(configuration: c)
    }()

    /// One POST. 429, 5xx and transport errors are retried up to three times with a pause (Retry-After, else 2, 4 s);
    /// the latency is that of the last try alone, the retries are counted.
    static func post(_ url: URL, headers: [String: String], body: Data, scrub: (String) -> String) async -> HTTPReply {
        var retries = 0
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            let clock = ContinuousClock()
            let start = clock.now
            do {
                let (data, response) = try await session.data(for: request)
                let ms = Int((clock.now - start) / .milliseconds(1))
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (status == 429 || status >= 500) && retries < 3 {
                    let wait = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? Double(2 << retries)
                    retries += 1
                    try? await Task.sleep(for: .seconds(min(wait, 30)))
                    continue
                }
                return HTTPReply(status: status, data: data, ms: ms, retries: retries, error: nil)
            } catch {
                let ms = Int((clock.now - start) / .milliseconds(1))
                if retries < 3 && (error as? URLError)?.code != .cancelled {
                    retries += 1
                    try? await Task.sleep(for: .seconds(Double(2 << (retries - 1))))
                    continue
                }
                return HTTPReply(status: 0, data: Data(), ms: ms, retries: retries, error: scrub("network: \((error as? URLError)?.code.rawValue ?? 0)"))
            }
        }
    }
}

/// Rejected fields remembered per engine, as the app's `EngineClient` does (a 400 naming a field we sent: retry once without it).
final class Rejections: @unchecked Sendable {
    private let lock = NSLock()
    private var fields: Set<String> = []
    var all: Set<String> { lock.lock(); defer { lock.unlock() }; return fields }
    func add(_ f: String) { lock.lock(); fields.insert(f); lock.unlock() }
}

func scrubber(_ key: String?) -> (String) -> String {
    guard let key, !key.isEmpty else { return { $0 } }
    return { $0.replacingOccurrences(of: key, with: "***") }
}

// MARK: - OpenAI-compatible chat

public final class ChatEngine: BenchEngine, @unchecked Sendable {
    let file: EngineFile
    let baseURL: URL
    let key: String?
    let rejections = Rejections()
    public var label: String { file.name }
    public var model: String { file.model ?? "" }
    public var kindName: String { file.kind }
    public var price: String? { file.price }

    init(file: EngineFile, baseURL: URL, key: String?) {
        self.file = file
        self.baseURL = baseURL
        self.key = key
    }

    public func preflight() -> String? {
        if key == nil && !ChatTranslation.isOnThisMac(baseURL) { return "set $\(file.keyEnv ?? "KEY") (keyEnv in the engine file) for \(baseURL.host ?? "the host")" }
        return nil
    }

    public func translate(_ r: EngineRequest) async -> EngineReply {
        let thinking = file.thinking ?? .off
        var body = ChatTranslation.requestBody(lines: r.items.map(\.text), source: coreLanguage(r.source), target: coreLanguage(r.target),
                                               glossary: [], model: model, baseURL: baseURL, thinking: thinking)
        var obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let messages = obj["messages"] as? [[String: Any]] ?? []
        let baseSystem = messages.first?["content"] as? String ?? ""
        let baseUser = messages.last?["content"] as? String ?? ""
        let wire = Wiring.compose(system: baseSystem, user: baseUser, prompt: r.prompt)
        if let override = r.prompt.bodyOverride {
            body = override
        } else if r.prompt != Prompt() {
            obj["messages"] = [["role": "system", "content": wire.system], ["role": "user", "content": wire.user]]
            body = Wiring.encode(obj)
        }
        if file.cache == "openai-key", r.prompt.bodyOverride == nil, var o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            o["prompt_cache_key"] = r.sequenceID
            body = Wiring.encode(o)
        }
        body = ChatTranslation.withoutFields(body, rejections.all)

        var headers = ["Content-Type": "application/json"]
        if let key { headers["Authorization"] = "Bearer \(key)" }
        for (k, v) in file.extraHeaders ?? [:] { headers[k] = v.replacingOccurrences(of: "{{key}}", with: key ?? "") }
        let scrub = scrubber(key)
        let url = URL(string: baseURL.absoluteString.trimmingSuffix("/") + "/chat/completions")!

        var reply = await HTTP.post(url, headers: headers, body: body, scrub: scrub)
        if reply.status == 400, let fix = ChatTranslation.withoutRejectedField(body, errorBody: reply.data) {
            body = fix.body
            let again = await HTTP.post(url, headers: headers, body: body, scrub: scrub)
            rejections.add(fix.field)
            reply = HTTPReply(status: again.status, data: again.data, ms: again.ms, retries: reply.retries + again.retries, error: again.error)
        }
        return Self.finish(reply, count: r.items.count, wire: wire, scrub: scrub)
    }

    static func finish(_ reply: HTTPReply, count: Int, wire: Wire, scrub: (String) -> String) -> EngineReply {
        var out = EngineReply(translations: nil, text: "", usage: nil, latencyMs: reply.ms, retries: reply.retries, error: reply.error, wire: wire)
        if let e = reply.error { out.error = e; return out }
        let root = (try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any]) ?? [:]
        out.usage = Usage.openAI(root)
        if !(200..<300).contains(reply.status) {
            out.error = scrub("HTTP \(reply.status): " + Wiring.errorMessage(reply.data))
            return out
        }
        out.text = scrub(((root["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? "")
        do { out.translations = try ChatTranslation.parseTranslations(reply.data, count: count) } catch { out.error = scrub(Wiring.describe(error)) }
        return out
    }
}

extension String {
    func trimmingSuffix(_ s: String) -> String {
        var t = self
        while t.hasSuffix(s) { t.removeLast(s.count) }
        return t
    }
}

// MARK: - Anthropic

public final class AnthropicEngine: BenchEngine, @unchecked Sendable {
    let file: EngineFile
    let baseURL: URL
    let key: String?
    public var label: String { file.name }
    public var model: String { file.model ?? "" }
    public var kindName: String { file.kind }
    public var price: String? { file.price }

    init(file: EngineFile, baseURL: URL, key: String?) {
        self.file = file
        self.baseURL = baseURL
        self.key = key
    }

    public func preflight() -> String? { key == nil ? "set $\(file.keyEnv ?? "KEY") (keyEnv in the engine file)" : nil }

    public func translate(_ r: EngineRequest) async -> EngineReply {
        var body = AnthropicTranslation.requestBody(lines: r.items.map(\.text), source: coreLanguage(r.source), target: coreLanguage(r.target),
                                                    glossary: [], model: model, thinking: file.thinking ?? .off)
        var obj = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let baseSystem = obj["system"] as? String ?? ""
        let baseUser = ((obj["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
        let wire = Wiring.compose(system: baseSystem, user: baseUser, prompt: r.prompt)
        if let override = r.prompt.bodyOverride {
            body = override
        } else {
            if r.prompt != Prompt() {
                obj["system"] = wire.system
                obj["messages"] = [["role": "user", "content": wire.user]]
                if r.prompt.askForTerms { obj["max_tokens"] = (obj["max_tokens"] as? Int ?? 1024) + 256 }
            }
            if file.cache == "anthropic-auto" { obj["cache_control"] = ["type": "ephemeral"] }
            body = Wiring.encode(obj)
        }
        var headers = AnthropicTranslation.headers()
        headers["x-api-key"] = key ?? ""
        let scrub = scrubber(key)
        let url = URL(string: baseURL.absoluteString.trimmingSuffix("/") + AnthropicTranslation.path)!
        let reply = await HTTP.post(url, headers: headers, body: body, scrub: scrub)

        var out = EngineReply(translations: nil, text: "", usage: nil, latencyMs: reply.ms, retries: reply.retries, error: reply.error, wire: wire)
        if reply.error != nil { return out }
        let root = (try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any]) ?? [:]
        out.usage = Usage.anthropic(root)
        if !(200..<300).contains(reply.status) {
            out.error = scrub("HTTP \(reply.status): " + Wiring.errorMessage(reply.data))
            return out
        }
        out.text = scrub(((root["content"] as? [[String: Any]]) ?? []).compactMap { $0["text"] as? String }.joined())
        do { out.translations = try AnthropicTranslation.parseTranslations(reply.data, count: r.items.count) } catch { out.error = scrub(Wiring.describe(error)) }
        return out
    }
}

// MARK: - DeepL

public final class DeepLEngine: BenchEngine, @unchecked Sendable {
    let file: EngineFile
    let baseURL: URL
    let key: String?
    public var label: String { file.name }
    public var model: String { "deepl" }
    public var kindName: String { file.kind }
    public var price: String? { file.price }

    init(file: EngineFile, baseURL: URL, key: String?) {
        self.file = file
        self.baseURL = baseURL
        self.key = key
    }

    public func preflight() -> String? { key == nil ? "set $\(file.keyEnv ?? "KEY") (keyEnv in the engine file)" : nil }

    /// DeepL takes the context as its own parameter (not billed); the memory, learned terms and speakers have no slot
    /// (its glossary needs a created glossary id), so M, W and L send only the context lines.
    public func translate(_ r: EngineRequest) async -> EngineReply {
        let texts = r.items.map(\.text)
        let body0 = DeepLTranslation.requestBody(lines: texts, source: coreLanguage(r.source), target: coreLanguage(r.target), formality: file.formality)
        var obj = (try? JSONSerialization.jsonObject(with: body0) as? [String: Any]) ?? [:]
        if let c = r.prompt.deepLContext, !c.isEmpty { obj["context"] = c }
        let body = Wiring.encode(obj)
        let wire = Wire(system: r.prompt.deepLContext ?? "", user: texts.joined(separator: "\n"))
        let scrub = scrubber(key)
        let base = DeepLTranslation.resolvedBaseURL(baseURL, key: key)
        let url = URL(string: base.absoluteString.trimmingSuffix("/") + DeepLTranslation.path)!
        let reply = await HTTP.post(url, headers: ["Content-Type": "application/json", "Authorization": "DeepL-Auth-Key \(key ?? "")"],
                                    body: body, scrub: scrub)
        var out = EngineReply(translations: nil, text: "", usage: Usage(chars: texts.reduce(0) { $0 + $1.count }), latencyMs: reply.ms,
                              retries: reply.retries, error: reply.error, wire: wire)
        if reply.error != nil { return out }
        if !(200..<300).contains(reply.status) {
            out.error = scrub("HTTP \(reply.status): " + Wiring.errorMessage(reply.data))
            return out
        }
        out.text = String(decoding: reply.data, as: UTF8.self)
        do { out.translations = try DeepLTranslation.parseTranslations(reply.data, count: texts.count) } catch { out.error = scrub(Wiring.describe(error)) }
        return out
    }
}

// MARK: - oracle

/// Replays the sequence's own `ref` lines with no latency. It makes the scorer's 100 % end to end, and gives the size
/// accounting of every condition without a model (the token counts are the estimate, flagged).
public struct OracleEngine: BenchEngine {
    public var name: String
    public var label: String { name }
    public var model: String { "oracle" }
    public var kindName: String { "oracle" }
    public var price: String? { nil }

    public func preflight() -> String? { nil }

    public func translate(_ r: EngineRequest) async -> EngineReply {
        // Today's system prompt and user message from MwoyeoCore, so the size accounting starts from the real condition A.
        let body = ChatTranslation.requestBody(lines: r.items.map(\.text), source: coreLanguage(r.source), target: coreLanguage(r.target),
                                               glossary: [], model: "oracle", baseURL: nil, thinking: .off)
        let messages = ((try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["messages"] as? [[String: Any]]) ?? []
        let wire = Wiring.compose(system: messages.first?["content"] as? String ?? "", user: messages.last?["content"] as? String ?? "",
                                  prompt: r.prompt)
        let t = r.items.map(\.ref)
        let text = ReferenceLayout.json(["translations": t])
        let usage = Usage(input: Int(Tokens.estimate(wire.system + wire.user).rounded()), output: Int(Tokens.estimate(text).rounded()), estimated: true)
        return EngineReply(translations: t, text: text, usage: usage, latencyMs: 0, retries: 0, error: nil, wire: wire)
    }
}
