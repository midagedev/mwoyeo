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
    var isOnThisMac: Bool {
        switch kind {
        case let .openAICompatible(url, _, _, _), let .anthropic(url, _, _), let .deepL(url, _): ChatTranslation.isOnThisMac(url)
        case let .httpTemplate(t): URL(string: t.url).map(ChatTranslation.isOnThisMac) ?? false
        case .command: true
        }
    }

    /// "<host or command> · <model>", the list row's second line.
    var subtitle: String {
        [endpointName, modelName].compactMap { $0 }.joined(separator: " · ")
    }

    /// Whether this build can run the engine: the App Store build runs no program, so a command engine that came in with
    /// imported settings or a file stays in the list but is never used.
    func isAvailable(allowsCommands: Bool = !Distribution.isAppStore) -> Bool {
        if case .command = kind { return allowsCommands }
        return true
    }

    /// `subtitle` for the engine list; "Not available in this version" while this build cannot run it.
    func listSubtitle(allowsCommands: Bool = !Distribution.isAppStore) -> String {
        isAvailable(allowsCommands: allowsCommands) ? subtitle : String(localized: "Not available in this version")
    }

    /// The lens pill's mark for this engine (SF Symbol).
    var badgeSymbol: String { isOnThisMac ? "desktopcomputer" : "cloud" }
}
