import Foundation
import MwoyeoCore

/// Which engine and which profile one request pairs: both are the app UNDER THE LENS's (design names-and-context §1.3: the whole chain
/// is per lens, languages and engine too, Q1; §8 P1). A lens over the window of app B translates with B's profile over the base
/// (`AppSettings.effective(frontmost: B)`: its pair, its engine) and is sent B's memory, whichever app is in front, so the engine of one
/// app is never sent the memory of another. Before this round the engine was the app in front's and the profile the lens's app's, two
/// apps whenever a lens covered a window of an app other than the one in front (the "cross pairing", "Also sent to …").
///
/// This is the only place that says so. The request path (`TranslationService.contextPlan`) asks `pair`, and the Memory sheet's "Sent:" line
/// asks `own` (the pairing of a lens over the app), so what is shown cannot drift from what is sent.
enum ContextRoute {
    /// What one request is built from.
    struct Pairing {
        /// The added engine in effect for the app under the lens; nil is Apple Translation.
        var engine: EngineConfig?
        /// The profile of the app under the lens.
        var profile: AppProfile?
        /// `ContextOptions.requestOptions` of the two: Off is today's request.
        var options: ContextOptions
    }

    /// - `settings`: the settings the lens translates with (`LensRoute.settings`: `AppSettings.effective(frontmost:)` of the app under it).
    /// - `lens`: the bundle id of the app under the lens, the one `settings` were made for.
    static func pair(settings: AppSettings, lens: String?) -> Pairing {
        let engine = settings.activeEngineConfig
        let profile = AppProfiles.profile(for: lens, in: settings.appProfiles)
        return Pairing(engine: engine, profile: profile, options: ContextOptions.requestOptions(engine: engine, profile: profile))
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
