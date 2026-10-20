import Foundation
import Testing
@testable import MwoyeoCore

/// "Off sends exactly today's request": every body below was recorded from a build of main 93e6acc (not from this tree)
/// with the inputs in `CtxFix.lines` and `CtxFix.glossary`, and is compared byte for byte. The request passed in carries
/// a card, a note, rows, lines before and after and referents; with `ContextOptions.off` none of it may show.
@Suite struct TranslationContextGoldenTests {
    private func off(_ kind: LayoutKind, source: String?, target: String, glossary: [(String, String)],
                     options: ContextOptions = .off) -> Data {
        var request = CtxFix.rich(items: CtxFix.lines, target: target, source: source, glossary: glossary)
        request.threadKey = "mwoyeo-0123456789abcdef"
        return RequestLayout.body(kind: kind, request: request, options: options)
    }

    /// Both `.off` and a bare `ContextOptions()` must give the recorded body (design §9: the default is Off).
    private func check(_ name: String, _ kind: LayoutKind, source: String?, target: String, glossary: [(String, String)]) {
        let want = CtxFix.fixture("off-main-93e6acc/\(name).json")
        let got = off(kind, source: source, target: target, glossary: glossary)
        #expect(got == want, "\(name): \(CtxFix.text(got)) != \(CtxFix.text(want))")
        let byDefault = off(kind, source: source, target: target, glossary: glossary, options: ContextOptions())
        #expect(byDefault == want, "\(name) with the default options: \(CtxFix.text(byDefault)) != \(CtxFix.text(want))")
    }

    @Test func openAICompatibleOffIsToday() {
        let generic = LayoutKind.engine(CtxFix.openAI("https://llm.example.com/v1", model: "m1"))
        check("openai-plain", generic, source: "en", target: "ko", glossary: [])
        check("openai-plain-gloss", generic, source: nil, target: "ja", glossary: CtxFix.glossary)
        check("openai-ollama", .engine(CtxFix.openAI("http://localhost:11434/v1", model: "qwen3.5")), source: "ja", target: "en", glossary: CtxFix.glossary)
        check("openai-gpt5nano", .engine(CtxFix.openAI("https://api.openai.com/v1", model: "gpt-5-nano")), source: "en", target: "ko", glossary: CtxFix.glossary)
        check("openai-gpt54mini-provider", .engine(CtxFix.openAI("https://api.openai.com/v1", model: "gpt-5.4-mini", thinking: .provider)),
              source: "en", target: "ko", glossary: CtxFix.glossary)
        check("openai-gemini", .engine(CtxFix.openAI("https://generativelanguage.googleapis.com/v1beta/openai", model: "gemini-3.5-flash-lite")),
              source: "en", target: "ko", glossary: [])
    }

