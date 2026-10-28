import Foundation
import MwoyeoCore

/// How an added engine is described in the lists, the lens pill and the sheet.
extension EngineConfig {
    var modelName: String? {
        switch kind {
        case let .openAICompatible(_, model, _, _), let .anthropic(_, model, _): model.isEmpty ? nil : model
        default: nil
        }
    }

    /// Where requests go: a host, or the program's name.
    var endpointName: String {
        switch kind {
        case let .openAICompatible(url, _, _, _), let .anthropic(url, _, _): url.host ?? url.absoluteString
        // Free or Pro is decided by the key, so both official hosts read as one name.
        case let .deepL(url, _): DeepLTranslation.isOfficialHost(url) ? "deepl.com" : (url.host ?? url.absoluteString)
        case let .httpTemplate(t): URL(string: t.url)?.host ?? t.url
        case let .command(c): (c.executable as NSString).lastPathComponent
        }
    }

    /// True when nothing leaves this Mac: a local server, or the user's own program.
    var isOnThisMac: Bool { kind.isOnThisMac }

    /// "<host or command> · <model>", the list row's second line.
    var subtitle: String {
        [endpointName, modelName].compactMap { $0 }.joined(separator: " · ")
    }

    /// Whether this build runs the engine (`EngineReach`): the App Store build runs no program and sends nothing off this Mac, so a
    /// command engine or one off this Mac that came in with imported settings or a file stays in the list but is never used.
    func isAvailable(reach: EngineReach = Distribution.engineReach) -> Bool { reach.admits(kind) }

    /// Whether the engine list asks for the person's permission to send text to this engine's host (`EnginePermissions`): it runs in this
    /// build, is off this Mac and has no record for its current host.
    func needsPermission(_ permissions: EnginePermissions, reach: EngineReach = Distribution.engineReach) -> Bool {
        isAvailable(reach: reach) && !permissions.allows(self)
    }

    /// `subtitle` for the engine list; "Not available in this version" while this build cannot run it, "Needs your permission" while the
    /// person has not allowed sending to its host.
    func listSubtitle(reach: EngineReach = Distribution.engineReach, permissions: EnginePermissions = EnginePermissions()) -> String {
        if !isAvailable(reach: reach) { return String(localized: "Not available in this version") }
        return permissions.allows(self) ? subtitle : String(localized: "Needs your permission")
    }

    /// The lens pill's mark for this engine (SF Symbol).
    var badgeSymbol: String { isOnThisMac ? "desktopcomputer" : "cloud" }
}
