import CoreGraphics
import Foundation
import MwoyeoCore
import os

/// The answer of one document request, for the pass that sent it and for whoever looks later. The request itself is the host's: it
/// runs to completion whether or not a pass is still waiting (design invariant I3: nothing is cancelled or abandoned by our side).
final class DocsRead: @unchecked Sendable {
    typealias Outcome = Result<[[OCRLine]], ReadFailure>

    private struct State {
        var outcome: Outcome?
        var waiter: CheckedContinuation<Outcome?, Never>?
        var timer: Task<Void, Never>?
        var gaveUp = false
    }

    let key: String
    /// "WxH" and the region, for the read trace (`MWOYEO_TRACE_READS`).
    let size: String
    let roi: CGRect?
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(key: String, size: String, roi: CGRect?) { self.key = key; self.size = size; self.roi = roi }

    /// The answer if it is here, now.
    var answer: Outcome? { state.withLock { $0.outcome } }

    /// The request came back. True when the pass had stopped waiting by then (a late answer).
    @discardableResult
    func finish(_ outcome: Outcome) -> Bool {
        let (waiter, timer, late) = state.withLock { s -> (CheckedContinuation<Outcome?, Never>?, Task<Void, Never>?, Bool) in
            s.outcome = outcome
            defer { s.waiter = nil; s.timer = nil }
            return (s.waiter, s.timer, s.gaveUp)
        }
        timer?.cancel()
        waiter?.resume(returning: outcome)
        return late
    }

    /// The answer, or nil when `seconds` have passed without one: the pass's patience S. The request goes on either way.
    func wait(seconds: Double) async -> Outcome? {
        await withCheckedContinuation { (cont: CheckedContinuation<Outcome?, Never>) in
            let here: Outcome?? = state.withLock { s in
                if let outcome = s.outcome { return .some(outcome) }
                s.waiter = cont
                return nil
            }
            if let here { cont.resume(returning: here); return }
            let timer = Task { [self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                let waiter = state.withLock { s -> CheckedContinuation<Outcome?, Never>? in
                    defer { s.waiter = nil }
                    if s.waiter != nil { s.gaveUp = true }
                    return s.waiter
                }
                waiter?.resume(returning: nil)
            }
            state.withLock { s in if s.outcome == nil { s.timer = timer } else { timer.cancel() } }
        }
    }
}

/// The pipelines (lenses, the image window, a headless render) as the Docs host knows them: an id each, what to tell it when Docs
/// is ready, and whether its last layout came from the grouper (`LayoutStandIns`). Lock-protected, so that a pipeline registers
/// from its initializer and a pass records its outcome without a hop to the host.
final class ReaderClients: @unchecked Sendable {
    static let shared = ReaderClients()

    private struct State {
        var next = 0
        var onReady: [Int: @Sendable () -> Void] = [:]
        var standIns = LayoutStandIns()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// A client id. `onReady` is called, once per Docs-ready event, when the client's last layout was a stand-in.
    func add(onReady: @escaping @Sendable () -> Void) -> Int {
        state.withLock { s in
            s.next += 1
            s.onReady[s.next] = onReady
            return s.next
        }
    }

    func remove(_ client: Int) {
        state.withLock { s in
            s.onReady[client] = nil
            s.standIns.forget(client)
        }
    }

    /// The client's read was answered by the grouper where it wanted the document layout.
    func fellBack(_ client: Int?) {
        guard let client else { return }
        state.withLock { $0.standIns.fellBack(client) }
    }

    /// The client got the document layout.
    func served(_ client: Int?) {
        guard let client else { return }
        state.withLock { $0.standIns.served(client) }
    }

