import Foundation

/// Pure protocol code for the Anthropic Messages API (`POST {baseURL}/v1/messages`).
public enum AnthropicTranslation {
    public static let path = "/v1/messages"

    /// The headers the app adds besides `x-api-key`, which comes from the Keychain.
    public static func headers() -> [String: String] {
        ["anthropic-version": "2023-06-01", "content-type": "application/json"]
    }

    /// 256 + 4 × the characters of all lines, at most 8192.
    public static func maxTokens(for lines: [String]) -> Int {
        min(8192, 256 + 4 * lines.reduce(0) { $0 + $1.count })
    }

    /// `thinking` is never sent: `.off` is the API's default (no thinking block), and `.provider` adds nothing.
    /// `temperature` follows `ModelQuirks` (never for Claude).
    public static func requestBody(lines: [String], source: String?, target: String,
                                   glossary: [(String, String)], model: String, thinking: Thinking = .off) -> Data {
        var body: [String: Any] = [
            "model": model, "max_tokens": maxTokens(for: lines),
            "system": ChatTranslation.systemPrompt(source: source, target: target, glossary: glossary),
            "messages": [["role": "user", "content": ChatTranslation.userMessage(lines)]],
        ]
        let quirks = ModelQuirks.lookup(host: "api.anthropic.com", port: nil, model: model,
                                        kind: .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: model, thinking: thinking))
        if quirks.sendsTemperature { body["temperature"] = 0 }
        return ChatTranslation.encode(body)
    }

    /// The context layout (design §4). `system` is two text blocks, each with a `cache_control` marker: the rules, then the
    /// card and the user's note (the second block is left out, with its marker, when there is neither). The volatile last
    /// message is the only user message, after the last marker. The reply is `{"t": […], "terms": […]}`, so
    /// `max_tokens` adds room for the ids (16 per item) and up to 8 terms (256).
    static func contextRequestBody(_ p: RequestLayout.Prepared, request: ContextRequest, model: String, thinking: Thinking) -> Data {
        let marker: [String: Any] = ["type": "ephemeral"]
        var system: [[String: Any]] = [["type": "text", "cache_control": marker,
                                        "text": RequestLayout.rules(source: request.source, target: request.target, glossary: p.glossary, wantsTerms: p.wantsTerms)]]
        if !p.cardNote.isEmpty { system.append(["type": "text", "cache_control": marker, "text": p.cardNote]) }
        var body: [String: Any] = [
            "model": model,
            "max_tokens": min(8192, maxTokens(for: request.items) + 16 * request.items.count + 256),
            "system": system,
            "messages": [["role": "user", "content": RequestLayout.lastMessage(items: request.items, p)]],
        ]
        let quirks = ModelQuirks.lookup(host: "api.anthropic.com", port: nil, model: model,
                                        kind: .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: model, thinking: thinking))
        if quirks.sendsTemperature { body["temperature"] = 0 }
        return ChatTranslation.encode(body)
    }

    public static func parseTranslations(_ data: Data, count: Int) throws(ChatTranslationError) -> [String] {
        try parseReply(data, count: count).lines
    }

    /// The translations, the `terms` the model reported, and the usage (incl. cache fields) of one Messages reply.
    public static func parseReply(_ data: Data, count: Int) throws(ChatTranslationError) -> TranslationReply {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .malformed("response is not a JSON object")
        }
        if root["type"] as? String == "error" || root["error"] != nil {
            if let m = (root["error"] as? [String: Any])?["message"] as? String { throw .server(m) }
            throw .server("unknown error")
        }
        guard let blocks = root["content"] as? [[String: Any]] else { throw .malformed("no content array") }
        let text = blocks.compactMap { $0["type"] as? String == "text" || $0["type"] == nil ? $0["text"] as? String : nil }
            .joined()
        guard !text.isEmpty else { throw .malformed("no text in content") }
        let r = try ContextReply.parse(content: text, count: count)
        return TranslationReply(lines: r.lines, terms: r.terms, usage: TokenUsage.anthropic(root))
    }
}
