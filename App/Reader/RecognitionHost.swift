import CoreGraphics
import Foundation
import MwoyeoCore
import IOSurface
import os

/// What one read came to for the pass that asked.
enum ReadResult: Sendable {
    /// Lines of a lines read.
    case lines([OCRLine])
    /// The lines of each paragraph, from the document model.
    case paragraphs([[OCRLine]])
    /// No reader can take it now. The pipeline waits for `readerReady`, not for a timer (`ReadWait`).
    case unavailable(RecognitionWait)
    case failed(ReadFailure)
    /// A newer read of the same client took its place in the queue.
    case superseded
}

/// No reader can take the pass now: the lens shows the hint and reads again when a reader is ready (`ReaderClients`).
struct RecognitionUnavailable: Error, CustomStringConvertible {
    let why: RecognitionWait
    var description: String { "no reader is available (\(why.rawValue))" }
}

/// A newer read of the same pipeline took the place of this one while it queued.
struct ReadSuperseded: Error, CustomStringConvertible {
    var description: String { "the read was superseded by a newer one" }
}

/// One read as the host takes it: what the pipeline wants (`want`), the languages of the kinds that may serve it, and the picture.
struct ReadAsk: @unchecked Sendable {
    var client: Int?
    var purpose: WorkerJob.Purpose = .lens
    var want: RouteRequest.Want
    /// The pass wants the document layout in the end: a read that stands in for it (the grouper over lines) is read again when Docs
    /// is ready, whichever `want` this read has (`ReadTarget.StandIn.layout`).
    var layoutWanted = false
    var key: String
    /// The kinds that read every requested language, best first (`OCRFallback.ladder`).
    var ladder: [ReadVia]
    /// Vision's own identifiers per lines kind.
    var languages: [ReadVia: [String]] = [:]
    var documentLanguages: [Locale.Language] = []
    var customWords: [String] = []
    var image: CGImage
    var roi: CGRect?

    var size: String { "\(image.width)x\(image.height)" }
}

/// The answer of one ask, for whoever waits for it. The first result wins: a read that was rerouted has two requests behind it, and
/// the one that comes second is a late result (`ReadScheduler.complete`).
final class ReadTicket: @unchecked Sendable {
    private struct State {
        var result: ReadResult?
        var waiter: CheckedContinuation<ReadResult, Never>?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isDone: Bool { state.withLock { $0.result != nil } }

    /// True when this result is the one that counts.
    @discardableResult
    func finish(_ result: ReadResult) -> Bool {
        let (first, waiter) = state.withLock { s -> (Bool, CheckedContinuation<ReadResult, Never>?) in
            guard s.result == nil else { return (false, nil) }
            s.result = result
            defer { s.waiter = nil }
            return (true, s.waiter)
        }
        waiter?.resume(returning: result)
        return first
    }

    func wait() async -> ReadResult {
        await withCheckedContinuation { (cont: CheckedContinuation<ReadResult, Never>) in
            let here = state.withLock { s -> ReadResult? in
                if let result = s.result { return result }
                s.waiter = cont
                return nil
            }
            if let here { cont.resume(returning: here) }
        }
    }
}

/// The pipelines (lenses, the image window, a headless render) as the host knows them: an id each, what to tell it when a reader
/// is ready, its `ReadWait` (the lens's hint) and whether a lens is on. Lock-protected, so that a pipeline registers from its
/// initializer, the session reads its hint from the main actor, and a pass records its outcome without a hop to the host.
final class ReaderClients: @unchecked Sendable {
    static let shared = ReaderClients()

    private struct Client {
        var onReady: @Sendable () -> Void
        var onHint: (@Sendable () -> Void)?
        var wait = ReadWait()
    }

    private struct State {
        var next = 0
        var clients: [Int: Client] = [:]
        /// Clients whose last read found no reader: they read again when one is ready.
        var waiting: Set<Int> = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A client id. `onReady` is called when a reader the client waited for or stood in for is ready.
    func add(onReady: @escaping @Sendable () -> Void) -> Int {
        state.withLock { s in
            s.next += 1
            s.clients[s.next] = Client(onReady: onReady)
            return s.next
        }
    }

    func remove(_ client: Int) {
        state.withLock { s in
            s.clients[client] = nil
            s.waiting.remove(client)
        }
        Task { await RecognitionHost.shared.forget(client: client) }
    }

    /// Lenses (pipelines) that exist: a new language key gets no warm-up while there are some (`ReaderWarmup.want(_:lensOn:)`).
    var count: Int { state.withLock { $0.clients.count } }

    /// Called after the client's wait changed, so that its session puts the hint on the pill.
    func onHint(_ client: Int, _ call: @escaping @Sendable () -> Void) {
        state.withLock { $0.clients[client]?.onHint = call }
    }

    /// What the client's lens says about recognition now (`LensSignals.recognition`).
    func hint(_ client: Int) -> RecognitionWait? { state.withLock { $0.clients[client]?.wait.hint } }

