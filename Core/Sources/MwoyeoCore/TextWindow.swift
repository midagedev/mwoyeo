import Foundation

/// The wait after the last keystroke before the Translate Text window translates by itself. Pure: the caller passes `now` (any monotonic
/// clock, in seconds), so a test runs a typing session on a fake clock and no check waits for the real one.
public struct TypingPause: Sendable, Equatable {
    /// What the caller does at a moment: nothing waits; wait this long and ask again; or translate now (asked once per burst of edits).
    public enum Step: Equatable, Sendable {
        case idle
        case wait(TimeInterval)
        case fire
    }

    /// How long the typing stays quiet before the window translates (design text-translation §2).
    public static let standard: TimeInterval = 0.8

    public let delay: TimeInterval
    private var editedAt: TimeInterval?

    public init(delay: TimeInterval = standard) { self.delay = delay }

    /// A keystroke at `now`: the wait starts again from it.
    public mutating func edited(at now: TimeInterval) { editedAt = now }

    /// Nothing is waited for any more (the text was translated by other means, or emptied).
    public mutating func cancel() { editedAt = nil }

    public mutating func step(at now: TimeInterval) -> Step {
        guard let editedAt else { return .idle }
        let left = editedAt + delay - now
        if left > 0 { return .wait(left) }
        self.editedAt = nil
        return .fire
    }
}

/// When the window translates without being asked (design text-translation §2). Apple's engines run on the device and cost nothing, so a
/// pause in typing is enough. An added engine is a server that is sent the text, usually for tokens, and a half-typed sentence is not
/// worth either: it translates when the person asks (⌘↩ or the button).
public enum TextTrigger: Equatable, Sendable {
    case onPause
    case onRequest

    public static func forEngine(added: Bool) -> TextTrigger { added ? .onRequest : .onPause }
}
