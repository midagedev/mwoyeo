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

/// The picture side of the reads in progress: the asks (which carry the pictures), their tickets, and the pictures packed for the
/// jobs about to be sent. Lock-protected: the core's `pack` closure runs inside its calls, the actor's code around them.
private final class ReadDesk: @unchecked Sendable {
    struct Packed {
        var ask: ReadAsk
        var surface: IOSurface?
        var image: ReadImage?
    }

    private struct State {
        var asks: [Int: (ask: ReadAsk, ticket: ReadTicket)] = [:]
        var packed: [Int: Packed] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func add(_ ticket: Int, ask: ReadAsk, waiter: ReadTicket) { state.withLock { $0.asks[ticket] = (ask, waiter) } }

    func entry(_ ticket: Int) -> (ask: ReadAsk, ticket: ReadTicket)? { state.withLock { $0.asks[ticket] } }

    func remove(_ ticket: Int) { state.withLock { $0.asks[ticket] = nil } }

    /// Packs the picture of a job about to be sent (`ReaderHostCore.pack`); false when it cannot be packed.
    func pack(_ order: SendOrder) -> Bool {
        guard let ticket = order.ticket, let entry = entry(ticket) else { return false }
        var packed = Packed(ask: entry.ask)
        if !(RecognitionHost.inProcess && order.role == .lines) {
            guard let made = ReaderPixels.surface(from: entry.ask.image) else { return false }
            packed.image = made.image
            packed.surface = made.surface
        }
        state.withLock { $0.packed[order.job.id] = packed }
        return true
    }

    func take(job: Int) -> Packed? { state.withLock { $0.packed.removeValue(forKey: job) } }
}

/// The two Vision workers as the app hosts them (design §4): one actor owns both `ReaderConnection`s and does what `ReaderHostCore`
/// asks. The core is the policy (g2-fast-host-gates, 2026-10-19): `WorkerHealth` per role, `ReadRouter` and `ReadScheduler`, Docs'
/// rest, the retries of a read, the stand-ins that read again, and the warm-up (`ReaderWarmup`); it takes `now` and hands back
/// effects, so that Core's tests run its decisions on a fake clock. What stays here is the wiring: the XPC calls, the pictures,
/// the tickets the passes wait on, a timer per worker, the lens's hint (`ReaderClients`), the log and the trace. The services are the
/// only place Vision runs (`MWOYEO_READER=inproc` runs the Lines kinds here, for the equal gate and A/B; it is never the default).
///
/// - **One request in flight per worker.** A read is routed, submitted (latest wins per client, lens before image before warm-up)
///   and sent when its worker is free. A pass waits on its ticket for the answer.
/// - **Patience, not a deadline.** A request turns *suspect* at S(kind): the reads queued behind it and the pass waiting for it are
///   routed again without it, and the request runs on, never cancelled. Its answer, if it is first, is the pass's; else it is a late
///   result that only marks the worker usable again, and the lenses that stood in re-read once (`readerReady`).
/// - **No reader, no timeout.** When the router has none, the pass gets `.unavailable(why)` at once and reads again on `readerReady`
///   or `usableAgain`, never on a timer; the lens's hint says why (`ReadWait`).
/// - **Warm-up** (`warmUp`) follows `ReaderWarmup`: Lines first, Docs after, never while a lens is on for a key it has not seen.
/// - **A crash** clears what was warm, restarts on `Backoff.workerRestart` and warms again; the services relaunch on the next job.
///
/// Every duration is `RecognitionHost.timing` (`ReaderTiming`): the shipped numbers, and in a non-MAS build `MWOYEO_READER_TIMING`
/// (scaled-down numbers for the real-process smoke of tools/ocr-probe/host-gates.sh) and `MWOYEO_DOCS_WAIT=1`.
///
/// Seams left for R3b (lifecycle): the core ignores `.idleExit` and logs `.recycle` without acting; the per-role idle exit and the
/// footprint check are `WorkerHealth`'s events, and `wantsWorker` is what keeps an idle worker alive.
actor RecognitionHost {
    static let shared = RecognitionHost()

    // The environment switches below are for the equal gate, the benches and the smoke tests: the App Store build reads none of them.
    #if MAS
    static let inProcess = false
    static let ocrPath: PathOverride? = nil
    static let timing = ReaderTiming.standard
    private static let showsRing = false
    #else
    /// `MWOYEO_READER=inproc`: the Lines kinds run in this process (the equal gate's baseline). Documents never do.
    static let inProcess = ProcessInfo.processInfo.environment["MWOYEO_READER"] == "inproc"
    /// `MWOYEO_OCR_PATH=vn|swift` for the benches.
    static let ocrPath = ProcessInfo.processInfo.environment["MWOYEO_OCR_PATH"].flatMap(PathOverride.init(rawValue:))
    /// The durations of the host. `MWOYEO_READER_TIMING=doc=0.5,restart=0.2/2,…` (`ReaderTiming.applying`) scales them down for a
    /// smoke test; `MWOYEO_DOCS_WAIT=1` is the mutation of the silence gates: a layout read waits for Docs however long, as the
    /// in-process path did, and a gate that does not fail under it measures nothing.
    static let timing: ReaderTiming = {
        let environment = ProcessInfo.processInfo.environment
        var (timing, unknown) = ReaderTiming.standard.applying(environment["MWOYEO_READER_TIMING"])
        if environment["MWOYEO_DOCS_WAIT"] != nil { timing.waitsForDocs = true }
        for typo in unknown {
            FileHandle.standardError.write("reader: MWOYEO_READER_TIMING entry not understood: \(typo) (names: \(ReaderTiming.names.joined(separator: " ")))\n".data(using: .utf8)!)
        }
        return timing
    }()
    private static let showsRing = ProcessInfo.processInfo.environment["MWOYEO_READER_RING"] != nil
    #endif

    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "reader")
    private var core: ReaderHostCore
    private let desk = ReadDesk()
    private var warmer: Task<Void, Never>?
    private var watchers: [WorkerRole: Task<Void, Never>] = [:]
    private var nextTicket = 0
    private var anonymous = 0

