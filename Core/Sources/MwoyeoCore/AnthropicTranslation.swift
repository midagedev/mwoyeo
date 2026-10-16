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
    public static func requestBody(lines: [String], source: String?, target: String,
                                   glossary: [(String, String)], model: String, thinking: Thinking = .off) -> Data {
        let body: [String: Any] = [
            "model": model, "max_tokens": maxTokens(for: lines), "temperature": 0,
            "system": ChatTranslation.systemPrompt(source: source, target: target, glossary: glossary),
            "messages": [["role": "user", "content": ChatTranslation.userMessage(lines)]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
    }

    public static func parseTranslations(_ data: Data, count: Int) throws(ChatTranslationError) -> [String] {
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
        return try ChatTranslation.translations(fromContent: text, count: count)
    }
}
