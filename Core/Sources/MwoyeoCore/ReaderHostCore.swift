import Foundation

/// What one read asks of the host's policy: who asks, what for, in which language key, and with which rungs. The picture and the
/// languages Vision wants stay with the app (`ReadAsk`); the policy never looks at them.
public struct ReadPlan: Equatable, Sendable {
    /// The pipeline asking (`ReaderClients`), nil for a caller that is no pipeline.
    public var client: Int?
    public var purpose: WorkerJob.Purpose
    public var want: RouteRequest.Want
    /// The pass wants the document layout in the end: a read that stands in for it (the grouper over lines) is read again when Docs
    /// is ready, whichever `want` this read has (`ReadTarget.StandIn.layout`).
    public var layoutWanted: Bool
    public var key: String
    /// The kinds that read every requested language, best first (`OCRFallback.ladder`).
    public var ladder: [ReadVia]

    public init(client: Int? = nil, purpose: WorkerJob.Purpose = .lens, want: RouteRequest.Want, layoutWanted: Bool = false,
                key: String, ladder: [ReadVia]) {
        self.client = client
        self.purpose = purpose
        self.want = want
        self.layoutWanted = layoutWanted
        self.key = key
        self.ladder = ladder
    }
}

/// A request to send to a worker: the job the scheduler handed out, and what it is for.
public struct SendOrder: Equatable, Sendable {
    public var role: WorkerRole
    public var job: ReadScheduler.Job
    /// The ticket of the pass that waits for the answer, nil for a warm-up.
    public var ticket: Int?
    /// The warm-up step this job is, nil for a read.
    public var warm: ReaderWarmup.Step?
}

/// How the pass that asked is answered. An answer's lines come with the reply, which the app has in hand when the verdict is applied.
public enum ReadVerdict: Equatable, Sendable {
    case answer(via: ReadVia)
    /// No reader can take it now. The pipeline waits for `readerReady`, not for a timer.
    case unavailable(RecognitionWait)
    case failed(ReadFailure)
    /// A newer read of the same client took its place in the queue.
    case superseded
}

/// The host's decisions, as a value (g2-fast-host-gates, 2026-10-19): the part of `RecognitionHost` that is policy and not wiring. It
/// owns both workers' `WorkerHealth`, the `ReadScheduler`, the warm-up plan, Docs' rest, the retries of a read and the stand-ins that
/// read again on `readerReady`. It sends nothing, sleeps never and times nothing: every mutating call takes `now` (any monotonic
/// clock, in seconds), changes the state at once, and leaves the side effects, in order, for `drain()`. The app's actor does those
/// (the XPC call, the lens's hint, the log); a unit test does them on a fake clock and a fake service, and a policy that waits 40 s
/// for a slow Docs, or 61 s for a rung to rest, takes microseconds.
///
/// - **One request in flight per worker.** A read is routed (`ReadRouter`), submitted (`ReadScheduler`), and `pump` sends it when its
///   worker is free. A pass waits on its ticket for the verdict.
/// - **Patience, not a deadline.** A request turns *suspect* at S(kind): the reads queued behind it and the pass waiting for it are
///   routed again without it, and the request runs on, never cancelled. Its answer, if it is first, is the pass's; else it is a late
///   result that only marks the worker usable again, and the lenses that stood in read again once.
/// - **No reader, no timeout.** When the router has none the pass gets `.unavailable(why)` at once; nothing here reads it again.
/// - **Warm-up** follows `ReaderWarmup`: Lines first, Docs after, never while a lens is on for a key it has not seen. It is a
///   coroutine the app drives: `warmStart`, then a `sleep` (`warmResume`) or a `send` (`warmReplied`) until `stop`.
/// - **A crash** clears what was warm, restarts on `ReaderTiming.restart` and warms again.
public struct ReaderHostCore: Sendable {
    /// What the app does about a decision, in the order the decisions were made.
    public enum Effect: Equatable, Sendable {
        /// Notice-level log line (public).
        case log(String)
        case logError(String)
        /// `Trace.count`.
        case count(String)
        /// `Trace.mark(label, since:)`.
        case trace(String, since: TimeInterval)
        /// The router's answer for the client's read (`ReaderClients.routed`).
        case routed(client: Int?, ReadRoute)
        case completed(client: Int?)
        case failed(client: Int?)
        /// Answer the pass of this ticket. At most once per ticket.
        case finish(ticket: Int, ReadVerdict)
        /// Send the job (the app packs the picture and calls `replied` with the answer). The worker's health is dispatched already.
        case send(SendOrder)
        /// Re-arm the timer of the worker (`nextWake`).
        case watch(WorkerRole)
        /// A reader is ready: the clients that waited for one (`ReaderClients.takeWaiting`) and `standIns` read again.
        case announce(WorkerRole, standIns: [Int])
        /// The same, when the rest of Docs is over.
        case announceAfter(WorkerRole, TimeInterval)
        case setup(SetupChange)
        /// Start the warm-up if none runs.
        case kickWarmup
    }

