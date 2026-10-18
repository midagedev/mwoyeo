import Foundation

/// Turns a flickering "working" signal into a calm one for the lens's dot and glow: on after `onAfter` of continuous
/// work, off after `offAfter` of continuous rest. Pure: callers pass `now` (any monotonic clock, in seconds).
public struct BusyDebounce: Sendable, Equatable {
    public static let onAfter: TimeInterval = 0.6
    public static let offAfter: TimeInterval = 1.5

    public private(set) var shown = false
    private var raw = false
    private var since: TimeInterval = 0

    public init() {}

    /// Feeds the raw signal and returns what to show now.
    @discardableResult
    public mutating func update(_ on: Bool, now: TimeInterval) -> Bool {
        if on != raw { raw = on; since = now }
        if !shown, raw, now - since >= Self.onAfter { shown = true }
        if shown, !raw, now - since >= Self.offAfter { shown = false }
        return shown
    }

    /// When `update` will next change what is shown if the signal stays as it is; nil when nothing is pending.
    public var nextChange: TimeInterval? {
        if !shown, raw { return since + Self.onAfter }
        if shown, !raw { return since + Self.offAfter }
        return nil
    }
}

/// Decides whether a notice may reach the lens's tab: the same headline not again within `repeatAfter`, and a
/// different one replacing it at most once per `replaceAfter`. Empty text is never shown.
public struct NoticeGate: Sendable, Equatable {
    public static let repeatAfter: TimeInterval = 60
    public static let replaceAfter: TimeInterval = 10

    private var lastShown: [String: TimeInterval] = [:]
    private var lastAny: TimeInterval?

    public init() {}

    /// Records and returns true when `headline` may be shown at `now`.
    public mutating func allow(_ headline: String, now: TimeInterval) -> Bool {
        guard !headline.isEmpty else { return false }
        if let t = lastShown[headline], now - t < Self.repeatAfter { return false }
        if let t = lastAny, now - t < Self.replaceAfter { return false }
        lastShown[headline] = now
        lastAny = now
        return true
    }
}