    private var readMs: [WorkerRole: [Int]] = [:]
    private var lastServiceMs: [WorkerRole: Double] = [:]
    private var lastFootprint: [WorkerRole: UInt64] = [:]

    private init() {
        var core = ReaderHostCore(timing: Self.timing, path: Self.ocrPath)
        let desk = desk
        core.pack = { desk.pack($0) }
        core.freeSpace = { HomeVolume.freeBytes() }
        self.core = core
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
        let plan = ask.plan
        // `MWOYEO_DOCS_WAIT=1`: the pass waits until Docs can take the layout read, however long (the mutation of the silence gates).
        while core.mustWaitForDocs(plan, now: Trace.now) {
            apply()
            try? await Task.sleep(for: .seconds(Self.timing.docsWaitPoll))
        }
        apply()
        let ticket = ReadTicket()
        nextTicket += 1
        let id = nextTicket
        desk.add(id, ask: ask, waiter: ticket)
        let client: Int
        if let c = ask.client { client = c } else { anonymous -= 1; client = anonymous }
        core.read(plan, ticket: id, client: client, now: Trace.now)
        apply()
        let result = await ticket.wait()
        if ask.client == nil { core.release(client: client) }
        return result
    }

    /// Whether a layout read of `key` would go to the Docs service now (it is idle and warm for the key and not resting). The
    /// client that is turned away reads again when Docs is ready.
    func documentsUsable(key: String, ladder: [ReadVia]) async -> Bool {
        let probe = ReadPlan(want: .layout, key: key, ladder: ladder)
        while core.mustWaitForDocs(probe, now: Trace.now) {
            apply()
            try? await Task.sleep(for: .seconds(Self.timing.docsWaitPoll))
        }
        let usable = core.documentsUsable(key: key, ladder: ladder, now: Trace.now)
        apply()
        return usable
    }

    /// The pipeline went away: its queued read, its frame record and its stand-in flag go.
    func forget(client: Int) {
        core.forget(client: client)
        apply()
    }

    private static func kind(of via: ReadVia) -> ReadKind {
        switch via {
        case .doc: .doc
        case .rev3: .rev3
        case .rev2: .rev2
        case .fast: .fast
        }
    }

