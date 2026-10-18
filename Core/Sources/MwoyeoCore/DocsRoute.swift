import Foundation

/// How a read that wants the document layout meets the Docs worker in 1.1.2, where Docs is the one hosted worker and Lines is still
/// the app's own process. Pure: the worker's health at `now` in, a route out. It is the Docs half of `ReadRouter` (rules 1, 2 and 7
/// of design §4.5) with one difference that is deliberate: a busy Docs is not queued behind. A request in flight within S is
/// usually a compile in its first seconds, and the lens has the grouper at hand, so it reads at once.
///
/// - Docs idle (or not started) and warm for the key → `doc`. The request goes, and the lens waits S (`ReadVia.doc.patience`) for it.
/// - Any other state → `fallback(why)`: the read is lines + `ParagraphGrouper` in this process (v1.1.0 quality), never a wait.
/// - A request that went suspect and then answered puts Docs to rest for a while (`restingUntil`, the host's `Backoff`): a read that
///   keeps taking longer than S would otherwise be sent again by every recovery re-read, for ever, and the lens would read twice
///   each time. It reads with the grouper until the rest ends, and an answer within S ends the streak.
/// - `MWOYEO_OCR_PATH=vn` never asks Docs; `swift` assumes the key warm (the benches).
public enum DocsRoute: Equatable, Sendable {
    case doc
    case fallback(Why)

    /// Why the read does not go to Docs. Counted as `reader.docs.fallback.<why>` and logged.
    public enum Why: String, Sendable, CaseIterable {
        /// `MWOYEO_OCR_PATH=vn`.
        case vnOnly
        /// Docs has not answered a document read for this key: the first one compiles for tens of seconds.
        case cold
        /// A warm-up job is in flight.
        case warming
        /// A request is in flight, younger than S.
        case busy
        /// A request is in flight, S or older: probably compiling. It runs on and its answer is observed.
        case suspect
        case stuck
        /// After a crash, in `Backoff.workerRestart`.
        case restarting
        /// Crash loop, or stuck twice. No more attempts in this app run.
        case disabled
        /// The picture could not be packed into an IOSurface.
        case packing
        /// The last request answered after S: the next one waits out a rest that doubles per consecutive slow answer.
        case resting
    }

    public static func route(docs: WorkerHealth, key: String, now: TimeInterval, path: PathOverride? = nil,
                             restingUntil: TimeInterval? = nil) -> DocsRoute {
        if path == .vn { return .fallback(.vnOnly) }
        switch docs.effectiveState(now: now) {
        case .warming: return .fallback(.warming)
        case .busy: return .fallback(.busy)
        case .suspect: return .fallback(.suspect)
        case .stuck: return .fallback(.stuck)
        case .restarting: return .fallback(.restarting)
        case .disabled: return .fallback(.disabled)
        case .cold, .idle: break
        }
        if let restingUntil, now < restingUntil { return .fallback(.resting) }
        return docs.readiness(for: .doc, key: key, now: now, assumeWarm: path == .swift) == .ready ? .doc : .fallback(.cold)
    }
}

/// The rest of Docs after requests that answered later than S (`DocsRoute` `restingUntil`). The first slow answer is one episode (a
/// cold compile of a figure page): the lenses that stood in read again at once. Each consecutive slow answer after it rests the
/// worker 1, 2, 4 … 30 s from the answer (`Backoff.rev3Rung`, the table's rung that keeps failing) before the next request goes, so
/// that a Docs that always takes longer than S is not asked again by every recovery re-read, for ever (found with `docs-slow`).
/// An answer within S ends the streak. Pure: callers pass `now` (any monotonic clock, in seconds).
public struct DocsRest: Equatable, Sendable {
    private var backoff = Backoff.rev3Rung
    /// Consecutive slow answers since the last answer within S.
    public private(set) var streak = 0
    /// The rest ends at this time; nil when Docs is not resting.
    public private(set) var until: TimeInterval?

    public init() {}

    /// A request answered after S. Returns how long Docs rests (0: not at all, the first time).
    @discardableResult
    public mutating func slowAnswer(now: TimeInterval) -> TimeInterval {
        streak += 1
        guard streak > 1 else { return 0 }
        let wait = backoff.failure(now: now)
        until = now + wait
        return wait
    }

    /// A request answered within S.
    public mutating func answeredInTime() {
        streak = 0
        backoff.reset()
        until = nil
    }

    public func isResting(now: TimeInterval) -> Bool { until.map { now < $0 } ?? false }
}

/// The lenses whose layout came from the fallback while Docs was not ready, so that each reads once more when it is (design §10.4:
/// "on `readerReady(.docs)`, lenses whose layout came from a reroute re-read once"). Clients are the pipelines; a client that gets
/// its document layout, or goes away, is not on the list. The same bookkeeping as `ReadScheduler.readerReady(.docs)`, for the
/// host that has no scheduler yet.
public struct LayoutStandIns: Equatable, Sendable {
    private var clients: Set<Int> = []

    public init() {}

    /// The client's read was answered by the grouper where it wanted the document layout (or is being, and Docs may come first).
    public mutating func fellBack(_ client: Int) { clients.insert(client) }

    /// The client got the document layout.
    public mutating func served(_ client: Int) { clients.remove(client) }

    public mutating func forget(_ client: Int) { clients.remove(client) }

    public func contains(_ client: Int) -> Bool { clients.contains(client) }

    /// Docs is ready: the clients to read again, each once, in order.
    public mutating func ready() -> [Int] {
        defer { clients = [] }
        return clients.sorted()
    }
}
