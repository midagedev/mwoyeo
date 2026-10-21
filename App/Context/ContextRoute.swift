import Foundation
import MwoyeoCore

extension AppSettings {
    /// What every lens is pinned to (design §1.3): the file's `profilePin`. nil is Auto; `all` is All apps only; an id is a profile, and one
    /// that is gone falls back to Auto (`ProfileChain.chain`).
    var pin: ProfilePin {
        switch profilePin {
        case nil: .auto
        case AppProfile.allAppsID?: .allAppsOnly
        case let id?: .profile(id)
        }
    }

    /// All apps as the chain's base (design §1.1, §2.1): the top-level keys of the file, for the app under the lens.
    func chainBase(bundleID: String?) -> ChainBase {
        ChainBase(pair: LanguageChoice(source: sourceLanguage, target: targetLanguage, customEngineID: customEngineID),
                  engine: customEngineID.map { ProfileEngine.added($0) }, reader: paragraphReader,
                  amount: context.map { ContextAmount($0) } ?? .memory, learn: useLearned,
                  glossary: glossaryPairs.map { GlossaryPair(src: $0.0, dst: $0.1) }, glossaryApply: glossaryApply,
                  knownEngines: Set(engines.map(\.id)), bundleID: bundleID)
    }

    /// The names and terms (a row with its mode) that exist anywhere: a row that is not a hint, or the glossary used as more than a hint.
    /// A lens reads its window for them, for the profile that applies is chosen by it (`ContextPlan.needsWindow`).
    var hasReplaceRows: Bool {
        (glossaryApply != .hint && !glossaryPairs.isEmpty) || appProfiles.contains { $0.entries.contains { $0.apply != .hint } }
    }
}

/// Which engine and which chain one request pairs (design names-and-context §1.3, §2.1, §4.2): the chain of the window under the lens (its
/// profiles, narrowest first, then All apps), merged, and the engine of the lens. The whole chain is per lens, languages and engine too
/// (Q1; §8 P1): a lens over the window of app B translates with B's chain over the base (`AppSettings.effective(frontmost: B)`: its pair, its
/// engine) and is sent B's memory, whichever app is in front, so the engine of one app is never sent the memory of another.
///
/// This is the only place that says so. The request path (`TranslationService.contextPlan`) asks `pair`, the Memory sheet's "Sent:" line
/// asks `own`, and the engine sheet's disclosure asks the same `merged`, so what is shown cannot drift from what is sent.
enum ContextRoute {
    /// What one request is built from.
    struct Pairing {
        /// The added engine in effect for the app under the lens; nil is Apple Translation.
        var engine: EngineConfig?
        /// The chain of the window under the lens, merged (design §2.1): its note, its names and terms, its amount, its learn switch.
        var chain: MergedChain
        /// `ContextOptions.requestOptions(engine:chain:)` of the two (design §4.2): Off is today's request.
        var options: ContextOptions

        /// The first profile of the chain, the one that decides the languages and keeps the learned names; nil when All apps is first.
        var profile: AppProfile? { chain.head.profile }
    }

    /// The chain of the window under a lens, merged. Auto picks every profile whose conditions the window meets; a pin gives the chain of
    /// that profile (design §1.3).
    /// - `lens`: the bundle id of the app under the lens.
    /// - `title`: the window's confirmed title; nil until it is confirmed, and only app conditions match then (§1.2).
    static func merged(settings: AppSettings, lens: String?, title: String? = nil) -> MergedChain {
        let links = ProfileChain.chain(for: WindowFacts(bundleID: lens, title: title), profiles: settings.appProfiles, pin: settings.pin)
        return ProfileChain.merge(links, base: settings.chainBase(bundleID: lens))
    }

    /// The chains the request table is asked about ahead of any window (design §1.3, §2.1): All apps alone, and each profile over All apps.
    /// "Could this engine be sent more than the line?" ("does a lens need its window?", the disclosure) is answered over these. A chain
    /// of several profiles (a window's title and its app) can name another engine or amount; which one is the window's to say, so these
    /// speak of the chain each profile makes by itself.
    static func candidates(_ settings: AppSettings) -> [(owner: AppProfile?, chain: MergedChain)] {
        let links: [(AppProfile?, [ChainLink])] = [(nil, [.allApps])] + settings.appProfiles.map { ($0, [.profile($0), .allApps]) }
        return links.map { owner, links in (owner, ProfileChain.merge(links, base: settings.chainBase(bundleID: owner?.bundleID))) }
    }

    /// - `settings`: the settings the lens translates with (`LensRoute.settings`: `AppSettings.effective(frontmost:)` of the app under it).
    /// - `lens`: the bundle id of the app under the lens, the one `settings` were made for.
    /// - `title`: the lens's confirmed window title (`LensContext.confirmedTitle`).
    static func pair(settings: AppSettings, lens: String?, title: String? = nil) -> Pairing {
        let engine = settings.activeEngineConfig
        let chain = merged(settings: settings, lens: lens, title: title)
        return Pairing(engine: engine, chain: chain, options: ContextOptions.requestOptions(engine: engine, chain: chain))
    }

    /// The pairings a lens over `lens`'s window can have: one, the app's own (the app in front does not matter).
    static func pairings(lens: String, in base: AppSettings) -> [Pairing] {
        [own(lens, in: base)]
    }

    /// The pairing of a lens over the app's window, the only one there is: what the app's own Memory sheet describes.
    static func own(_ bundleID: String, in base: AppSettings) -> Pairing {
        pair(settings: base.effective(frontmost: bundleID), lens: bundleID)
    }

    /// The added engines other than the app's own that a lens over its window is sent more than the lines to (the app's memory, or
    /// its context): none, by construction, as `pairings` has the app's own pairing alone. In order of first appearance, each once.
    static func otherReceivers(of lens: String, in base: AppSettings) -> [EngineConfig] {
        let ownID = own(lens, in: base).engine?.id
        var seen = Set<UUID>()
        return pairings(lens: lens, in: base).compactMap { p in
            guard let e = p.engine, e.id != ownID, p.options.enabled, LayoutKind.engine(e.kind).tier != nil, seen.insert(e.id).inserted else { return nil }
            return e
        }
    }
}