    /// What the setup screen's mirror of the warm-up (`SwiftVisionGate`) is told.
    public enum SetupChange: Equatable, Sendable {
        case want(String)
        case retry
        case started(SwiftVisionGate.Due, now: TimeInterval)
        case finished(failure: String?, now: TimeInterval)
    }

    /// What the warm-up coroutine asks of the app next.
    public enum WarmAction: Equatable, Sendable {
        /// The warm-up is over (nothing due, or what is due is blocked for good).
        case stop
        /// Wait this long, then `warmResume`.
        case sleep(TimeInterval)
        /// Run this warm-up job in the worker, then `warmReplied` with how it ended.
        case send(SendOrder)
    }

    public struct Counts: Equatable, Sendable {
        public var reads = 0
        public var unavailable = 0
        public var rerouted = 0
        public var retried = 0
        public var late = 0
        public var rereads = 0
        public var superseded = 0
        public var docsFallbacks = 0
        /// Lines the services left out of their answers for a confidence under the least they keep (`ReadReply.lowConfidence`).
        public var lowConfidence = 0
    }

    private struct Pending {
        var plan: ReadPlan
        let ticket: Int
        /// The document model failed this read (or rests): it is read as lines + grouper on Lines.
        var noDocs = false
        var tries = 0
    }

    private struct Performing: Equatable {
        var step: ReaderWarmup.Step
        var began: TimeInterval
        /// The wait before the next ask while the programs are not ready.
        var again: Backoff
        /// How long the worker has been busy under this step.
        var busy: TimeInterval = 0
    }

    private enum WarmPhase: Equatable {
        case stopped
        case scanning(blocked: TimeInterval)
        case performing(Performing)
        case awaiting(Performing, job: ReadScheduler.Job)
    }

    public let timing: ReaderTiming
    /// `MWOYEO_OCR_PATH` for the benches.
    public let path: PathOverride?
    /// Packs the picture of an order before it is dispatched; false when it cannot be packed (the pass fails). The app's wiring.
    public var pack: @Sendable (SendOrder) -> Bool = { _ in true }
    /// The free bytes on the volume the compiler writes to, nil when they cannot be told. The app's wiring; asked at most once per
    /// `timing.diskSampleEvery` (`sampleDisk`). Core never touches the file system.
    public var freeSpace: @Sendable () -> UInt64? = { nil }

    public private(set) var health: [WorkerRole: WorkerHealth]
    public private(set) var scheduler = ReadScheduler()
    public private(set) var warmup = ReaderWarmup()
    public private(set) var wantedKeys: [String] = []
    public private(set) var rest: DocsRest
    public var counts = Counts()
    /// The last 64 transitions and reads, newest last (numbers and names only).
    public private(set) var ring: [String] = []

    private var rewarmPending = false
    private var diskSampledAt: TimeInterval?
    /// Workers that lost their process (a crash or a recycle): when one is usable again it has nothing warm, and the plan runs again.
    private var restarted: Set<WorkerRole> = []
    private var jobs: [Int: Pending] = [:]
    /// Tickets that have their verdict. A ticket stays here while a job of it is alive (a rerouted read has two).
    private var finished: Set<Int> = []
    private var frames: [Int: Int] = [:]
    private var warmPhase = WarmPhase.stopped
    private var out: [Effect] = []