    /// Sends the job the core dispatched: its picture was packed by `ReadDesk.pack` when the core took it from the queue.
    private func send(_ order: SendOrder) {
        guard let packed = desk.take(job: order.job.id) else { return }
        let role = order.role
        let job = order.job
        let ask = packed.ask
        let via = job.target.via
        let readJob = ReadJob(kind: Self.kind(of: via), image: packed.image, roi: ask.roi, languages: ask.languages[via] ?? [],
                              documentLanguages: ask.documentLanguages, customWords: ask.customWords)
        let surface = packed.surface
        Task { [self] in
            let reply = await execute(role, readJob, surface: surface, image: ask.image)
            replied(role, job, reply)
        }
    }

    /// One job to the service of `role`; the Lines kinds in this process under `MWOYEO_READER=inproc`.
    private nonisolated func execute(_ role: WorkerRole, _ job: ReadJob, surface: IOSurface?, image: CGImage?) async -> ReadReply {
        guard Self.inProcess, role == .lines else { return await Self.connection(role).perform(job, surface: surface) }
        let began = Trace.now
        do {
            let (out, lowConfidence) = try await VisionExec.runCounting(job.kind, image: image, roi: job.roi, languages: job.languages,
                                                                        documentLanguages: job.documentLanguages, customWords: job.customWords)
            return ReadReply(id: job.id, role: .lines, pid: 0, lines: out.lines.map(VisionExec.wire),
                             paragraphs: out.paragraphs.map { $0.map(VisionExec.wire) }, ms: (Trace.now - began) * 1000, lowConfidence: lowConfidence)
        } catch {
            return ReadReply(id: job.id, role: .lines, pid: 0, error: ReadFailure.from(error))
        }
    }

    // MARK: What came back

    private func record(_ role: WorkerRole, _ reply: ReadReply) {
        if reply.pid != 0 || Self.inProcess { lastServiceMs[role] = reply.ms; lastFootprint[role] = reply.footprint }
        if reply.error == nil {
            readMs[role, default: []].append(Int(reply.ms.rounded()))
            if readMs[role]!.count > 40 { readMs[role]!.removeFirst(readMs[role]!.count - 40) }
        }
    }

    private func replied(_ role: WorkerRole, _ job: ReadScheduler.Job, _ reply: ReadReply) {
        record(role, reply)
        core.replied(role, job, error: reply.error, ms: Int(reply.ms.rounded()), pid: reply.pid, lowConfidence: reply.lowConfidence, now: Trace.now)
        apply(reply: reply)
    }

    private func connectionEvent(_ role: WorkerRole, _ event: ReaderConnectionEvent) {
        switch event {
        case let .connected(_, pid):
            log.notice("reader service connected role=\(role.rawValue, privacy: .public) pid=\(pid)")
        case .interrupted, .invalidated:
            core.connectionLost(role, now: Trace.now)
            apply()
            // The request that was in flight answers with its own error (`replied`); a worker without one just restarts.
        }
    }

    // MARK: What the core asks

    /// Does what the core decided since the last call, in order. `reply` is the answer of the request whose decisions these are.
    private func apply(reply: ReadReply? = nil) {
        for effect in core.drain() {
            switch effect {
            case let .log(line): log.notice("\(line, privacy: .public)")
            case let .logError(line): log.error("\(line, privacy: .public)")
            case let .count(key): Trace.count(key)
            case let .trace(label, since): Trace.mark(label, since: since)
            case let .routed(client, route): ReaderClients.shared.routed(client, route)
            case let .completed(client): ReaderClients.shared.completed(client)
            case let .failed(client): ReaderClients.shared.failed(client)
            case let .finish(ticket, verdict): finish(ticket, verdict, reply: reply)
            case let .send(order): send(order)
            case let .watch(role): watch(role)
            case let .announce(role, standIns): announce(role, standIns: standIns)
            case let .announceAfter(role, wait):
                // The lenses that stood in read again when the rest of Docs is over, not before: they would only be turned away.
                Task { [self] in
                    try? await Task.sleep(for: .seconds(wait))
                    core.announceNow(role)
                    apply()
                }
            case let .setup(change): setup(change)
            case .kickWarmup: kickWarmup()
            }
        }
    }

