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

    /// `ModelQuirks` has the rest: no `temperature` for Claude; for `thinking == .off` the model's way to stop reasoning (Claude 5
    /// thinks by default, so each row says `disabled`, `between_tools` or `effort: low`; `.provider` adds nothing); and for a model
    /// that takes it `output_config.format`, a JSON schema that makes the reply `{"translations": [...]}` and nothing else.
    public static func requestBody(lines: [String], source: String?, target: String,
                                   glossary: [(String, String)], model: String, thinking: Thinking = .off) -> Data {
        var body: [String: Any] = [
            "model": model, "max_tokens": maxTokens(for: lines),
            "system": ChatTranslation.systemPrompt(source: source, target: target, glossary: glossary),
            "messages": [["role": "user", "content": ChatTranslation.userMessage(lines)]],
        ]
        addQuirkFields(&body, model: model, thinking: thinking, schema: translationsSchema)
        return ChatTranslation.encode(body)
    }

    /// `temperature`, the thinking-off fields and the reply schema `ModelQuirks` has for this model. `output_config` is one object
    /// that can hold both `effort` (a thinking-off row) and `format` (the schema).
    private static func addQuirkFields(_ body: inout [String: Any], model: String, thinking: Thinking, schema: [String: Any]) {
        let quirks = ModelQuirks.lookup(host: "api.anthropic.com", port: nil, model: model,
                                        kind: .anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: model, thinking: thinking))
        if quirks.sendsTemperature { body["temperature"] = 0 }
        var fields = thinking == .off ? quirks.thinkingOff.mapValues(\.json) : [:]
        if quirks.structuredReply {
            let format: [String: Any] = ["format": ["type": "json_schema", "schema": schema] as [String: Any]]
            fields["output_config"] = (fields["output_config"] as? [String: Any] ?? [:]).merging(format) { _, new in new }
        }
        body.merge(fields) { _, new in new }
    }

    /// The reply the plain request asks for, `{"translations": [...]}`, as the JSON schema Anthropic's structured outputs take
    /// (every object closed, no length limits: those are refused).
    static var translationsSchema: [String: Any] { [
        "type": "object", "additionalProperties": false, "required": ["translations"],
        "properties": ["translations": ["type": "array", "items": ["type": "string"]]],
    ] }

    /// The reply the context request asks for, `{"t": [{"id", "text"}], "terms": [{"src", "dst", "kind"?, "gender"?}]}`; `terms` only when
    /// the request asks for them (`RequestLayout.rules`).
    static func contextSchema(wantsTerms: Bool) -> [String: Any] {
        var properties: [String: Any] = [
            "t": ["type": "array", "items": ["type": "object", "additionalProperties": false, "required": ["id", "text"],
                                             "properties": ["id": ["type": "integer"], "text": ["type": "string"]]]],
        ]
        if wantsTerms {
            properties["terms"] = ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["src", "dst"],
                "properties": ["src": ["type": "string"], "dst": ["type": "string"],
                               "kind": ["type": "string", "enum": ["person", "place", "term", "org"]],
                               "gender": ["type": "string", "enum": ["f", "m", "n"]]]]]
        }
        return ["type": "object", "additionalProperties": false, "required": ["t"], "properties": properties]
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
            "max_tokens": min(8192, maxTokens(for: request.sent) + 16 * request.sent.count + 256),
            "system": system,
            "messages": [["role": "user", "content": RequestLayout.lastMessage(items: request.sent, p)]],
        ]
        addQuirkFields(&body, model: model, thinking: thinking, schema: contextSchema(wantsTerms: p.wantsTerms))
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