    public init(timing: ReaderTiming = .standard, path: PathOverride? = nil) {
        self.timing = timing
        self.path = path
        health = [.lines: WorkerHealth(role: .lines, timing: timing), .docs: WorkerHealth(role: .docs, timing: timing)]
        rest = DocsRest(timing: timing)
    }

    /// The side effects of the calls since the last drain, in order.
    public mutating func drain() -> [Effect] {
        defer { out = [] }
        return out
    }

    // MARK: Reading

    /// The pass wants a keyed reader: its warm-up steps are due, unless a lens is on for a key the plan has not seen.
    public mutating func want(_ key: String, lensOn: Bool) {
        guard warmup.want(key, lensOn: lensOn) else { return }
        wantedKeys.append(key)
        out.append(.setup(.want(key)))
        kickWarmup()
    }

    /// `MWOYEO_DOCS_WAIT=1`, the mutation of the silence gates: the layout read waits until Docs can take it, however long. The app
    /// asks again after `timing.docsWaitPoll`. False in every shipped configuration.
    public mutating func mustWaitForDocs(_ plan: ReadPlan, now: TimeInterval) -> Bool {
        guard timing.waitsForDocs, plan.want == .layout else { return false }
        tickBoth(now)
        return route(plan, noDocs: false, now: now).target?.via != .doc
    }

    /// One read: routed, queued behind the request in flight if the worker is busy within S, sent, answered. `client` is the
    /// scheduler's id of the pipeline (a caller that is none gets a private one, and `release`s it after).
    public mutating func read(_ plan: ReadPlan, ticket: Int, client: Int, now: TimeInterval) {
        counts.reads += 1
        submit(Pending(plan: plan, ticket: ticket), client: client, frame: nextFrame(client), purpose: plan.purpose, now: now)
    }

    /// Whether a layout read of `key` would go to the Docs service now (it is idle and warm for the key and not resting). The
    /// client that is turned away reads again when Docs is ready.
    public mutating func documentsUsable(key: String, ladder: [ReadVia], now: TimeInterval) -> Bool {
        let probe = ReadPlan(want: .layout, key: key, ladder: ladder)
        tickBoth(now)
        if route(probe, noDocs: false, now: now).target?.via == .doc { return true }
        counts.docsFallbacks += 1
        out.append(.count("reader.docs.fallback"))
        return false
    }

    /// The pipeline went away: its queued read, its frame record and its stand-in flag go.
    public mutating func forget(client: Int) {
        scheduler.forget(client: client)
        frames[client] = nil
        pruneJobs()
    }

    /// A caller that was no pipeline is done with its private client id.
    public mutating func release(client: Int) {
        scheduler.forget(client: client)
        frames[client] = nil
    }

    private mutating func nextFrame(_ client: Int) -> Int {
        frames[client, default: 0] += 1
        return frames[client]!
    }

    private mutating func submit(_ p: Pending, client: Int, frame: Int, purpose: WorkerJob.Purpose, now: TimeInterval) {
        tickBoth(now)
        let route = route(p.plan, noDocs: p.noDocs, now: now)
        out.append(.routed(client: p.plan.client, route))
        switch route {
        case let .unavailable(why):
            counts.unavailable += 1
            out.append(.count("reader.unavailable.\(why.rawValue)"))
            note("unavailable client=\(client) why=\(why.rawValue)", now)
            finish(p.ticket, .unavailable(why))
        case let .dispatch(target), let .queue(target):
            var target = target
            if p.plan.layoutWanted, target.via != .doc { target.standIn.insert(.layout) }
            if let from = target.reroutedFrom {
                counts.rerouted += 1
                out.append(.count("reader.reroute.\(from.rawValue).\(target.role.rawValue)"))
            }
            let sub = scheduler.submit(client: client, purpose: purpose, frame: frame, key: p.plan.key, target: target, now: now)
            if let old = sub.superseded, let gone = jobs.removeValue(forKey: old.id) {
                counts.superseded += 1
                finish(gone.ticket, .superseded)
            }
            jobs[sub.job.id] = p
            pump(target.role, now: now)
        }
    }