    /// The hint of the first client that has one: a headless run has a single pipeline, and no session to ask.
    var anyHint: RecognitionWait? {
        state.withLock { s in
            for id in s.clients.keys.sorted() { if let hint = s.clients[id]?.wait.hint { return hint } }
            return nil
        }
    }

    func routed(_ client: Int?, _ route: ReadRoute) {
        update(client) { wait, waiting in
            wait.routed(route, now: Trace.now)
            if case .unavailable = route { waiting = true }
        }
    }

    func completed(_ client: Int?) { update(client) { wait, _ in wait.completed() } }
    func failed(_ client: Int?) { update(client) { wait, _ in wait.failed() } }

    private func update(_ client: Int?, _ change: (inout ReadWait, inout Bool) -> Void) {
        guard let client else { return }
        let call: (@Sendable () -> Void)? = state.withLock { s in
            guard var c = s.clients[client] else { return nil }
            let before = c.wait.hint
            var waiting = s.waiting.contains(client)
            change(&c.wait, &waiting)
            if waiting { s.waiting.insert(client) } else { s.waiting.remove(client) }
            s.clients[client] = c
            return c.wait.hint == before ? nil : c.onHint
        }
        call?()
    }

    /// The clients that found no reader, once.
    func takeWaiting() -> [Int] {
        state.withLock { s in defer { s.waiting = [] }; return s.waiting.sorted() }
    }

    /// Tells the clients to read again. Returns how many were told.
    @discardableResult
    func notify(_ ids: [Int]) -> Int {
        let calls = state.withLock { s in ids.compactMap { s.clients[$0]?.onReady } }
        for call in calls { call() }
        return calls.count
    }
}

/// The two Vision workers as the app hosts them (design §4): one actor owns both `ReaderConnection`s and a `WorkerHealth` each,
/// Core's `ReadRouter` and `ReadScheduler`, a `ReadWait` per pipeline (`ReaderClients`, the lens's hint) and the warm-up plan
/// (`ReaderWarmup`). The services are the only place Vision runs (`MWOYEO_READER=inproc` runs the Lines kinds here, for the equal
/// gate and A/B; it is never the default).
///
/// - **One request in flight per worker.** A read is routed (`ReadRouter`), submitted (`ReadScheduler`: latest wins per client, lens
///   before image before warm-up) and sent when its worker is free. A pass waits on its ticket for the answer.
/// - **Patience, not a deadline.** A request turns *suspect* at S(kind) (`WorkerHealth`): the reads queued behind it and the pass
///   waiting for it are routed again without it, and the request runs on, never cancelled. Its answer, if it is first, is the pass's;
///   else it is a late result that only marks the worker usable again, and the lenses that stood in re-read once (`readerReady`).
/// - **No reader, no timeout.** When the router has none, the pass gets `.unavailable(why)` at once and reads again on `readerReady`
///   or `usableAgain`, never on a timer; the lens's hint says why (`ReadWait`).
/// - **Warm-up** (`warmUp`) follows `ReaderWarmup`: Lines first, Docs after, never while a lens is on for a key it has not seen.
/// - **A crash** clears what was warm, restarts on `Backoff.workerRestart` and warms again; the services relaunch on the next job.
///
/// Seams left for R3b (lifecycle): `handle` ignores `.idleExit` and logs `.recycle` without acting (`recycle`); the per-role idle
/// exit and the footprint check are `WorkerHealth`'s events, and `wantsWorker` is what keeps an idle worker alive.
actor RecognitionHost {
    static let shared = RecognitionHost()

    struct WarmFailure: Error, CustomStringConvertible { let description: String }

    /// `MWOYEO_READER=inproc`: the Lines kinds run in this process (the equal gate's baseline). Documents never do.
    static let inProcess = ProcessInfo.processInfo.environment["MWOYEO_READER"] == "inproc"
    /// `MWOYEO_OCR_PATH=vn|swift` for the benches.
    static let ocrPath = ProcessInfo.processInfo.environment["MWOYEO_OCR_PATH"].flatMap(PathOverride.init(rawValue:))
    /// `MWOYEO_DOCS_WAIT=1` is the mutation of the silence gates: a layout read waits for Docs however long, as the in-process path
    /// did. A gate that does not fail under it measures nothing.
    static let waitsForDocs = ProcessInfo.processInfo.environment["MWOYEO_DOCS_WAIT"] != nil
    private static let showsRing = ProcessInfo.processInfo.environment["MWOYEO_READER_RING"] != nil

    private struct Pending {
        var ask: ReadAsk
        let ticket: ReadTicket
        /// The document model failed this read (or rests): it is read as lines + grouper on Lines.
        var noDocs = false
        var tries = 0
    }

    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "reader")
    private var health: [WorkerRole: WorkerHealth] = [.lines: WorkerHealth(role: .lines), .docs: WorkerHealth(role: .docs)]
    private var scheduler = ReadScheduler()
    private var warmup = ReaderWarmup()
    private var wantedKeys: [String] = []
    private var warmer: Task<Void, Never>?
    private var rewarmPending = false
    /// Workers that lost their process (a crash or a recycle): when one is usable again it has nothing warm, and the plan runs again.
    private var restarted: Set<WorkerRole> = []
    private var watchers: [WorkerRole: Task<Void, Never>] = [:]
    private var jobs: [Int: Pending] = [:]
    private var frames: [Int: Int] = [:]
    private var anonymous = 0
    /// After consecutive document requests that answered past S, Docs rests before the next one (`DocsRest`).
    private var rest = DocsRest()

