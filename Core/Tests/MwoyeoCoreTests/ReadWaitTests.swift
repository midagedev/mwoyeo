import Foundation
import Testing
@testable import MwoyeoCore

/// R2 reader-core (2026-10-18, design §4.7): one lens's wait for a reader, and the whole flow on a simulated clock.
@Suite struct ReadWaitTests {
    private let target = ReadTarget(role: .lines, via: .rev3)

    @Test func aDispatchIsReadingAndEveryRerouteResetsIt() {
        var w = ReadWait()
        #expect(w.state == .idle && w.hint == nil)
        w.routed(.dispatch(target), now: 10)
        #expect(w.state == .reading(since: 10) && w.readingSince == 10 && w.hint == nil)
        w.routed(.queue(target), now: 12)                        // rerouted behind another request: reading from now on
        #expect(w.state == .reading(since: 12))
    }

    @Test func noReaderIsAHintAtOnceAndKeepsItsStartWhileTheSameReasonLasts() {
        var w = ReadWait()
        w.routed(.unavailable(.preparing), now: 5)
        #expect(w.state == .waiting(.preparing, since: 5) && w.hint == .preparing)
        w.routed(.unavailable(.preparing), now: 9)               // asked again on a readerReady that found nobody
        #expect(w.state == .waiting(.preparing, since: 5))
        w.routed(.unavailable(.notResponding), now: 250)         // a different reason is a new wait
        #expect(w.state == .waiting(.notResponding, since: 250) && w.hint == .notResponding)
        w.routed(.unavailable(.restartApp), now: 260)
        #expect(w.hint == .restartApp)
    }

    @Test func aReaderEndsTheHintAndAReadShowsAndAFailureOrAResetIsQuiet() {
        var w = ReadWait()
        w.routed(.unavailable(.preparing), now: 0)
        w.routed(.dispatch(target), now: 80)
        #expect(w.hint == nil)
        w.completed()
        #expect(w.state == .showing && w.hint == nil && w.readingSince == nil)
        w.routed(.dispatch(target), now: 90)
        w.failed()
        #expect(w.state == .idle)
        w.routed(.unavailable(.preparing), now: 91)
        w.reset()
        #expect(w.state == .idle && w.hint == nil)
    }

    // MARK: the whole flow on a simulated clock

    private let docEN = WarmKey(.doc, "en"), rev3EN = WarmKey(.rev3, "en")

    /// §4.7's worst case for one lens: Docs is suspect at S_docs = 2 s, the reroute goes to Lines, and Lines is not answering either.
    /// Docs suspect → Lines suspect → a read that lands. The lens is silent (no hint, no translation) for at most 5 s here and shows
    /// its translation at 7.38 s: the design's sum 2 + 3 + 1.5 + 0.29 + 0.59 = 7.4 s, inside N = 8 s.
    ///
    /// Each lens queued ahead of this one adds about 0.9 s (one typical read, 0.25-0.88 s warm; `lensesQueuedOnOneWorkerAddOneRead`
    /// below), so the bound N = 8 s holds for a single lens (§10.7); with more lenses the bound is 8 s + 0.9 s per lens ahead.
    @Test func testSilenceBound() {
        // Docs compiles a network for 40 s (doc p13: 34.3 s); Lines answers its first read slowly (a new width class compiling):
        // 4.5 s, i.e. suspect at 3 s and back at 4.5 s.
        var sim = ReaderSim(service: { role, via, n in
            switch (role, via, n) {
            case (.docs, .doc, 0): 40
            case (.lines, .rev3, 0): 4.5
            default: 0.4
            }
        })
        sim.warm(.docs, .doc, "en")
        sim.warm(.lines, .rev3, "en")
        sim.start(client: 1, RouteRequest(want: .layout, key: "en", ladder: [.rev3, .rev2, .fast]))
        let silent = sim.sample(client: 1, until: 12)

        // Docs went suspect at S_docs, the read moved to Lines at once; Lines went suspect at S_lines after that.
        #expect(sim.dispatches[1]?.map(\.via) == [.doc, .rev3])
        let handoff = sim.dispatches[1]?.dropFirst().first
        #expect(abs((handoff?.at ?? -99) - 2) < 1e-9)
        // Hint up at S after the last candidate was handed the read, and not before: no hint while a reroute target existed.
        let hintAt = sim.hintAt[1]
        #expect(hintAt != nil)
        #expect(abs((hintAt ?? 0) - 5) < 1e-9)
        #expect((hintAt ?? 99) - (handoff?.at ?? -99) <= ReadVia.rev3.patience + 1e-9)
        #expect(sim.hintLog[1]?.first?.what == .preparing)
        #expect(silent <= 5.0 + 1e-9)
        // The read lands (Lines answered at 2 + 4.5 s), then erase and the first batch.
        let shown = sim.translation[1]
        #expect(abs((shown ?? 0) - 7.38) < 1e-9)
        #expect(silent <= 8)
        #expect((shown ?? 99) <= 8)
        // The hint went away when the translation came, and the pill stays quiet after.
        #expect(sim.waits[1]?.hint == nil)
        // Docs finishes its compile at 40 s: its result is late and dropped, and the lens reads once more through Docs.
        sim.advance(to: 45)
        #expect(sim.sched.dropped[.rerouted] == 1)
        #expect(sim.rereads == [1])
        #expect(sim.docs.state == .idle && sim.docs.isWarm(.doc, key: "en"))
    }

