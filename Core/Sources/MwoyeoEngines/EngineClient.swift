import Foundation
import MwoyeoCore

/// Talks to whatever engine the user configured. Request building and reply parsing are MwoyeoCore's
/// (`ChatTranslation`, `AnthropicTranslation`, `DeepLTranslation`, `HTTPTemplate`, `CommandEngine`); this actor adds the
/// shared connection pool, the key lookup, the error mapping, and the two things worth remembering per engine: the
/// request fields a server rejected, and the model list.
public actor EngineClient {
    private let secrets: any SecretStore
    private let metrics: (@Sendable (URLSessionTaskMetrics) -> Void)?
    private var rejections: [UUID: Set<String>] = [:]
    private var modelLists: [String: [String]] = [:]

    /// `metrics` sees every finished HTTP task (timing and `isReusedConnection`); the client logs nothing itself.
    public init(secrets: any SecretStore, metrics: (@Sendable (URLSessionTaskMetrics) -> Void)? = nil) {
        self.secrets = secrets
        self.metrics = metrics
    }

    // MARK: remembered rejections

    /// The request fields this engine's server refused (stripped from every request from then on).
    public func learnedRejections(for engine: UUID) -> Set<String> {
        rejections[engine] ?? []
    }

    /// Restores what the app saved from an earlier run.
    public func seedRejections(_ fields: Set<String>, for engine: UUID) {
        rejections[engine] = fields
    }

    // MARK: translate

    /// Today's call, kept as a wrapper: the context layout with `ContextOptions.off`, which sends exactly the old body.
    public func translate(_ lines: [String], source: String?, target: String, glossary: [(String, String)],
                          engine: EngineConfig) async throws(EngineError) -> [String] {
        if lines.isEmpty { return [] }
        let request = ContextRequest(items: lines, source: source, target: target, glossary: glossary)
        return try await translate(request, options: .off, engine: engine).lines
    }

    /// The context-aware call: the body comes from `RequestLayout` (stable parts first), and the reply carries the lines in
    /// item order, the `terms` the model reported and the token usage (cached tokens included). An HTTP template or a
    /// command engine gets the lines only. No text is logged.
    public func translate(_ request: ContextRequest, options: ContextOptions,
                          engine: EngineConfig) async throws(EngineError) -> TranslationReply {
        let lines = request.items
        if lines.isEmpty { return TranslationReply(lines: []) }
        if Task.isCancelled { throw .cancelled }
        let source = request.source, target = request.target
        switch engine.kind {
        case let .openAICompatible(baseURL, _, _, extraHeaders):
            let key = try key(for: engine, required: !ChatTranslation.isOnThisMac(baseURL))
            let body = RequestLayout.body(kind: engine.kind, request: request, options: options)
            var headers = ["Content-Type": "application/json"]
            if let key { headers["Authorization"] = "Bearer \(key)" }
            for (k, v) in extraHeaders { headers[k] = v.replacingOccurrences(of: "{{key}}", with: key ?? "") }
            return try await chat(engine, url: try endpoint(baseURL, "/chat/completions"), headers: headers, body: body,
                                  count: lines.count, key: key) { d, n throws(ChatTranslationError) in try ChatTranslation.parseReply(d, count: n) }
        case let .anthropic(baseURL, _, _):
            let key = try key(for: engine, required: true)
            let body = RequestLayout.body(kind: engine.kind, request: request, options: options)
            var headers = AnthropicTranslation.headers()
            headers["x-api-key"] = key
            return try await chat(engine, url: try endpoint(baseURL, AnthropicTranslation.path), headers: headers, body: body,
                                  count: lines.count, key: key) { d, n throws(ChatTranslationError) in try AnthropicTranslation.parseReply(d, count: n) }
        case let .deepL(baseURL, _):
            let key = try key(for: engine, required: true)
            let body = RequestLayout.body(kind: engine.kind, request: request, options: options)
            let headers = ["Content-Type": "application/json", "Authorization": "DeepL-Auth-Key \(key ?? "")"]
            let base = DeepLTranslation.resolvedBaseURL(baseURL, key: key)
            return try await chat(engine, url: try endpoint(base, DeepLTranslation.path), headers: headers, body: body,
                                  count: lines.count, key: key) { d, n throws(ChatTranslationError) in try DeepLTranslation.parseReply(d, count: n) }
        case let .httpTemplate(template):
            return TranslationReply(lines: try await httpTemplate(template, engine: engine, lines: lines, source: source, target: target))
        case let .command(spec):
            let reply = try await CommandRunner.run(spec, input: CommandEngine.encodeRequest(lines: lines, source: source, target: target),
                                                    scrub: Scrubber(key: nil))
            return TranslationReply(lines: try mapped { () throws(ChatTranslationError) in try CommandEngine.decodeResponse(reply, count: lines.count) })
        }
    }

    /// OpenAI-style, Anthropic and DeepL calls: one POST, and on a 400 that names a field we sent, one retry without it.
    private func chat(_ engine: EngineConfig, url: URL, headers: [String: String], body: Data, count: Int, key: String?,
                      parse: (Data, Int) throws(ChatTranslationError) -> TranslationReply) async throws(EngineError) -> TranslationReply {
        let scrub = Scrubber(key: key)
        var body = ChatTranslation.withoutFields(body, rejections[engine.id] ?? [])
        var reply = try await post(url, headers: headers, body: body, scrub: scrub)
        if reply.status == 400, let fix = ChatTranslation.withoutRejectedField(body, errorBody: reply.data) {
            body = fix.body
            reply = try await post(url, headers: headers, body: body, scrub: scrub)
            // Remembered only once the retry got an answer: a cancelled call teaches nothing.
            rejections[engine.id, default: []].insert(fix.field)
        }
        try Self.check(reply, scrub: scrub)
        do throws(ChatTranslationError) { return try parse(reply.data, count) } catch { throw Self.map(error, scrub: scrub) }
    }

    /// `.perLine` sends one request per line in order; `.jsonArray` one for the batch. No field healing: the body is the user's.
    private func httpTemplate(_ template: HTTPTemplate, engine: EngineConfig, lines: [String], source: String?,
                              target: String) async throws(EngineError) -> [String] {
        let key = try key(for: engine, required: template.headers.values.contains { $0.contains("{{key}}") })
        let scrub = Scrubber(key: key)
        let requests: [HTTPTemplate.Request]
        do throws(HTTPTemplateError) { requests = try HTTPTemplate.requests(template, lines: lines, source: source, target: target, key: key) }
        catch { throw .malformed(scrub("template: \(Self.describe(error))")) }
        var out: [String] = []
        for r in requests {
            guard let url = URL(string: r.url) else { throw .malformed("the template's URL is not valid") }
            var request = URLRequest(url: url)
            request.httpMethod = r.method
            request.httpBody = r.body
            for (k, v) in r.headers { request.setValue(v, forHTTPHeaderField: k) }
            let reply = try await send(request, scrub: scrub)
            try Self.check(reply, scrub: scrub)
            do throws(HTTPTemplateError) { out += try HTTPTemplate.parseResponse(template, data: reply.data, count: template.batching == .perLine ? 1 : lines.count) }
            catch { throw .malformed(scrub(Self.describe(error))) }
        }
        return out
    }

    // MARK: models

    /// The ids the engine offers (`GET /models`; Anthropic `GET /v1/models`); other kinds have none. The list is kept
    /// per engine for the client's lifetime; `refresh` asks again.
    public func models(_ engine: EngineConfig, refresh: Bool = false) async throws(EngineError) -> [String] {
        let url: URL, headers: [String: String], key: String?
        switch engine.kind {
        case let .openAICompatible(baseURL, _, _, extraHeaders):
            key = try self.key(for: engine, required: !ChatTranslation.isOnThisMac(baseURL))
            url = try endpoint(baseURL, "/models")
            var h: [String: String] = [:]
            if let key { h["Authorization"] = "Bearer \(key)" }
            for (k, v) in extraHeaders { h[k] = v.replacingOccurrences(of: "{{key}}", with: key ?? "") }
            headers = h
        case let .anthropic(baseURL, _, _):
            key = try self.key(for: engine, required: true)
            url = try endpoint(baseURL, "/v1/models")
            var h = AnthropicTranslation.headers()
            h["x-api-key"] = key
            headers = h
        default:
            return []
        }
        let cacheKey = "\(engine.id)|\(url.absoluteString)"
        if !refresh, let cached = modelLists[cacheKey] { return cached }
        let scrub = Scrubber(key: key)
        var request = URLRequest(url: url)
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        let reply = try await send(request, scrub: scrub)
        try Self.check(reply, scrub: scrub)
        let ids: [String]
        do throws(ChatTranslationError) { ids = try ChatTranslation.modelIDs(reply.data) } catch { throw Self.map(error, scrub: scrub) }
        modelLists[cacheKey] = ids
        return ids
    }

    // MARK: prewarm and probe

    /// Opens the connection before the first batch needs it, so the batch skips the TLS handshake. Errors are ignored.
    public func prewarm(_ engine: EngineConfig) async {
        switch engine.kind {
        case .openAICompatible, .anthropic:
            _ = try? await models(engine)
        case let .deepL(baseURL, _):
            let key = try? secrets.secret(for: engine.id)
            await head(DeepLTranslation.resolvedBaseURL(baseURL, key: key).absoluteString)
        case let .httpTemplate(t):
            await head(t.url)
        case .command:
            break
        }
    }

    private func head(_ url: String) async {
        guard let origin = Self.origin(of: url), let u = URL(string: origin) else { return }
        var request = URLRequest(url: u)
        request.httpMethod = "HEAD"
        _ = try? await send(request, scrub: Scrubber(key: nil))
    }

    /// `scheme://host[:port]` of a URL string that may still hold `{{placeholders}}` further on.
    static func origin(of url: String) -> String? {
        guard let r = url.range(of: "://") else { return nil }
        let rest = url[r.upperBound...]
        let end = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? rest.endIndex
        let origin = String(url[..<end])
        return origin.contains("{") ? nil : origin
    }

    /// Translates one fixed line, for the add-engine sheet's "it works, 840 ms" line.
    public func probe(_ engine: EngineConfig, target: String) async -> (sample: String?, ms: Int, error: EngineError?) {
        let clock = ContinuousClock()
        let start = clock.now
        func ms() -> Int { Int((clock.now - start) / .milliseconds(1)) }
        do {
            let out = try await translate(["Hello, world."], source: nil, target: target, glossary: [], engine: engine)
            return (out.first, ms(), nil)
        } catch {
            return (nil, ms(), error)
        }
    }

    // MARK: plumbing

    private func key(for engine: EngineConfig, required: Bool) throws(EngineError) -> String? {
        let found: String?
        do { found = try secrets.secret(for: engine.id) } catch { throw .missingKey }
        guard let found, !found.isEmpty else {
            if required { throw .missingKey }
            return nil
        }
        return found
    }

    private func endpoint(_ base: URL, _ path: String) throws(EngineError) -> URL {
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s + path) else { throw .malformed("the base URL is not valid") }
        return url
    }

    private func post(_ url: URL, headers: [String: String], body: Data, scrub: Scrubber) async throws(EngineError) -> EngineTransport.Reply {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
        return try await send(request, scrub: scrub)
    }

    private func send(_ request: URLRequest, scrub: Scrubber) async throws(EngineError) -> EngineTransport.Reply {
        try await EngineTransport.send(request, metrics: metrics, scrub: scrub)
    }

    /// A non-2xx reply as an `EngineError`.
    static func check(_ reply: EngineTransport.Reply, scrub: Scrubber) throws(EngineError) {
        guard !(200..<300).contains(reply.status) else { return }
        let message = scrub(errorMessage(reply.data) ?? "HTTP \(reply.status)")
        switch reply.status {
        case 401, 403: throw .unauthorized(message)
        case 429: throw .rateLimited(retryAfter: reply.retryAfter)
        case 400, 404, 422: throw .rejected(message)
        case 456: throw .server("quota exceeded")
        default: throw .server(message)
        }
    }

    /// The server's own words from `{"error": {"message"}}`, `{"error": "…"}` or `{"message": "…"}`; else the start of the body.
    static func errorMessage(_ data: Data) -> String? {
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = root["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = root["error"] as? String { return m }
            if let m = root["message"] as? String { return m }
        }
        let text = String(decoding: data.prefix(400), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func map(_ error: ChatTranslationError, scrub: Scrubber) -> EngineError {
        switch error {
        case let .server(m): .server(scrub(m))
        case let .countMismatch(expected, got): .countMismatch(expected: expected, got: got)
        case let .malformed(m): .malformed(scrub(m))
        }
    }

    private func mapped(_ body: () throws(ChatTranslationError) -> [String]) throws(EngineError) -> [String] {
        do throws(ChatTranslationError) { return try body() } catch { throw Self.map(error, scrub: Scrubber(key: nil)) }
    }

    private static func describe(_ error: HTTPTemplateError) -> String {
        switch error {
        case let .invalid(problems): problems.joined(separator: "; ")
        case let .path(segment, reason): "\(segment): \(reason)"
        case let .countMismatch(expected, got): "expected \(expected) translations, got \(got)"
        case let .malformed(m): m
        }
    }
}
