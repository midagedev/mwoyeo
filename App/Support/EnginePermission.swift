import Foundation
import MwoyeoCore

/// The person's permission to send the text a lens reads to an engine that is not on this Mac (App Review 5.1.2(i): disclose where
/// personal data goes, including third-party AI, and get explicit permission before sending it).
///
/// The record is keyed by the engine's id and the host the person allowed. It is the person's decision, so it is run-time state like the
/// folder bookmark: in the preferences' copy of the settings, never in settings.json (`SettingsFileCheck.notInFile`), so a file edit, an
/// agent or a settings import cannot grant it. An engine whose host changed no longer matches its record and is asked about again.
/// Apple Translation and engines on this Mac (`EngineConfig.isOnThisMac`) never need one.
struct EnginePermissions: Codable, Equatable {
    /// Engine id (`uuidString`) → the host the person allowed it to send to.
    private(set) var hosts: [String: String] = [:]
    /// The one-time upgrade step ran (`launch`): it grants the engines a DMG user already had, once.
    private(set) var migrated = false

    init() {}

    // Lenient like AppSettings: a field that is missing or unreadable is its default, which grants nothing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hosts = (try? c.decodeIfPresent([String: String].self, forKey: .hosts)) ?? [:]
        migrated = (try? c.decodeIfPresent(Bool.self, forKey: .migrated)) ?? false
    }

    /// The host a call to `engine` goes to, or nil while nothing leaves this Mac. Compared in lower case.
    static func host(of engine: EngineConfig) -> String? {
        engine.isOnThisMac ? nil : engine.endpointName.lowercased()
    }

    /// Whether `engine` may be sent text: it stays on this Mac, or the record names the host it has now.
    func allows(_ engine: EngineConfig) -> Bool {
        guard let host = Self.host(of: engine) else { return true }
        return hosts[engine.id.uuidString] == host
    }

    /// The sheet's rule: Add and Save are open for an engine off this Mac only while the box is ticked for the host it has now.
    static func mayCommit(_ engine: EngineConfig, ticked: String?) -> Bool {
        guard let host = host(of: engine) else { return true }
        return ticked == host
    }

    /// The person ticked (or cleared) the box for `engine` as it is now. An engine on this Mac keeps no record.
    mutating func set(_ allowed: Bool, for engine: EngineConfig) {
        if allowed, let host = Self.host(of: engine) { hosts[engine.id.uuidString] = host } else { hosts[engine.id.uuidString] = nil }
    }

    mutating func forget(_ id: UUID) { hosts[id.uuidString] = nil }

    /// What happens when the app starts. The first time only, an install that is allowed to grant (the DMG: its people configured and
    /// used these engines knowingly) allows each engine already in settings.json; the App Store build, and every later start, grants
    /// nothing, so an engine that arrives later by paste, import or file edit asks. A record whose engine is gone is dropped.
    mutating func launch(engines: [EngineConfig], grantsExisting: Bool) {
        if !migrated {
            migrated = true
            if grantsExisting { for e in engines { set(true, for: e) } }
        }
        let live = Set(engines.map { $0.id.uuidString })
        for id in hosts.keys where !live.contains(id) { hosts[id] = nil }
    }

    /// Whether this engine could be sent more than the lines: context rows (recent lines of the same window) go along when the engine's
    /// switch, or an app's override, can turn context on. The same condition that decides whether a lens reads its window at all
    /// (`ContextPlan.needsWindow`).
    static func sendsContext(_ engine: EngineConfig, profiles: [AppProfile]) -> Bool {
        LayoutKind.engine(engine.kind).tier != nil && ContextOptions.couldBeOn(engine: engine, profiles: profiles)
    }

    /// The profiles whose written memory goes to `engine` (design §9, D1: writing a note or names is the opt-in): the app has a note
    /// or names and the request path would send it. The question is put to the request path's own rule (`ContextOptions.requestOptions`),
    /// so the disclosure cannot drift from what is sent: it covers an engine whose Context is off ("memory only") and one that is on, and
    /// leaves out an app whose context is `off`, DeepL, and an engine that owns its body.
    ///
    /// The profile's own `customEngineID` is not asked: a request pairs the engine of the app in front with the profile of the app under
    /// the lens (`ContextRoute`), so a lens over app B while app A is in front sends B's memory to A's engine. Any engine can be the one
    /// in front (the base choice, an app's own, or one the person is about to choose), so every profile with memory is a candidate.
    /// `ContextChecks` walks `ContextRoute.pairings` against this.
    static func memoryProfiles(_ engine: EngineConfig, profiles: [AppProfile]) -> [AppProfile] {
        let kind = LayoutKind.engine(engine.kind)
        guard kind.tier != nil else { return [] }
        return profiles.filter { p in
            guard p.hasMemory else { return false }
            let options = ContextOptions.requestOptions(engine: engine, profile: p)
            return options.enabled && kind.sendsMemory(options)
        }
    }

    /// What `engine` could be sent beyond the lines to translate, for the engine sheet's footnote and its "Sent:" line. One value, two
    /// kinds of data: the lines of the window (the engine's switch, or an app's override, can turn them on) and the memory the person
    /// wrote for apps (their names, which the engine can also be sent: the app's name and category, the note, the names in the text).
    struct ContextDisclosure: Equatable {
        /// Recent lines of the window go along (`sendsContext`).
        var lines: Bool
        /// The apps (profile names, in profile order) whose note and names go along.
        var memoryApps: [String]

        /// Nothing beyond the lines to translate: the footnote says nothing more.
        var isEmpty: Bool { !lines && memoryApps.isEmpty }
        /// The memory goes and the lines of the window do not (the engine's Context is off): "memory only".
        var memoryOnly: Bool { !lines && !memoryApps.isEmpty }
    }

    static func disclosure(_ engine: EngineConfig, profiles: [AppProfile]) -> ContextDisclosure {
        ContextDisclosure(lines: sendsContext(engine, profiles: profiles), memoryApps: memoryProfiles(engine, profiles: profiles).map(\.appName))
    }
}
