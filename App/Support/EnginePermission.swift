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

    /// The sheet's rule: Add and Save are open only for an engine this build runs (`EngineReach`), and for one off this Mac only while
    /// the box is ticked for the host it has now.
    static func mayCommit(_ engine: EngineConfig, ticked: String?, reach: EngineReach = Distribution.engineReach) -> Bool {
        guard reach.admits(engine.kind) else { return false }
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

    /// The chains this engine is the engine of (`ContextRoute.candidates`): a lens uses the engine of its chain (the narrowest profile that
    /// sets one, else All apps'), so a profile's memory goes to the engine its own chain names, never to another's: there is no cross pairing
    /// (Q1).
    private static func chains(of engine: EngineConfig, in settings: AppSettings) -> [(owner: AppProfile?, chain: MergedChain)] {
        ContextRoute.candidates(settings).filter { $0.chain.engine?.id == engine.id }
    }

    /// Whether this engine could be sent more than the lines: the lines around the text (and the title with them) go along when the chain's
    /// amount asks for them and the engine allows them (design §4.2's table, by the request path's own rule). The same condition that decides
    /// whether a lens reads its window at all (`ContextPlan.needsWindow`).
    static func sendsContext(_ engine: EngineConfig, in settings: AppSettings) -> Bool {
        guard LayoutKind.engine(engine.kind).tier != nil else { return false }
        return chains(of: engine, in: settings).contains { _, chain in
            let options = ContextOptions.requestOptions(engine: engine, chain: chain)
            return options.enabled && !options.memoryOnly && chain.amount.sendsLines
        }
    }

    /// The profiles whose written memory goes to `engine` (design §4.2, D1: writing a note or names is the opt-in): the profile has a note or
    /// a name that is a hint, its chain's engine is this one, and the request table sends memory to it. The question is put to the request
    /// path's own rule (`ContextOptions.requestOptions(engine:chain:)`), so the disclosure cannot drift from what is sent: it covers an engine
    /// whose amount is `memory` ("memory only") and one that sends lines, and leaves out a profile whose amount is `off`, DeepL without its
    /// opt-in, and an engine that owns its body. The profile's own engine is asked now (it was not under the cross pairing, when every profile
    /// with memory was a candidate for every engine): `ContextChecks` walks `ContextRoute.pairings` against this, for equality.
    static func memoryProfiles(_ engine: EngineConfig, in settings: AppSettings) -> [AppProfile] {
        let kind = LayoutKind.engine(engine.kind)
        guard kind.tier != nil else { return [] }
        return chains(of: engine, in: settings).compactMap { owner, chain in
            guard let owner, chain.hasMemory else { return nil }
            let options = ContextOptions.requestOptions(engine: engine, chain: chain)
            return options.enabled && kind.sendsMemory(options) ? owner : nil
        }
    }

    /// What `engine` could be sent beyond the lines to translate, for the engine sheet's footnote and its "Sent:" line. One value, two
    /// kinds of data: the lines of the window (the amount can ask for them) and the memory the person wrote for profiles (their names, which
    /// the engine can also be sent: the app's name and category, the note, the names in the text).
    struct ContextDisclosure: Equatable {
        /// Recent lines of the window go along (`sendsContext`).
        var lines: Bool
        /// The profiles (their names, in profile order) whose note and names go along.
        var memoryApps: [String]

        /// Nothing beyond the lines to translate: the footnote says nothing more.
        var isEmpty: Bool { !lines && memoryApps.isEmpty }
        /// The memory goes and the lines of the window do not (the amount is `memory`): "memory only".
        var memoryOnly: Bool { !lines && !memoryApps.isEmpty }
    }

    static func disclosure(_ engine: EngineConfig, in settings: AppSettings) -> ContextDisclosure {
        ContextDisclosure(lines: sendsContext(engine, in: settings), memoryApps: memoryProfiles(engine, in: settings).map(\.appName))
    }
}
