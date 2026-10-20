import Foundation

public enum ChatTranslationError: Error, Equatable, Sendable {
    /// The server answered with an `{"error": {"message": …}}` body.
    case server(String)
    case countMismatch(expected: Int, got: Int)
    case malformed(String)
}

/// Pure protocol code for an OpenAI-compatible `/chat/completions` translation engine.
public enum ChatTranslation {
    /// `ModelQuirks` picks the fields from the host and model id: `temperature` where the model takes it, and for
    /// `thinking == .off` the provider's "do not reason" field (each rule's evidence is in `ModelQuirks`). An unknown
    /// host or model gets `temperature: 0` and nothing extra; `.provider` sends no thinking field.
    public static func requestBody(lines: [String], source: String?, target: String,
                                   glossary: [(String, String)], model: String,
                                   baseURL: URL? = nil, thinking: Thinking = .off) -> Data {
        var body: [String: Any] = [
            "model": model, "stream": false,
            "messages": [["role": "system", "content": systemPrompt(source: source, target: target, glossary: glossary)],
                         ["role": "user", "content": userMessage(lines)]],
        ]
        addQuirkFields(&body, model: model, baseURL: baseURL, thinking: thinking)
        return encode(body)
    }

    /// `temperature` and the thinking-off fields `ModelQuirks` has for this host and model.
    private static func addQuirkFields(_ body: inout [String: Any], model: String, baseURL: URL?, thinking: Thinking) {
        let quirks = ModelQuirks.lookup(host: baseURL?.host ?? "", port: baseURL?.port, model: model,
                                        kind: .openAICompatible(baseURL: baseURL ?? URL(fileURLWithPath: "/"), model: model,
                                                                thinking: thinking, extraHeaders: [:]))
        if quirks.sendsTemperature { body["temperature"] = 0 }
        if thinking == .off { for (k, v) in quirks.thinkingOff { body[k] = v.json } }
    }

    /// The context layout (design §4): the rules, the card and the user's note in the system message, and the volatile
    /// last message as the user message. `prompt_cache_key` (the thread's hashed key) and `store: false` go only to
    /// api.openai.com (`ModelQuirks.acceptsPromptCache`); a server that rejects them anyway loses them through
    /// `withoutRejectedField`.
    static func contextRequestBody(_ p: RequestLayout.Prepared, request: ContextRequest, model: String, baseURL: URL?,
                                   thinking: Thinking) -> Data {
        let rules = RequestLayout.rules(source: request.source, target: request.target, glossary: p.glossary, wantsTerms: p.wantsTerms)
        let system = p.cardNote.isEmpty ? rules : rules + "\n\n" + p.cardNote
        var body: [String: Any] = [
            "model": model, "stream": false,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": RequestLayout.lastMessage(items: request.items, p)]],
        ]
        addQuirkFields(&body, model: model, baseURL: baseURL, thinking: thinking)
        if ModelQuirks.acceptsPromptCache(host: baseURL?.host ?? "") {
            body["store"] = false
            if let key = request.threadKey { body["prompt_cache_key"] = key }
        }
        return encode(body)
    }

    static func encode(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
    }

    /// The fields a 400 may name and we can then drop. `prompt_cache_key` and `store` are OpenAI's (a local server answers
    /// them with a 400); `context`, `custom_instructions` and `formality` are DeepL's (design §8.6).
    /// `output_config` is Anthropic's (`effort` and the reply schema; a gateway that does not know it answers with a 400).
    static let rejectableFields = ["temperature", "reasoning_effort", "reasoning", "thinking", "enable_thinking", "output_config",
                                   "prompt_cache_key", "store", "context", "custom_instructions", "formality"]