    private var counts = Counts()
    private var readMs: [WorkerRole: [Int]] = [:]
    private var lastServiceMs: [WorkerRole: Double] = [:]
    private var lastFootprint: [WorkerRole: UInt64] = [:]
    private var ring: [String] = []

    private struct Counts {
        var reads = 0
        var unavailable = 0
        var rerouted = 0
        var retried = 0
        var late = 0
        var rereads = 0
        var superseded = 0
        var docsFallbacks = 0
    }

    private init() {
        for role in WorkerRole.allCases {
            // The stream exists before anything is sent: a late listener missed events in R1's first fakes run.
            let events = Self.connection(role).events()
            Task { [self] in for await event in events { await connectionEvent(role, event) } }
        }
        #if !MAS
        SelfTest.register(inFlight: { await RecognitionHost.shared.inFlight },
                          readerReady: { await RecognitionHost.shared.isReady },
                          statsLines: { await RecognitionHost.shared.statsLines() })
        #endif
    }

    private static func connection(_ role: WorkerRole) -> ReaderConnection {
        ReaderConnection.shared(ReaderRole(rawValue: role.rawValue) ?? .lines)
    }

    // MARK: Reading

    /// One read: routed, queued behind the request in flight if the worker is busy within S, sent, and answered. Never throws and
    /// never times out by itself; a worker that goes quiet turns the read into `.unavailable` (or into a read by another worker).
    func read(_ ask: ReadAsk) async -> ReadResult {
        want(ask.key)
        await waitIfMutated(ask)
        counts.reads += 1
        let ticket = ReadTicket()
        let client: Int
        if let c = ask.client { client = c } else { anonymous -= 1; client = anonymous }
        submit(Pending(ask: ask, ticket: ticket), client: client, frame: nextFrame(client), purpose: ask.purpose)
        let result = await ticket.wait()
        if ask.client == nil { scheduler.forget(client: client); frames[client] = nil }
        return result
    }

    /// Whether a layout read of `key` would go to the Docs service now (it is idle and warm for the key and not resting). The
    /// client that is turned away reads again when Docs is ready.
    func documentsUsable(key: String, ladder: [ReadVia]) async -> Bool {
        let probe = ReadAsk.probe(key: key, ladder: ladder)
        await waitIfMutated(probe)
        tickBoth()
        let route = route(probe, noDocs: false)
        if route.target?.via == .doc { return true }
        counts.docsFallbacks += 1
        Trace.count("reader.docs.fallback")
        return false
    }

    /// The pipeline went away: its queued read, its frame record and its stand-in flag go.
    func forget(client: Int) {
        scheduler.forget(client: client)
        frames[client] = nil
        pruneJobs()
    }

    private func nextFrame(_ client: Int) -> Int {
        frames[client, default: 0] += 1
        return frames[client]!
    }

    private func submit(_ p: Pending, client: Int, frame: Int, purpose: WorkerJob.Purpose) {
        tickBoth()
        let now = Trace.now
        let route = route(p.ask, noDocs: p.noDocs)
        ReaderClients.shared.routed(p.ask.client, route)
        switch route {
        case let .unavailable(why):
            counts.unavailable += 1
            Trace.count("reader.unavailable.\(why.rawValue)")
            note("unavailable client=\(client) why=\(why.rawValue)")
            p.ticket.finish(.unavailable(why))
        case let .dispatch(target), let .queue(target):
            var target = target
            if p.ask.layoutWanted, target.via != .doc { target.standIn.insert(.layout) }
            if let from = target.reroutedFrom {
                counts.rerouted += 1
                Trace.count("reader.reroute.\(from.rawValue).\(target.role.rawValue)")
            }
            let sub = scheduler.submit(client: client, purpose: purpose, frame: frame, key: p.ask.key, target: target, now: now)
            if let old = sub.superseded, let gone = jobs.removeValue(forKey: old.id) {
                counts.superseded += 1
                gone.ticket.finish(.superseded)
            }
            jobs[sub.job.id] = p
            pump(target.role)
        }
    }

