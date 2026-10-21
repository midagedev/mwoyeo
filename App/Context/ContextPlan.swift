import Foundation
import MwoyeoCore

/// What a call that came with a `LensContext` does, decided once at the top of `TranslationService.translate`. nil is today's path,
/// untouched (design §9: the default translation never changes; context works only where the user turned it on).
enum ContextPlan: Equatable {
    /// The added engine gets the document's context: the card, the note and names, the lines before and after. With
    /// `options.memoryOnly` it gets the card, the note and the matching names and nothing of the document. `replace` are the rows
    /// written into the line being translated (design §10); the hint rows are chosen on the original line, so a `both` row is both.
    case engine(EngineConfig, ContextOptions, MergedChain, replace: [MemoryEntry])
    /// The kinds that take no hints (Apple Translation, Foundation Models for profile rows, a template, a command), and an engine whose
    /// request is Off, get the replace rows written into the source text and nothing else (design §10: "Apple pre-insertion is the replace
    /// mode, not a path of its own"). Never the context path: they take no context, whatever the amount says.
    case replaceOnly([MemoryEntry])

    /// Whether a lens has any use for the window it covers under these settings: a name or term is written into the text (which profile
    /// applies is decided by the window), or the added engine could be sent more than the line (design §4.2, asked of the request table over
    /// `ContextRoute.candidates`): lines around the text, or the card, the note and the names. Anything else reads no window at all, so Off
    /// costs nothing.
    static func needsWindow(_ s: AppSettings) -> Bool {
        if s.hasReplaceRows { return true }
        guard let engine = s.activeEngineConfig else { return false }
        return ContextRoute.candidates(s).contains { ContextOptions.requestOptions(engine: engine, chain: $0.chain).enabled }
    }

    /// - `engine`: the added engine in use, nil for Apple.
    /// - `engineRests`: that engine is cooling down after a failure, so Apple stands in.
    /// - `chain`: the chain of the window under the lens, merged (`ContextRoute.pair`).
    static func decide(settings: AppSettings, engine: EngineConfig?, engineRests: Bool, chain: MergedChain) -> ContextPlan? {
        // Every kind takes the replace rows: they are free and cost the engine nothing it does not already do (design §10). Foundation Models
        // has the glossary in its instructions (`RequestLayout.foundationModelsInstructions`), so it is given the profiles' rows alone.
        let followsGlossary = engine == nil && settings.engine == .customModel
        let replace = followsGlossary
            ? ContextMemory.replaceRows(rows: chain.rows.map(\.entry), glossary: [], glossaryApply: .hint)
            : ContextMemory.replaceRows(chain: chain)
        if let engine, !engineRests, LayoutKind.engine(engine.kind).tier != nil {
            // The request table (design §4.2): what the chain wants, cut to what the engine allows and its kind takes.
            let options = ContextOptions.requestOptions(engine: engine, chain: chain)
            if options.enabled { return .engine(engine, options, chain, replace: replace) }
        }
        // Apple Translation, a resting engine's stand-in, a template, a command, Foundation Models, or an engine with nothing to send: today's
        // path, with the replace rows in the source when there are any.
        return replace.isEmpty ? nil : .replaceOnly(replace)
    }
}