    /// The router's answer for this read, with Docs' rest and a failed document read applied (the grouper reads, and the pass is
    /// read again once Docs is ready).
    private mutating func route(_ plan: ReadPlan, noDocs: Bool, now: TimeInterval) -> ReadRoute {
        let noDocs = noDocs || plan.want == .layout && rest.isResting(now: now)
        var request = RouteRequest(want: plan.want, key: plan.key, ladder: plan.ladder, path: path)
        let standsIn = plan.want == .layout && noDocs
        if noDocs { request.path = .vn }
        let route = ReadRouter.route(request, lines: health[.lines]!, docs: health[.docs]!, now: now)
        guard standsIn else { return route }
        switch route {
        case var .dispatch(target): target.standIn.insert(.layout); return .dispatch(target)
        case var .queue(target): target.standIn.insert(.layout); return .queue(target)
        case .unavailable: return route
        }
    }

    /// Gives the pass its verdict. True when this is the one that counts (a rerouted read has two requests behind it).
    @discardableResult
    private mutating func finish(_ ticket: Int, _ verdict: ReadVerdict) -> Bool {
        guard finished.insert(ticket).inserted else { return false }
        out.append(.finish(ticket: ticket, verdict))
        return true
    }

    /// Sends the next job of `role` when its worker is free. A queued job whose pass has its answer already is dropped.
    public mutating func pump(_ role: WorkerRole, now: TimeInterval) {
        while health[role]!.canDispatch, let job = scheduler.next(role) {
            guard let p = jobs[job.id], !finished.contains(p.ticket) else {
                _ = scheduler.lost(role)
                jobs[job.id] = nil
                continue
            }
            let order = SendOrder(role: role, job: job, ticket: p.ticket, warm: nil)
            guard pack(order) else {
                _ = scheduler.lost(role)
                jobs[job.id] = nil
                finish(p.ticket, .failed(.badJob("the picture could not be packed")))
                continue
            }
            let via = job.target.via
            health[role]!.dispatch(job.workerJob, now: now)
            out.append(.watch(role))
            out.append(.log("reader dispatched role=\(role.rawValue) via=\(via.rawValue) key=\(p.plan.key)"))
            note("dispatch \(role.rawValue)/\(via.rawValue) client=\(job.client) frame=\(job.frame)", now)
            out.append(.send(order))
            return
        }
    }

    // MARK: What came back

    /// The request of `job` returned (`error` nil: it answered). Frees the worker, tells its health, gives the pass its verdict or
    /// reads again with what is left. Returns the error, for a warm-up.
    @discardableResult
    public mutating func replied(_ role: WorkerRole, _ job: ReadScheduler.Job, error: ReadFailure?, ms: Int, pid: Int32 = 0,
                                 lowConfidence: Int = 0, now: TimeInterval) -> ReadFailure? {
        // A request that took S or longer is suspect by now, whether or not the timer ran yet: its answer is what recovers it.
        sampleDisk(now)
        var events = health[role]!.tick(now: now, wanted: wantsWorker(role))
        switch error {
        case nil: events += health[role]!.reply(.answered, now: now)
        case .programsNotReady?: events += health[role]!.reply(.notReady, now: now)
        case .compileFailed?: events += health[role]!.reply(.compileFailed, now: now)
        case .interrupted?, .unavailable?:
            // Nothing answered: the service is gone (the connection's own event says the same, and is a no-op after this).
            events += health[role]!.interrupted(now: now)
        case .failed?, .badJob?: events += health[role]!.reply(.failed, now: now)
        }
        let named = error.map { Self.name($0, diskIsWhy: health[role]!.lacksDiskSpace) }
        if let named {
            out.append(.log("reader failed role=\(role.rawValue) via=\(job.target.via.rawValue) why=\(named)"))
        } else {
            out.append(.log("reader answered role=\(role.rawValue) via=\(job.target.via.rawValue) ms=\(ms) pid=\(pid)"
                            + (lowConfidence > 0 ? " low=\(lowConfidence)" : "")))
        }
        counts.lowConfidence += lowConfidence
        note("reply \(role.rawValue)/\(job.target.via.rawValue) client=\(job.client) frame=\(job.frame) \(named ?? "ok") ms=\(ms)"
             + (lowConfidence > 0 ? " low=\(lowConfidence)" : ""), now)
        let delivery = scheduler.complete(role, id: job.id)
        if case .drop = delivery { out.append(.count("reader.dropped")) }
        if let p = jobs.removeValue(forKey: job.id) {
            deliver(p, job, error, role: role, late: finished.contains(p.ticket), events: events, now: now)
        }
        handle(role, events, now: now)
        pump(role, now: now)
        pruneJobs()
        kickWarmup()
        return error
    }