    /// The router's answer for this ask, with Docs' rest and a failed document read applied (the grouper reads, and the pass is
    /// read again once Docs is ready).
    private func route(_ ask: ReadAsk, noDocs: Bool) -> ReadRoute {
        let now = Trace.now
        let noDocs = noDocs || ask.want == .layout && rest.isResting(now: now)
        var request = RouteRequest(want: ask.want, key: ask.key, ladder: ask.ladder, path: Self.ocrPath)
        let standsIn = ask.want == .layout && noDocs
        if noDocs { request.path = .vn }
        let route = ReadRouter.route(request, lines: health[.lines]!, docs: health[.docs]!, now: now)
        guard standsIn else { return route }
        switch route {
        case var .dispatch(target): target.standIn.insert(.layout); return .dispatch(target)
        case var .queue(target): target.standIn.insert(.layout); return .queue(target)
        case .unavailable: return route
        }
    }

    /// Sends the next job of `role` when its worker is free. A queued job whose pass has its answer already is dropped.
    private func pump(_ role: WorkerRole) {
        while health[role]!.canDispatch, let job = scheduler.next(role) {
            guard let p = jobs[job.id], !p.ticket.isDone else {
                _ = scheduler.lost(role)
                jobs[job.id] = nil
                continue
            }
            let ask = p.ask
            let via = job.target.via
            var surface: IOSurface?
            var image: ReadImage?
            if !(Self.inProcess && role == .lines) {
                guard let packed = ReaderPixels.surface(from: ask.image) else {
                    _ = scheduler.lost(role)
                    jobs[job.id] = nil
                    p.ticket.finish(.failed(.badJob("the picture could not be packed")))
                    continue
                }
                image = packed.image
                surface = packed.surface
            }
            let readJob = ReadJob(kind: Self.kind(of: via), image: image, roi: ask.roi, languages: ask.languages[via] ?? [],
                                  documentLanguages: ask.documentLanguages, customWords: ask.customWords)
            health[role]!.dispatch(job.workerJob, now: Trace.now)
            watch(role)
            log.notice("reader dispatched role=\(role.rawValue, privacy: .public) via=\(via.rawValue, privacy: .public) key=\(ask.key, privacy: .public)")
            note("dispatch \(role.rawValue)/\(via.rawValue) client=\(job.client) frame=\(job.frame)")
            Task { [self] in
                let reply = await execute(role, readJob, surface: surface, image: ask.image)
                replied(role, job, reply)
            }
            return
        }
    }

    private static func kind(of via: ReadVia) -> ReadKind {
        switch via {
        case .doc: .doc
        case .rev3: .rev3
        case .rev2: .rev2
        case .fast: .fast
        }
    }

    /// One job to the service of `role`; the Lines kinds in this process under `MWOYEO_READER=inproc`.
    private nonisolated func execute(_ role: WorkerRole, _ job: ReadJob, surface: IOSurface?, image: CGImage?) async -> ReadReply {
        guard Self.inProcess, role == .lines else { return await Self.connection(role).perform(job, surface: surface) }
        let began = Trace.now
        do {
            let out = try await VisionExec.run(job.kind, image: image, roi: job.roi, languages: job.languages,
                                               documentLanguages: job.documentLanguages, customWords: job.customWords)
            return ReadReply(id: job.id, role: .lines, pid: 0, lines: out.lines.map(VisionExec.wire),
                             paragraphs: out.paragraphs.map { $0.map(VisionExec.wire) }, ms: (Trace.now - began) * 1000)
        } catch {
            return ReadReply(id: job.id, role: .lines, pid: 0, error: ReadFailure.from(error))
        }
    }

    // MARK: What came back

    @discardableResult
    private func replied(_ role: WorkerRole, _ job: ReadScheduler.Job, _ reply: ReadReply) -> ReadFailure? {
        let now = Trace.now
        // A request that took S or longer is suspect by now, whether or not the timer ran yet: its answer is what recovers it.
        var events = health[role]!.tick(now: now, wanted: wantsWorker(role))
        switch reply.error {
        case nil: events += health[role]!.reply(.answered, now: now)
        case .programsNotReady?: events += health[role]!.reply(.notReady, now: now)
        case .interrupted?, .unavailable?:
            // Nothing answered: the service is gone (the connection's own event says the same, and is a no-op after this).
            events += health[role]!.interrupted(now: now)
        case .failed?, .badJob?: events += health[role]!.reply(.failed, now: now)
        }
        if reply.pid != 0 || Self.inProcess { lastServiceMs[role] = reply.ms; lastFootprint[role] = reply.footprint }
        if reply.error == nil {
            readMs[role, default: []].append(Int(reply.ms.rounded()))
            if readMs[role]!.count > 40 { readMs[role]!.removeFirst(readMs[role]!.count - 40) }
            log.notice("reader answered role=\(role.rawValue, privacy: .public) via=\(job.target.via.rawValue, privacy: .public) ms=\(Int(reply.ms.rounded())) pid=\(reply.pid)")
        } else if let error = reply.error {
            log.notice("reader failed role=\(role.rawValue, privacy: .public) via=\(job.target.via.rawValue, privacy: .public) why=\(Self.name(error), privacy: .public)")
        }
        note("reply \(role.rawValue)/\(job.target.via.rawValue) client=\(job.client) frame=\(job.frame) \(reply.error.map(Self.name) ?? "ok") ms=\(Int(reply.ms.rounded()))")
        let delivery = scheduler.complete(role, id: job.id)
        if case .drop = delivery { Trace.count("reader.dropped") }
        if let p = jobs.removeValue(forKey: job.id) { deliver(p, job, reply, role: role, late: p.ticket.isDone, events: events) }
        handle(role, events)
        pump(role)
        pruneJobs()
        kickWarmup()
        return reply.error
    }