    /// Docs is ready: every client that stood in for it reads once more. Returns how many were told.
    @discardableResult
    func docsReady() -> Int {
        let calls = state.withLock { s in s.standIns.ready().compactMap { s.onReady[$0] } }
        for call in calls { call() }
        return calls.count
    }
}

/// The Docs worker as the app hosts it in 1.1.2 (design §4.2 for one of the two workers): the XPC service that runs
/// `RecognizeDocumentsRequest`, the only place a document read happens. A document read that compiles its networks (34 s + 26 s for
/// the first figure page, ocr-stall-112) blocks every Vision request of its process, so it runs where nothing else does.
///
/// - **One request in flight.** `WorkerHealth(.docs)` says whether a read may go (`DocsRoute`): Docs idle and warm for the key.
///   Anything else reads with the grouper at once (v1.1.0 quality), and a lens never waits for Docs.
/// - **Patience, not a deadline.** The pass waits S (`ReadVia.doc.patience`, 2 s) for the answer. Past S the request is *suspect*:
///   the pass reads with the grouper, the request runs on, and its answer marks Docs warm for the key and ready for the lenses that
///   stood in for it (`ReaderClients.docsReady`). Nothing is cancelled and nothing is retried against the clock; a slow answer is
///   never a failure.
/// - **Warm-up** (`warm`) is a job in the service, never in this process, and never cancelled.
/// - **A crash** (`ReaderConnection` events) clears what was warm and restarts on `Backoff.workerRestart`; the warm-up job asks
///   again, which relaunches the service (launchd waits ~10 s when the last instance lived under 10 s, and the lens reads with the
///   grouper meanwhile).
/// - The `recycle` events of `WorkerHealth` are logged and not acted on: this slice never kills a request in flight.
///
/// R3-full folds this into `RecognitionHost` next to the Lines worker.
actor DocsHost {
    static let shared = DocsHost()

    /// What `send` returns.
    enum Sent {
        case fallback(DocsRoute.Why)
        case sent(DocsRead)
    }

    struct WarmFailure: Error, CustomStringConvertible { let description: String }

    /// How long a pass waits for Docs: S (`ReadVia.doc.patience`). `MWOYEO_DOCS_WAIT=1` is the mutation of the silence gates (it
    /// waits for Docs, however long, as the in-process path did): a gate that does not fail under it measures nothing.
    static let waitsForDocs = ProcessInfo.processInfo.environment["MWOYEO_DOCS_WAIT"] != nil
    static var patience: Double { waitsForDocs ? 3600 : ReadVia.doc.patience }

    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "reader")
    private let connection: ReaderConnection
    private let path: PathOverride?
    private var health = WorkerHealth(role: .docs)
    private var wanted: [String] = []
    private var watcher: Task<Void, Never>?
    private var rewarming = false
    /// After consecutive requests that answered past S, Docs rests before the next one (`DocsRest`, `DocsRoute` `restingUntil`).
    private var rest = DocsRest()

    private var fallbacks: [DocsRoute.Why: Int] = [:]
    private var lastFallbackLog: (why: DocsRoute.Why, at: TimeInterval)?
    private var lateAnswers = 0
    private var rereads = 0
    private var readMs: [Int] = []
    private var lastServiceMs = 0.0
    private var lastFootprint: UInt64 = 0

    private init() {
        connection = ReaderConnection.shared(.docs)
        path = ProcessInfo.processInfo.environment["MWOYEO_OCR_PATH"].flatMap(PathOverride.init(rawValue:))
        // The stream exists before anything is sent: a late listener missed events in R1's first fakes run.
        let events = connection.events()
        Task { [self] in for await event in events { await connectionEvent(event) } }
        SelfTest.register(inFlight: { await DocsHost.shared.inFlight },
                          readerReady: { await DocsHost.shared.isReady },
                          statsLines: { await DocsHost.shared.statsLines() })
    }

    // MARK: Reading

    /// Whether a read of `key` would go to Docs now. A read that cannot is counted and its client noted as standing in (`client`).
    func route(key: String, client: Int?) async -> DocsRoute {
        await waitIfMutated(key: key)
        let route = DocsRoute.route(docs: health, key: key, now: Trace.now, path: path, restingUntil: rest.until)
        if case let .fallback(why) = route { fellBack(client: client, why: why) }
        return route
    }