    /// For a 400 whose message names one of the fields we send, the request body without it and the field's name;
    /// otherwise nil. The caller retries once and remembers the field per engine.
    public static func withoutRejectedField(_ body: Data, errorBody: Data) -> (body: Data, field: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: errorBody) else { return nil }
        let errors = (root as? [Any]) ?? [root]
        let messages = errors.compactMap { e -> String? in
            // DeepL answers `{"message": "…"}` without an `error` key.
            guard let err = (e as? [String: Any])?["error"] else { return (e as? [String: Any])?["message"] as? String }
            return (err as? [String: Any])?["message"] as? String ?? err as? String
        }
        guard !messages.isEmpty, var request = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        // `reasoning_effort` contains `reasoning`: take the longest match first.
        for field in rejectableFields.sorted(by: { $0.count > $1.count })
        where request[field] != nil && messages.contains(where: { $0.lowercased().contains(field) }) {
            request[field] = nil
            return (encode(request), field)
        }
        return nil
    }

    /// The request body without the fields an engine is known to reject (the ones `withoutRejectedField` found earlier).
    /// A body that is not a JSON object, or has none of them, comes back unchanged.
    public static func withoutFields(_ body: Data, _ fields: Set<String>) -> Data {
        guard !fields.isEmpty, var request = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              fields.contains(where: { request[$0] != nil })
        else { return body }
        for field in fields { request[field] = nil }
        return encode(request)
    }

    /// The instructions shared by every chat-style engine.
    static func systemPrompt(source: String?, target: String, glossary: [(String, String)]) -> String {
        var system = "Translate each line of the user's JSON into \(languageName(target))"
        if let source { system += " from \(languageName(source))" }
        system += ". Keep names, numbers, emoji, URLs and @handles unchanged."
        system += " Give one translation per line, in the same order."
        if !glossary.isEmpty {
            system += " Follow these glossary pairs exactly:\n"
            system += glossary.map { "\($0.0) → \($0.1)" }.joined(separator: "\n")
        }
        system += "\nReply with only {\"translations\": [...]}."
        return system
    }

    static func userMessage(_ lines: [String]) -> String {
        (try? JSONSerialization.data(withJSONObject: ["lines": lines], options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"lines\":[]}"
    }

    public static func parseTranslations(_ data: Data, count: Int) throws(ChatTranslationError) -> [String] {
        try parseReply(data, count: count).lines
    }

    /// The translations, the `terms` the model reported, and the usage of one `/chat/completions` reply.
    public static func parseReply(_ data: Data, count: Int) throws(ChatTranslationError) -> TranslationReply {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .malformed("response is not a JSON object")
        }
        if let err = root["error"] {
            if let m = (err as? [String: Any])?["message"] as? String { throw .server(m) }
            if let m = err as? String { throw .server(m) }
            throw .server("unknown error")
        }
        guard let choices = root["choices"] as? [[String: Any]], let first = choices.first,
              let content = (first["message"] as? [String: Any])?["content"] as? String
        else { throw .malformed("no choices[0].message.content") }

        let r = try ContextReply.parse(content: content, count: count)
        return TranslationReply(lines: r.lines, terms: r.terms, usage: TokenUsage.openAI(root))
    }

    /// The `{"t": [...]}`, `{"translations": [...]}` (or bare array) inside a model's text reply, as lines.
    static func translations(fromContent content: String, count: Int) throws(ChatTranslationError) -> [String] {
        try ContextReply.parse(content: content, count: count).lines
    }

    /// True only for `localhost`, `127.0.0.1` and `::1`; a `.local` host is another machine.
    public static func isOnThisMac(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return isOnThisMac(host: host)
    }

    static func isOnThisMac(host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Model ids from a `GET /models` response, sorted, without Gemini's leading `models/`.
    public static func modelIDs(_ data: Data) throws(ChatTranslationError) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .malformed("response is not a JSON object")
        }
        if let m = (root["error"] as? [String: Any])?["message"] as? String { throw .server(m) }
        guard let items = root["data"] as? [[String: Any]] else { throw .malformed("no data array") }
        return items.compactMap { ($0["id"] as? String).map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } }.sorted()
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    /// The JSON part of a model reply: fences stripped, then the span from the first `{` to the last `}`
    /// (or the whole bare array).
    static func extractJSON(_ content: String) -> String {
        var s = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = String(s.drop(while: { $0 != "\n" }))
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("[") { return s }
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}"), a < b { return String(s[a...b]) }
        if let a = s.firstIndex(of: "["), let b = s.lastIndex(of: "]"), a < b { return String(s[a...b]) }
        return s
    }
}
