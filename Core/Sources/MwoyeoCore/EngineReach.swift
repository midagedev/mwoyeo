import Foundation

/// Which engines a build runs. The DMG runs every engine. The Mac App Store build runs only what keeps the screen's text on this
/// Mac and needs no program: Apple's own, and an engine whose address is this Mac (`ChatTranslation.isOnThisMac`). A command
/// engine needs a program the sandbox does not start, and an address off this Mac would send the text away, which the App Store
/// version never does: its answer to App Review and its privacy label rest on that (docs/app-store/review-2026-10-27.md).
///
/// Core cannot see the app's `#if MAS`, so the app passes its reach on. An engine the reach leaves out stays in the settings (it
/// may come in by import or a file edit) but is never sent anything: `EngineClient` checks every request against the reach.
public enum EngineReach: Sendable {
    case anywhere
    case thisMac

    public func admits(_ kind: EngineKind) -> Bool {
        switch self {
        case .anywhere: true
        case .thisMac: if case .command = kind { false } else { kind.isOnThisMac }
        }
    }

    /// The address a request goes to: under `thisMac`, only this Mac.
    public func admits(_ url: URL?) -> Bool {
        switch self {
        case .anywhere: true
        case .thisMac: url.map(ChatTranslation.isOnThisMac) ?? false
        }
    }
}

extension EngineKind {
    /// True when nothing leaves this Mac: a local server, or the user's own program.
    public var isOnThisMac: Bool {
        switch self {
        case let .openAICompatible(url, _, _, _), let .anthropic(url, _, _), let .deepL(url, _): ChatTranslation.isOnThisMac(url)
        case let .httpTemplate(t): URL(string: t.url).map(ChatTranslation.isOnThisMac) ?? false
        case .command: true
        }
    }
}