    /// The document read of a picture: sent to the service when Docs is idle and warm for `key`, else the reason it is not. The
    /// picture is packed (one copy into an IOSurface, ~3 ms for a Retina screen) only when it goes.
    func send(client: Int?, key: String, image: CGImage, roi: CGRect?, languages: [Locale.Language], customWords: [String]) async -> Sent {
        await waitIfMutated(key: key)
        let now = Trace.now
        handle(health.tick(now: now, wanted: true))
        if case let .fallback(why) = DocsRoute.route(docs: health, key: key, now: now, path: path, restingUntil: rest.until) {
            fellBack(client: client, why: why)
            return .fallback(why)
        }
        guard let packed = ReaderPixels.surface(from: image) else {
            fellBack(client: client, why: .packing)
            return .fallback(.packing)
        }
        let job = ReadJob(kind: .doc, image: packed.image, roi: roi, documentLanguages: languages, customWords: customWords)
        let workerJob = WorkerJob(via: .doc, key: key, purpose: .lens)
        health.dispatch(workerJob, now: now)
        watch()
        let read = DocsRead(key: key, size: "\(image.width)x\(image.height)", roi: roi)
        log.notice("docs dispatched kind=doc key=\(key, privacy: .public)")
        Task { [self] in
            let reply = await connection.perform(job, surface: packed.surface)
            replied(reply, kind: .doc, read: read)
        }
        return .sent(read)
    }

