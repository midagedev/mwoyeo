import Foundation

/// The two Vision workers (design §4.2). `lines` hosts `VNRecognizeTextRequest` (rev3, rev2, `.fast`); `docs` hosts
/// `RecognizeDocumentsRequest`, plus `.fast` as an ANE-free stand-in.
public enum WorkerRole: String, Sendable, CaseIterable, Hashable {
    case lines, docs
}

/// What a request asks a worker to run. The router picks one per job; health, patience and warmth are per kind.
public enum ReadVia: String, Sendable, CaseIterable, Hashable {
    /// `RecognizeDocumentsRequest`: lines and paragraphs.
    case doc
    /// `VNRecognizeTextRequest`, accurate, revision 3: the newest model, whose width classes compile for 32-65 s each.
    case rev3
    /// Accurate revision 2.
    case rev2
    /// The fast recognizer: never compiles, Latin only.
    case fast

    /// S(kind): how long a lens waits for this kind before it reroutes or says so. Derived from warm latency with a load margin
    /// (design §4.4): doc 0.33-0.48 s → 2 s; accurate 0.25-0.88 s, ×3 → 3 s; `.fast` 0.06-0.1 s → 1 s.
    public var patience: TimeInterval {
        switch self {
        case .doc: 2
        case .rev3, .rev2: 3
        case .fast: 1
        }
    }

    /// The worker this kind belongs to. A kind never goes to a worker that has not answered it, except to its home (a second cold
    /// compile in the other cache is what that rule prevents); `.fast` never compiles and has no home.
    public var home: WorkerRole? {
        switch self {
        case .doc: .docs
        case .rev3, .rev2: .lines
        case .fast: nil
        }
    }
}

/// One request as health sees it.
public struct WorkerJob: Equatable, Sendable {
    /// Who asked. The order is the scheduling priority: lens, then the image window (and a headless render), then warm-up.
    public enum Purpose: Int, Sendable, Comparable {
        case lens, image, warmup
        public static func < (a: Purpose, b: Purpose) -> Bool { a.rawValue < b.rawValue }
    }

    public var via: ReadVia
    /// The language key: the requested languages ("ja", "zh-Hans", "ja,en"), or "auto" when the language is detected.
    public var key: String
    public var purpose: Purpose

    public init(via: ReadVia, key: String, purpose: Purpose = .lens) {
        self.via = via
        self.key = key
        self.purpose = purpose
    }
}

/// A kind that has answered for a language key in this worker (its cache is warm for it).
public struct WarmKey: Hashable, Sendable {
    public var via: ReadVia
    public var key: String

    public init(_ via: ReadVia, _ key: String) {
        self.via = via
        self.key = key
    }
}

/// The health of one worker (design §4.4, with the amendments of §10): what the router may send it, when a request that is slow
/// stops being waited for, and when the process is recycled. A pure state machine. Callers pass `now` (any monotonic clock, in
/// seconds), do the work, and act on the returned `Event`s; nothing here sleeps, sends or kills.
///
/// - A request is never cancelled or abandoned: `busy` turns `suspect` at S(kind) and the router reroutes the lens, while the
///   request runs on and its answer is observed. A slow answer is never a failure: any number of late answers leave the worker usable.
/// - `suspect` turns `stuck` at 240 s: one recycle; if the successor's first job is stuck too, no more recycles (`disabled`).
/// - `warming` (a warm-up job, expected to compile) never hits that rule. Its own bound is 400 s, and the same one recycle applies after it.
public struct WorkerHealth: Sendable, Equatable {
    /// A lens or image job in flight this long is stuck (`OCRHealth.giveUpAfter` was 180; 240 is above the longest cold compile
    /// seen, 138 s under contention, with a load margin).
    public static let stuckAfter: TimeInterval = 240
    /// A warm-up job in flight this long is overdue (at least twice the longest warm-up).
    public static let warmingBound: TimeInterval = 400
    /// A worker idle this long, with no lens that wants it, exits. The next job relaunches it (~0.6 s warm).
    public static let idleExitAfter: TimeInterval = 600
    /// A streak of rev3 Code-13 errors this long (count and seconds), after rev3 had answered in this process: only a restart ended it.
    public static let code13Streak = 20
    public static let code13Span: TimeInterval = 60
    /// At most this many recycles (Code 13, footprint) in this window.
    public static let recycleMax = 3
    public static let recycleWindow: TimeInterval = 1800
    /// This many crashes inside this window disable the worker.
    public static let crashLimit = 5
    public static let crashWindow: TimeInterval = 600
    /// A worker above this multiple of its post-warm-up footprint is recycled when idle.
    public static let footprintFactor = 2.0

