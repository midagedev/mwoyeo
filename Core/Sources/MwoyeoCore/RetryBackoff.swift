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