    /// The same flow when Lines is healthy: no hint ever, and the first translation at 2 + 1.5 + 0.88 = 4.38 s (design §2.1: ≈ 4.4).
    @Test func aHealthyReroutePutsNoHintUpAtAll() {
        var sim = ReaderSim(service: { role, via, n in
            switch (role, via, n) {
            case (.docs, .doc, 0): 40
            case (.lines, .rev3, _): 1.5
            default: 0.4
            }
        })
        sim.warm(.docs, .doc, "en")
        sim.warm(.lines, .rev3, "en")
        sim.start(client: 1, RouteRequest(want: .layout, key: "en", ladder: [.rev3, .rev2, .fast]))
        let silent = sim.sample(client: 1, until: 8)
        #expect(sim.hintLog[1] == nil)
        #expect(sim.hintAt[1] == nil)
        #expect(abs((sim.translation[1] ?? 0) - 4.38) < 1e-9)
        #expect(silent <= 4.4 + 1e-9)
    }

    /// With no reroute (the router keeps Docs in the plan while it is suspect: today's "wait for the read" shape, and
    /// `MWOYEO_READER_REROUTE=off` of R3's gate), the lens is silent until the compile ends: ≥ 38 s.
    /// This test pins the *effect* of the real router; FAIL-first is the mutation that makes it route to a suspect worker.
    @Test func aLensDoesNotWaitForADocsCompile() {
        var sim = ReaderSim(service: { role, via, n in (role, via, n) == (.docs, .doc, 0) ? 40 : 0.4 })
        sim.warm(.docs, .doc, "en")
        sim.warm(.lines, .rev3, "en")
        sim.start(client: 1, RouteRequest(want: .layout, key: "en", ladder: [.rev3, .rev2, .fast]))
        let silent = sim.sample(client: 1, until: 45)
        #expect(silent < 8)
        #expect((sim.translation[1] ?? 99) < 8)
    }

    @Test func lensesQueuedOnOneWorkerAddOneReadEach() {
        // Two lenses read at once. Docs is the first worker for both: lens 1 is in flight, lens 2 queues behind it. At S_docs both
        // reroute to Lines, which reads them one after the other, 0.9 s each.
        var sim = ReaderSim(service: { role, via, n in
            switch (role, via) {
            case (.docs, .doc): n == 0 ? 40 : 0.4
            case (.lines, .rev3): 0.9
            default: 0.4
            }
        })
        sim.warm(.docs, .doc, "en")
        sim.warm(.lines, .rev3, "en")
        let request = RouteRequest(want: .layout, key: "en", ladder: [.rev3, .rev2, .fast])
        sim.start(client: 1, request)
        sim.start(client: 2, request)
        let silent = sim.sample(clients: [1, 2], until: 9)
        let first = sim.translation[1] ?? 99, second = sim.translation[2] ?? 99
        #expect(abs(first - (2 + 0.9 + 0.88)) < 1e-9)
        #expect(abs((second - first) - 0.9) < 1e-9)
        #expect((silent[1] ?? 99) <= 8 && (silent[2] ?? 99) <= 8 + 0.9)
        #expect(sim.hintLog[1] == nil && sim.hintLog[2] == nil)
    }