    /// A read the scheduler dropped from its queue (the original of a reroute answered first, or the client went) leaves its picture
    /// here: forget every job that is neither in flight nor queued.
    private func pruneJobs() {
        var live: Set<Int> = []
        for role in WorkerRole.allCases {
            if let job = scheduler.inFlight(role) { live.insert(job.id) }
            for job in scheduler.queued(role) { live.insert(job.id) }
        }
        jobs = jobs.filter { live.contains($0.key) }
    }

    private func deliver(_ p: Pending, _ job: ReadScheduler.Job, _ reply: ReadReply, role: WorkerRole, late: Bool, events: [WorkerHealth.Event]) {
        var p = p
        if late {
            counts.late += 1
            Trace.count("reader.\(role.rawValue).late")
            return
        }
        guard let error = reply.error else {
            let doc = job.target.via == .doc
            let result: ReadResult = doc ? .paragraphs(reply.paragraphs.map { $0.map(VisionExec.unwire) }) : .lines(reply.lines.map(VisionExec.unwire))
            if TextRecognizer.traceReads {
                let out: VisionExec.Output = doc ? .paragraphs(reply.paragraphs.map { $0.map(VisionExec.unwire) }) : .lines(reply.lines.map(VisionExec.unwire))
                TextRecognizer.printRead(Self.kind(of: job.target.via), size: p.ask.size, roi: p.ask.roi, out)
            }
            if p.ticket.finish(result) { ReaderClients.shared.completed(p.ask.client) }
            // An answer within S ends a streak of slow document answers (the slow one is `.recovered`, handled with the events).
            if doc, !events.contains(where: { if case .recovered = $0 { true } else { false } }) { rest.answeredInTime() }
            return
        }
        // The read goes on with what is left, a few times at most: a rung that is not ready rests (`WorkerHealth`), a worker that
        // is gone is `restarting`, and a document model that failed leaves the layout to the grouper.
        p.tries += 1
        let doc = job.target.via == .doc
        if doc { Trace.count("ocr.swift.failed") }
        if p.tries <= 3, doc || error.programsNotReady || error.serviceLost {
            p.noDocs = p.noDocs || doc
            counts.retried += 1
            Trace.count("reader.retried")
            ReaderClients.shared.failed(p.ask.client)
            submit(p, client: job.client, frame: nextFrame(job.client), purpose: job.purpose)
        } else {
            if p.ticket.finish(.failed(error)) { ReaderClients.shared.failed(p.ask.client) }
        }
    }

    private static func name(_ error: ReadFailure) -> String {
        switch error {
        case .programsNotReady: "programsNotReady"
        case .failed: "failed"
        case .badJob: "badJob"
        case .interrupted: "interrupted"
        case .unavailable: "unavailable"
        }
    }

    private func connectionEvent(_ role: WorkerRole, _ event: ReaderConnectionEvent) {
        switch event {
        case let .connected(_, pid):
            log.notice("reader service connected role=\(role.rawValue, privacy: .public) pid=\(pid)")
        case .interrupted, .invalidated:
            handle(role, health[role]!.interrupted(now: Trace.now))
            // The request that was in flight answers with its own error (`replied`); a worker without one just restarts.
        }
    }

    // MARK: Health events

