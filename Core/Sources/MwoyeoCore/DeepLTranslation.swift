import Foundation

/// Pure protocol code for DeepL (`POST {baseURL}/v2/translate`, header `Authorization: DeepL-Auth-Key <key>`).
public enum DeepLTranslation {
    public static let path = "/v2/translate"

    static let proHost = "api.deepl.com"
    static let freeHost = "api-free.deepl.com"

    /// True for the two official DeepL hosts, where the key decides which one is called.
    public static func isOfficialHost(_ url: URL) -> Bool {
        let host = url.host?.lowercased()
        return host == proHost || host == freeHost
    }

    /// The base URL to call. On an official DeepL host the key decides: a key ending in `:fx` is a Free key and goes to
    /// `api-free.deepl.com`, any other goes to `api.deepl.com`. A proxy host is kept as configured.
    public static func resolvedBaseURL(_ configured: URL, key: String?) -> URL {
        guard isOfficialHost(configured) else { return configured }
        let free = key?.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(":fx") ?? false
        return URL(string: "https://" + (free ? freeHost : proHost)) ?? configured
    }

    public static func requestBody(lines: [String], source: String?, target: String, formality: String?) -> Data {
        var body: [String: Any] = ["text": lines, "target_lang": upper(target)]
        if let source { body["source_lang"] = upper(source) }
        if let formality { body["formality"] = formality }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
    }

    public static func parseTranslations(_ data: Data, count: Int) throws(ChatTranslationError) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw .malformed("response is not a JSON object")
        }
        if let m = root["message"] as? String, root["translations"] == nil { throw .server(m) }
        guard let items = root["translations"] as? [[String: Any]] else { throw .malformed("no translations array") }
        let list = items.compactMap { $0["text"] as? String }
        guard list.count == items.count else { throw .malformed("a translation has no text") }
        guard list.count == count else { throw .countMismatch(expected: count, got: list.count) }
        return list
    }

    /// DeepL language codes are upper case and the region part is kept only for targets that need it (`EN-US`, `PT-BR`).
    /// `zh-Hans` becomes `ZH`; the part after the language is kept only when it is a two-letter region.
    static func upper(_ bcp47: String) -> String {
        let parts = bcp47.split(separator: "-").map(String.init)
        guard let lang = parts.first else { return bcp47.uppercased() }
        if parts.count > 1, parts[1].count == 2 { return "\(lang)-\(parts[1])".uppercased() }
        return lang.uppercased()
    }
}