    @Test func aLatinLensReadsFastInDocsWhileLinesCompiles() {
        // The p13 fresh-id gate (§4.7, expected ~1-2 s): Lines is in its 80 s first compile, Docs has not compiled anything.
        var sim = ReaderSim(service: { _, _, _ in 0.1 })
        sim.warmup(.lines, .rev3, "en", takes: 80)
        sim.start(client: 1, RouteRequest(want: .lines, key: "en", ladder: [.rev3, .rev2, .fast]))
        let silent = sim.sample(client: 1, until: 5)
        #expect(sim.dispatches[1]?.map(\.via) == [.fast])
        #expect(sim.hintLog[1] == nil)
        #expect(abs((sim.translation[1] ?? 0) - 0.98) < 1e-9)
        #expect(silent <= 1.0 + 1e-9)
        // Lines is warm at 80 s: `readerReady(.lines)` and the lens that read `.fast` reads again, once.
        sim.advance(to: 81)
        #expect(sim.rereads == [1])
        #expect(sim.lines.isWarm(.rev3, key: "en"))
    }

    @Test func aJapaneseLensSaysSoAtOnceAndReadsWhenLinesIsWarm() {
        // No `.fast` for Japanese and Docs has nothing for it: the hint is up at the first read (≤ 3.5 s is R3's gate; here it is 0)
        // and the lens reads as soon as Lines is warm for "ja".
        var sim = ReaderSim(service: { _, _, _ in 0.3 })
        sim.warmup(.lines, .rev3, "ja", takes: 80)
        sim.start(client: 1, RouteRequest(want: .lines, key: "ja", ladder: [.rev3, .rev2]))
        sim.advance(to: 1)
        #expect(sim.hintAt[1] == 0)
        #expect(sim.waits[1]?.hint == .preparing)
        sim.advance(to: 79.9)
        #expect(sim.waits[1]?.hint == .preparing)
        _ = sim.sample(client: 1, until: 85)
        #expect(sim.waits[1]?.hint == nil)
        #expect(abs((sim.translation[1] ?? 0) - (80 + 0.3 + 0.88)) < 1e-9)
    }
}

/// What a test needs of the host: the pure types composed on a simulated clock, as `RecognitionHost` composes them (R3). The
/// clock is advanced to each deadline in order: health ticks, answers, then the routing that follows.
struct ReaderSim {
    struct Dispatch { var at: TimeInterval; var via: ReadVia; var role: WorkerRole }
    struct HintChange { var at: TimeInterval; var what: RecognitionWait? }

    var now: TimeInterval = 0
    var lines = WorkerHealth(role: .lines)
    var docs = WorkerHealth(role: .docs)
    var sched = ReadScheduler()
    var waits: [Int: ReadWait] = [:]
    /// How long a request takes, from its start: by worker, kind, and how many requests that worker has started.
    var service: (WorkerRole, ReadVia, Int) -> TimeInterval
    /// Erase and the first translation batch after a read lands (design §4.7: 0.29 + 0.59).
    var tail: TimeInterval = 0.88

    private var requests: [Int: RouteRequest] = [:]
    private var frames: [Int: Int] = [:]
    private var parked: Set<Int> = []
    private var due: [(at: TimeInterval, role: WorkerRole, id: Int)] = []
    private var started: [WorkerRole: Int] = [:]

    // what a test looks at
    var dispatches: [Int: [Dispatch]] = [:]
    var hintLog: [Int: [HintChange]] = [:]
    var hintAt: [Int: TimeInterval] = [:]
    var translation: [Int: TimeInterval] = [:]
    var rereads: [Int] = []

    init(service: @escaping (WorkerRole, ReadVia, Int) -> TimeInterval) { self.service = service }

    private func health(_ role: WorkerRole) -> WorkerHealth { role == .lines ? lines : docs }
    private mutating func set(_ role: WorkerRole, _ h: WorkerHealth) { if role == .lines { lines = h } else { docs = h } }

    /// The worker has answered `via` for `key` already (a warm-up ran before the clock started).
    mutating func warm(_ role: WorkerRole, _ via: ReadVia, _ key: String) {
        var h = health(role)
        h.dispatch(WorkerJob(via: via, key: key, purpose: .warmup), now: -2)
        h.reply(.answered, now: -1)
        set(role, h)
    }

    /// A warm-up of the worker is in flight from the start and ends after `seconds`.
    mutating func warmup(_ role: WorkerRole, _ via: ReadVia, _ key: String, takes seconds: TimeInterval) {
        guard let job = sched.beginWarmup(client: 0, role: role, via: via, key: key, now: now) else { return }
        var h = health(role)
        h.dispatch(job.workerJob, now: now)
        set(role, h)
        due.append((now + seconds, role, job.id))
    }

    /// The lens reads (a new frame).
    mutating func start(client: Int, _ request: RouteRequest) {
        requests[client] = request
        frames[client, default: 0] += 1
        route(client)
    }

