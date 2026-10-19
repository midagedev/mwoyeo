import Foundation

/// What one added engine may be sent besides the lines to translate (design §3, §9, §10). Written in `settings.json` as
/// `engines[].context`; the names are those of `appProfiles[].context` (`AppContextOverride`), so a file keeps one vocabulary.
///
/// Every default is Off (design §9, the user's rule that the default translation never breaks and anything risky is
/// opt-in): an engine without a `context`, or with `enabled: false`, sends exactly today's request. Everything else here
/// says what a request carries once the user turned `enabled` on.
public struct EngineContext: Codable, Equatable, Sendable {
    /// False sends today's request, byte for byte, whatever the other fields say.
    public var enabled: Bool
    /// How many earlier lines go along, 0 to `AppContextOverride.maxPreviousLines`. Code that sets a value out of range gets
    /// the nearest end; a file that holds one gets `AppContextOverride.defaultPreviousLines` (see `init(from:)`).
    public var previousLines: Int { didSet { previousLines = AppContextOverride.clamped(previousLines) } }
    /// The window title may go to this engine although it is not on this Mac. On-device engines get it regardless.
    public var includeTitle: Bool
    /// Learned memory rows (the model's own suggestions) go into requests, and the reply's `terms` are recorded.
    public var useLearned: Bool
    /// DeepL only: `custom_instructions` and `formality` come from the memory. Other engine kinds ignore it.
    public var deepLInstructions: Bool

    public init(enabled: Bool = false, previousLines: Int = AppContextOverride.defaultPreviousLines, includeTitle: Bool = false,
                useLearned: Bool = false, deepLInstructions: Bool = false) {
        self.enabled = enabled
        self.previousLines = AppContextOverride.clamped(previousLines)
        self.includeTitle = includeTitle
        self.useLearned = useLearned
        self.deepLInstructions = deepLInstructions
    }

    // Read from a file, one rule shared with the settings-file check (a field it reports as "ignored" is the default): every
    // field is optional, and one that is missing or of the wrong type is its default. A `previousLines` that is not a whole
    // number or is outside 0...maxPreviousLines is `defaultPreviousLines`, as in `AppContextOverride`; the clamp is only for
    // values set in code. A `context` that is not an object at all is read as no context by `EngineConfig`.
    enum CodingKeys: String, CodingKey, CaseIterable { case enabled, previousLines, includeTitle, useLearned, deepLInstructions }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let lines = ((try? c.decodeIfPresent(Int.self, forKey: .previousLines)) ?? nil)
            .flatMap { (0...AppContextOverride.maxPreviousLines).contains($0) ? $0 : nil }
        self.init(enabled: (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false,
                  previousLines: lines ?? AppContextOverride.defaultPreviousLines,
                  includeTitle: (try? c.decodeIfPresent(Bool.self, forKey: .includeTitle)) ?? false,
                  useLearned: (try? c.decodeIfPresent(Bool.self, forKey: .useLearned)) ?? false,
                  deepLInstructions: (try? c.decodeIfPresent(Bool.self, forKey: .deepLInstructions)) ?? false)
    }
}

extension ContextOptions {
    /// The options an engine's own switches give, before any app override.
    ///
    /// - No context, or `enabled == false` → `ContextOptions()` (Off), whatever the other fields say.
    /// - `previousLines` → `transcriptCount`; more than `shortTranscript` lines also turn on `longTranscript`.
    /// - `useLearned` → `includeLearned`.
    /// - `includeTitle` and `deepLInstructions` are copied.
    /// - Every other field is its `ContextOptions()` default: `trusted` none, `includeUser` and `includeCard` true, `format` line.
    ///   The engine's switches say how much text goes along and what may leave this Mac, not which rows or card go in.
    public static func from(engine: EngineContext?) -> ContextOptions {
        guard let engine, engine.enabled else { return ContextOptions() }
        return ContextOptions(enabled: true, transcriptCount: engine.previousLines, includeLearned: engine.useLearned,
                              includeTitle: engine.includeTitle, deepLInstructions: engine.deepLInstructions,
                              longTranscript: engine.previousLines > shortTranscript)
    }

    /// The options one request is built with: the engine's switches with the frontmost app's override laid over them
    /// (`resolved(base:override:)`). `engine` is nil for Apple Translation; `profile` is nil when no profile applies.
    ///
    /// An override of `nearby` or `conversation` turns context on even when the engine has no context of its own: writing
    /// the override in the app's profile is the user's opt-in (design §9). The base stays Off, so nothing else is on.
    public static func effective(engine: EngineConfig?, profile: AppProfile?) -> ContextOptions {
        resolved(base: .from(engine: engine?.context), override: profile?.context)
    }

    // MARK: memory only (lead decision D1, 2026-10-19)

    /// The options of "memory only": the card, the note and the matching rows of the app, and nothing else. Nil when it does not
    /// apply: no engine (Apple takes no context), an engine that owns its body (a template, a command) or takes the memory only
    /// through its own opt-in (DeepL: `deepLInstructions`), no profile or a profile with neither a note nor a name, or an app
    /// whose override is `off` (off turns this off too).
    ///
    /// It is the case of an engine that is off: `requestOptions(engine:profile:)` asks only when `effective` is Off. Writing the
    /// note or the names is the user's opt-in (design §9); the lines and the title stay behind their own switches.
    public static func memoryOnlyOptions(engine: EngineConfig?, profile: AppProfile?) -> ContextOptions? {
        guard let engine, let profile, profile.hasMemory, profile.context?.mode != .off,
              LayoutKind.engine(engine.kind).tier != nil else { return nil }
        if case .deepL = engine.kind { return nil }
        return ContextOptions(enabled: true, transcriptCount: 0, memoryOnly: true)
    }

    /// Whether some profile could make `memoryOnlyOptions` apply to `engine`: the lens then reads the window it covers, for the
    /// app's name and category (the card). "Possibly": the app under the lens decides.
    public static func memoryOnlyCouldApply(engine: EngineConfig?, profiles: [AppProfile]) -> Bool {
        profiles.contains { memoryOnlyOptions(engine: engine, profile: $0) != nil }
    }

    /// What one request to `engine` is built with for the app of `profile`: the explicit switches (`effective`) when they say
    /// On, else memory only when the user wrote some memory for the app, else Off. Off is `ContextOptions()`: today's request.
    public static func requestOptions(engine: EngineConfig?, profile: AppProfile?) -> ContextOptions {
        let explicit = effective(engine: engine, profile: profile)
        if explicit.enabled { return explicit }
        return memoryOnlyOptions(engine: engine, profile: profile) ?? explicit
    }
}
