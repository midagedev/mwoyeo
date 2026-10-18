import Foundation

/// What a lens that has no reader tells the user (design §4.7). It is `LensSignals.recognition`, per lens; the words are the app's.
public enum RecognitionWait: String, Sendable, Equatable {
    /// No reader is ready yet, and one will be (a compile, a restart): "Preparing text recognition".
    case preparing
    /// The worker was stuck and its one recycle was stuck too: "Text recognition isn't responding".
    case notResponding
    /// The worker crash-looped and is switched off for this run: "Restart Mwoyeo".
    case restartApp
}

/// One lens's wait for a reader (design §4.7). Driven only by what the router said about its read: a lens never has a state of
/// its own to time out.
///
/// The lens is never silent: while a candidate reader is in the way, the pipeline either reroutes (`routed(.dispatch)` again,
/// the state is `reading` and no hint shows) or the router has none left (`routed(.unavailable)`: the hint is up at once). The
/// moment of that call is S after the last candidate was handed the job, because a worker turns `suspect` at S(kind) and
/// `WorkerHealth.tick` is what asks the pipeline to route again. So the longest time a lens shows nothing is the sum of the S of
/// the candidates it tried, not a timer of its own: one lens, Docs suspect (2 s) then Lines suspect (3 s) → the hint at 5 s.
public struct ReadWait: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Nothing asked yet, or reset by a change of geometry or language.
        case idle
        /// The job went to a reader (dispatched or queued behind a request in flight); reset on every reroute.
        case reading(since: TimeInterval)
        /// The router had no reader. The pill says why, while no translation is shown.
        case waiting(RecognitionWait, since: TimeInterval)
        /// A read returned.
        case showing
    }

    public private(set) var state = State.idle

    public init() {}

    /// The router answered for this lens's read. A reroute is a new `routed` with a dispatch: there is never a hint between
    /// the suspect reader and the one that takes over.
    public mutating func routed(_ route: ReadRoute, now: TimeInterval) {
        switch route {
        case .dispatch, .queue:
            state = .reading(since: now)
        case let .unavailable(why):
            // Still the same wait: keep when it began.
            if case let .waiting(old, since) = state, old == why { state = .waiting(why, since: since) } else { state = .waiting(why, since: now) }
        }
    }

    /// A read returned (with blocks or none: the reader works, the lens has nothing more to say about it).
    public mutating func completed() { state = .showing }

    /// A read ended in a hard error (the lens's own backoff takes over, not this wait).
    public mutating func failed() { state = .idle }

    public mutating func reset() { state = .idle }

    /// The one thing the pill says about recognition now, nil when the lens is reading, showing or idle.
    public var hint: RecognitionWait? {
        if case let .waiting(why, _) = state { why } else { nil }
    }

    /// Since when the lens has waited on the current reader, nil unless it is reading.
    public var readingSince: TimeInterval? {
        if case let .reading(since) = state { since } else { nil }
    }
}
