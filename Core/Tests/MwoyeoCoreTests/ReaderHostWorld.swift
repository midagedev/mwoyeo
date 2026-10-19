import Foundation
@testable import MwoyeoCore

/// A world for `ReaderHostCore` on a fake clock (g2-fast-host-gates, 2026-10-19): the host's policy, two fake services that obey
/// `MWOYEO_FAKE_READER` (the real `ReaderFakePlan`, so a gate's spec string is the test's), and the pipelines' side of `ReaderClients`.
/// It does what `RecognitionHost` does with the core's effects, minus Vision, XPC and the sleeping: the clock jumps to the next
/// thing that happens (a reply, a worker's timer, the warm-up's wake), so a service that takes 40 s costs microseconds.
final class HostWorld {
    /// A lens (pipeline) as `ReaderClients` and `ReadWait` know it.
    final class Lens {
        let id: Int
        var plan: ReadPlan
        var wait = ReadWait()
        /// Every pass it started: the ticket, when, and how it ended.
        var passes: [Pass] = []
        init(id: Int, plan: ReadPlan) { self.id = id; self.plan = plan }
        var hint: RecognitionWait? { wait.hint }
    }

    struct Pass {
        var ticket: Int
        var started: TimeInterval
        var ended: TimeInterval?
        var verdict: ReadVerdict?
        /// How long the lens had nothing to show: from asking to the answer or the hint.
        var silence: TimeInterval? { ended.map { $0 - started } }
    }

    private enum Event {
        case reply(SendOrder, error: ReadFailure?, ms: Int, warm: Bool)
        case timer(WorkerRole)
        case warmWake
        case announceAfter(WorkerRole)
        case reread(Int)
        case connectionLost(WorkerRole)
    }

    private struct Scheduled {
        var at: TimeInterval
        var seq: Int
        var event: Event
    }

    var core: ReaderHostCore
    private(set) var now: TimeInterval = 0
    let fakes: ReaderFakePlan
    /// How long a warm service takes to answer a kind, before the fake's own delay.
    var base: [ReadKind: TimeInterval] = [.rev3: 0.30, .rev2: 0.25, .fast: 0.10, .doc: 0.40, .warmLines: 0.60, .warmDoc: 0.60]
    /// How long the first job after a crash waits for launchd to start the service again.
    var relaunch: TimeInterval = 10

    private var queue: [Scheduled] = []
    private var seq = 0
    private var timers: [WorkerRole: Int] = [:]
    private var warmRunning = false
    private var relaunchDue: Set<ReaderRole> = []
    private var waiting: Set<Int> = []
    private var nextTicket = 0
    private var ticketLens: [Int: (lens: Int, pass: Int)] = [:]
    private(set) var lenses: [Int: Lens] = [:]

    /// Everything the core asked of the app, with the time it was asked.
    private(set) var effects: [(at: TimeInterval, effect: ReaderHostCore.Effect)] = []
    private(set) var logs: [(at: TimeInterval, line: String)] = []
    private(set) var counted: [String: Int] = [:]
    /// Jobs the services were sent, in order.
    private(set) var sent: [(at: TimeInterval, role: WorkerRole, via: ReadVia, warm: Bool)] = []

    init(timing: ReaderTiming = .standard, fakes: String = "", path: PathOverride? = nil) {
        core = ReaderHostCore(timing: timing, path: path)
        self.fakes = ReaderFakePlan(fakes)
        precondition(self.fakes.unrecognized.isEmpty, "fake mode not understood: \(self.fakes.unrecognized)")
    }

    // MARK: The app

    /// The app starts the warm-up for these languages' key (`RecognitionHost.warmUp`).
    func warmUp(key: String) {
        core.want(key, lensOn: !lenses.isEmpty)
        apply()
    }

    func addLens(plan: ReadPlan) -> Lens {
        let lens = Lens(id: lenses.count + 1, plan: plan)
        lens.plan.client = lens.id
        lenses[lens.id] = lens
        return lens
    }

    /// One pass of the lens: `RecognitionHost.read`. A pass that waits for Docs (the mutation) lets the clock run first.
    @discardableResult
    func ask(_ lens: Lens) -> Int {
        core.want(lens.plan.key, lensOn: true)
        apply()
        var guardrail = 0
        while core.mustWaitForDocs(lens.plan, now: now) {
            apply()
            advance(by: core.timing.docsWaitPoll)
            guardrail += 1
            if guardrail > 100_000 { break }
        }
        apply()
        nextTicket += 1
        let ticket = nextTicket
        lens.passes.append(Pass(ticket: ticket, started: now))
        ticketLens[ticket] = (lens.id, lens.passes.count - 1)
        core.read(lens.plan, ticket: ticket, client: lens.id, now: now)
        apply()
        return ticket
    }

    func pass(_ lens: Lens, _ index: Int = 0) -> Pass { lens.passes[index] }

    // MARK: The clock

    func advance(by seconds: TimeInterval) { advance(to: now + seconds) }

    /// Runs everything that happens up to `target`, in order, and leaves the clock there.
    func advance(to target: TimeInterval) {
        while let next = queue.min(by: { ($0.at, $0.seq) < ($1.at, $1.seq) }), next.at <= target {
            queue.removeAll { $0.seq == next.seq }
            now = max(now, next.at)
            fire(next.event)
        }
        now = max(now, target)
    }

    /// Runs until nothing is scheduled any more, or `limit` seconds have passed.
    func settle(limit: TimeInterval = 3600) {
        let end = now + limit
        while let next = queue.map(\.at).min(), next <= end { advance(to: next) }
    }

    private func schedule(_ delay: TimeInterval, _ event: Event) -> Int {
        seq += 1
        queue.append(Scheduled(at: now + delay, seq: seq, event: event))
        return seq
    }

