import MwoyeoCore

/// The "Sent: …" line of one app (design §3): what the engine in effect for the app's profile would be sent, by the same rule
/// the request path uses (`ContextOptions.requestOptions`) and the same layout (`RequestLayout.sentSummary`). Pure.
enum ContextPreview {
    /// - `engine`: the added engine in effect for the app; nil is Apple Translation, which takes no context.
    /// - `category`: the app's `LSApplicationCategoryType`, for the card's domain word.
    /// - `learnedUsable`: how many learned rows the app has that a request may use (`LearnedCounts.usable`); they count only while
    ///   the engine's `useLearned` is on.
    /// - `glossary`: the global glossary's pairs, which go along with every request and count as the names of all apps.
    static func summary(engine: EngineConfig?, profile: AppProfile?, appName: String, category: String?, learnedUsable: Int,
                        glossary: [(String, String)] = []) -> SentSummary {
        guard let engine else { return SentSummary(mode: .linesOnly) }
        let options = ContextOptions.requestOptions(engine: engine, profile: profile)
        // Learned rows are in the translator; each counts as an average-sized row against the engine's row budget.
        let learned = options.includeLearned ? (0..<min(learnedUsable, ContextMemory.maxLearned)).map {
            MemoryEntry(src: "learned\($0)", dst: "learned", kind: .term, origin: .learned)
        } : []
        return RequestLayout.sentSummary(options: options, kind: .engine(engine.kind), engineName: engine.name, appName: appName,
                                         domain: CategoryDomain.word(for: category), note: profile?.note ?? "",
                                         rows: (profile?.entries ?? []) + learned, glossary: glossary)
    }

    /// The engine sheet's "Sent:" line, true for the settings as they stand (design §3, D1). An app that wrote a note or names puts
    /// the engine on the memory it sends (`EnginePermissions.memoryProfiles`): the line describes the first such app, as the request
    /// path would send it. With none, it describes a sample app under the engine's own switches.
    /// - `category`: the category of an app by its bundle id (`AppModel.category(ofApp:)`).
    static func engineSummary(engine: EngineConfig, profiles: [AppProfile], category: (String) -> String?, glossary: [(String, String)] = [],
                              sampleApp: String = "Example Chat", sampleCategory: String? = "public.app-category.social-networking") -> SentSummary {
        if let p = EnginePermissions.memoryProfiles(engine, profiles: profiles).first {
            return summary(engine: engine, profile: p, appName: p.appName, category: category(p.bundleID), learnedUsable: 0, glossary: glossary)
        }
        return summary(engine: engine, profile: nil, appName: sampleApp, category: sampleCategory, learnedUsable: 0, glossary: glossary)
    }
}
