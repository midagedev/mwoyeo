import Foundation

// The retry waits of the app are one type, `Backoff` (Backoff.swift, the policy table). The three types below are the names the
// pipeline and the translation service still call; each is a thin wrapper over one row of the table, and R3 (reader-host)
// rewires the callers to `Backoff` and removes them. `SourceStrikes` and `StrikeRule` are not backoff and stay.

/// How long the translation queue rests after a batch fails: 2 s, doubling per consecutive failure, capped at 30 s
/// (`Backoff.Use.translationQueue`). Pure: callers pass `now` (any monotonic clock, in seconds).
public struct RetryBackoff: Sendable, Equatable {
    public static var base: TimeInterval { Backoff.translationQueue.base }
    public static var cap: TimeInterval { Backoff.translationQueue.cap }

    private var steps = Backoff.translationQueue

    public var failures: Int { steps.failures }
    public var pausedUntil: TimeInterval? { steps.until }

    public init() {}

    /// Records a failed batch and returns how long to pause.
    @discardableResult
    public mutating func failure(now: TimeInterval) -> TimeInterval { steps.failure(now: now) }

    /// Any successful batch ends the streak.
    public mutating func success() { steps.reset() }
    public mutating func reset() { steps.reset() }

    public func isPaused(now: TimeInterval) -> Bool { steps.isWaiting(now: now) }
}

/// Sources the engine keeps not returning. A strike is "not returned while another source of the same batch was"; at
/// `limit` strikes the source is parked (left out of the queue) until `reset()`. A returned translation clears its strikes.
public struct SourceStrikes: Sendable, Equatable {
    public static let limit = 3

    private var counts: [String: Int] = [:]

    public init() {}

    /// Adds a strike; true when the source is now parked.
    @discardableResult
    public mutating func strike(_ source: String) -> Bool {
        counts[source, default: 0] += 1
        return isParked(source)
    }

    public mutating func clear(_ source: String) { counts[source] = nil }
    public mutating func reset() { counts = [:] }
    public func isParked(_ source: String) -> Bool { counts[source, default: 0] >= Self.limit }
    public var parkedCount: Int { counts.values.filter { $0 >= Self.limit }.count }
}

/// An engine's cooldown steps (`Backoff.Use.engineCooldown`). A success does not end the streak by itself: an engine that fails
/// every few calls would be retried at the first step forever. The steps restart only once the engine has answered over a whole
/// `window` (first success after a failure to a later success); a failure inside the window keeps doubling.
public struct HealthyBackoff: Sendable, Equatable {
    /// Long enough to span several of the 30 s capped retries, short enough that a recovered engine is not punished for long.
    public static var window: TimeInterval { Backoff.engineCooldown.healthyWindow ?? 0 }

    private var steps = Backoff.engineCooldown

    public init() {}

    public var failures: Int { steps.failures }

    @discardableResult
    public mutating func failure(now: TimeInterval) -> TimeInterval { steps.failure(now: now) }

    public mutating func success(now: TimeInterval) { steps.success(now: now) }
}

/// Which sources of a finished group earn a strike. A source the engine skipped while others came back, or when the
/// whole group came back unchanged without an error, is struck; a group that threw is the engine's trouble, not the source's.
public enum StrikeRule {
    public static func struck(items: [String], translated: [String: String], groupFailed: Bool) -> Set<String> {
        let missing = items.filter { translated[$0] == nil }
        if missing.count == items.count && groupFailed { return [] }
        return Set(missing)
    }
}

/// How long the lens waits before reading a region again after a recognition pass failed. A hard failure (the same pixels would
/// fail again) waits 1 s, doubling per consecutive failure, capped at 5 s (`Backoff.Use.lensRead`; a lens is idle 5 s at most once
/// recognition works again). A transient failure (programs not ready after a compile, no result) is a streak of its own that
/// doubles 1 s to 30 s (`Backoff.Use.rev3Rung`); it was a fixed 1 s until 2026-10-18, which with a lens on a stalled recognizer
/// meant 56 errors a minute (design F5, §4.8). Ended by a successful pass or a change of geometry/language (`reset()`).
public struct ReadBackoff: Sendable, Equatable {
    public static var base: TimeInterval { Backoff.lensRead.base }
    public static var cap: TimeInterval { Backoff.lensRead.cap }

    private var hard = Backoff.lensRead
    private var transient = Backoff.rev3Rung
    private var until: TimeInterval?

    public init() {}

    /// Failures of both streaks since the last success.
    public var failures: Int { hard.failures + transient.failures }

    @discardableResult
    public mutating func failure(now: TimeInterval, transient isTransient: Bool = false) -> TimeInterval {
        let wait = isTransient ? transient.failure(now: now) : hard.failure(now: now)
        until = now + wait
        return wait
    }

    public mutating func success() { hard.reset(); transient.reset(); until = nil }
    public mutating func reset() { success() }

    public func isWaiting(now: TimeInterval) -> Bool { until.map { now < $0 } ?? false }
    /// Seconds left of the wait, nil when not waiting.
    public func remaining(now: TimeInterval) -> TimeInterval? { until.flatMap { now < $0 ? $0 - now : nil } }
}
