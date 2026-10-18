import Foundation

// Replies (design §4, §6): the `{"t": [...], "terms": [...]}` shape, today's `{"translations": [...]}`, and the usage
// fields of OpenAI-style and Anthropic replies. Nothing here logs text.

/// Token counts of one request, from the provider's own `usage`. `prompt` is the whole input: for Anthropic that is
/// `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`, so the two providers read the same way.
public struct TokenUsage: Equatable, Sendable {
    public var prompt: Int
    public var completion: Int
    /// Input tokens served from the provider's prompt cache (OpenAI `cached_tokens`, Anthropic `cache_read_input_tokens`).
    public var cached: Int
    /// Input tokens written to the cache (Anthropic `cache_creation_input_tokens`; 0 for providers that do not report it).
    public var cacheWrite: Int

    public static let zero = TokenUsage(prompt: 0, completion: 0, cached: 0, cacheWrite: 0)

    public init(prompt: Int, completion: Int, cached: Int = 0, cacheWrite: Int = 0) {
        self.prompt = prompt
        self.completion = completion
        self.cached = cached
        self.cacheWrite = cacheWrite
    }

    /// Input tokens billed at the full rate.
    public var uncached: Int { max(0, prompt - cached - cacheWrite) }

    /// OpenAI-style `usage`: `prompt_tokens`, `completion_tokens`, and the cached count from
    /// `prompt_tokens_details.cached_tokens` (Chat Completions), `input_tokens_details.cached_tokens` (Responses) or
    /// `prompt_cache_hit_tokens` (DeepSeek). Missing fields are 0.
    static func openAI(_ root: [String: Any]) -> TokenUsage {
        guard let u = root["usage"] as? [String: Any] else { return .zero }
        let prompt = int(u["prompt_tokens"]) ?? int(u["input_tokens"]) ?? 0
        let completion = int(u["completion_tokens"]) ?? int(u["output_tokens"]) ?? 0
        let cached = int((u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])
            ?? int((u["input_tokens_details"] as? [String: Any])?["cached_tokens"])
            ?? int(u["prompt_cache_hit_tokens"]) ?? 0
        let write = int((u["input_tokens_details"] as? [String: Any])?["cache_write_tokens"]) ?? 0
        return TokenUsage(prompt: prompt, completion: completion, cached: cached, cacheWrite: write)
    }

    /// Anthropic `usage`: `input_tokens` (after the last cache breakpoint), `output_tokens`, `cache_creation_input_tokens`,
    /// `cache_read_input_tokens`.
    static func anthropic(_ root: [String: Any]) -> TokenUsage {
        guard let u = root["usage"] as? [String: Any] else { return .zero }
        let input = int(u["input_tokens"]) ?? 0
        let create = int(u["cache_creation_input_tokens"]) ?? 0
        let read = int(u["cache_read_input_tokens"]) ?? 0
        return TokenUsage(prompt: input + create + read, completion: int(u["output_tokens"]) ?? 0, cached: read, cacheWrite: create)
    }

    private static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double, d == d.rounded() { return Int(d) }
        return nil
    }
}

/// What a context-aware translate call returns: the lines in item order, the terms the model reported, and the usage.
public struct TranslationReply: Equatable, Sendable {
    public var lines: [String]
    public var terms: [TermHint]
    public var usage: TokenUsage

    public init(lines: [String], terms: [TermHint] = [], usage: TokenUsage = .zero) {
        self.lines = lines
        self.terms = terms
        self.usage = usage
    }
}

enum ContextReply {
    /// The reply text of an engine: `{"t": [{"id","text"}], "terms": [...]}`, today's `{"translations": [...]}`, or a bare
    /// array of strings. For `t`, the ids must be exactly 0..<count: a missing, extra or duplicate id is a
    /// `countMismatch` like a wrong count (`got` = the ids that were valid and distinct, or the entry count when that
    /// differs from `count`). Entries are put in id order.
    static func parse(content: String, count: Int) throws(ChatTranslationError) -> (lines: [String], terms: [TermHint]) {
        let json = ChatTranslation.extractJSON(content)
        guard let jsonData = json.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: jsonData)
        else { throw .malformed("content has no JSON") }
        if let obj = value as? [String: Any] {
            let terms = parseTerms(obj["terms"])
            if let t = obj["t"] { return (try lines(fromT: t, count: count), terms) }
            guard let list = obj["translations"] as? [String] else { throw .malformed("translations is not an array of strings") }
            guard list.count == count else { throw .countMismatch(expected: count, got: list.count) }
            return (list, terms)
        }
        guard let arr = value as? [String] else { throw .malformed("unexpected JSON shape") }
        guard arr.count == count else { throw .countMismatch(expected: count, got: arr.count) }
        return (arr, [])
    }

    private static func lines(fromT t: Any, count: Int) throws(ChatTranslationError) -> [String] {
        guard let entries = t as? [Any] else { throw .malformed("t is not an array") }
        var parsed: [(id: Int?, text: String)] = []
        for e in entries {
            if let s = e as? String { parsed.append((nil, s)); continue }
            guard let o = e as? [String: Any], let text = o["text"] as? String else { throw .malformed("t has an entry without text") }
            parsed.append((id(o["id"]), text))
        }
        // No ids at all: positional, like `{"translations": [...]}`.
        if parsed.allSatisfy({ $0.id == nil }) {
            guard parsed.count == count else { throw .countMismatch(expected: count, got: parsed.count) }
            return parsed.map(\.text)
        }
        guard parsed.count == count else { throw .countMismatch(expected: count, got: parsed.count) }
        let valid = Set(parsed.compactMap(\.id).filter { (0..<count).contains($0) })
        guard valid.count == count, parsed.allSatisfy({ $0.id != nil }) else {
            throw .countMismatch(expected: count, got: valid.count)
        }
        return parsed.sorted { $0.id! < $1.id! }.map(\.text)
    }

    private static func id(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double, d == d.rounded() { return Int(d) }
        if let s = v as? String { return Int(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    /// `terms` entries with a `src` and a `dst`; anything else is skipped. An unknown kind or gender is dropped, not the term.
    static func parseTerms(_ v: Any?) -> [TermHint] {
        guard let list = v as? [Any] else { return [] }
        return list.compactMap { e in
            guard let o = e as? [String: Any], let src = o["src"] as? String, let dst = o["dst"] as? String,
                  !src.isEmpty, !dst.isEmpty else { return nil }
            return TermHint(src: src, dst: dst, kind: (o["kind"] as? String).flatMap { EntryKind(rawValue: $0.lowercased()) },
                            gender: (o["gender"] as? String).flatMap { Gender(rawValue: $0.lowercased()) })
        }
    }
}
