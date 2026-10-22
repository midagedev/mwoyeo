import Foundation

/// What the menu bar icon shows: a symbol for the app's state, and a small static badge while a lens cannot do its job (before it, a
/// lens whose capture failed looked like a working one, and only the menu panel said otherwise).
public struct MenuBarIcon: Equatable, Sendable {
    /// The SF Symbol of the state.
    public var symbol: String
    /// The badge: a lens is down, or Screen Recording is missing for the lenses that wait for it.
    public var badge: Bool

    public init(paused: Bool, translationsVisible: Bool, hasLens: Bool, needsAttention: Bool) {
        // Paused is on purpose, and nothing runs: no badge.
        badge = needsAttention && !paused
        symbol = if paused { "pause.circle" } else if !translationsVisible { "eye.slash" } else { hasLens ? "text.viewfinder" : "viewfinder" }
    }

    /// A lens needs the person when Screen Recording is missing for lenses that are on, or a lens's capture is down for good.
    public static func needsAttention(permissionGranted: Bool, enabledLenses: Int, lensesDown: Int) -> Bool {
        enabledLenses > 0 && (!permissionGranted || lensesDown > 0)
    }
}

/// What opening the app again shows (Spotlight, Finder or `open -a` while it runs: the system's reopen). The menu bar item is the app's way in,
/// and a menu bar manager can hide it or the notch cover it, so a reopen opens a window of its own: the welcome while it is still needed (it
/// tells to reopen after Screen Recording is allowed), else the panel the item shows, which holds Translate Text and the rest.
public enum ReopenWindow: Equatable, Sendable {
    case welcome, menu

    public static func shown(completedWelcome: Bool, screenAccess: Bool) -> ReopenWindow { completedWelcome && screenAccess ? .menu : .welcome }
}