    public enum DisabledWhy: String, Sendable, Equatable {
        /// ≥ 5 crashes in 10 minutes. The user's way out is restarting the app.
        case crashLoop
        /// Stuck, recycled, and the successor's first job was stuck too. Restarting the Mac usually fixes it.
        case stuckTwice
    }

    public enum RecycleWhy: String, Sendable, Equatable {
        case stuck, code13, footprint
    }

    public enum State: Equatable, Sendable {
        /// Not started, or exited idle. The cache may be warm. The router may start it with its first job.
        case cold
        /// A warm-up job is in flight (a cold compile is expected). Unavailable.
        case warming(WorkerJob, since: TimeInterval)
        /// Answered before, nothing in flight. Usable for the kinds in `warm` (and the home kinds).
        case idle
        /// In flight, age below S(kind). A job may queue behind it.
        case busy(WorkerJob, since: TimeInterval)
        /// In flight, age at or past S(kind): probably compiling. Unavailable, lens jobs reroute.
        case suspect(WorkerJob, since: TimeInterval)
        /// In flight at or past `stuckAfter` (or `warmingBound`) and the recycle is pending: the worker will exit.
        case stuck(WorkerJob, since: TimeInterval)
        /// After a crash or a recycle, in `Backoff.workerRestart`. Then `cold`.
        case restarting(until: TimeInterval)
        /// No more attempts in this app run.
        case disabled(DisabledWhy)

        public var name: String {
            switch self {
            case .cold: "cold"
            case .warming: "warming"
            case .idle: "idle"
            case .busy: "busy"
            case .suspect: "suspect"
            case .stuck: "stuck"
            case .restarting: "restarting"
            case .disabled: "disabled"
            }
        }

        /// The request in flight, if any.
        public var job: WorkerJob? {
            switch self {
            case let .warming(j, _), let .busy(j, _), let .suspect(j, _), let .stuck(j, _): j
            default: nil
            }
        }
    }

    /// How a request ended, as far as health is concerned.
    public enum Outcome: Equatable, Sendable {
        /// A result (even of no text).
        case answered
        /// A fast error saying the programs are not ready (`OCRHealth.programsNotReady`) or no result at all (`nilError`): the
        /// worker is alive, and the rev3 rung rests on `Backoff.rev3Rung`.
        case notReady
        /// Any other error: the worker answered, but this request would fail again.
        case failed
    }

    /// What a transition asks of the owner. Logged at notice level (design §4.15); the first four also drive routing.
    public enum Event: Equatable, Sendable {
        /// busy → suspect: reroute the lens jobs queued here and the one in flight (it runs on; its answer is observed).
        case suspected(WorkerJob, after: TimeInterval)
        /// suspect or stuck → idle by an answer, `after` seconds in flight. The worker is readable again.
        case recovered(WorkerJob, after: TimeInterval)
        /// A warm-up ended. `readerReady` follows.
        case warmed(WorkerJob, after: TimeInterval)
        /// `readerReady(worker)`: the recovery re-reads (`ReadScheduler.readerReady`) and every waiting lens read again.
        case readerReady
        /// The worker is usable again without having answered (restart ended, rev3 rung rest ended, an error ended a suspect):
        /// lenses that waited re-run, but nothing is "recovered".
        case usableAgain
        /// suspect → stuck.
        case stuck(WorkerJob, after: TimeInterval)
        /// Exit the process now (the exit message; the last resort is `kill` on the recorded pid). `interrupted` reports the exit.
        case recycle(RecycleWhy)
        case crashed(count: Int)
        case disabled(DisabledWhy)
        /// Idle for `idleExitAfter` with no lens that wants it: exit. The state is `cold`.
        case idleExit
        /// The rev3 rung rests for this long.
        case rungResting(ReadVia, for: TimeInterval)
    }

