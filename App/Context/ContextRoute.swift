import Foundation
import MwoyeoCore

/// Which engine and which profile one request pairs: the engine is the one in effect while the app IN FRONT is in front
/// (`AppSettings.effective(frontmost:)`, its profile's engine over the base choice), the profile is the one of the app UNDER THE LENS
/// (its note, names and context). They are two apps only when a lens covers a window of an app other than the one in front.
///
/// This is the only place that says so. The request path (`TranslationService.contextPlan`) asks `pair`, and so do the disclosures
/// (the engine sheet's footnote and "Sent:" line, the Memory sheet's "Sent:" line): they walk the apps that can be in front and ask
/// `pair` for each, so what is shown cannot drift from what is sent.
enum ContextRoute {
    /// What one request is built from.
    struct Pairing {
        /// The added engine in effect for the app in front; nil is Apple Translation.
        var engine: EngineConfig?
        /// The profile of the app under the lens.
        var profile: AppProfile?
        /// `ContextOptions.requestOptions` of the two: Off is today's request.
        var options: ContextOptions
    }

    /// - `settings`: the settings in effect while some app is in front (`AppSettings.effective(frontmost:)`).
    /// - `lens`: the bundle id of the app under the lens.
    static func pair(settings: AppSettings, lens: String?) -> Pairing {
        let engine = settings.activeEngineConfig
        let profile = AppProfiles.profile(for: lens, in: settings.appProfiles)
        return Pairing(engine: engine, profile: profile, options: ContextOptions.requestOptions(engine: engine, profile: profile))
    }

    /// The apps that can be in front, as far as the engine is concerned: each app with a profile (it may name its own engine), and any
    /// app without one (nil: the base engine).
    static func fronts(of base: AppSettings) -> [String?] {
        [nil] + base.appProfiles.map { Optional($0.bundleID) }
    }

    /// The pairings a lens over `lens`'s window can have, one per app that can be in front.
    static func pairings(lens: String, in base: AppSettings) -> [Pairing] {
        fronts(of: base).map { pair(settings: base.effective(frontmost: $0), lens: lens) }
    }

    /// The pairing while the app itself is in front, the usual case: what the app's own Memory sheet describes first.
    static func own(_ bundleID: String, in base: AppSettings) -> Pairing {
        pair(settings: base.effective(frontmost: bundleID), lens: bundleID)
    }

    /// The added engines other than the app's own that a lens over its window is sent more than the lines to (the app's memory, or
    /// its context): the engines of the other apps that can be in front. In order of first appearance, each once.
    static func otherReceivers(of lens: String, in base: AppSettings) -> [EngineConfig] {
        let ownID = own(lens, in: base).engine?.id
        var seen = Set<UUID>()
        return pairings(lens: lens, in: base).compactMap { p in
            guard let e = p.engine, e.id != ownID, p.options.enabled, LayoutKind.engine(e.kind).tier != nil, seen.insert(e.id).inserted else { return nil }
            return e
        }
    }
}