    /// What the log and the ring call a failure. A compile failure is called `nospace` once the worker's health holds the disk to be
    /// why (`WorkerHealth.lacksDiskSpace`): the one place that names it, for the failed line and the ring alike.
    public static func name(_ error: ReadFailure, diskIsWhy: Bool = false) -> String {
        switch error {
        case .programsNotReady: "programsNotReady"
        case .compileFailed: diskIsWhy ? "nospace" : "compileFailed"
        case .failed: "failed"
        case .badJob: "badJob"
        case .interrupted: "interrupted"
        case .unavailable: "unavailable"
        }
    }

    /// A read the scheduler dropped from its queue (the original of a reroute answered first, or the client went) leaves its picture
    /// here: forget every job that is neither in flight nor queued.
    private mutating func pruneJobs() {
        var live: Set<Int> = []
        for role in WorkerRole.allCases {
            if let job = scheduler.inFlight(role) { live.insert(job.id) }
            for job in scheduler.queued(role) { live.insert(job.id) }
        }
        jobs = jobs.filter { live.contains($0.key) }
        let tickets = Set(jobs.values.map(\.ticket))
        finished = finished.filter { tickets.contains($0) }
    }

    private mutating func deliver(_ p: Pending, _ job: ReadScheduler.Job, _ error: ReadFailure?, role: WorkerRole, late: Bool,
                                  events: [WorkerHealth.Event], now: TimeInterval) {
        var p = p
        if late {
            counts.late += 1
            out.append(.count("reader.\(role.rawValue).late"))
            return
        }
        let doc = job.target.via == .doc
        guard let error else {
            if finish(p.ticket, .answer(via: job.target.via)) { out.append(.completed(client: p.plan.client)) }
            // An answer within S ends a streak of slow document answers (the slow one is `.recovered`, handled with the events).
            if doc, !events.contains(where: { if case .recovered = $0 { true } else { false } }) { rest.answeredInTime() }
            return
        }
        // The read goes on with what is left, a few times at most: a rung that is not ready rests (`WorkerHealth`), a worker that
        // is gone is `restarting`, and a document model that failed leaves the layout to the grouper.
        p.tries += 1
        if doc { out.append(.count("ocr.swift.failed")) }
        if p.tries <= 3, doc || error.isModelNotReady || error.isServiceLost {
            p.noDocs = p.noDocs || doc
            counts.retried += 1
            out.append(.count("reader.retried"))
            out.append(.failed(client: p.plan.client))
            submit(p, client: job.client, frame: nextFrame(job.client), purpose: job.purpose, now: now)
        } else if finish(p.ticket, .failed(error)) {
            out.append(.failed(client: p.plan.client))
        }
    }

    // MARK: Health events

    /// The connection to the worker's service was interrupted or invalidated. The request in flight answers with its own error
    /// (`replied`); a worker without one just restarts.
    public mutating func connectionLost(_ role: WorkerRole, now: TimeInterval) {
        handle(role, health[role]!.interrupted(now: now), now: now)
    }

    /// The worker's timer ran (`nextWake`).
    public mutating func timerFired(_ role: WorkerRole, now: TimeInterval) {
        handle(role, health[role]!.tick(now: now, wanted: wantsWorker(role)), now: now)
    }

    /// Seconds from `now` until the worker's health changes by itself (`suspect`, `stuck`, the end of a restart), nil when it
    /// does not. One timer per worker, re-armed on every `.watch`.
    public func nextWake(_ role: WorkerRole, now: TimeInterval) -> TimeInterval? {
        let h = health[role]!
        switch h.state {
        case .busy, .suspect, .warming, .restarting: return h.nextDeadline(now: now).map { $0 - now }
        case .cold, .idle, .stuck, .disabled: return nil
        }
    }

    private mutating func tickBoth(_ now: TimeInterval) {
        sampleDisk(now)
        for role in WorkerRole.allCases { handle(role, health[role]!.tick(now: now, wanted: wantsWorker(role)), now: now) }
    }

