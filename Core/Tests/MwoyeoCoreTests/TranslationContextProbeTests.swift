import Foundation
import Testing
@testable import MwoyeoCore

/// Debug probes, off unless `MWOYEO_CTX_PROBE=<output dir>` is set (`MWOYEO_CTX_PROBE=/tmp/x swift test --filter Probe`).
/// They write one sample request per engine and print the size of each part and the host time of the layout, so the
/// numbers in a report come from the code and not from a hand count. No assertions on timing: a loaded machine must not fail a gate.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MWOYEO_CTX_PROBE"] != nil)) struct TranslationContextProbeTests {
    private var outDir: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MWOYEO_CTX_PROBE"] ?? "/tmp") }

    private func sampleRequest() -> ContextRequest {
        CtxFix.rich(items: ["アリスは田中に言った。", "ボブは来なかった。"], target: "ko", source: "ja",
                    glossary: [("ファイアボール", "파이어볼")])
    }

    @Test func sampleRequestsAndSizes() throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let deepL = EngineKind.deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil)
        let kinds: [(String, LayoutKind)] = [
            ("openai", .engine(CtxFix.openAI())), ("local", .engine(CtxFix.local)), ("anthropic", .engine(CtxFix.anthropic)),
            ("deepl", .engine(deepL)), ("fm", .appleFoundationModels),
        ]
        var optIn = CtxFix.on
        optIn.includeTitle = false
        for (name, kind) in kinds {
            let on = RequestLayout.body(kind: kind, request: sampleRequest(), options: ContextOptions(enabled: true, trusted: .trusted, includeLearned: true))
            let off = RequestLayout.body(kind: kind, request: sampleRequest(), options: .off)
            try on.write(to: outDir.appendingPathComponent("\(name)-on.json"))
            try off.write(to: outDir.appendingPathComponent("\(name)-off.json"))
            print("PROBE \(name): off \(off.count) B, on \(on.count) B, on approxTokens \(approxTokens(CtxFix.text(on)))")
        }
        let rules = RequestLayout.rules(source: "ja", target: "ko", glossary: [], wantsTerms: true)
        print("PROBE rules: \(rules.count) chars, \(approxTokens(rules)) approxTokens; today's system prompt: "
              + "\(approxTokens(ChatTranslation.systemPrompt(source: "ja", target: "ko", glossary: [])))")
        let p = RequestLayout.prepare(sampleRequest(), CtxFix.on, .engine(CtxFix.anthropic))
        print("PROBE card \(approxTokens(p.card ?? "")) tok, note \(approxTokens(p.note)) tok, "
              + "rows \(p.rows.map { approxTokens(RequestLayout.renderLine($0)) + 1 }) tok, "
              + "last message \(approxTokens(RequestLayout.lastMessage(items: sampleRequest().items, p))) tok")
    }

    /// Host time of the layout for the largest request the budgets allow: 40 user rows and 30 learned rows (all hits),
    /// 20 items, 8 lines before, 2 after, a 500-character note, on every cloud-or-local engine.
    @Test func hostTimeOfTheLayout() {
        let rows = (0..<70).map { MemoryEntry(src: "名前\($0)", dst: "이름\($0)", kind: .person, gender: .f, note: "ten words of a note, no more",
                                              origin: $0 < 40 ? .user : .learned, uses: $0) }
        let items = (0..<20).map { i in "名前\(i * 3)は「こんにちは」と言った。" + String(repeating: "あ", count: 40) }
        let request = ContextRequest(items: items, before: (0..<8).map { ContextLine(source: String(repeating: "前", count: 100) + "\($0)") },
                                     after: ["次1", "次2"], memory: rows, card: CtxFix.card, note: String(repeating: "あ", count: 500),
                                     referents: [Referent(pronoun: "he", refersTo: "田中")], source: "ja", target: "ko", threadKey: "k")
        let clock = ContinuousClock()
        for (name, kind) in [("anthropic", LayoutKind.engine(CtxFix.anthropic)), ("local", .engine(CtxFix.local)), ("fm", .appleFoundationModels)] {
            _ = RequestLayout.body(kind: kind, request: request, options: CtxFix.on)          // warm
            let n = 50
            let start = clock.now
            var bytes = 0
            for _ in 0..<n { bytes = RequestLayout.body(kind: kind, request: request, options: CtxFix.on).count }
            let ms = Double((clock.now - start) / .nanoseconds(1)) / 1e6 / Double(n)
            print("PROBE host \(name): \(String(format: "%.3f", ms)) ms per request, \(bytes) B")
        }
    }
}
