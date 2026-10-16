import Foundation

public enum ChatTranslationError: Error, Equatable, Sendable {
    /// The server answered with an `{"error": {"message": …}}` body.
    case server(String)
    case countMismatch(expected: Int, got: Int)
    case malformed(String)
}

/// Pure protocol code for an OpenAI-compatible `/chat/completions` translation engine.
public enum ChatTranslation {
    public static func requestBody(lines: [String], source: String?, target: String,
                                   glossary: [(String, String)], model: String) -> Data {
        var system = "Translate each line of the user's JSON into \(languageName(target))"
        if let source { system += " from \(languageName(source))" }
        system += ". Keep names, numbers, emoji, URLs and @handles unchanged."
        system += " Give one translation per line, in the same order."
        if !glossary.isEmpty {
            system += " Follow these glossary pairs exactly:\n"
            system += glossary.map { "\($0.0) → \($0.1)" }.joined(separator: "\n")
        }
        system += "\nReply with only {\"translations\": [...]}."
        let user = (try? JSONSerialization.data(withJSONObject: ["lines": lines], options: [.withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{\"lines\":[]}"
        let body: [String: Any] = [
            "model": model, "temperature": 0, "stream": false,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
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
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Model ids from a `GET /models` response, sorted.
    public static func modelIDs(_ data: Data) throws(ChatTranslationError) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .malformed("response is not a JSON object")
        }
        if let m = (root["error"] as? [String: Any])?["message"] as? String { throw .server(m) }
        guard let items = root["data"] as? [[String: Any]] else { throw .malformed("no data array") }
        return items.compactMap { $0["id"] as? String }.sorted()
    }

    private static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code) ?? code
    }

    /// The JSON part of a model reply: fences stripped, then the span from the first `{` to the last `}`
    /// (or the whole bare array).
    private static func extractJSON(_ content: String) -> String {
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
