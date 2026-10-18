import Foundation

/// How long the translation queue rests after a batch fails: 2 s, doubling per consecutive failure, capped at 30 s.
/// Pure: callers pass `now` (any monotonic clock, in seconds).
public struct RetryBackoff: Sendable, Equatable {
    public static let base: TimeInterval = 2
    public static let cap: TimeInterval = 30

    public private(set) var failures = 0
    public private(set) var pausedUntil: TimeInterval?

    public init() {}

    /// Records a failed batch and returns how long to pause.
    @discardableResult
    public mutating func failure(now: TimeInterval) -> TimeInterval {
        let pause = min(Self.cap, Self.base * pow(2, Double(min(failures, 10))))
        failures += 1
        pausedUntil = now + pause
        return pause
    }

    /// Any successful batch ends the streak.
    public mutating func success() { failures = 0; pausedUntil = nil }
    public mutating func reset() { success() }

    public func isPaused(now: TimeInterval) -> Bool { pausedUntil.map { now < $0 } ?? false }
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

/// An engine's cooldown steps. A success does not end the streak by itself: an engine that fails every few calls would
/// be retried at the first step forever. The steps restart only once the engine has answered over a whole `window`
/// (first success after a failure to a later success); a failure inside the window keeps doubling.
public struct HealthyBackoff: Sendable, Equatable {
    /// Long enough to span several of the 30 s capped retries, short enough that a recovered engine is not punished for long.
    public static let window: TimeInterval = 60

    private var steps = RetryBackoff()
    private var healthySince: TimeInterval?

    public init() {}

    public var failures: Int { steps.failures }

    @discardableResult
    public mutating func failure(now: TimeInterval) -> TimeInterval {
        healthySince = nil
        return steps.failure(now: now)
    }

    public mutating func success(now: TimeInterval) {
        guard steps.failures > 0 else { return }
        guard let since = healthySince else { healthySince = now; return }
        if now - since >= Self.window { steps.reset(); healthySince = nil }
    }
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

/// How long the lens waits before reading a region again after a recognition pass failed: 1 s, doubling per consecutive
/// failure, capped at 30 s. Ended by a successful pass or a change of geometry/language (`reset()`).
public struct ReadBackoff: Sendable, Equatable {
    public static let base: TimeInterval = 1
    public static let cap: TimeInterval = 30

    public private(set) var failures = 0
    private var until: TimeInterval?

    public init() {}

    @discardableResult
    public mutating func failure(now: TimeInterval) -> TimeInterval {
        let wait = min(Self.cap, Self.base * pow(2, Double(min(failures, 10))))
        failures += 1
        until = now + wait
        return wait
    }

    public mutating func success() { failures = 0; until = nil }
    public mutating func reset() { success() }

    public func isWaiting(now: TimeInterval) -> Bool { until.map { now < $0 } ?? false }
    /// Seconds left of the wait, nil when not waiting.
    public func remaining(now: TimeInterval) -> TimeInterval? { until.flatMap { now < $0 ? $0 - now : nil } }
}
