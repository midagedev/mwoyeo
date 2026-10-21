import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct EnginePresetsTests {
    @Test func theListHasEveryPlannedPreset() {
        #expect(EnginePresets.all.map(\.name) == ["Gemini", "DeepSeek", "OpenAI", "OpenRouter", "Groq", "Qwen (Alibaba Cloud)", "Ollama",
                                                  "LM Studio", "Claude", "DeepL", "DeepL Free", "LibreTranslate", "DeepLX"])
        #expect(Set(EnginePresets.all.map(\.name)).count == EnginePresets.all.count)
    }

    @Test func everyPresetValidatesAndRoundTripsThroughShare() throws {
        for p in EnginePresets.all {
            if case let .httpTemplate(t) = p.config.kind { #expect(HTTPTemplate.validate(t).isEmpty, "\(p.name)") }
            let back = try EngineShare.decode(EngineShare.encode(p.config))
            #expect(back.kind == p.config.kind && back.name == p.config.name, "\(p.name)")
            #expect(p.instantiate().id != p.config.id)
        }
    }

    @Test func localPresetsNeedNoKeyAndHostedOnesDo() {
        for p in EnginePresets.all {
            if case let .openAICompatible(url, _, _, _) = p.config.kind {
                #expect(p.needsKey == !ChatTranslation.isOnThisMac(url), "\(p.name)")
                #expect(p.config.kind == .openAICompatible(baseURL: url, model: "", thinking: .off, extraHeaders: [:]))
            }
            #expect(!p.needsKey || p.keyURL != nil, "\(p.name)")
            #expect(!p.hint.isEmpty)
        }
    }

    /// 2026-10-21 (trust1): "DeepL Free" starts at the Free host with the memory on as DeepL instructions; `instantiate()` keeps that
    /// opt-in. 2026-10-21 (prof-file): the opt-in is `allow.deepLInstructions` now (design §4.1), and with the default amount (`memory`) a
    /// chain with a note makes `requestOptions` send it as DeepL's instructions.
    /// FAIL-first: before the row existed `first` was nil, and before `instantiate()` took the template's allow the engine had none.
    @Test func deepLFreeStartsWithTheMemorySentAsInstructions() throws {
        let p = try #require(EnginePresets.all.first { $0.name == "DeepL Free" })
        #expect(p.config.kind == .deepL(baseURL: URL(string: "https://api-free.deepl.com")!, formality: nil))
        #expect(p.needsKey && p.keyURL != nil)
        let engine = p.instantiate()
        #expect(engine.allow.deepLInstructions && engine.context == nil)
        #expect(engine.id != p.config.id)
        let note = AppProfile(bundleID: "com.example.chat", appName: "Chat", source: "en", target: "ko", note: "Casual.")
        let chain = ProfileChain.merge([.profile(note), .allApps], base: ChainBase())
        let options = ContextOptions.requestOptions(engine: engine, chain: chain)
        #expect(options.enabled && options.deepLInstructions && options.transcriptCount == 0)
        let plain = try #require(EnginePresets.all.first { $0.name == "DeepL" }).instantiate()
        #expect(plain.context == nil && plain.allow == .default, "the plain DeepL row is unchanged")
        #expect(ContextOptions.requestOptions(engine: plain, chain: chain) == .off, "plain DeepL gets nothing without the opt-in")
    }
}
