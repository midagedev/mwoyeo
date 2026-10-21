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

    // MARK: context (design §4, §8.6)

    /// Target languages DeepL documents `custom_instructions` for (de, en, es, fr, it, ja, ko, zh and their variants;
    /// developers.deepl.com custom-instructions docs, read 2026-10-18). The supported-languages table lists more; this is
    /// the part both sources agree on. Instructions are limited to 10, 300 characters each, and are only in the JSON body.
    static let customInstructionFamilies: Set<String> = ["DE", "EN", "ES", "FR", "IT", "JA", "KO", "ZH"]
    static let maxInstructions = 10
    static let maxInstructionLength = 300
    /// At most this many names ride in `custom_instructions` ("Write X as Y.").
    static let maxNameInstructions = 8
    static let maxReferentInstructions = 2

    static func family(_ upperTarget: String) -> String {
        upperTarget.split(separator: "-").first.map(String.init) ?? upperTarget
    }

    static func supportsCustomInstructions(target upperTarget: String) -> Bool {
        customInstructionFamilies.contains(family(upperTarget))
    }

    /// Targets that take `formality` (KO does not, JA does; design §8.6). The docs name no list on the translate page
    /// (`GET /v3/languages` is the authority); a `prefer_…` value is accepted for any target, so a wrong entry here costs
    /// nothing worse than a missing hint.
    static func supportsFormality(target upperTarget: String) -> Bool {
        ["DE", "ES", "FR", "IT", "JA", "NL", "PL", "RU"].contains(family(upperTarget)) || upperTarget.hasPrefix("PT-")
    }

    /// The register the selected rows agree on: all casual → casual; all polite, formal or honorific → polite; else nil.
    static func agreedRegister(_ rows: [MemoryEntry]) -> Register? {
        let all = rows.flatMap { $0.addressing.map(\.register) }
        guard !all.isEmpty else { return nil }
        if all.allSatisfy({ $0 == .casual }) { return .casual }
        if all.allSatisfy({ $0 != .casual }) { return .polite }
        return nil
    }

    /// `custom_instructions`: the app note (in pieces of 300 characters, at most 2), the register, the referents (at most
    /// 2), then names as "Write X as Y." (at most 8): the selected rows, then the global glossary pairs that occur in the
    /// items. At most 10 instructions of 300 characters.
    ///
    /// TODO(glossary): names belong in a DeepL glossary, which DeepL applies exactly. It needs `POST /v2/glossaries`
    /// (name, source_lang, target_lang, entries, entries_format "tsv") → `glossary_id`, passed as `glossary_id` on
    /// `/v2/translate`; one glossary per language pair, re-created (and the old one deleted) when the sheet changes
    /// (`ContextMemory.memoryFingerprint`), with the id kept per engine in the app. EngineClient has no glossary path
    /// today, so v1 sends names here.
    static func customInstructions(_ p: RequestLayout.Prepared, items: [String], register: Register?) -> [String] {
        func fit(_ s: String) -> String { ContextText.truncated(s, toCharacters: maxInstructionLength) }
        var out: [String] = []
        let note = p.note.trimmingCharacters(in: .whitespacesAndNewlines)
        var rest = Substring(note)
        while !rest.isEmpty, out.count < 2 {
            out.append(String(rest.prefix(maxInstructionLength)))
            rest = rest.dropFirst(maxInstructionLength)
        }
        if let register { out.append(register == .casual ? "Use casual speech." : "Use polite speech.") }
        for r in p.referents.prefix(maxReferentInstructions) { out.append(fit("\"\(r.pronoun)\" refers to \(r.refersTo).")) }
        var names = p.rows.map { ($0.src, $0.dst) }
        let have = Set(names.map { ContextText.foldedKey($0.0) })
        names += p.glossary.filter { g in
            !have.contains(ContextText.foldedKey(g.0)) && items.contains { ContextText.occurs(g.0, in: $0) }
        }
        let room = max(0, min(maxNameInstructions, maxInstructions - out.count))
        for (src, dst) in names.prefix(room) { out.append(fit("Write \(src) as \(dst).")) }
        return Array(out.prefix(maxInstructions))
    }

    /// The text for `context`, which DeepL neither translates nor bills: the card, the lines before, the lines after.
    static func contextString(_ p: RequestLayout.Prepared) -> String {
        var lines: [String] = []
        if let card = p.card, !card.isEmpty { lines.append(card) }
        lines += p.before.map(\.source)
        lines += p.after
        return lines.joined(separator: "\n")
    }

    /// The context layout: `context` (card, lines before and after), which DeepL does not bill. With `instructions`
    /// (`ContextOptions.deepLInstructions`, the user's opt-in, design §9) also `custom_instructions` (note, register,
    /// referents, names) and, where the pair supports it, `formality`: the engine's own formality wins unless it is nil
    /// or "default"; then the register the rows agree on becomes `prefer_more` or `prefer_less`. Without it the engine's
    /// formality is sent as it is and nothing is mapped from the memory.
    static func contextRequestBody(_ p: RequestLayout.Prepared, request: ContextRequest, formality engineFormality: String?,
                                   instructions: Bool) -> Data {
        let target = upper(request.target)
        var body: [String: Any] = ["text": request.sent, "target_lang": target]
        if let source = request.source { body["source_lang"] = upper(source) }
        var formality = engineFormality
        var register: Register?
        if instructions {
            register = agreedRegister(p.rows)
            if engineFormality == nil || engineFormality == "default", supportsFormality(target: target), let register {
                formality = register == .casual ? "prefer_less" : "prefer_more"
            }
        }
        if let formality { body["formality"] = formality }
        let context = contextString(p)
        if !context.isEmpty { body["context"] = context }
        if instructions, supportsCustomInstructions(target: target) {
            let list = customInstructions(p, items: request.items, register: register)
            if !list.isEmpty { body["custom_instructions"] = list }
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
    }

    /// DeepL reports no token usage; the reply carries the translations only.
    public static func parseReply(_ data: Data, count: Int) throws(ChatTranslationError) -> TranslationReply {
        TranslationReply(lines: try parseTranslations(data, count: count))
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