    private func fire(_ event: Event) {
        switch event {
        case let .reply(order, error, ms, warm):
            if warm {
                let action = core.warmReplied(error: error, ms: ms, now: now)
                apply()
                warmAction(action)
            } else {
                core.replied(order.role, order.job, error: error, ms: ms, now: now)
                apply()
            }
        case let .timer(role):
            timers[role] = nil
            core.timerFired(role, now: now)
            apply()
        case .warmWake:
            let action = core.warmResume(now: now)
            apply()
            warmAction(action)
        case let .announceAfter(role):
            core.announceNow(role)
            apply()
        case let .reread(id):
            if let lens = lenses[id] { ask(lens) }
        case let .connectionLost(role):
            core.connectionLost(role, now: now)
            apply()
        }
    }

    // MARK: What the core asks

    private func apply() {
        for effect in core.drain() {
            effects.append((now, effect))
            switch effect {
            case let .log(line), let .logError(line): logs.append((now, line))
            case let .count(key): counted[key, default: 0] += 1
            case .trace, .setup: break
            case let .routed(client, route):
                guard let client, let lens = lenses[client] else { break }
                lens.wait.routed(route, now: now)
                if case .unavailable = route { waiting.insert(client) }
            case let .completed(client): if let client { lenses[client]?.wait.completed() }
            case let .failed(client): if let client { lenses[client]?.wait.failed() }
            case let .finish(ticket, verdict):
                if let (lensID, index) = ticketLens[ticket], let lens = lenses[lensID] {
                    lens.passes[index].ended = now
                    lens.passes[index].verdict = verdict
                }
            case let .send(order): send(order, warm: false)
            case let .watch(role):
                if let old = timers[role] { queue.removeAll { $0.seq == old }; timers[role] = nil }
                if let wake = core.nextWake(role, now: now) { timers[role] = schedule(max(0.01, wake), .timer(role)) }
            case let .announce(_, standIns):
                // `RecognitionHost.announceReady`: the clients that found no reader, and the ones that stood in.
                let ids = Array(Set(waiting).union(standIns)).sorted()
                waiting = []
                core.counts.rereads += ids.filter { lenses[$0] != nil }.count
                for id in ids where lenses[id] != nil { _ = schedule(0, .reread(id)) }
            case let .announceAfter(role, wait): _ = schedule(wait, .announceAfter(role))
            case .kickWarmup:
                if !warmRunning {
                    warmRunning = true
                    warmAction(core.warmStart(now: now))
                    apply()
                }
            }
        }
    }

    private func warmAction(_ action: ReaderHostCore.WarmAction) {
        switch action {
        case .stop: warmRunning = false
        case let .sleep(seconds): _ = schedule(seconds, .warmWake)
        case let .send(order): send(order, warm: true)
        }
    }

    // MARK: The services

    private func send(_ order: SendOrder, warm: Bool) {
        let role = ReaderRole(rawValue: order.role.rawValue)!
        let kind: ReadKind
        if order.warm != nil {
            kind = order.role == .lines ? .warmLines : .warmDoc
        } else {
            switch order.job.target.via {
            case .doc: kind = .doc
            case .rev3: kind = .rev3
            case .rev2: kind = .rev2
            case .fast: kind = .fast
            }
        }
        sent.append((now, order.role, order.job.target.via, order.warm != nil))
        var delay = relaunchDue.remove(role) != nil ? relaunch : 0
        var error: ReadFailure?
        var slow = 0.0
        var crash = false
        var e5rt = false
        for action in fakes.actions(role: role, kind: kind) {
            switch action {
            case let .slow(ms): slow += Double(ms) / 1000
            case .e5rt: e5rt = true
            case .crash: crash = true
            case .shift1: break
            }
        }
        if crash {
            // `exit(1)` on the job: the connection is interrupted, and the job answers with that.
            relaunchDue.insert(role)
            _ = schedule(0.005, .connectionLost(order.role))
            _ = schedule(0.006, .reply(order, error: .interrupted, ms: 6, warm: warm))
            return
        }
        delay += slow
        if e5rt {
            delay += 0.012
            error = .programsNotReady(ReaderFakeAction.e5rtDescription)
        } else {
            delay += base[kind] ?? 0.3
        }
        _ = schedule(delay, .reply(order, error: error, ms: Int((delay * 1000).rounded()), warm: warm))
    }

    /// The service of `role` dies while idle (the system kills it, or it crashes between jobs): the connection is interrupted, and the
    /// next job waits for launchd.
    func kill(_ role: WorkerRole) {
        relaunchDue.insert(ReaderRole(rawValue: role.rawValue)!)
        _ = schedule(0, .connectionLost(role))
    }

    // MARK: Looking

    func waits(containing needle: String) -> [(at: TimeInterval, line: String)] { logs.filter { $0.line.contains(needle) } }

    /// The seconds of every `reader rung resting role=lines via=rev3 for=N s` line, in order.
    var rungWaits: [Int] {
        logs.compactMap { entry in
            guard entry.line.hasPrefix("reader rung resting role=lines via=rev3 for="),
                  let value = entry.line.split(separator: "=").last?.split(separator: " ").first else { return nil }
            return Int(value)
        }
    }

    /// The most Code-13 failures of rev3 in any `window` seconds.
    func worstCode13(window: TimeInterval = 60) -> Int {
        let times = waits(containing: "reader failed role=lines via=rev3 why=programsNotReady").map(\.at)
        return times.map { start in times.filter { $0 >= start && $0 < start + window }.count }.max() ?? 0
    }

    func state(_ role: WorkerRole) -> WorkerHealth.State { core.health[role]!.effectiveState(now: now) }
}
