import MwoyeoCore

/// The "Sent: …" line (design §3): what the engine in effect for a chain would be sent, by the same rule the request path uses
/// (`ContextOptions.requestOptions(engine:chain:)`, design §4.2) and the same layout (`RequestLayout.sentSummary`). Pure.
enum ContextPreview {
    /// - `engine`: the added engine in effect; nil is Apple Translation, which takes no context.
    /// - `chain`: the chain of the lens, merged: its note, its names and terms, its amount, and All apps' glossary and how it is used.
    /// - `category`: the app's `LSApplicationCategoryType`, for the card's domain word.
    /// - `learnedUsable`: how many learned rows the head of the chain has that a request may use (`LearnedCounts.usable`); they count only
    ///   while the chain learns and the kind takes them.
    static func summary(engine: EngineConfig?, chain: MergedChain, appName: String, category: String?, learnedUsable: Int) -> SentSummary {
        guard let engine else { return SentSummary(mode: .linesOnly) }
        let options = ContextOptions.requestOptions(engine: engine, chain: chain)
        // Learned rows are in the translator; each counts as an average-sized row against the engine's row budget.
        let learned = options.includeLearned ? (0..<min(learnedUsable, ContextMemory.maxLearned)).map {
            MemoryEntry(src: "learned\($0)", dst: "learned", kind: .term, origin: .learned)
        } : []
        return RequestLayout.sentSummary(options: options, kind: .engine(engine.kind), engineName: engine.name, appName: appName,
                                         domain: CategoryDomain.word(for: category), note: chain.note,
                                         rows: chain.rows.map(\.entry).filter { $0.origin == .user } + learned,
                                         glossary: chain.glossary.map { ($0.src, $0.dst) }, glossaryApply: chain.glossaryApply)
    }

    /// The engine sheet's "Sent:" line, true for the settings as they stand (design §3, D1). A profile that wrote a note or names puts the
    /// engine on the memory it sends (`EnginePermissions.memoryProfiles`): the line describes the first such profile, as the request path
    /// would send it. With none, it describes a sample app under All apps' own amount.
    /// - `category`: the category of an app by its bundle id (`AppModel.category(ofApp:)`).
    static func engineSummary(engine: EngineConfig, settings: AppSettings, category: (String) -> String?,
                              sampleApp: String = "Example Chat", sampleCategory: String? = "public.app-category.social-networking") -> SentSummary {
        if let p = EnginePermissions.memoryProfiles(engine, in: settings).first {
            let chain = ProfileChain.merge([.profile(p), .allApps], base: settings.chainBase(bundleID: p.bundleID))
            return summary(engine: engine, chain: chain, appName: p.appName, category: category(p.bundleID), learnedUsable: 0)
        }
        let chain = ProfileChain.merge([.allApps], base: settings.chainBase(bundleID: nil))
        return summary(engine: engine, chain: chain, appName: sampleApp, category: sampleCategory, learnedUsable: 0)
    }
}