    private mutating func route(_ client: Int) {
        guard let request = requests[client], let frame = frames[client] else { return }
        let route = ReadRouter.route(request, lines: lines, docs: docs, now: now)
        var wait = waits[client] ?? ReadWait()
        let before = wait.hint
        wait.routed(route, now: now)
        waits[client] = wait
        noteHint(client, before: before)
        switch route {
        case .unavailable:
            parked.insert(client)
        case let .dispatch(target), let .queue(target):
            parked.remove(client)
            _ = sched.submit(client: client, purpose: .lens, frame: frame, key: request.key, target: target, now: now)
            pump()
        }
    }

    private mutating func noteHint(_ client: Int, before: RecognitionWait?) {
        let after = waits[client]?.hint
        guard after != before else { return }
        hintLog[client, default: []].append(HintChange(at: now, what: after))
        if after != nil, hintAt[client] == nil { hintAt[client] = now }
    }

    private mutating func pump() {
        for role in WorkerRole.allCases {
            while health(role).canDispatch, let job = sched.next(role) {
                let n = started[role, default: 0]
                started[role] = n + 1
                var h = health(role)
                h.dispatch(job.workerJob, now: now)
                set(role, h)
                due.append((now + service(role, job.target.via, n), role, job.id))
                dispatches[job.client, default: []].append(Dispatch(at: now, via: job.target.via, role: role))
            }
        }
    }

    /// Moves the clock to `t`, handling every deadline on the way in order.
    mutating func advance(to t: TimeInterval) {
        var guardrail = 0
        while guardrail < 1000 {
            guardrail += 1
            let deadlines = [lines.nextDeadline(now: now), docs.nextDeadline(now: now)].compactMap { $0 } + due.map(\.at)
            guard let next = deadlines.filter({ $0 <= t && $0 >= now }).min() else { break }
            now = next
            step()
        }
        now = t
    }

    private mutating func step() {
        let answers = due.filter { $0.at <= now }.sorted { $0.at < $1.at }
        due.removeAll { $0.at <= now }
        for a in answers { answer(a.role, a.id) }
        for role in WorkerRole.allCases {
            var h = health(role)
            let events = h.tick(now: now)
            set(role, h)
            handle(events, role)
        }
        pump()
    }

    private mutating func answer(_ role: WorkerRole, _ id: Int) {
        let job = sched.inFlight(role)
        let delivery = sched.complete(role, id: id)
        var h = health(role)
        let events = h.reply(.answered, now: now)
        set(role, h)
        if delivery == .accept, let job {
            var wait = waits[job.client] ?? ReadWait()
            let before = wait.hint
            wait.completed()
            waits[job.client] = wait
            noteHint(job.client, before: before)
            translation[job.client] = now + tail
            parked.remove(job.client)
        }
        handle(events, role)
    }

    private mutating func handle(_ events: [WorkerHealth.Event], _ role: WorkerRole) {
        for event in events {
            switch event {
            case .suspected:
                for job in sched.reroute(role) { route(job.client) }
            case .readerReady:
                rereads += sched.readerReady(role)
                for client in parked.sorted() { route(client) }
            case .usableAgain:
                for client in parked.sorted() { route(client) }
            default:
                break
            }
        }
    }

    /// Samples every 100 ms up to `end` what the pill and the lens show for each client: silent is no hint and no translation yet.
    /// Returns the longest silent stretch of each.
    mutating func sample(clients: [Int], until end: TimeInterval) -> [Int: TimeInterval] {
        var longest: [Int: TimeInterval] = [:]
        var runStart: [Int: TimeInterval] = Dictionary(uniqueKeysWithValues: clients.map { ($0, now) })
        for i in Int((now * 10).rounded())...Int(end * 10) {
            let t = Double(i) / 10
            advance(to: t)
            for client in clients {
                let translated = translation[client].map { $0 <= t + 1e-9 } ?? false
                if waits[client]?.hint == nil, !translated {
                    if runStart[client] == nil { runStart[client] = t }
                } else if let start = runStart[client] {
                    longest[client] = max(longest[client] ?? 0, t - start)
                    runStart[client] = nil
                }
            }
        }
        for (client, start) in runStart { longest[client] = max(longest[client] ?? 0, end - start) }
        return longest
    }

    mutating func sample(client: Int, until end: TimeInterval) -> TimeInterval {
        sample(clients: [client], until: end)[client] ?? 0
    }
}