    private func handle(_ role: WorkerRole, _ events: [WorkerHealth.Event]) {
        let name = role.rawValue
        for event in events {
            switch event {
            case let .suspected(_, after):
                Trace.count("reader.\(name).suspect")
                log.notice("reader suspect role=\(name, privacy: .public) after=\(Int(after * 1000)) ms")
                note("suspect \(name)")
                rerouteQueued(role)
            case let .recovered(_, after):
                // A request that went suspect has answered. The first time the lenses read again at once; a Docs that keeps answering
                // past S rests before each next request, so that every recovery re-read does not send another one for ever.
                let wait = role == .docs ? rest.slowAnswer(now: Trace.now) : 0
                log.notice("reader recovered role=\(name, privacy: .public) after=\(Int(after * 1000)) ms rest=\(Int(wait)) s")
            case .warmed:
                break
            case .readerReady:
                note("readerReady \(name)")
                if role == .docs, let until = rest.until, until > Trace.now {
                    // The lenses that stood in read again when the rest is over, not before: they would only be turned away.
                    let wait = until - Trace.now
                    Task { [self] in
                        try? await Task.sleep(for: .seconds(wait))
                        announceReady(role)
                    }
                } else {
                    announceReady(role)
                }
            case .usableAgain:
                log.notice("reader usable again role=\(name, privacy: .public)")
                note("usableAgain \(name)")
                announceReady(role, standIns: false)
                // A rung that rests (Code 13) is usable again with its process; only a restarted worker has lost what was warm.
                if restarted.remove(role) != nil { rewarmPending = true }
            case let .stuck(_, after):
                log.notice("reader stuck role=\(name, privacy: .public) after=\(Int(after)) s")
                rerouteQueued(role)
            case let .recycle(why):
                recycle(role, why)
            case let .crashed(count):
                Trace.count("reader.\(name).crash")
                log.notice("reader service crashed role=\(name, privacy: .public) count=\(count)")
                rerouteQueued(role)
            case let .disabled(why):
                log.notice("reader disabled role=\(name, privacy: .public) why=\(why.rawValue, privacy: .public)")
                rerouteQueued(role)
                announceReady(role, standIns: false)
            case .idleExit:
                // R3b: the process exits (`exitWhenIdle`). Until then the state machine runs its timer without the exit.
                break
            case let .rungResting(via, wait):
                log.notice("reader rung resting role=\(name, privacy: .public) via=\(via.rawValue, privacy: .public) for=\(Int(wait)) s")
            }
        }
        if case .restarting = health[role]!.state { restarted.insert(role) }
        if events.contains(where: { if case .usableAgain = $0 { true } else { false } }) { kickWarmup() }
        watch(role)
        pump(role)
    }

    /// R3b: the stuck recycle (`killService`, the exit message in a sandbox) and the Code-13 and footprint recycles. Not acted on
    /// here: this slice never kills a request in flight, and the answer, if it comes, ends the episode.
    private func recycle(_ role: WorkerRole, _ why: WorkerHealth.RecycleWhy) {
        log.notice("reader recycle not done role=\(role.rawValue, privacy: .public) why=\(why.rawValue, privacy: .public)")
    }

    /// Whether anything wants this worker alive (it keeps an idle worker from exiting). R3b: Lines only while a lens is on.
    private func wantsWorker(_ role: WorkerRole) -> Bool { true }

    /// The worker turned suspect: the lens reads queued behind its request, and the one in flight (it runs on), are routed again
    /// without it. A read with no other reader is `.unavailable` at once.
    private func rerouteQueued(_ role: WorkerRole) {
        // `MWOYEO_DOCS_WAIT=1`: the pass waits for the document answer however long, as the in-process path did.
        if Self.waitsForDocs, role == .docs { return }
        for job in scheduler.reroute(role) {
            guard let p = jobs[job.id] else { continue }
            if scheduler.inFlight(role)?.id != job.id { jobs[job.id] = nil }
            guard !p.ticket.isDone else { continue }
            submit(p, client: job.client, frame: job.frame, purpose: job.purpose)
        }
    }

    private func announceReady(_ role: WorkerRole, standIns: Bool = true) {
        var ids = ReaderClients.shared.takeWaiting()
        if standIns { ids = Array(Set(ids).union(scheduler.readerReady(role))).sorted() }
        guard !ids.isEmpty else { return }
        let told = ReaderClients.shared.notify(ids)
        counts.rereads += told
        Trace.count("reader.\(role.rawValue).ready")
        log.notice("reader ready role=\(role.rawValue, privacy: .public) rereads=\(told)")
    }