    private func finish(_ id: Int, _ verdict: ReadVerdict, reply: ReadReply?) {
        guard let (ask, ticket) = desk.entry(id) else { return }
        desk.remove(id)
        switch verdict {
        case let .answer(via):
            guard let reply else { ticket.finish(.failed(.failed("the answer was lost"))); return }
            let doc = via == .doc
            let result: ReadResult = doc ? .paragraphs(reply.paragraphs.map { $0.map(VisionExec.unwire) }) : .lines(reply.lines.map(VisionExec.unwire))
            if TextRecognizer.traceReads {
                let out: VisionExec.Output = doc ? .paragraphs(reply.paragraphs.map { $0.map(VisionExec.unwire) }) : .lines(reply.lines.map(VisionExec.unwire))
                TextRecognizer.printRead(Self.kind(of: via), size: ask.size, roi: ask.roi, out)
                TextRecognizer.dumpRead(ask.image, kind: Self.kind(of: via), roi: ask.roi)
            }
            ticket.finish(result)
        case let .unavailable(why): ticket.finish(.unavailable(why))
        case let .failed(error): ticket.finish(.failed(error))
        case .superseded: ticket.finish(.superseded)
        }
    }

    private func setup(_ change: ReaderHostCore.SetupChange) {
        switch change {
        case let .want(key): TextRecognizer.setup { $0.want(key) }
        case .retry: TextRecognizer.setup { $0.retry() }
        case let .started(due, now): TextRecognizer.setup { $0.started(due, now: now) }
        case let .finished(failure, now): TextRecognizer.setup { $0.finished(failure: failure, now: now) }
        }
    }

    /// A reader is ready: the clients that found none, and the ones that stood in for it, read again.
    private func announce(_ role: WorkerRole, standIns: [Int]) {
        let ids = Array(Set(ReaderClients.shared.takeWaiting()).union(standIns)).sorted()
        guard !ids.isEmpty else { return }
        let told = ReaderClients.shared.notify(ids)
        core.counts.rereads += told
        Trace.count("reader.\(role.rawValue).ready")
        log.notice("reader ready role=\(role.rawValue, privacy: .public) rereads=\(told)")
    }