    /// Asks the app for the free space, at most once per `timing.diskSampleEvery`, and tells both workers. Free space back above the
    /// line ends the rest of a rung that compile failures put on (`WorkerHealth.sampledDisk`); their next `tick` says so.
    private mutating func sampleDisk(_ now: TimeInterval) {
        guard diskSampledAt.map({ now - $0 >= timing.diskSampleEvery }) ?? true else { return }
        diskSampledAt = now
        let bytes = freeSpace()
        note("disk free=\(bytes.map { "\($0 >> 20) MB" } ?? "?")", now)
        for role in WorkerRole.allCases { health[role]!.sampledDisk(bytes, now: now) }
    }

    /// Whether anything wants this worker alive (it keeps an idle worker from exiting). R3b: Lines only while a lens is on.
    private func wantsWorker(_ role: WorkerRole) -> Bool { true }

    private mutating func handle(_ role: WorkerRole, _ events: [WorkerHealth.Event], now: TimeInterval) {
        let name = role.rawValue
        for event in events {
            switch event {
            case let .suspected(_, after):
                out.append(.count("reader.\(name).suspect"))
                out.append(.log("reader suspect role=\(name) after=\(Int(after * 1000)) ms"))
                note("suspect \(name)", now)
                rerouteQueued(role, now: now)
            case let .recovered(_, after):
                // A request that went suspect has answered. The first time the lenses read again at once; a Docs that keeps answering
                // past S rests before each next request, so that every recovery re-read does not send another one for ever.
                let wait = role == .docs ? rest.slowAnswer(now: now) : 0
                out.append(.log("reader recovered role=\(name) after=\(Int(after * 1000)) ms rest=\(Int(wait)) s"))
            case .warmed:
                break
            case .readerReady:
                note("readerReady \(name)", now)
                if role == .docs, let until = rest.until, until > now {
                    // The lenses that stood in read again when the rest is over, not before: they would only be turned away.
                    out.append(.announceAfter(role, until - now))
                } else {
                    announce(role)
                }
            case .usableAgain:
                out.append(.log("reader usable again role=\(name)"))
                note("usableAgain \(name)", now)
                announce(role, standIns: false)
                // A rung that rests (Code 13) is usable again with its process; only a restarted worker has lost what was warm.
                if restarted.remove(role) != nil { rewarmPending = true }
            case let .stuck(_, after):
                out.append(.log("reader stuck role=\(name) after=\(Int(after)) s"))
                rerouteQueued(role, now: now)
            case let .recycle(why):
                // R3b: the stuck recycle (`killService`, the exit message in a sandbox) and the Code-13 and footprint recycles. Not
                // acted on here: this slice never kills a request in flight, and the answer, if it comes, ends the episode.
                out.append(.log("reader recycle not done role=\(name) why=\(why.rawValue)"))
            case let .crashed(count):
                out.append(.count("reader.\(name).crash"))
                out.append(.log("reader service crashed role=\(name) count=\(count)"))
                rerouteQueued(role, now: now)
            case let .disabled(why):
                out.append(.log("reader disabled role=\(name) why=\(why.rawValue)"))
                rerouteQueued(role, now: now)
                announce(role, standIns: false)
            case .idleExit:
                // R3b: the process exits (`exitWhenIdle`). Until then the state machine runs its timer without the exit.
                break
            case let .rungResting(via, wait):
                out.append(.log("reader rung resting role=\(name) via=\(via.rawValue) for=\(Int(wait)) s"))
            }
        }
        if case .restarting = health[role]!.state { restarted.insert(role) }
        if events.contains(where: { if case .usableAgain = $0 { true } else { false } }) { kickWarmup() }
        out.append(.watch(role))
        pump(role, now: now)
    }

    /// The worker turned suspect: the lens reads queued behind its request, and the one in flight (it runs on), are routed again
    /// without it. A read with no other reader is `.unavailable` at once.
    private mutating func rerouteQueued(_ role: WorkerRole, now: TimeInterval) {
        // `MWOYEO_DOCS_WAIT=1`: the pass waits for the document answer however long, as the in-process path did.
        if timing.waitsForDocs, role == .docs { return }
        for job in scheduler.reroute(role) {
            guard let p = jobs[job.id] else { continue }
            if scheduler.inFlight(role)?.id != job.id { jobs[job.id] = nil }
            guard !finished.contains(p.ticket) else { continue }
            submit(p, client: job.client, frame: job.frame, purpose: job.purpose, now: now)
        }
    }

