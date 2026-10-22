import Foundation
import MwoyeoCore
import os

/// What happened to the service, as it happens (the gates read these; the app's log has the same lines, category `script`).
enum ScriptConnectionEvent: Equatable, Sendable {
    /// A service answered for the first time (a new process), with its pid.
    case connected(pid: Int32)
    /// The service was killed over the time limit.
    case killed(pid: Int32)
    /// The service exited after `idleAfter` with no call.
    case idleExit(pid: Int32)
    /// The service did not answer (it died, or never started); the next call starts a fresh one.
    case lost
}

/// What a check of a profile's rewrites found (rewrite-rules §2, §3): the pure checks of `RewriteCheck` and the service's (a pattern that compiles, a script
/// that parses and defines a function), by `item`.
struct RewriteCheckResult: Equatable {
    var issues: [RewriteIssue]
    /// The stages whose function the script defines (empty with no script).
    var defines: [RewriteStage]
}

/// The app's side of the script service (`Script/`, rewrite-rules §5): an `NSXPCConnection`, the jobs of `RewriteSession` sent one at a time, and the
/// time limit. It is `ReaderConnection`'s pattern: the interruption and invalidation handlers, SIGKILL to the pid the service gave, and an exit when idle.
///
/// **The limit is the app's.** `JSContextGroupSetExecutionTimeLimit` is private API (2.5.1), so each call is timed here, from when it is sent to a service
/// that is up and warm: over its budget the service is killed and the call says `.timedOut` (the caller turns the unit off, §5). The next call starts a fresh
/// service. Calls queue in `gate`, one at a time, so a call is never timed while it waits behind another: a job in the service is the only job.
///
/// **A new service can be slow to start.** launchd starts the job again no sooner than `launchThrottle` after its last start (see there), so the call that
/// follows a kill or an exit of a service younger than that waits for the rest of it: `ready()` allows for it (`helloBudget`), and the call is answered, not
/// turned away. It is at most `launchThrottle`, and only after a loop or a catastrophic pattern within that time of a start. A call that says it does not
/// wait (`waits` false, a lens line) is not held up by it: while the service is down and launchd holds it back, the call answers `.held` at once and the line
/// passes as it was; only the editor's try and `test_rules` wait it out.
///
/// Nothing is connected until a call needs it: a chain with no regex row and no script never calls (`RewritePlan.needsService`), so `connectionsMade` stays 0.
/// The service is found by name, `<app bundle id>.script`, in this app's `Contents/XPCServices`.
final class ScriptConnection: RewriteRunner, @unchecked Sendable {
    let serviceName: String
    /// How long without a call before the service is asked to exit (§5: 60 s). A parameter, so a gate can shrink it.
    let idleAfter: TimeInterval
    /// How long a service may take to start and answer `hello` before the call gives up with the line as it was, on top of `hold`.
    let startBudget: TimeInterval
    /// launchd does not start a service job again sooner than this after its last start, whether the instance was killed or exited (its ThrottleInterval;
    /// measured 2026-10-21: a hello after a kill 0.3 s into the service's life answered 10.0 s later, one 3.2 s into it 7.0 s later, one 12.8 s into it
    /// 37 ms later; the key is not read from the service's Info.plist). So the first call after a service that lived less than this waits for the rest of it.
    let launchThrottle: TimeInterval
    /// Called by a call that is about to wait for a new service (`starting` is true), with what is left of launchd's throttle that its hello is allowed for on top of
    /// `startBudget` (0 with none), and awaited before the hello is sent. nil in the app. A gate holds a restart in front of its calls with it, as long as it likes
    /// and for no wall-clock time, so that "a call is waiting out the restart" is a state the gate sets and reads, not one it races (round flake117).
    let startGate: (@Sendable (TimeInterval) async -> Void)?

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var pid: Int32?
    private var nextID: UInt64 = 0
    private var listeners: [UUID: AsyncStream<ScriptConnectionEvent>.Continuation] = [:]
    private var idle: DispatchWorkItem?
    private var generation = 0
    private var made = 0, started = 0, killed = 0, sent = 0
    /// When (`uptime`) the newest service first answered, so when launchd saw it start, give or take its start-up.
    private var launchedAt: Double?
    private var lastKilled: Int32?
    private var lastCut: Double?
    /// A call is waiting for a new service's `hello` (inside the gate).
    private var starting = false
    private let gate = SerialGate()
    private let timers = DispatchQueue(label: "dev.midagedev.mwoyeo.script.timer", qos: .userInitiated)
    private let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "script")

    /// The process's connection. Made on first use, and it connects on its first call.
    static let shared = ScriptConnection()

    init(appID: String = Bundle.main.bundleIdentifier ?? "dev.midagedev.mwoyeo", idleAfter: TimeInterval = 60, startBudget: TimeInterval = 10, launchThrottle: TimeInterval = 10,
         startGate: (@Sendable (TimeInterval) async -> Void)? = nil) {
        self.serviceName = ScriptWire.serviceName(appID: appID)
        self.idleAfter = idleAfter
        self.startBudget = startBudget
        self.launchThrottle = launchThrottle
        self.startGate = startGate
    }

    /// What is left of launchd's throttle after the last start (`launchedAt`, nil = none) at `now`, in seconds.
    static func throttleLeft(launchedAt: Double?, now: Double, launchThrottle: Double) -> Double {
        launchedAt.map { max(0, $0 + launchThrottle - now) } ?? 0
    }

    /// How long a hello may take: `startBudget` for the start itself, and what is left of launchd's throttle.
    static func helloBudget(launchedAt: Double?, now: Double, launchThrottle: Double, startBudget: Double) -> Double {
        startBudget + throttleLeft(launchedAt: launchedAt, now: now, launchThrottle: launchThrottle)
    }

    /// How long launchd still holds the next start back while there is no service up: 0 with one up, and 0 before the first start.
    private func heldFor() -> Double {
        lock.withLock { self.pid != nil ? 0 : Self.throttleLeft(launchedAt: self.launchedAt, now: Self.uptime(), launchThrottle: self.launchThrottle) }
    }

    private static func uptime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// The pid of the service that answered last, nil before the first answer and after a kill, an exit or an interruption.
    var servicePid: Int32? { lock.withLock { pid } }
    /// `NSXPCConnection`s made. 0 until a call needs the service.
    var connectionsMade: Int { lock.withLock { made } }
    /// Service processes that answered (each new pid).
    var servicesStarted: Int { lock.withLock { started } }
    /// Services killed over the limit.
    var servicesKilled: Int { lock.withLock { killed } }
    /// The pid of the service killed last over the limit.
    var lastKilledPid: Int32? { lock.withLock { lastKilled } }
    /// What the call that was cut last had taken, in ms, when it was (its budget and the timer's lateness): the number the limit's gates read.
    var lastCutMs: Double? { lock.withLock { lastCut } }
    /// A call is waiting for a new service to answer its `hello`: what a gate reads to know another call is in front of it.
    var isStarting: Bool { lock.withLock { starting } }
    /// Jobs handed to a service (a hello is not a job).
    var jobsSent: Int { lock.withLock { sent } }

    /// The events as they happen. Each call is its own stream.
    func events() -> AsyncStream<ScriptConnectionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            lock.withLock { listeners[id] = continuation }
            continuation.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.listeners.removeValue(forKey: id) } }
        }
    }

    // MARK: RewriteRunner

    func regex(_ row: RewriteRow, on text: String, budgetMs: Double, waits: Bool = true) async -> RewriteRun {
        await run(ScriptJob(kind: .regex, text: text, pattern: row.find, replacement: row.replace), budgetMs: budgetMs, waits: waits)
    }

    func script(_ script: RewriteScript, stage: RewriteStage, text: String, src: String, context: RewriteContext, budgetMs: Double, waits: Bool = true) async -> RewriteRun {
        await run(ScriptJob(kind: stage == .before ? .before : .after, text: text, src: src, source: script.source, context: context), budgetMs: budgetMs, waits: waits)
    }

    private func run(_ job: ScriptJob, budgetMs: Double, waits: Bool) async -> RewriteRun {
        let (sent, ms) = await send(job, budgetMs: budgetMs, waits: waits)
        switch sent {
        case .held: return RewriteRun(.held)
        case .timedOut: return RewriteRun(.timedOut, usedMs: ms)
        case .unavailable(let why): return RewriteRun(.failed(RewriteFailure("\(RewriteText.serviceUnavailable) (\(why))")), usedMs: ms)
        case .reply(let reply):
            if let failure = reply.failure { return RewriteRun(.failed(failure), usedMs: ms) }
            guard let text = reply.text else { return RewriteRun(.failed(RewriteFailure("the service answered with no text")), usedMs: ms) }
            return RewriteRun(.text(text), usedMs: ms)
        }
    }

    /// Starts the service if it is not up and waits until it answers (§5: it starts when a chain that needs it becomes active). False: it did not answer, and the
    /// next call tries again. A call starts it by itself; this is for a caller that wants the start behind it before its own clock runs.
    func start() async -> Bool {
        await gate.enter()
        defer { armIdle(); gate.leave() }
        noteCall()
        return await ready()
    }

    // MARK: Check

    /// The strict checks of §2 and §3 in full (`RewriteCheck`'s, then the service's: each regex row's pattern compiled and never run; the script parsed, and its
    /// top level run once to see which functions it defines). The service is asked only when there is a regex row or a script to ask about, and a script
    /// over its length is not sent. A check that takes longer than `RewriteLimits.checkBudgetMs` kills the service, as a call does.
    func check(rows: [RewriteRow], script: RewriteScript?) async -> RewriteCheckResult {
        var issues = RewriteCheck.rows(rows) + (script.map(RewriteCheck.script) ?? [])
        let patterns = rows.prefix(RewriteLimits.maxRows).enumerated().filter { $0.element.regex && !$0.element.find.isEmpty }
            .map { ScriptPattern(item: $0.offset, pattern: $0.element.find) }
        let source = script.map(\.source).flatMap { $0.count <= RewriteLimits.maxScript ? $0 : nil } ?? ""
        guard !patterns.isEmpty || !source.isEmpty else { return RewriteCheckResult(issues: issues, defines: []) }
        let (sent, _) = await send(ScriptJob(kind: .check, source: source, patterns: patterns), budgetMs: RewriteLimits.checkBudgetMs, waits: true)
        switch sent {
        case .held: return RewriteCheckResult(issues: issues, defines: [])
        case .timedOut:
            issues.append(RewriteIssue(item: RewriteIssue.script, message: RewriteText.checkTookTooLong))
            return RewriteCheckResult(issues: issues, defines: [])
        case .unavailable(let why):
            issues.append(RewriteIssue(item: RewriteIssue.script, message: "\(RewriteText.serviceUnavailable) (\(why))"))
            return RewriteCheckResult(issues: issues, defines: [])
        case .reply(let reply):
            return RewriteCheckResult(issues: issues + reply.issues, defines: reply.defines)
        }
    }

    // MARK: One job

    private enum Sent {
        case reply(ScriptReply)
        case timedOut
        case unavailable(String)
        /// Not sent: the service is down and launchd holds its start (only for a call that does not wait).
        case held
    }

    /// One job to the service, alone (behind the gate), timed from the moment it is sent to a service that has answered `hello`. Returns what came back and how
    /// long it took. A timeout kills the service. A call that does not wait (`waits` false) gets `.held` while the service is down and launchd holds its start
    /// back: asked before the gate (a call in the gate may be waiting out the hold in `ready()`, and this one must not queue behind it) and again inside it (the
    /// call ahead may have been the one that was cut).
    private func send(_ job: ScriptJob, budgetMs: Double, waits: Bool) async -> (Sent, Double) {
        if !waits, noteHeld() { return (.held, 0) }
        await gate.enter()
        defer { armIdle(); gate.leave() }
        noteCall()
        if !waits, noteHeld() { return (.held, 0) }
        guard await ready() else { return (.unavailable("no answer"), 0) }
        var job = job
        job.id = lock.withLock { nextID += 1; return nextID }
        guard let encoded = try? ScriptWire.encode(job) else { return (.unavailable("the job could not be encoded"), 0) }
        lock.withLock { sent += 1 }
        let began = DispatchTime.now().uptimeNanoseconds
        let outcome: Sent = await withCheckedContinuation { (continuation: CheckedContinuation<Sent, Never>) in
            let once = Once(continuation)
            let timer = DispatchWorkItem { once.resume(.timedOut) }
            timers.asyncAfter(deadline: .now() + budgetMs / 1000, execute: timer)
            let proxy = connect().remoteObjectProxyWithErrorHandler { error in
                timer.cancel()
                once.resume(.unavailable(Self.describe(error)))
            } as? ScriptXPC
            guard let proxy else { timer.cancel(); once.resume(.unavailable("no remote object")); return }
            proxy.run(encoded) { data in
                timer.cancel()
                if let reply = try? ScriptWire.decode(ScriptReply.self, from: data) { once.resume(.reply(reply)) } else { once.resume(.unavailable("undecodable reply")) }
            }
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
        switch outcome {
        case .timedOut:
            lock.withLock { lastCut = ms }
            killService()
        case .unavailable: lost()
        case .reply(let reply): note(pid: reply.pid)
        case .held: break // never the outcome of a job that was sent
        }
        return (outcome, ms)
    }

    /// Whether a call that does not wait is to be turned away now, and the log's line for it.
    private func noteHeld() -> Bool {
        let held = heldFor()
        guard held > 0 else { return false }
        log.info("script service restarting: the call was skipped, launchd holds its start for \(held, format: .fixed(precision: 1)) s")
        return true
    }

    /// The service is up and warm, and its pid is known (the kill needs it): one `hello` for a new process.
    private func ready() async -> Bool {
        if servicePid != nil { return true }
        let budget = lock.withLock { Self.helloBudget(launchedAt: self.launchedAt, now: Self.uptime(), launchThrottle: self.launchThrottle, startBudget: self.startBudget) }
        let hold = budget - startBudget
        if hold > 0 { log.notice("script service starting: launchd's throttle holds it for \(hold, format: .fixed(precision: 1)) s") }
        lock.withLock { self.starting = true }
        defer { lock.withLock { self.starting = false } }
        await startGate?(hold)
        let hello: Int32? = await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            let once = Once(continuation)
            let timer = DispatchWorkItem { once.resume(nil) }
            timers.asyncAfter(deadline: .now() + budget, execute: timer)
            let proxy = connect().remoteObjectProxyWithErrorHandler { _ in timer.cancel(); once.resume(nil) } as? ScriptXPC
            guard let proxy else { timer.cancel(); once.resume(nil); return }
            proxy.hello { pid in timer.cancel(); once.resume(pid) }
        }
        guard let hello else { lost(); return false }
        note(pid: hello)
        return true
    }

    /// The last resort of a call over its limit: SIGKILL to the service pid recorded when it last answered. Only that pid. The connection is dropped with it,
    /// so the next call makes a new one and a fresh service.
    func killService() {
        let (dead, old) = lock.withLock { () -> (Int32?, NSXPCConnection?) in
            defer { pid = nil; connection = nil }
            if pid != nil { killed += 1; lastKilled = pid }
            return (pid, connection)
        }
        if let dead {
            log.notice("kill script pid=\(dead)")
            kill(dead, SIGKILL)
            emit(.killed(pid: dead))
        }
        old?.invalidate()
    }

    /// Drops a connection that did not answer, so the next call starts fresh.
    private func lost() {
        let old = lock.withLock { () -> NSXPCConnection? in defer { pid = nil; connection = nil }; return connection }
        old?.invalidate()
        log.notice("script service lost")
        emit(.lost)
    }

    // MARK: Exit when idle

    /// A call starts: the idle timer of the last one is stale.
    private func noteCall() {
        lock.withLock {
            generation += 1
            idle?.cancel()
            idle = nil
        }
    }

    /// A call is done: the service may go if no other call comes within `idleAfter`.
    private func armIdle() {
        lock.withLock {
            let mine = generation
            let item = DispatchWorkItem { [weak self] in self?.idleElapsed(mine) }
            idle = item
            timers.asyncAfter(deadline: .now() + idleAfter, execute: item)
        }
    }

    /// Asks the service to exit once idle, then lets the connection go. Behind the gate, so a call that came in meanwhile (its own timer is newer) wins.
    private func idleElapsed(_ mine: Int) {
        Task { [self] in
            await gate.enter()
            defer { gate.leave() }
            guard lock.withLock({ generation == mine }), let dead = servicePid else { return }
            let proxy = connect().remoteObjectProxyWithErrorHandler { _ in } as? ScriptXPC
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard let proxy else { continuation.resume(); return }
                let once = Once(continuation)
                proxy.exitWhenIdle { _ in once.resume(()) }
            }
            let old = lock.withLock { () -> NSXPCConnection? in defer { pid = nil; connection = nil }; return connection }
            old?.invalidate()
            log.notice("script idle exit pid=\(dead)")
            emit(.idleExit(pid: dead))
        }
    }

    // MARK: The connection

    private func connect() -> NSXPCConnection {
        lock.withLock {
            if let connection { return connection }
            let made = NSXPCConnection(serviceName: serviceName)
            made.remoteObjectInterface = ScriptWire.interface()
            made.interruptionHandler = { [weak self, weak made] in self?.interrupted(made) }
            made.invalidationHandler = { [weak self, weak made] in self?.invalidated(made) }
            made.resume()
            connection = made
            self.made += 1
            return made
        }
    }

    private func interrupted(_ made: NSXPCConnection?) {
        // The service died by itself (a crash, a kill from outside): the pid is gone, the connection stays and the next message starts a fresh one.
        let current = lock.withLock { () -> Bool in guard connection === made else { return false }; pid = nil; return true }
        if current { log.notice("script interrupted"); emit(.lost) }
    }

    private func invalidated(_ made: NSXPCConnection?) {
        lock.withLock { if connection === made { connection = nil; pid = nil } }
    }

    private func note(pid seen: Int32) {
        guard seen != 0 else { return }
        let changed = lock.withLock { () -> Bool in
            defer { pid = seen }
            guard pid != seen else { return false }
            started += 1
            launchedAt = Self.uptime()
            return true
        }
        guard changed else { return }
        log.notice("script connected pid=\(seen)")
        emit(.connected(pid: seen))
    }

    private func emit(_ event: ScriptConnectionEvent) {
        let all = lock.withLock { Array(listeners.values) }
        for continuation in all { continuation.yield(event) }
    }

    private static func describe(_ error: Error) -> String {
        let e = error as NSError
        return e.domain == NSCocoaErrorDomain && e.code == NSXPCConnectionInterrupted ? "the service stopped" : "\(e.domain) \(e.code)"
    }

    /// Resumes its continuation the first time, whichever of the reply, the error handler and the timer comes.
    private final class Once<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?

        init(_ continuation: CheckedContinuation<T, Never>) { self.continuation = continuation }

        func resume(_ value: T) {
            let c = lock.withLock { () -> CheckedContinuation<T, Never>? in defer { continuation = nil }; return continuation }
            c?.resume(returning: value)
        }
    }

    /// One caller at a time, in the order they came.
    private final class SerialGate: @unchecked Sendable {
        private let lock = NSLock()
        private var busy = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func enter() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if busy { waiters.append(continuation); lock.unlock() } else { busy = true; lock.unlock(); continuation.resume() }
            }
        }

        func leave() {
            lock.lock()
            if waiters.isEmpty { busy = false; lock.unlock() } else { let next = waiters.removeFirst(); lock.unlock(); next.resume() }
        }
    }
}