    /// Ticks the health at its next deadline while a request is in flight or the worker restarts, so that `suspect`, `stuck` and the
    /// restart's end are noticed when they happen, not at the next read. One timer per worker, re-armed after every change of state:
    /// a timer that was set for a warm-up's bound must not be the one that watches the next request's S.
    private func watch(_ role: WorkerRole) {
        watchers[role]?.cancel()
        watchers[role] = nil
        guard let wait = core.nextWake(role, now: Trace.now) else { return }
        watchers[role] = Task { [self] in
            try? await Task.sleep(for: .seconds(max(0.01, wait)))
            guard !Task.isCancelled else { return }
            core.timerFired(role, now: Trace.now)
            apply()
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
        core.retryWarmup()
        apply()
    }

    private func want(_ key: String) {
        core.want(key, lensOn: ReaderClients.shared.count > 0)
        apply()
    }

    private func kickWarmup() {
        guard warmer == nil, core.warmWanted else { return }
        warmer = Task { [self] in
            await warmLoop()
            warmer = nil
        }
    }

    /// Drives the core's warm-up coroutine: it says to wait, or to run a job in a service, until nothing is due.
    private func warmLoop() async {
        var action = core.warmStart(now: Trace.now)
        apply()
        while true {
            switch action {
            case .stop:
                return
            case let .sleep(seconds):
                try? await Task.sleep(for: .seconds(seconds))
                action = core.warmResume(now: Trace.now)
                apply()
            case let .send(order):
                let role = order.role
                let languages = order.warm.map { TextRecognizer.languages(of: $0.key) } ?? []
                let readJob = role == .lines ? ReadJob(kind: .warmLines) : ReadJob(kind: .warmDoc, documentLanguages: languages)
                let reply = await execute(role, readJob, surface: nil, image: nil)
                record(role, reply)
                action = core.warmReplied(error: reply.error, ms: Int(reply.ms.rounded()), pid: reply.pid, now: Trace.now)
                if reply.error == nil, TextRecognizer.traceReads {
                    TextRecognizer.printRead(readJob.kind, size: "probe", roi: nil, role == .lines ? .lines(reply.lines.map(VisionExec.unwire)) : .paragraphs(reply.paragraphs.map { $0.map(VisionExec.unwire) }))
                }
                apply()
            }
        }
    }

    // MARK: For the headless tools and the debugging

    /// The last 64 transitions and reads, newest last (numbers and names only).
    func debugRing() -> [String] { core.ring }

    /// Requests in flight in the services (`SelfTest.Hooks.inFlight`): the drain before exit waits for it, so that a compile is not
    /// thrown away.
    var inFlight: Int { core.inFlight }

    /// Both workers are warm for every key the app asked for and idle (`SelfTest.Hooks.readerReady`, `--then reader-ready`).
    var isReady: Bool { core.isReady(now: Trace.now) }

    /// `reader: <role> …`: numbers and names, two lines per worker (state and counts, then the footprint and the read times).
    func statsLines() -> [String] {
        var out: [String] = []
        let mb = { (bytes: UInt64) in Int(bytes / 1_048_576) }
        for role in [WorkerRole.docs, .lines] {
            let h = core.health[role]!
            let s = h.stats
            let warm = h.warm.map { "\($0.via.rawValue):\($0.key)" }.sorted().joined(separator: ",")
            let pid = Self.inProcess && role == .lines ? "inproc" : Self.connection(role).servicePid.map(String.init) ?? "-"
            var line = "reader: \(role.rawValue) state=\(h.state.name) pid=\(pid) warm=\(warm.isEmpty ? "-" : warm) "
                + "dispatched=\(s.dispatched.values.reduce(0, +)) answered=\(s.answered.values.reduce(0, +)) failed=\(s.failed.values.reduce(0, +)) "
                + "suspects=\(s.suspects) stuck=\(s.stuck) crashes=\(s.crashes) recycles=\(s.recycles)"
            if role == .docs { line += " slow-streak=\(core.rest.streak)" }
            line += " free=\(h.freeBytes.map { "\(mb($0)) MB" } ?? "-") compile-fails=\(h.compileFailuresInWindow) "
                + "last-compile-fail=\(h.lastCompileFailure.map { String(format: "%.0f", $0) } ?? "-") "
                + "rest-until=\(h.restUntil.map { String(format: "%.0f", $0) } ?? "-") nospace=\(h.lacksDiskSpace)"
            out.append(line)
            out.append("reader: \(role.rawValue) footprint=\(mb(lastFootprint[role] ?? 0)) MB gui=\(mb(ReaderWire.physFootprint())) MB "
                + "last-ms=\(Int((lastServiceMs[role] ?? 0).rounded())) ms=\((readMs[role] ?? []).map(String.init).joined(separator: ","))")
        }
        let c = core.counts
        out.append("reader: host reads=\(c.reads) unavailable=\(c.unavailable) rerouted=\(c.rerouted) retried=\(c.retried) "
            + "late=\(c.late) rereads=\(c.rereads) superseded=\(c.superseded) docs-fallbacks=\(c.docsFallbacks) "
            + "low-confidence=\(c.lowConfidence) "
            + "dropped=\(core.scheduler.dropped.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: ","))")
        if Self.showsRing { out += core.ring.map { "reader: ring \($0)" } }
        return out
    }
}

/// The free space the compiler can use: the home volume's raw available capacity, not the "for important usage" figure (which counts
/// purgeable space as free): the compiler service is a root daemon whose `F_PREALLOCATE` does not purge anything. A sandboxed app reads
/// the attributes of its own container's volume without an entitlement. Nil when it cannot be read.
enum HomeVolume {
    static func freeBytes() -> UInt64? {
        let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.flatMap { UInt64(exactly: $0) }
    }
}

extension ReadAsk {
    /// What the host's policy needs of this ask (`ReaderHostCore`): not the picture, not Vision's identifiers.
    var plan: ReadPlan { ReadPlan(client: client, purpose: purpose, want: want, layoutWanted: layoutWanted, key: key, ladder: ladder) }
}