    private mutating func announce(_ role: WorkerRole, standIns: Bool = true) {
        out.append(.announce(role, standIns: standIns ? scheduler.readerReady(role) : []))
    }

    /// The rest of Docs is over (`.announceAfter`): the lenses that stood in read again.
    public mutating func announceNow(_ role: WorkerRole) { announce(role) }

    // MARK: Warming

    /// Every failed step is due again (the setup screen's retry button).
    public mutating func retryWarmup() {
        warmup.retry()
        out.append(.setup(.retry))
        kickWarmup()
    }

    private mutating func kickWarmup() {
        if warmWanted { out.append(.kickWarmup) }
    }

    /// Some warm-up step can run, or a restarted worker wants the plan run again.
    public var warmWanted: Bool { warmupDue || rewarmPending }

    /// Some step can still run: `MWOYEO_OCR_PATH=vn` never asks Docs, so its steps stay pending for good.
    private var warmupDue: Bool {
        guard warmup.remaining > 0 else { return false }
        guard path == .vn else { return true }
        return wantedKeys.contains { if case .pending? = warmup.state(.init(.lines, $0)) { true } else { false } }
    }

    /// The warm-up begins: for the keys the app wants, Lines then Docs, to completion (a load is never cancelled). A failed step is
    /// not retried here: the next launch or `retryWarmup` does.
    public mutating func warmStart(now: TimeInterval) -> WarmAction {
        warmPhase = .scanning(blocked: 0)
        return scan(blocked: 0, now: now)
    }

    /// The sleep the last action asked for is over.
    public mutating func warmResume(now: TimeInterval) -> WarmAction {
        switch warmPhase {
        case let .scanning(blocked): return scan(blocked: blocked, now: now)
        case let .performing(pf): return perform(pf, now: now)
        case .stopped, .awaiting: return .stop
        }
    }

    /// The warm-up job returned (`error` nil: it answered).
    public mutating func warmReplied(error: ReadFailure?, ms: Int, pid: Int32 = 0, now: TimeInterval) -> WarmAction {
        guard case let .awaiting(awaited, job) = warmPhase else { return .stop }
        var pf = awaited
        replied(pf.step.role, job, error: error, ms: ms, pid: pid, now: now)
        guard let error else { return endStep(pf, failure: nil, now: now) }
        if error.isServiceLost {
            // The service went away with the job. `replied` told the health, which restarts it after its backoff.
            warmPhase = .performing(pf)
            return .sleep(timing.warmPoll)
        }
        if error.isModelNotReady, now - pf.began < timing.coldWait {
            // Not before the worker's rung has rested: on a full disk each ask preallocates 2.4 GB and fails 35-55 s later.
            let wait = max(pf.again.failure(now: now), (health[pf.step.role]!.restUntil ?? now) - now)
            warmPhase = .performing(pf)
            return .sleep(wait)
        }
        return endStep(pf, failure: String(describing: error), now: now)
    }

    private mutating func scan(blocked: TimeInterval, now: TimeInterval) -> WarmAction {
        if warmup.remaining == 0, rewarmPending {
            // A worker restarted without what it had warm: ask again for every key the app wants.
            rewarmPending = false
            warmup = ReaderWarmup()
            for key in wantedKeys { warmup.want(key, lensOn: false) }
        }
        guard warmupDue else { warmPhase = .stopped; return .stop }
        tickBoth(now)
        var slots = ReaderWarmup.idleSlots(lines: health[.lines]!, docs: health[.docs]!, scheduler: scheduler)
        if path == .vn { slots.remove(.docs) }
        guard let step = warmup.nextDue(idleSlots: slots) else {
            // A lens's request is compiling, or a service restarts: the step goes after it.
            if blocked >= timing.coldWait { warmPhase = .stopped; return .stop }
            warmPhase = .scanning(blocked: blocked + timing.warmPoll)
            return .sleep(timing.warmPoll)
        }
        warmup.started(step, now: now)
        out.append(.setup(.started(SwiftVisionGate.Due(key: step.key, step: step.role == .lines ? .textModel : .documentModel), now: now)))
        return perform(Performing(step: step, began: now, again: timing.rung), now: now)
    }

