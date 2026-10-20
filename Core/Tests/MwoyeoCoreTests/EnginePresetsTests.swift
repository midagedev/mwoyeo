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

    /// 2026-10-21 (trust1): "DeepL Free" starts at the Free host with the memory on as DeepL instructions; `instantiate()` keeps that context.
    /// FAIL-first: before the row existed `first` was nil, and before `instantiate()` took the template's context the engine had none.
    @Test func deepLFreeStartsWithTheMemorySentAsInstructions() throws {
        let p = try #require(EnginePresets.all.first { $0.name == "DeepL Free" })
        #expect(p.config.kind == .deepL(baseURL: URL(string: "https://api-free.deepl.com")!, formality: nil))
        #expect(p.needsKey && p.keyURL != nil)
        let engine = p.instantiate()
        #expect(engine.context?.enabled == true && engine.context?.deepLInstructions == true)
        #expect(engine.id != p.config.id)
        let plain = try #require(EnginePresets.all.first { $0.name == "DeepL" }).instantiate()
        #expect(plain.context == nil, "the plain DeepL row is unchanged")
    }
}