    /// What the router may do with this worker for one kind.
    public enum Readiness: Equatable, Sendable {
        /// Dispatch now.
        case ready
        /// Busy within S(kind): FIFO behind the request in flight.
        case queueBehind
        case unusable
    }

    /// Numbers for `stats()` and the debug ring.
    public struct Stats: Sendable, Equatable {
        public var dispatched: [ReadVia: Int] = [:]
        public var answered: [ReadVia: Int] = [:]
        public var failed: [ReadVia: Int] = [:]
        public var suspects = 0
        public var maxSuspectSeconds: TimeInterval = 0
        public var stuck = 0
        public var recycles = 0
        public var crashes = 0
        /// Consecutive rev3 Code-13 errors since rev3 last answered.
        public var code13Streak = 0
    }

    public let role: WorkerRole
    public private(set) var state = State.cold
    /// Kinds that answered for a key in this process incarnation or its predecessors since the last crash or recycle. An idle exit
    /// keeps it (the compile cache is on disk); a crash or a recycle clears it.
    public private(set) var warm: Set<WarmKey> = []
    public private(set) var stats = Stats()

    private var restart = Backoff.workerRestart
    private var rung3 = Backoff.rev3Rung
    private var rung3RestUntil: TimeInterval?
    /// The rung's rest ended and nobody was told.
    private var rung3NoticePending = false
    private var rung3Answered = false
    private var code13Since: TimeInterval?
    private var recycles: [TimeInterval] = []
    private var crashes: [TimeInterval] = []
    /// Stuck episodes since the worker last answered anything.
    private var stuckStreak = 0
    private var idleSince: TimeInterval?
    private var baselineFootprint: Double?

    public init(role: WorkerRole) { self.role = role }

    // MARK: asking

    /// A job may be dispatched: nothing is in flight and the worker is not down.
    public var canDispatch: Bool {
        switch state {
        case .cold, .idle: true
        default: false
        }
    }

    /// The state with the age rules applied at `now`, so that a caller whose timer ran late does not see a stale `busy`.
    public func effectiveState(now: TimeInterval) -> State {
        var copy = self
        _ = copy.tick(now: now)
        return copy.state
    }

    /// Whether the rev3 rung is resting (its last Code-13 error is recent and rev3 has not answered since).
    public func isResting(_ via: ReadVia, now: TimeInterval) -> Bool {
        guard via == .rev3, let until = rung3RestUntil else { return false }
        return now < until
    }

    /// What the router may do with this worker for `via` and a language key at `now`.
    ///
    /// - Down (`warming`, `suspect`, `stuck`, `restarting`, `disabled`): unusable for every kind, `.fast` too (one request blocks
    ///   the process).
    /// - A kind never goes to a worker that has not answered it for the key, unless this is the kind's home (rev3 and rev2 at
    ///   `lines`). `.fast` may go anywhere. `.doc` is the exception to the exception: it is asked only where it is warm, even at
    ///   `docs`, because a doc read of a cold key compiles for ~130 s and blocks the whole worker (`assumeWarm` is the bench
    ///   override `MWOYEO_OCR_PATH=swift`).
    /// - rev3 is unusable while its rung rests.
    public func readiness(for via: ReadVia, key: String, now: TimeInterval, assumeWarm: Bool = false) -> Readiness {
        let base: Readiness
        switch effectiveState(now: now) {
        case .cold, .idle: base = .ready
        case .busy: base = .queueBehind
        case .warming, .suspect, .stuck, .restarting, .disabled: return .unusable
        }
        if isResting(via, now: now) { return .unusable }
        if via == .fast { return base }
        if warm.contains(WarmKey(via, key)) || assumeWarm && via == .doc { return base }
        return via.home == role && via != .doc ? base : .unusable
    }