    /// One warm-up step: a job in the worker that compiles the model for the key's languages (tens of seconds when cold, ~0.6 s from
    /// the cache). Waits for the worker to be free, never cancels, and asks again while the programs are not ready (a fast Code 13
    /// after a long compile) on `ReaderTiming.rung`. Fails when the worker is disabled or the job fails for good.
    private mutating func perform(_ pf: Performing, now: TimeInterval) -> WarmAction {
        var pf = pf
        let step = pf.step
        let role = step.role
        handle(role, health[role]!.tick(now: now, wanted: wantsWorker(role)), now: now)
        if case .disabled = health[role]!.effectiveState(now: now) {
            return endStep(pf, failure: "the \(role.rawValue) service is disabled for this run", now: now)
        }
        if health[role]!.isWarm(step.via, key: step.key) { return endStep(pf, failure: nil, now: now) }
        guard health[role]!.canDispatch, let job = scheduler.beginWarmup(client: 0, role: role, via: step.via, key: step.key, now: now) else {
            if pf.busy >= timing.coldWait {
                return endStep(pf, failure: "the \(role.rawValue) service was busy for \(Int(pf.busy)) s", now: now)
            }
            pf.busy += timing.warmPoll
            warmPhase = .performing(pf)
            return .sleep(timing.warmPoll)
        }
        health[role]!.dispatch(job.workerJob, now: now)
        out.append(.watch(role))
        out.append(.log("reader dispatched role=\(role.rawValue) via=warm key=\(step.key)"))
        warmPhase = .awaiting(pf, job: job)
        return .send(SendOrder(role: role, job: job, ticket: nil, warm: step))
    }

    private mutating func endStep(_ pf: Performing, failure: String?, now: TimeInterval) -> WarmAction {
        let step = pf.step
        warmup.finished(failure: failure, now: now)
        out.append(.setup(.finished(failure: failure, now: now)))
        out.append(.trace("reader warm-up \(step.role.rawValue) [\(step.key)] \(failure.map { "failed: \($0)," } ?? "done,")", since: pf.began))
        if let failure { out.append(.logError("reader warm-up role=\(step.role.rawValue) key=\(step.key) failed: \(failure)")) }
        note("warm \(step.role.rawValue) \(failure == nil ? "done" : "failed")", now)
        warmPhase = .scanning(blocked: 0)
        return scan(blocked: 0, now: now)
    }

    // MARK: Looking

    private mutating func note(_ line: String, _ now: TimeInterval) {
        ring.append(String(format: "%.3f ", now) + line)
        if ring.count > 64 { ring.removeFirst(ring.count - 64) }
    }

    /// Requests in flight in the services: the drain before exit waits for it, so that a compile is not thrown away.
    public var inFlight: Int { WorkerRole.allCases.filter { health[$0]!.state.job != nil }.count }

    /// Both workers are warm for every key the app asked for and idle. Nothing to wait for on a worker that the run does not use,
    /// and on a key that a lens's own read compiles (it has no warm-up).
    public func isReady(now: TimeInterval) -> Bool {
        for role in WorkerRole.allCases {
            if role == .docs, path == .vn { continue }
            switch health[role]!.effectiveState(now: now) {
            case .cold, .idle: break
            default: return false
            }
            for key in wantedKeys where !health[role]!.isWarm(role == .lines ? .rev3 : .doc, key: key) { return false }
        }
        return true
    }
}

extension ReadFailure {
    /// The service went away with the request, or none answered: not a verdict on the picture.
    public var isServiceLost: Bool {
        switch self {
        case .interrupted, .unavailable: true
        default: false
        }
    }

    /// The newest model is not ready: its programs are not (Code 13) or its compile failed (Code 11). The read goes on with what is
    /// left and the model is asked again later. `isCompileFailed` is the second alone.
    public var isModelNotReady: Bool {
        switch self {
        case .programsNotReady, .compileFailed: true
        default: false
        }
    }

    public var isCompileFailed: Bool {
        switch self {
        case .compileFailed: true
        default: false
        }
    }
}
