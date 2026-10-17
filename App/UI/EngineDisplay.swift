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
        case let .openAICompatible(url, _, _, _), let .anthropic(url, _, _), let .deepL(url, _): url.host ?? url.absoluteString
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

    /// The lens pill's mark for this engine (SF Symbol).
    var badgeSymbol: String { isOnThisMac ? "desktopcomputer" : "cloud" }
}
