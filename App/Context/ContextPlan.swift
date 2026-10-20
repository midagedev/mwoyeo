import Foundation
import MwoyeoCore

/// What a call that came with a `LensContext` does, decided once at the top of `TranslationService.translate`. nil is today's path,
/// untouched (design §9: the default translation never changes; context works only where the user turned it on).
enum ContextPlan: Equatable {
    /// The added engine gets the document's context: the card, the note and names, the lines before and after. With
    /// `options.memoryOnly` it gets the card, the note and the matching names and nothing of the document.
    case engine(EngineConfig, ContextOptions, AppProfile?)
    /// Apple Translation gets the user's pinned names and terms put into its source text (`ApplePreinsertion`). Never the context
    /// path: Apple takes no context, whatever the app's override says.
    case applePins([MemoryEntry])

    /// Whether a lens has any use for the window it covers under these settings: the added engine could be On (the engine's switch or
    /// some app's override) or could send some app's written memory (the card needs the app), or Apple Translation has pinned terms
    /// to use. Anything else reads no window at all, so Off costs nothing.
    static func needsWindow(_ s: AppSettings) -> Bool {
        if let engine = s.activeEngineConfig {
            return LayoutKind.engine(engine.kind).tier != nil
                && (ContextOptions.couldBeOn(engine: engine, profiles: s.appProfiles)
                    || ContextOptions.memoryOnlyCouldApply(engine: engine, profiles: s.appProfiles))
        }
        // The pinned terms are the app's own names and the global glossary's pairs: the lens is read for either of them, for the
        // plan that carries them needs a lens.
        return s.appleUsesPinnedTerms && s.engine != .customModel
            && (s.appProfiles.contains { !$0.entries.isEmpty } || !s.glossaryPairs.isEmpty)
    }

    /// - `engine`: the added engine in use, nil for Apple.
    /// - `engineRests`: that engine is cooling down after a failure, so Apple stands in.
    /// - `profile`: the profile of the app under the lens (not the app in front).
    static func decide(settings: AppSettings, engine: EngineConfig?, engineRests: Bool, profile: AppProfile?) -> ContextPlan? {
        if let engine {
            // A resting engine is Apple's stand-in; an HTTP template or a command owns its body, so no context goes into it.
            guard !engineRests, LayoutKind.engine(engine.kind).tier != nil else { return nil }
            // The engine's switches and the app's override, else the app's written memory alone, else today's path.
            let options = ContextOptions.requestOptions(engine: engine, profile: profile)
            return options.enabled ? .engine(engine, options, profile) : nil
        }
        // Apple Translation: the profile's override may say On (`nearby` alone turns it on), and that changes nothing here. Only
        // the pinned names do, and only when the user turned them on and wrote some for this app or in the global glossary.
        guard settings.appleUsesPinnedTerms, settings.engine != .customModel else { return nil }
        // The app's own rows first, then the glossary's pairs the app's memory does not have (the app's row wins).
        let rows = ContextMemory.applePins(appRows: profile?.entries ?? [], glossary: settings.glossaryPairs)
        guard !rows.isEmpty else { return nil }
        return .applePins(rows)
    }
}
