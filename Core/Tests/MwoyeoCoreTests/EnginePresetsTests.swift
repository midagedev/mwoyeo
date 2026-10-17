import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct EnginePresetsTests {
    @Test func theListHasEveryPlannedPreset() {
        #expect(EnginePresets.all.map(\.name) == ["Gemini", "DeepSeek", "OpenAI", "OpenRouter", "Groq", "Qwen (Alibaba Cloud)", "Ollama",
                                                  "LM Studio", "Claude", "DeepL Free", "DeepL Pro", "LibreTranslate", "DeepLX"])
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
}
