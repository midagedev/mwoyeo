import Foundation
import Testing
@testable import MwoyeoCore

/// `RequestLayout.foundationModelsInstructions` is the one copy of the Apple Foundation Models session instructions; the app's
/// `IntelligenceTranslator.session(source:target:glossary:)` calls it. The text must stay what main 93e6acc sent.
@Suite struct FoundationModelsInstructionsTests {
    /// The body of the app's own function before round T3a-1 replaced it with a call (TranslationService.swift, main 7c67d1d),
    /// copied character for character. It is the reference every pair and glossary shape below is compared with.
    private func appInstructionsAtMain(source: String?, target: String, glossary: [(String, String)]) -> String {
        let en = Locale(identifier: "en")
        let targetName = en.localizedString(forIdentifier: target) ?? target
        let sourceName = source.flatMap { en.localizedString(forIdentifier: $0) } ?? "the source language"
        var instructions = """
        You translate text captured from a computer screen — apps, games, web pages, comics, video subtitles — \
        from \(sourceName) into natural, fluent \(targetName).
        Rules:
        - Reply with the translation only: no quotes, labels, explanations, romanization or notes.
        - Keep it about as short as the original; it replaces UI labels and captions in place. Match the original's register.
        - Keep numbers, units, names, product names, keyboard shortcuts and placeholders like %@ or {0} unchanged.
        """
        if !glossary.isEmpty {
            instructions += "\nGlossary — always use these translations:\n"
            instructions += glossary.map { "- \($0.0) → \($0.1)" }.joined(separator: "\n")
        }
        return instructions
    }

    @Test func theRecordedInstructionsAreWhatTheCoreFunctionReturns() {
        for (name, glossary) in [("fm-instructions-ja-ko", [(String, String)]()), ("fm-instructions-ja-ko-gloss", CtxFix.glossary)] {
            let want = CtxFix.text(CtxFix.fixture("off-main-93e6acc/\(name).txt"))
            #expect(RequestLayout.foundationModelsInstructions(source: "ja", target: "ko", glossary: glossary) == want, "\(name)")
        }
    }

    /// Every source and target the app offers (Languages.sources and targets, plus nil for the prewarm session), against the
    /// glossary shapes `AppSettings.glossaryPairs` can produce: none, one pair, several, non-ASCII, and text that looks like
    /// markup or a placeholder.
    @Test func theCoreFunctionEqualsTheAppsFunctionForEveryPairAndGlossaryShape() {
        let sources: [String?] = [nil, "auto", "en", "ja", "ko", "zh-Hans", "zh-Hant", "fr", "de", "es", "it", "pt-BR", "ru", "uk", "vi", "th"]
        let targets = ["en", "ko", "ja", "zh-Hans", "zh-Hant", "fr", "de", "es", "it", "pt-BR", "ru", "uk", "vi", "th"]
        let glossaries: [[(String, String)]] = [
            [],
            [("Mwoyeo", "뭐여")],
            CtxFix.glossary,
            [("田中", "Tanaka"), ("花", "Hana"), ("Tarou", "タロウ")],
            [("%@ items", "{0} 개"), ("a → b", "c = d"), ("\"quoted\"", "<tag>")],
        ]
        var compared = 0
        for source in sources {
            for target in targets {
                for glossary in glossaries {
                    let got = RequestLayout.foundationModelsInstructions(source: source, target: target, glossary: glossary)
                    let want = appInstructionsAtMain(source: source, target: target, glossary: glossary)
                    #expect(got == want, "\(String(describing: source)) → \(target), \(glossary.count) pairs")
                    compared += 1
                }
            }
        }
        #expect(compared == sources.count * targets.count * glossaries.count)
    }

    /// The Off layout of the Foundation Models kind builds its instructions with the same function.
    @Test func theOffLayoutUsesTheSameInstructions() throws {
        let request = ContextRequest(items: ["こんにちは"], source: "ja", target: "ko", glossary: CtxFix.glossary)
        let body = RequestLayout.body(kind: .appleFoundationModels, request: request, options: .off)
        let object = CtxFix.json(body)
        #expect(object["instructions"] as? String == RequestLayout.foundationModelsInstructions(source: "ja", target: "ko", glossary: CtxFix.glossary))
    }
}