    /// `MWOYEO_DOCS_WAIT=1`: the pass waits until Docs can take the layout read, however long (the mutation of the silence gates).
    private func waitIfMutated(_ ask: ReadAsk) async {
        guard Self.waitsForDocs, ask.want == .layout else { return }
        while true {
            tickBoth()
            if route(ask, noDocs: false).target?.via == .doc { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func tickBoth() {
        for role in WorkerRole.allCases { handle(role, health[role]!.tick(now: Trace.now, wanted: wantsWorker(role))) }
    }

    /// Ticks the health at its next deadline while a request is in flight or the worker restarts, so that `suspect`, `stuck` and the
    /// restart's end are noticed when they happen, not at the next read. One timer per worker, re-armed after every change of state
    /// (`handle` ends here): a timer that was set for a warm-up's bound must not be the one that watches the next request's S.
    private func watch(_ role: WorkerRole) {
        watchers[role]?.cancel()
        watchers[role] = nil
        guard let wait = nextWake(role) else { return }
        watchers[role] = Task { [self] in
            try? await Task.sleep(for: .seconds(max(0.01, wait)))
            guard !Task.isCancelled else { return }
            handle(role, health[role]!.tick(now: Trace.now, wanted: wantsWorker(role)))
        }
    }

    private func nextWake(_ role: WorkerRole) -> TimeInterval? {
        let now = Trace.now
        let h = health[role]!
        switch h.state {
        case .busy, .suspect, .warming, .restarting: return h.nextDeadline(now: now).map { $0 - now }
        case .cold, .idle, .stuck, .disabled: return nil
        }
    }

    // MARK: Warming

    /// The initialization at every launch (and after a language change): for the key of `languages`, Lines then Docs, in the
    /// background and to completion (a load is never cancelled). A key that is new while a lens is on has no steps. A failed step
    /// is not retried here: the next launch or `retrySetup` does. Returns when the steps that could run have.
    func warmUp(languages: [Locale.Language]) async {
        want(TextRecognizer.key(languages))
        kickWarmup()
        while warmer != nil { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Every failed step is due again (the setup screen's retry button).
    func retryWarmup() {
        warmup.retry()
        TextRecognizer.setup { $0.retry() }
        kickWarmup()
    }

    private func want(_ key: String) {
        if warmup.want(key, lensOn: ReaderClients.shared.count > 0) {
            wantedKeys.append(key)
            TextRecognizer.setup { $0.want(key) }
            kickWarmup()
        }
    }

    private func kickWarmup() {
        guard warmer == nil, warmupDue || rewarmPending else { return }
        warmer = Task { [self] in
            await warmLoop()
            warmer = nil
        }
    }

    private func warmLoop() async {
        var blocked: TimeInterval = 0
        while true {
            if warmup.remaining == 0, rewarmPending {
                // A worker restarted without what it had warm: ask again for every key the app wants.
                rewarmPending = false
                warmup = ReaderWarmup()
                for key in wantedKeys { warmup.want(key, lensOn: false) }
            }
            guard warmupDue else { return }
            tickBoth()
            var slots = ReaderWarmup.idleSlots(lines: health[.lines]!, docs: health[.docs]!, scheduler: scheduler)
            if Self.ocrPath == .vn { slots.remove(.docs) }
            guard let step = warmup.nextDue(idleSlots: slots) else {
                // A lens's request is compiling, or a service restarts: the step goes after it.
                if blocked >= OCRHealth.coldWait { return }
                try? await Task.sleep(for: .milliseconds(200))
                blocked += 0.2
                continue
            }
            blocked = 0
            warmup.started(step, now: Trace.now)
            let due = SwiftVisionGate.Due(key: step.key, step: step.role == .lines ? .textModel : .documentModel)
            TextRecognizer.setup { $0.started(due, now: Trace.now) }
            let began = Trace.now
            var failure: String?
            do { try await perform(step) } catch { failure = String(describing: error) }
            warmup.finished(failure: failure, now: Trace.now)
            TextRecognizer.setup { $0.finished(failure: failure, now: Trace.now) }
            Trace.mark("reader warm-up \(step.role.rawValue) [\(step.key)] \(failure.map { "failed: \($0)," } ?? "done,")", since: began)
            if let failure { log.error("reader warm-up role=\(step.role.rawValue, privacy: .public) key=\(step.key, privacy: .public) failed: \(failure, privacy: .public)") }
            note("warm \(step.role.rawValue) \(failure == nil ? "done" : "failed")")
        }
    }

    /// Some step can still run: `MWOYEO_OCR_PATH=vn` never asks Docs, so its steps stay pending for good.
    private var warmupDue: Bool {
        guard warmup.remaining > 0 else { return false }
        guard Self.ocrPath == .vn else { return true }
        return wantedKeys.contains { if case .pending? = warmup.state(.init(.lines, $0)) { true } else { false } }
    }

    /// One warm-up step: a job in the service that compiles the model for the key's languages (tens of seconds when cold, ~0.6 s
    /// from the cache). Waits for the worker to be free, never cancels, and asks again while the programs are not ready (a fast
    /// Code 13 after a long compile) on `Backoff.rev3Rung`. Throws when the worker is disabled or the job fails for good.
    private func perform(_ step: ReaderWarmup.Step) async throws {
        let role = step.role
        var again = Backoff.rev3Rung
        let began = Trace.now
        var busy: TimeInterval = 0
        while true {
            let now = Trace.now
            handle(role, health[role]!.tick(now: now, wanted: wantsWorker(role)))
            if case .disabled = health[role]!.effectiveState(now: now) { throw WarmFailure(description: "the \(role.rawValue) service is disabled for this run") }
            if health[role]!.isWarm(step.via, key: step.key) { return }
            guard health[role]!.canDispatch, let job = scheduler.beginWarmup(client: 0, role: role, via: step.via, key: step.key, now: now) else {
                if busy >= OCRHealth.coldWait { throw WarmFailure(description: "the \(role.rawValue) service was busy for \(Int(busy)) s") }
                try await Task.sleep(for: .milliseconds(200))
                busy += 0.2
                continue
            }
            health[role]!.dispatch(job.workerJob, now: now)
            watch(role)
            log.notice("reader dispatched role=\(role.rawValue, privacy: .public) via=warm key=\(step.key, privacy: .public)")
            let readJob = role == .lines ? ReadJob(kind: .warmLines) : ReadJob(kind: .warmDoc, documentLanguages: TextRecognizer.languages(of: step.key))
            let reply = await execute(role, readJob, surface: nil, image: nil)
            let error = replied(role, job, reply)
            if error == nil, TextRecognizer.traceReads {
                TextRecognizer.printRead(readJob.kind, size: "probe", roi: nil, role == .lines ? .lines(reply.lines.map(VisionExec.unwire)) : .paragraphs(reply.paragraphs.map { $0.map(VisionExec.unwire) }))
            }
            guard let error else { return }
            if error.serviceLost {
                // The service went away with the job. `replied` told the health, which restarts it after its backoff.
                try await Task.sleep(for: .milliseconds(200))
            } else if error.programsNotReady, Trace.now - began < OCRHealth.coldWait {
                try await Task.sleep(for: .seconds(again.failure(now: Trace.now)))
            } else {
                throw error
            }
        }
    }

    // MARK: For the headless tools and the debugging

    private func note(_ line: String) {
        ring.append(String(format: "%.3f ", Trace.now) + line)
        if ring.count > 64 { ring.removeFirst(ring.count - 64) }
    }

    /// The last 64 transitions and reads, newest last (numbers and names only).
    func debugRing() -> [String] { ring }

    /// Requests in flight in the services (`SelfTest.Hooks.inFlight`): the drain before exit waits for it, so that a compile is not
    /// thrown away.
    var inFlight: Int { WorkerRole.allCases.filter { health[$0]!.state.job != nil }.count }

    /// Both workers are warm for every key the app asked for and idle (`SelfTest.Hooks.readerReady`, `--then reader-ready`). Nothing
    /// to wait for on a worker that the run does not use, and on a key that a lens's own read compiles (it has no warm-up).
    var isReady: Bool {
        let now = Trace.now
        for role in WorkerRole.allCases {
            if role == .docs, Self.ocrPath == .vn { continue }
            switch health[role]!.effectiveState(now: now) {
            case .cold, .idle: break
            default: return false
            }
            for key in wantedKeys where !health[role]!.isWarm(role == .lines ? .rev3 : .doc, key: key) { return false }
        }
        return true
    }

    /// `reader: <role> …`: numbers and names, two lines per worker (state and counts, then the footprint and the read times).
    func statsLines() -> [String] {
        var out: [String] = []
        let mb = { (bytes: UInt64) in Int(bytes / 1_048_576) }
        for role in [WorkerRole.docs, .lines] {
            let h = health[role]!
            let s = h.stats
            let warm = h.warm.map { "\($0.via.rawValue):\($0.key)" }.sorted().joined(separator: ",")
            let pid = Self.inProcess && role == .lines ? "inproc" : Self.connection(role).servicePid.map(String.init) ?? "-"
            var line = "reader: \(role.rawValue) state=\(h.state.name) pid=\(pid) warm=\(warm.isEmpty ? "-" : warm) "
                + "dispatched=\(s.dispatched.values.reduce(0, +)) answered=\(s.answered.values.reduce(0, +)) failed=\(s.failed.values.reduce(0, +)) "
                + "suspects=\(s.suspects) stuck=\(s.stuck) crashes=\(s.crashes) recycles=\(s.recycles)"
            if role == .docs { line += " slow-streak=\(rest.streak)" }
            out.append(line)
            out.append("reader: \(role.rawValue) footprint=\(mb(lastFootprint[role] ?? 0)) MB gui=\(mb(ReaderWire.physFootprint())) MB "
                + "last-ms=\(Int((lastServiceMs[role] ?? 0).rounded())) ms=\((readMs[role] ?? []).map(String.init).joined(separator: ","))")
        }
        out.append("reader: host reads=\(counts.reads) unavailable=\(counts.unavailable) rerouted=\(counts.rerouted) retried=\(counts.retried) "
            + "late=\(counts.late) rereads=\(counts.rereads) superseded=\(counts.superseded) docs-fallbacks=\(counts.docsFallbacks) "
            + "dropped=\(scheduler.dropped.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: ","))")
        if Self.showsRing { out += ring.map { "reader: ring \($0)" } }
        return out
    }
}

private extension ReadAsk {
    /// A routing question without a picture (`documentsUsable`).
    static func probe(key: String, ladder: [ReadVia]) -> ReadAsk {
        ReadAsk(want: .layout, key: key, ladder: ladder, image: ReaderProbe.pixel)
    }
}

private enum ReaderProbe {
    /// A 1x1 picture so that a routing question can use the same type as a read.
    static let pixel: CGImage = {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }()
}

private extension ReadFailure {
    /// The service went away with the request, or none answered: not a verdict on the picture.
    var serviceLost: Bool {
        switch self {
        case .interrupted, .unavailable: true
        default: false
        }
    }

    var programsNotReady: Bool {
        if case .programsNotReady = self { true } else { false }
    }
}
