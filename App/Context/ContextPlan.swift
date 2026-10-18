import Foundation
import MwoyeoCore

/// What a call that came with a `LensContext` does, decided once at the top of `TranslationService.translate`. nil is today's path,
/// untouched (design §9: the default translation never changes; context works only where the user turned it on).
enum ContextPlan: Equatable {
    /// The added engine gets the document's context: the card, the note and names, the lines before and after.
    case engine(EngineConfig, ContextOptions, AppProfile?)
    /// Apple Translation gets the user's pinned names and terms put into its source text (`ApplePreinsertion`). Never the context
    /// path: Apple takes no context, whatever the app's override says.
    case applePins([MemoryEntry])

    /// Whether a lens has any use for the window it covers under these settings: the added engine could be On (the engine's switch or
    /// some app's override), or Apple Translation has pinned terms to use. Anything else reads no window at all, so Off costs nothing.
    static func needsWindow(_ s: AppSettings) -> Bool {
        if let engine = s.activeEngineConfig {
            return LayoutKind.engine(engine.kind).tier != nil && ContextOptions.couldBeOn(engine: engine, profiles: s.appProfiles)
        }
        return s.appleUsesPinnedTerms && s.engine != .customModel && s.appProfiles.contains { !$0.entries.isEmpty }
    }

    /// - `engine`: the added engine in use, nil for Apple.
    /// - `engineRests`: that engine is cooling down after a failure, so Apple stands in.
    /// - `profile`: the profile of the app under the lens (not the app in front).
    static func decide(settings: AppSettings, engine: EngineConfig?, engineRests: Bool, profile: AppProfile?) -> ContextPlan? {
        if let engine {
            // A resting engine is Apple's stand-in; an HTTP template or a command owns its body, so no context goes into it.
            guard !engineRests, LayoutKind.engine(engine.kind).tier != nil else { return nil }
            let options = ContextOptions.effective(engine: engine, profile: profile)
            return options.enabled ? .engine(engine, options, profile) : nil
        }
        // Apple Translation: the profile's override may say On (`nearby` alone turns it on), and that changes nothing here. Only
        // the pinned names do, and only when the user turned them on and wrote some for this app.
        guard settings.appleUsesPinnedTerms, settings.engine != .customModel, let profile, !profile.entries.isEmpty else { return nil }
        return .applePins(profile.entries)
    }
}