    public func isWarm(_ via: ReadVia, key: String) -> Bool { warm.contains(WarmKey(via, key)) }

    /// The earliest time at which `tick` changes something, nil when nothing is pending.
    public func nextDeadline(now: TimeInterval) -> TimeInterval? {
        var due: [TimeInterval] = []
        switch state {
        case let .busy(job, since): due.append(since + job.via.patience)
        case let .suspect(_, since): due.append(since + Self.stuckAfter)
        case let .warming(_, since): due.append(since + Self.warmingBound)
        case let .restarting(until): due.append(until)
        case .idle: if let idleSince { due.append(idleSince + Self.idleExitAfter) }
        case .cold, .stuck, .disabled: break
        }
        if rung3NoticePending, let until = rung3RestUntil { due.append(until) }
        return due.min()
    }

    // MARK: doing

    /// The job is sent. False (and nothing changes) when the worker cannot take it: one request in flight per worker.
    @discardableResult
    public mutating func dispatch(_ job: WorkerJob, now: TimeInterval) -> Bool {
        guard canDispatch else { return false }
        stats.dispatched[job.via, default: 0] += 1
        idleSince = nil
        state = job.purpose == .warmup ? .warming(job, since: now) : .busy(job, since: now)
        return true
    }

    /// The clock moved. `wanted`: some lens or client wants this worker (it keeps an idle worker from exiting).
    @discardableResult
    public mutating func tick(now: TimeInterval, wanted: Bool = false) -> [Event] {
        var events: [Event] = []
        if case let .busy(job, since) = state, now - since >= job.via.patience {
            state = .suspect(job, since: since)
            stats.suspects += 1
            events.append(.suspected(job, after: now - since))
        }
        if case let .suspect(job, since) = state, now - since >= Self.stuckAfter {
            events += becomeStuck(job, since: since, now: now)
        }
        if case let .warming(job, since) = state, now - since >= Self.warmingBound {
            events += becomeStuck(job, since: since, now: now)
        }
        if case let .restarting(until) = state, now >= until {
            state = .cold
            events.append(.usableAgain)
        }
        if case .idle = state {
            if wanted { idleSince = now }
            if let idleSince, now - idleSince >= Self.idleExitAfter {
                state = .cold
                self.idleSince = nil
                resetProcess(clearWarm: false)
                events.append(.idleExit)
            }
        }
        if rung3NoticePending, let until = rung3RestUntil, now >= until {
            rung3NoticePending = false
            events.append(.usableAgain)
        }
        return events
    }

    /// The request in flight returned. A reply with nothing in flight (the answer of a process that was recycled meanwhile) changes
    /// nothing. `footprintMB`: the worker's `phys_footprint` after the request.
    @discardableResult
    public mutating func reply(_ outcome: Outcome, now: TimeInterval, footprintMB: Double? = nil) -> [Event] {
        guard let job = state.job else { return [] }
        let since: TimeInterval
        let wasDown: Bool
        switch state {
        case let .busy(_, s): since = s; wasDown = false
        case let .suspect(_, s), let .stuck(_, s): since = s; wasDown = true
        case let .warming(_, s): since = s; wasDown = false
        default: return []
        }
        let wasWarming = job.purpose == .warmup
        let age = max(0, now - since)
        var events: [Event] = []
        stuckStreak = 0
        idleSince = now
        state = .idle

        switch outcome {
        case .answered:
            warm.insert(WarmKey(job.via, job.key))
            stats.answered[job.via, default: 0] += 1
            restart.success(now: now)
            if job.via == .rev3 {
                rung3.reset()
                rung3RestUntil = nil
                rung3NoticePending = false
                rung3Answered = true
                code13Since = nil
                stats.code13Streak = 0
            }
        case .notReady, .failed:
            stats.failed[job.via, default: 0] += 1
            if outcome == .notReady, job.via == .rev3 {
                stats.code13Streak += 1
                code13Since = code13Since ?? now
                let wait = rung3.failure(now: now)
                rung3RestUntil = now + wait
                rung3NoticePending = true
                events.append(.rungResting(.rev3, for: wait))
            }
        }
        if wasDown { stats.maxSuspectSeconds = max(stats.maxSuspectSeconds, age) }

        if outcome == .answered {
            if wasDown { events.append(.recovered(job, after: age)) }
            if wasWarming { events.append(.warmed(job, after: age)) }
            if wasDown || wasWarming { events.append(.readerReady) }
        } else if wasDown || wasWarming {
            events.append(.usableAgain)
        }

        // The recycles happen at idle, and the worker is idle right here (a Code-13 request fails in 12 ms).
        if let footprintMB, outcome == .answered {
            // The baseline is the footprint after the latest warm-up, or after the first answer of a process that had none.
            if wasWarming || baselineFootprint == nil {
                baselineFootprint = footprintMB
            } else if let baseline = baselineFootprint, footprintMB > baseline * Self.footprintFactor, recycleAllowed(now: now) {
                events += recycle(.footprint, now: now)
                return events
            }
        }
        if rung3Answered, stats.code13Streak >= Self.code13Streak, let streakStart = code13Since,
           now - streakStart >= Self.code13Span, recycleAllowed(now: now) {
            events += recycle(.code13, now: now)
        }
        return events
    }

