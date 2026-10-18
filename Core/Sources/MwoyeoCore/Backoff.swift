import Foundation

/// The one backoff: a wait of `base` seconds after the first failure, `factor` times longer after each further one, never longer
/// than `cap`. Every retry wait of the read and translate paths is a configuration of this type (`Backoff.table`); no path retries
/// at once, and none has a fixed wait of its own (the transient fixed 1 s and the 5 s "not ready" wait of the old read path are gone:
/// under them a stalled recognizer saw 56 Code-13 errors a minute for 32 minutes, and 13,361 in one process over three hours).
///
/// `healthyWindow` makes the steps sticky: a success does not end the streak by itself, because a service that fails every few
/// calls would be retried at the first step for ever. The streak restarts only once the service has answered over a whole window
/// (its first success after a failure to a later success); a failure inside the window keeps doubling. Without a window a success
/// ends the streak at once.
///
/// Pure: callers pass `now` (any monotonic clock, in seconds).
public struct Backoff: Sendable, Equatable {
    public let base: TimeInterval
    public let factor: Double
    public let cap: TimeInterval
    public let healthyWindow: TimeInterval?
    /// An explicit list of waits in place of the doubling (the capture restart keeps its own values, 1 2 5 15 30). Once it runs
    /// out, `exhausted` is true and the last wait repeats.
    public let steps: [TimeInterval]?

    public private(set) var failures = 0
    /// When the wait of the last failure ends, nil when not waiting.
    public private(set) var until: TimeInterval?
    private var healthySince: TimeInterval?

    public init(base: TimeInterval, factor: Double = 2, cap: TimeInterval, healthyWindow: TimeInterval? = nil) {
        self.base = base
        self.factor = factor
        self.cap = cap
        self.healthyWindow = healthyWindow
        steps = nil
    }

    /// The waits are exactly `steps`; `base` and `cap` are the first and the last of them.
    public init(steps: [TimeInterval], healthyWindow: TimeInterval? = nil) {
        precondition(!steps.isEmpty, "a backoff needs at least one step")
        base = steps[0]
        factor = 2
        cap = steps[steps.count - 1]
        self.healthyWindow = healthyWindow
        self.steps = steps
    }

    /// The wait after `failures` earlier failures.
    public func wait(after failures: Int) -> TimeInterval {
        if let steps { return steps[min(max(failures, 0), steps.count - 1)] }
        return min(cap, base * pow(factor, Double(min(max(failures, 0), 10))))
    }

    /// The first `count` waits of a streak that never ends, as the policy table prints them.
    public func schedule(_ count: Int) -> [TimeInterval] { (0..<count).map { wait(after: $0) } }

    /// A list of steps that ran out (only for an explicit list): the owner stops retrying and waits for another event.
    public var exhausted: Bool { steps.map { failures >= $0.count } ?? false }

    /// Records a failure and returns how long to wait.
    @discardableResult
    public mutating func failure(now: TimeInterval) -> TimeInterval {
        let pause = wait(after: failures)
        healthySince = nil
        failures += 1
        until = now + pause
        return pause
    }

    /// An answer. With a window it counts toward the healthy stretch (`success(now:)`); this one ends the streak at once and is for
    /// the configurations without a window.
    public mutating func success() { reset() }

    public mutating func success(now: TimeInterval) {
        guard let window = healthyWindow else { reset(); return }
        guard failures > 0 else { return }
        guard let since = healthySince else { healthySince = now; return }
        if now - since >= window { reset() }
    }

    public mutating func reset() { failures = 0; until = nil; healthySince = nil }

    public func isWaiting(now: TimeInterval) -> Bool { until.map { now < $0 } ?? false }
    /// Seconds left of the wait, nil when not waiting.
    public func remaining(now: TimeInterval) -> TimeInterval? { until.flatMap { now < $0 ? $0 - now : nil } }
}

extension Backoff {
    /// The policy table (design §4.8). One row per use; the numbers live here and nowhere else.
    public enum Use: String, Sendable, CaseIterable {
        /// The translation queue after a failed batch. Reset by a success.
        case translationQueue
        /// An added engine's cooldown. Reset by a stretch of 60 s answering.
        case engineCooldown
        /// A lens's read after a hard error (the same pixels would fail again). Reset by a success, a change of geometry or language.
        case lensRead
        /// The rev3 rung of a Lines worker after `programsNotReady` / `nilError` (Code 13); rev2 and `.fast` serve meanwhile.
        /// Reset by a rev3 answer. A streak of 20 over 60 s recycles the worker (`WorkerHealth`).
        case rev3Rung
        /// A worker restart after a crash or a recycle. Reset by 10 minutes without a crash.
        case workerRestart
        /// A capture restart (`CaptureRecoveryPolicy.standard`, the same values). A stream that ran 30 s starts a new episode.
        case captureRestart

        public var backoff: Backoff {
            switch self {
            case .translationQueue: Backoff(base: 2, cap: 30)
            case .engineCooldown: Backoff(base: 2, cap: 30, healthyWindow: 60)
            case .lensRead: Backoff(base: 1, cap: 5)
            case .rev3Rung: Backoff(base: 1, cap: 30)
            case .workerRestart: Backoff(base: 1, cap: 30, healthyWindow: 600)
            case .captureRestart: Backoff(steps: [1, 2, 5, 15, 30], healthyWindow: 30)
            }
        }
    }

    public static var translationQueue: Backoff { Use.translationQueue.backoff }
    public static var engineCooldown: Backoff { Use.engineCooldown.backoff }
    public static var lensRead: Backoff { Use.lensRead.backoff }
    public static var rev3Rung: Backoff { Use.rev3Rung.backoff }
    public static var workerRestart: Backoff { Use.workerRestart.backoff }
    public static var captureRestart: Backoff { Use.captureRestart.backoff }

    /// The table as `use: waits…`, for the trace and the stats.
    public static var table: [(use: Use, waits: [TimeInterval])] {
        Use.allCases.map { ($0, $0.backoff.schedule(7)) }
    }
}
