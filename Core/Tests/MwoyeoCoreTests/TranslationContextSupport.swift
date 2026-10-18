import Foundation
@testable import MwoyeoCore

/// Fixtures and builders shared by the TranslationContext tests.
enum CtxFix {
    /// `Core/Tests/Fixtures` (outside the test target, so SwiftPM does not see them as resources).
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func fixture(_ path: String) -> Data {
        guard let d = try? Data(contentsOf: fixtures.appendingPathComponent(path)) else { fatalError("missing fixture \(path)") }
        return d
    }

    static func json(_ d: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: d) as? [String: Any]) ?? [:]
    }

    // The inputs the Off goldens were recorded with (main 93e6acc, `DumpGolden`).
    static let lines = ["Hello \"you\"", "안녕 / ok", "こんにちは\n二行目"]
    static let glossary = [("Mwoyeo", "뭐여"), ("Alice", "앨리스")]

    static let alice = MemoryEntry(src: "アリス", dst: "앨리스", kind: .person, gender: .f, note: "20s, shy",
                                   addressing: [Addressing(to: "ボブ", register: .casual)])
    static let bob = MemoryEntry(src: "ボブ", dst: "밥", kind: .person, gender: .m)
    static let tanaka = MemoryEntry(src: "田中", dst: "다나카", kind: .person, gender: .m, note: "boss", reading: "たなか")
    static let skill = MemoryEntry(src: "ファイアボール", dst: "파이어볼", kind: .term)

    /// Every switch the context layouts read, on. `ContextOptions()` is Off (design §9), so the layout tests start from this.
    static let on = ContextOptions(enabled: true, includeLearned: true, deepLInstructions: true)

    static let card = DocumentCard(appName: "Messages", domain: "social", title: "Alice Smith")

    /// A request that carries everything a layout may use.
    static func rich(items: [String] = ["アリスは田中に言った", "ボブは来た"], target: String = "ko", source: String? = "ja",
                     memory: [MemoryEntry]? = nil, before: [ContextLine]? = nil, after: [String]? = nil,
                     glossary: [(String, String)] = [], note: String = "Close friends, casual chat.",
                     referents: [Referent] = [Referent(pronoun: "he/그", refersTo: "田中")]) -> ContextRequest {
        ContextRequest(
            items: items,
            before: before ?? [ContextLine(source: "前の行1", translation: "이전 줄 1", trusted: true), ContextLine(source: "前の行2", translation: "이전 줄 2", trusted: false)],
            after: after ?? ["次の行"],
            memory: memory ?? [alice, tanaka, bob, skill],
            card: card, note: note, referents: referents, source: source, target: target, glossary: glossary,
            threadKey: ThreadKey(bundleID: "com.apple.MobileSMS", title: "Alice Smith", pair: LanguagePair("ja", "ko"), engineID: "E1").cacheKey)
    }

    static func openAI(_ host: String = "https://api.openai.com/v1", model: String = "gpt-5.4-mini", thinking: Thinking = .off) -> EngineKind {
        .openAICompatible(baseURL: URL(string: host)!, model: model, thinking: thinking, extraHeaders: [:])
    }

    static let local = openAI("http://localhost:11434/v1", model: "qwen3.5")
    static let anthropic = EngineKind.anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "claude-haiku-5-5", thinking: .off)

    /// The text of the last message (the user message) of a chat-style body, parsed.
    static func lastMessage(_ body: Data) -> [String: Any] {
        let root = json(body)
        let messages = root["messages"] as? [[String: Any]] ?? []
        let content = messages.last?["content"] as? String ?? "{}"
        return json(Data(content.utf8))
    }

    static func systemText(_ body: Data) -> String {
        let root = json(body)
        if let s = root["system"] as? String { return s }
        if let blocks = root["system"] as? [[String: Any]] { return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        return ((root["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
    }

    /// How many `cache_control` keys appear anywhere in the JSON.
    static func markerCount(_ any: Any) -> Int {
        if let o = any as? [String: Any] { return o.reduce(0) { $0 + ($1.key == "cache_control" ? 1 : 0) + markerCount($1.value) } }
        if let a = any as? [Any] { return a.reduce(0) { $0 + markerCount($1) } }
        return 0
    }

    static func text(_ d: Data) -> String { String(decoding: d, as: UTF8.self) }
}