    /// The XPC connection was interrupted or invalidated. In `stuck` that is the recycle's own exit; after our own exit (`cold`,
    /// `restarting`) it says nothing new; otherwise the worker crashed: the request in flight is lost, the warm set is gone, and
    /// the restart waits on `Backoff.workerRestart`; the fifth crash in 10 minutes disables the worker.
    @discardableResult
    public mutating func interrupted(now: TimeInterval) -> [Event] {
        switch state {
        case .stuck:
            beginRestart(now: now)
            return []
        case .cold, .restarting, .disabled:
            return []
        case .idle, .busy, .suspect, .warming:
            crashes = crashes.filter { now - $0 < Self.crashWindow } + [now]
            stats.crashes += 1
            var events: [Event] = [.crashed(count: crashes.count)]
            if crashes.count >= Self.crashLimit {
                state = .disabled(.crashLoop)
                resetProcess(clearWarm: true)
                events.append(.disabled(.crashLoop))
            } else {
                beginRestart(now: now)
            }
            return events
        }
    }

    // MARK: private

    private func recycleAllowed(now: TimeInterval) -> Bool {
        recycles.filter { now - $0 < Self.recycleWindow }.count < Self.recycleMax
    }

    private mutating func recycle(_ why: RecycleWhy, now: TimeInterval) -> [Event] {
        recycles = recycles.filter { now - $0 < Self.recycleWindow } + [now]
        stats.recycles += 1
        beginRestart(now: now)
        return [.recycle(why)]
    }

    private mutating func becomeStuck(_ job: WorkerJob, since: TimeInterval, now: TimeInterval) -> [Event] {
        stats.stuck += 1
        stuckStreak += 1
        var events: [Event] = [.stuck(job, after: now - since)]
        if stuckStreak >= 2 {
            // The successor's first job is stuck too: another exit would only repeat it.
            state = .disabled(.stuckTwice)
            events.append(.disabled(.stuckTwice))
        } else {
            state = .stuck(job, since: since)
            stats.recycles += 1
            events.append(.recycle(.stuck))
        }
        return events
    }

    private mutating func beginRestart(now: TimeInterval) {
        state = .restarting(until: now + restart.failure(now: now))
        resetProcess(clearWarm: true)
    }

    /// A new process starts from nothing: the rung, the Code-13 streak and the footprint baseline are the old process's.
    private mutating func resetProcess(clearWarm: Bool) {
        if clearWarm { warm = [] }
        rung3.reset()
        rung3RestUntil = nil
        rung3NoticePending = false
        rung3Answered = false
        code13Since = nil
        stats.code13Streak = 0
        baselineFootprint = nil
        idleSince = nil
    }
}
