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
        let quirks = ModelQuirks.lookup(host: baseURL?.host ?? "", port: baseURL?.port, model: model,
                                        kind: .openAICompatible(baseURL: baseURL ?? URL(fileURLWithPath: "/"), model: model,
                                                                thinking: thinking, extraHeaders: [:]))
        if quirks.sendsTemperature { body["temperature"] = 0 }
        if thinking == .off { for (k, v) in quirks.thinkingOff { body[k] = v.json } }
        return encode(body)
    }

    static func encode(_ body: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
    }

    static let rejectableFields = ["temperature", "reasoning_effort", "reasoning", "thinking", "enable_thinking"]

    /// For a 400 whose message names one of the fields we send, the request body without it and the field's name;
    /// otherwise nil. The caller retries once and remembers the field per engine.
    public static func withoutRejectedField(_ body: Data, errorBody: Data) -> (body: Data, field: String)? {
        guard let root = try? JSONSerialization.jsonObject(with: errorBody) else { return nil }
        let errors = (root as? [Any]) ?? [root]
        let messages = errors.compactMap { e -> String? in
            guard let err = (e as? [String: Any])?["error"] else { return nil }
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

        return try translations(fromContent: content, count: count)
    }

    /// The `{"translations": [...]}` (or bare array) inside a model's text reply.
    static func translations(fromContent content: String, count: Int) throws(ChatTranslationError) -> [String] {
        let json = extractJSON(content)
        guard let jsonData = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: jsonData)
        else { throw .malformed("content has no JSON") }
        let list: [String]
        if let obj = value as? [String: Any] {
            guard let t = obj["translations"] as? [String] else { throw .malformed("translations is not an array of strings") }
            list = t
        } else if let arr = value as? [String] {
            list = arr
        } else {
            throw .malformed("unexpected JSON shape")
        }
        guard list.count == count else { throw .countMismatch(expected: count, got: list.count) }
        return list
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
