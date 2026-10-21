import Foundation
import MwoyeoCore
import OSLog

/// What one lens translates with: its own settings (languages, engine), and the cache namespace and pace slot that follow them
/// (design names-and-context §1.3 "The whole chain is per lens, languages and engine too (Q1)", §8 P1 and P2). A lens over the window of
/// app B translates with the settings in effect for B (`AppSettings.effective(frontmost:)`, an app profile over the base), whichever app
/// is in front; with no app profile it is the base, byte for byte, and no window is read for it.
///
/// The one place a namespace, a pace slot and an engine's fingerprint are made: `TranslationService` takes a route with each call and
/// reads its cache and its pace under the route's strings, so two lenses of different pairs never share a cache line or a pace.
struct LensRoute: Sendable {
    /// The settings this lens translates with.
    let settings: AppSettings
    /// The app the settings were made for (nil: none known). Only meaningful while `tracksApp`.
    let app: String?
    /// The settings were chosen by the app under the lens, so a document of another app does not belong to this route (`serves`).
    /// False for a route with no app profile to choose by, and for the service's own.
    let tracksApp: Bool
    /// What a cached translation depends on besides the text: pair | engine identity | glossary.
    let namespace: String
    /// The engine and pair a call is timed against (the namespace without the glossary).
    let slot: PaceStats.Slot
    /// The same for Apple Translation: where a group the engine failed is stored and timed while the engine rests.
    let appleNamespace: String
    let appleSlot: PaceStats.Slot

    /// The added engine the route uses; nil is Apple.
    var engine: EngineConfig? { settings.activeEngineConfig }

    /// The service's own route: `settings` as they stand, for a call that has no lens of its own (the menu bar's language bar, the harness,
    /// an agent's `translate_text`, the image window).
    init(_ settings: AppSettings) {
        self.init(settings, app: nil, tracksApp: false)
    }

    /// A lens over the window of `app` (nil: none known): the base settings with that app's profile over them. With no app profile the
    /// route is the base whichever app is under the lens, and it names no app.
    ///
    /// `pin` is the lens's own choice of profile (`RegionConfig.profilePin`, design §1.3: Auto or pinned per lens): the profile's id, or `all`
    /// for All apps alone. It lays over the file's `profilePin` for this lens. An id no profile has is no pin, and is logged.
    init(base: AppSettings, over app: String?, pin: String? = nil) {
        let lensPin = pin.flatMap { Self.known($0, in: base) ? $0 : nil }
        self.init(base.effective(frontmost: app, lensPin: lensPin), app: app, tracksApp: !base.appProfiles.isEmpty)
    }

    private static let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "lens")

    /// Whether a lens's pin names All apps or a profile that exists; a pin that names a gone profile is dropped with a log line.
    private static func known(_ pin: String, in base: AppSettings) -> Bool {
        if pin == AppProfile.allAppsID || base.appProfiles.contains(where: { $0.id == pin }) { return true }
        log.notice("a lens is pinned to a profile that is gone; it follows Auto")
        return false
    }

    private init(_ settings: AppSettings, app: String?, tracksApp: Bool) {
        self.settings = settings
        self.app = app
        self.tracksApp = tracksApp
        let engine = settings.activeEngineConfig
        namespace = Self.namespace(settings, engine: engine)
        slot = Self.paceSlot(settings, engine: engine)
        appleNamespace = Self.namespace(settings, engine: nil)
        appleSlot = Self.paceSlot(settings, engine: nil)
    }

    /// Whether a document of `bundleID` goes with this route. A route chosen by the app under the lens carries no document of another app:
    /// the engine and the memory of one request come from one app (`ContextRoute`), also in the moment between the lens's window changing
    /// hands and its route and its document catching up with each other.
    func serves(_ bundleID: String) -> Bool { !tracksApp || app == bundleID }

    /// What a cached translation depends on besides the text: pair | engine identity | glossary. The identity is the
    /// Apple choice, or the added engine's id with a fingerprint of its kind, so editing its model or URL makes the old
    /// entries unreachable while switching engines back and forth keeps each one's. The same string keys the pace stats.
    /// `engine: nil` is Apple's namespace whatever engine is chosen (where a fallback stores).
    static func namespace(_ s: AppSettings, engine: EngineConfig?) -> String {
        // How the glossary is used is part of what a translation depends on (design §10); `hint`, the default, adds nothing: today's key.
        let apply = s.glossaryApply == .hint ? "" : "|g:\(s.glossaryApply.rawValue)"
        return "\(space(s, engine: engine))|\(s.glossary.hashValue)\(apply)"
    }

    /// The namespace without the glossary: what an engine's speed depends on (pair and engine identity).
    static func space(_ s: AppSettings, engine: EngineConfig?) -> String {
        let identity = engine.map { "ext:\($0.id.uuidString.prefix(8)):\(fingerprint($0))" } ?? "apple:\(s.engine.rawValue)"
        return "\(s.sourceLanguage)>\(s.targetLanguage)|\(identity)"
    }

    static func paceSlot(_ s: AppSettings, engine: EngineConfig?) -> PaceStats.Slot {
        PaceStats.Slot(key: space(s, engine: engine), engine: engine?.id)
    }

    /// 64-bit FNV-1a of the engine's kind as sorted-key JSON (id and name left out: renaming keeps the cache).
    static func fingerprint(_ e: EngineConfig) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(e), var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "0" }
        obj["id"] = nil
        obj["name"] = nil
        // What an engine may be sent besides the lines is not its identity: the Off path's namespace, and what the client learned about its
        // server, must not move when the user turns context on or off, or what the engine is allowed (`allow`).
        obj["context"] = nil
        obj["allow"] = nil
        let canonical = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        var h: UInt64 = 0xcbf29ce484222325
        for b in canonical { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}

/// The app under a lens, as a run of window reads saw it (design names-and-context §1.3 "a lens knows its window's owner"). A read that
/// finds an app takes the lens to it at once. One that finds none is no news: the window list races a window changing hands, and a lens
/// that fell to the base on every such read would reset its pipeline and ask another engine. The app is kept until `lapse` reads in a row
/// found none, and a lens dropped somewhere new reads again and takes the answer whatever it is (`settle`).
struct OwnerTracker: Equatable {
    /// Reads in a row that find no app before the lens has none (about 1.5 s at the window read's 0.5 s cadence).
    static let lapse = 3
    private(set) var app: String?
    private var misses = 0

    init(_ app: String?) { self.app = app }

    /// Takes one read from the capture pass; true when the app changed.
    mutating func note(_ read: String?) -> Bool {
        guard let read else {
            guard app != nil else { return false }
            misses += 1
            return misses >= Self.lapse && settle(nil)
        }
        return settle(read)
    }

    /// Takes a read as the answer (the lens was dropped somewhere new, or the first look); true when the app changed.
    mutating func settle(_ read: String?) -> Bool {
        misses = 0
        defer { app = read }
        return read != app
    }
}