    /// anthropic-haiku.json and anthropic-nosource.json were re-pinned 2026-10-21 (round trust1); the other fixtures are main 93e6acc's bytes.
    /// Derivation: Claude 5 thinks when `thinking` is left out (haiku-5-5 measured 2026-10-21, film 2: a thinking block and ~500 output tokens
    /// a call), so `.off` now sends the model's own off switch (haiku-5-5 `thinking: {type: disabled}`, sonnet-5-5 `{type: between_tools}`:
    /// `disabled` is a 400 there; the claude-api skill, cached 2026-10-06), and both bodies carry `output_config.format`, the reply's JSON
    /// schema (`ModelQuirks.structuredReply`). Both bodies were sent to the API on 2026-10-21 and answered 200 with the schema's shape.
    /// FAIL-first: against the old fixtures the new code failed at the two `got == want` lines (/tmp/trust1/failfirst-1.log).
    @Test func anthropicOffIsToday() {
        let haiku = LayoutKind.engine(.anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "claude-haiku-5-5", thinking: .off))
        check("anthropic-haiku", haiku, source: "en", target: "ko", glossary: CtxFix.glossary)
        let sonnet = LayoutKind.engine(.anthropic(baseURL: EngineKind.anthropicDefaultBaseURL, model: "claude-sonnet-5-5", thinking: .off))
        check("anthropic-nosource", sonnet, source: nil, target: "ja", glossary: [])
    }

    @Test func deepLOffIsToday() {
        let base = URL(string: "https://api.deepl.com")!
        check("deepl-plain", .engine(.deepL(baseURL: base, formality: nil)), source: "en", target: "ko", glossary: CtxFix.glossary)
        check("deepl-formal", .engine(.deepL(baseURL: base, formality: "prefer_more")), source: nil, target: "ja", glossary: [])
        check("deepl-ptbr", .engine(.deepL(baseURL: base, formality: "less")), source: "en", target: "pt-BR", glossary: [])
    }

    /// The Apple model's pair, recorded from TranslationService.swift:901-917 and the `ask` at :866 of main 93e6acc.
    @Test func foundationModelsOffIsToday() throws {
        for (name, glossary) in [("fm-instructions-ja-ko", [(String, String)]()), ("fm-instructions-ja-ko-gloss", CtxFix.glossary)] {
            for options in [ContextOptions.off, ContextOptions()] {
                let body = off(.appleFoundationModels, source: "ja", target: "ko", glossary: glossary, options: options)
                let o = CtxFix.json(body)
                #expect(o["instructions"] as? String == CtxFix.text(CtxFix.fixture("off-main-93e6acc/\(name).txt")))
                #expect(o["prompt"] as? String == "Translate into Korean:\n" + CtxFix.lines.joined(separator: "\n"))
            }
        }
    }

    /// Off needs no request fields besides the lines: the same bodies come out of an empty request.
    @Test func offIgnoresEverythingButTheLines() {
        let bare = ContextRequest(items: CtxFix.lines, source: "en", target: "ko", glossary: CtxFix.glossary)
        let rich = CtxFix.rich(items: CtxFix.lines, target: "ko", source: "en", glossary: CtxFix.glossary)
        for kind in [CtxFix.openAI(), CtxFix.local, CtxFix.anthropic, .deepL(baseURL: URL(string: "https://api.deepl.com")!, formality: nil)] {
            #expect(RequestLayout.body(kind: kind, request: bare, options: .off) == RequestLayout.body(kind: kind, request: rich, options: .off))
        }
        #expect(RequestLayout.body(kind: .appleFoundationModels, request: bare, options: .off)
                == RequestLayout.body(kind: .appleFoundationModels, request: rich, options: .off))
    }

    /// The old engine API is a wrapper around the same builders: its body equals the Off layout's.
    @Test func oldRequestBodiesEqualOffLayout() {
        let request = ContextRequest(items: CtxFix.lines, source: "en", target: "ko", glossary: CtxFix.glossary)
        let kind = CtxFix.openAI("https://api.openai.com/v1", model: "gpt-5-nano")
        #expect(RequestLayout.body(kind: kind, request: request, options: .off)
                == ChatTranslation.requestBody(lines: CtxFix.lines, source: "en", target: "ko", glossary: CtxFix.glossary, model: "gpt-5-nano",
                                               baseURL: URL(string: "https://api.openai.com/v1")))
    }

    /// An HTTP template and a command engine are the user's: no context goes in, On or Off.
    @Test func commandEngineBodyIsUntouched() {
        let kind = EngineKind.command(CommandSpec(executable: "/bin/cat"))
        let request = CtxFix.rich(items: ["a", "b"], target: "ko", source: nil)
        let expected = CommandEngine.encodeRequest(lines: ["a", "b"], source: nil, target: "ko")
        #expect(RequestLayout.body(kind: kind, request: request, options: .off) == expected)
        #expect(RequestLayout.body(kind: kind, request: request, options: ContextOptions()) == expected)
    }

    @Test func httpTemplateBodyIsTheTemplatesOwn() throws {
        let template = HTTPTemplate(url: "https://tr.example.com/translate", body: "{\"q\": {{lines}}, \"target\": \"{{target}}\"}",
                                    resultPath: "translations[*].text", batching: .jsonArray)
        let request = CtxFix.rich(items: ["a", "b"], target: "ko", source: nil)
        let expected = try HTTPTemplate.requests(template, lines: ["a", "b"], source: nil, target: "ko", key: nil).first?.body
        #expect(expected != nil)
        #expect(RequestLayout.body(kind: .httpTemplate(template), request: request, options: .off) == expected)
        #expect(RequestLayout.body(kind: .httpTemplate(template), request: request, options: ContextOptions()) == expected)
        #expect(LayoutKind.engine(.httpTemplate(template)).tier == nil && LayoutKind.engine(.command(CommandSpec(executable: "x"))).tier == nil)
    }
}
