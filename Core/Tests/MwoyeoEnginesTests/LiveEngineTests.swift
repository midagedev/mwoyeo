import Foundation
import Testing
import MwoyeoCore
@testable import MwoyeoEngines

/// Real providers. Skipped unless `MWOYEO_LIVE=1`; keys come from the environment and are never printed.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MWOYEO_LIVE"] == "1")) struct LiveEngineTests {
    private func env(_ name: String) throws -> String {
        try #require(ProcessInfo.processInfo.environment[name].flatMap { $0.isEmpty ? nil : $0 }, "\(name) is not set")
    }

    private func translateOnce(_ label: String, preset: String, model: String, keyVar: String) async throws {
        var engine = try #require(EnginePresets.all.first { $0.name == preset }).instantiate()
        switch engine.kind {
        case let .openAICompatible(url, _, thinking, headers):
            engine.kind = .openAICompatible(baseURL: url, model: model, thinking: thinking, extraHeaders: headers)
        case let .anthropic(url, _, thinking):
            engine.kind = .anthropic(baseURL: url, model: model, thinking: thinking)
        default: break
        }
        let client = EngineClient(secrets: MemorySecrets([engine.id: try env(keyVar)]))
        let r = await client.probe(engine, target: "ko")
        print("LIVE \(label): \(r.ms) ms, sample=\(r.sample ?? "nil"), error=\(r.error.map { "\($0)" } ?? "none")")
        #expect(r.error == nil)
        #expect(r.sample?.isEmpty == false)
    }

    @Test func liveGemini() async throws {
        try await translateOnce("gemini", preset: "Gemini", model: "gemini-3.1-flash-lite", keyVar: "GEMINI_API_KEY")
    }

    @Test func liveOpenAI() async throws {
        try await translateOnce("openai", preset: "OpenAI", model: "gpt-5.6-luna", keyVar: "OPENAI_API_KEY")
    }

    @Test func liveClaude() async throws {
        try await translateOnce("claude", preset: "Claude", model: "claude-haiku-5-5", keyVar: "MWOYEO_CLAUDE_API_KEY")
    }

    @Test func liveDeepL() async throws {
        try await translateOnce("deepl", preset: "DeepL", model: "", keyVar: "DEEPL_API_KEY")
    }

    @Test func liveSecondCallReusesTheConnection() async throws {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var reused: [Bool] = []
            var ms: [Double] = []
        }
        let box = Box()
        var engine = try #require(EnginePresets.all.first { $0.name == "Gemini" }).instantiate()
        if case let .openAICompatible(url, _, thinking, headers) = engine.kind {
            engine.kind = .openAICompatible(baseURL: url, model: "gemini-3.1-flash-lite", thinking: thinking, extraHeaders: headers)
        }
        let client = EngineClient(secrets: MemorySecrets([engine.id: try env("GEMINI_API_KEY")])) { m in
            guard let t = m.transactionMetrics.last else { return }
            box.lock.withLock {
                box.reused.append(t.isReusedConnection)
                box.ms.append(m.taskInterval.duration * 1000)
            }
        }
        for _ in 0..<2 {
            _ = try await client.translate(["Good morning."], source: nil, target: "ko", glossary: [], engine: engine)
        }
        let (reused, ms) = box.lock.withLock { (box.reused, box.ms) }
        print("LIVE gemini reuse: isReusedConnection=\(reused), ms=\(ms.map { Int($0) })")
        #expect(reused.count == 2)
        #expect(reused.last == true)
    }
}