    /// `MWOYEO_DOCS_WAIT=1`: the pass waits until Docs can take the read, however long (the mutation of the silence gates).
    private func waitIfMutated(key: String) async {
        guard Self.waitsForDocs else { return }
        while true {
            let now = Trace.now
            handle(health.tick(now: now, wanted: true))
            if case .doc = DocsRoute.route(docs: health, key: key, now: now, path: path, restingUntil: rest.until) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Warming

    /// The warm-up of `key`: a job in the service that compiles the document model for the key's languages (tens of seconds when
    /// cold, ~0.6 s from the cache). Waits for the worker to be free, never cancels, and asks again while the programs are not ready
    /// (a fast Code 13 after a long compile) on `Backoff.rev3Rung`. Throws when Docs is disabled or the job fails for good.
    func warm(key: String, languages: [Locale.Language]) async throws {
        if !wanted.contains(key) { wanted.append(key) }
        var again = Backoff.rev3Rung
        let began = Trace.now
        var busy: TimeInterval = 0
        while true {
            let now = Trace.now
            handle(health.tick(now: now, wanted: true))
            if case .disabled = health.effectiveState(now: now) { throw WarmFailure(description: "the Docs service is disabled for this run") }
            if health.isWarm(.doc, key: key) { return }
            guard health.canDispatch else {
                // A lens's request is compiling, or the service restarts: the warm-up goes after it. Its answer may warm the key.
                if busy >= OCRHealth.coldWait { throw WarmFailure(description: "the Docs service was busy for \(Int(busy)) s") }
                try await Task.sleep(for: .milliseconds(200))
                busy += 0.2
                continue
            }
            health.dispatch(WorkerJob(via: .doc, key: key, purpose: .warmup), now: now)
            watch()
            log.notice("docs dispatched kind=warm key=\(key, privacy: .public)")
            let reply = await connection.perform(ReadJob(kind: .warmDoc, documentLanguages: languages))
            replied(reply, kind: .warmDoc, read: nil)
            if reply.error == nil, TextRecognizer.traceReads {
                TextRecognizer.printRead(.warmDoc, size: "probe", roi: nil, .paragraphs(reply.paragraphs.map { $0.map(VisionExec.unwire) }))
            }
            guard let error = reply.error else { return }
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

    // MARK: What came back

    private func replied(_ reply: ReadReply, kind: ReadKind, read: DocsRead?) {
        let now = Trace.now
        // A request that took S or longer is suspect by now, whether or not the timer ran yet: its answer is what recovers it.
        var events = health.tick(now: now, wanted: true)
        switch reply.error {
        case nil:
            events += health.reply(.answered, now: now)
        case .programsNotReady?:
            events += health.reply(.notReady, now: now)
        case .interrupted?, .unavailable?:
            // Nothing answered: the service is gone (the connection's own event says the same, and is a no-op after this).
            events += health.interrupted(now: now)
        case .failed?, .badJob?:
            events += health.reply(.failed, now: now)
        }
        if reply.pid != 0 { lastServiceMs = reply.ms; lastFootprint = reply.footprint }
        if reply.error == nil {
            readMs.append(Int(reply.ms.rounded()))
            if readMs.count > 40 { readMs.removeFirst(readMs.count - 40) }
            log.notice("docs answered kind=\(kind.rawValue, privacy: .public) ms=\(Int(reply.ms.rounded())) pid=\(reply.pid)")
        } else if let error = reply.error {
            log.notice("docs failed kind=\(kind.rawValue, privacy: .public) why=\(Self.name(error), privacy: .public)")
        }
        if let read {
            let paragraphs = reply.paragraphs.map { $0.map(VisionExec.unwire) }
            if reply.error == nil, TextRecognizer.traceReads { TextRecognizer.printRead(.doc, size: read.size, roi: read.roi, .paragraphs(paragraphs)) }
            let outcome: DocsRead.Outcome = reply.error.map { .failure($0) } ?? .success(paragraphs)
            if read.finish(outcome) {
                lateAnswers += 1
                Trace.count("reader.docs.late")
            } else if reply.error == nil {
                // An answer within S: the slow streak is over.
                rest.answeredInTime()
            }
        }
        handle(events)
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

    private func connectionEvent(_ event: ReaderConnectionEvent) {
        switch event {
        case let .connected(_, pid):
            log.notice("docs service connected pid=\(pid)")
        case .interrupted, .invalidated:
            handle(health.interrupted(now: Trace.now))
        }
    }

    private func fellBack(client: Int?, why: DocsRoute.Why) {
        fallbacks[why, default: 0] += 1
        Trace.count("reader.docs.fallback.\(why.rawValue)")
        ReaderClients.shared.fellBack(client)
        // One line when the reason changes or every 10 s, not one per pass: a scrolling lens reads 8 times a second.
        let now = Trace.now
        if lastFallbackLog?.why != why || now - (lastFallbackLog?.at ?? 0) >= 10 {
            lastFallbackLog = (why, now)
            log.notice("docs fallback why=\(why.rawValue, privacy: .public)")
        }
    }

    private func handle(_ events: [WorkerHealth.Event]) {
        for event in events {
            switch event {
            case let .suspected(_, after):
                Trace.count("reader.docs.suspect")
                log.notice("docs suspect after=\(Int(after * 1000)) ms")
            case let .recovered(_, after):
                // A request that went suspect has answered. The first time the lenses read again at once; a Docs that keeps answering
                // past S rests before each next request, so that every recovery re-read does not send another one for ever.
                let wait = rest.slowAnswer(now: Trace.now)
                log.notice("docs recovered after=\(Int(after * 1000)) ms rest=\(Int(wait)) s")
            case .warmed:
                break
            case .readerReady:
                if let until = rest.until, until > Trace.now {
                    // The lenses that stood in read again when the rest is over, not before: they would only be turned away.
                    let wait = until - Trace.now
                    Task { [self] in
                        try? await Task.sleep(for: .seconds(wait))
                        announceReady()
                    }
                } else {
                    announceReady()
                }
            case .usableAgain:
                log.notice("docs usable again")
                rewarmWanted()
            case let .stuck(_, after):
                log.notice("docs stuck after=\(Int(after)) s")
            case let .recycle(why):
                // Not acted on here: this slice never kills a request in flight. The answer, if it comes, ends the episode.
                log.notice("docs recycle not done why=\(why.rawValue, privacy: .public)")
            case let .crashed(count):
                Trace.count("reader.docs.crash")
                log.notice("docs service crashed count=\(count)")
            case let .disabled(why):
                log.notice("docs disabled why=\(why.rawValue, privacy: .public)")
            case .idleExit, .rungResting:
                break
            }
        }
        watch()
    }

    private func announceReady() {
        let told = ReaderClients.shared.docsReady()
        rereads += told
        Trace.count("reader.docs.ready")
        log.notice("docs ready rereads=\(told)")
    }

    /// The service restarted without what it had warm: ask again for every key the app wants.
    private func rewarmWanted() {
        guard !rewarming, !wanted.isEmpty else { return }
        rewarming = true
        Task { [self] in
            for key in wanted {
                try? await warm(key: key, languages: TextRecognizer.languages(of: key))
            }
            rewarming = false
        }
    }

    /// Ticks the health at its next deadline while a request is in flight or the worker restarts, so that `suspect`, `stuck` and the
    /// restart's end are noticed when they happen, not at the next read. One timer, re-armed after every change of state (`handle`
    /// ends here): a timer that was set for a warm-up's bound must not be the one that watches the next request's S.
    private func watch() {
        watcher?.cancel()
        watcher = nil
        guard let wait = nextWake() else { return }
        watcher = Task { [self] in
            try? await Task.sleep(for: .seconds(max(0.01, wait)))
            guard !Task.isCancelled else { return }
            handle(health.tick(now: Trace.now, wanted: true))
        }
    }

    private func nextWake() -> TimeInterval? {
        let now = Trace.now
        switch health.state {
        case .busy, .suspect, .warming, .restarting: return health.nextDeadline(now: now).map { $0 - now }
        case .cold, .idle, .stuck, .disabled: return nil
        }
    }

    // MARK: For the headless tools

    /// Requests in flight in the service (`SelfTest.Hooks.inFlight`): the drain before exit waits for it, so that a compile is not
    /// thrown away.
    var inFlight: Int { health.state.job == nil ? 0 : 1 }

    /// Docs is warm for every key the app asked for and idle (`SelfTest.Hooks.readerReady`, `--then reader-ready`). Nothing to wait
    /// for when documents are off.
    var isReady: Bool {
        if path == .vn { return true }
        let now = Trace.now
        switch health.effectiveState(now: now) {
        case .cold, .idle: return !wanted.isEmpty && wanted.allSatisfy { health.isWarm(.doc, key: $0) }
        default: return false
        }
    }

    /// `reader: docs …`: numbers and names, one line for the service and one for the reads.
    func statsLines() -> [String] {
        let s = health.stats
        let why = DocsRoute.Why.allCases.compactMap { w in fallbacks[w].map { "\(w.rawValue):\($0)" } }.joined(separator: ",")
        let warm = health.warm.map { "\($0.key)" }.sorted().joined(separator: ",")
        let mb = { (bytes: UInt64) in Int(bytes / 1_048_576) }
        return [
            "reader: docs state=\(health.state.name) pid=\(connection.servicePid.map(String.init) ?? "-") warm=\(warm.isEmpty ? "-" : warm) "
                + "dispatched=\(s.dispatched.values.reduce(0, +)) answered=\(s.answered.values.reduce(0, +)) failed=\(s.failed.values.reduce(0, +)) "
                + "suspects=\(s.suspects) stuck=\(s.stuck) crashes=\(s.crashes) late=\(lateAnswers) rereads=\(rereads) slow-streak=\(rest.streak) "
                + "fallbacks=\(why.isEmpty ? "-" : why)",
            "reader: docs footprint=\(mb(lastFootprint)) MB gui=\(mb(ReaderWire.physFootprint())) MB last-ms=\(Int(lastServiceMs.rounded())) "
                + "ms=\(readMs.map(String.init).joined(separator: ","))",
        ]
    }
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
