import Foundation

/// The warm-up plan of the two workers (design §4.10): which compile runs next, in which worker, for which language key. Once
/// compiles cannot silence a lens, warm-up buys first reads at full quality sooner (rev3 instead of `.fast`, the document layout
/// instead of the grouper); it no longer guards correctness.
///
/// - **Order: Lines first, then Docs, per key.** Docs starts after Lines' step of the key ended. The compile service is serial
///   and system-wide, and while Lines compiles, Docs' `.fast` keeps Latin readable; the other way round Lines reads. One warm-up
///   runs at a time across both workers, so at most one worker is ever down for a compile of ours. The order is load-bearing.
/// - A step goes only to an idle worker with an empty queue (`nextDue(idleSlots:)`), and is never cancelled.
/// - There is no `swiftTextModel` step: `RecognizeTextRequest` is never read, and it cost one ~30 s serial compile at first launch.
/// - A key that is new while a lens is on gets no warm-up: the lens's own read is the compile (`want(_:lensOn:)`).
///
/// Nothing is persisted: a step is done when it ran in this process. Pure: callers pass `now` (any monotonic clock, in seconds),
/// run the step in the worker (`WorkerHealth.dispatch` with a `.warmup` job) and report how it ended.
public struct ReaderWarmup: Sendable, Equatable {
    public struct Step: Hashable, Sendable {
        public var role: WorkerRole
        public var key: String

        public init(_ role: WorkerRole, _ key: String) {
            self.role = role
            self.key = key
        }

        /// The request that does it: rev3 on today's probe picture (aspect 82 plus a CJK line) at Lines, the document networks
        /// on doc-warm's drawn figure pages at Docs.
        public var via: ReadVia { role == .lines ? .rev3 : .doc }
        public var job: WorkerJob { WorkerJob(via: via, key: key, purpose: .warmup) }
    }

    public enum StepState: Sendable, Equatable {
        case pending
        case running(since: TimeInterval)
        case done(seconds: TimeInterval)
        case failed(String)
    }

    /// The key of a read that detects the language.
    public static let anyLanguage = "auto"

    private var keys: [String] = []
    private var states: [Step: StepState] = [:]
    /// Keys that came while a lens was on and have no steps.
    private var skipped: Set<String> = []
    /// The step that runs, nil if none.
    public private(set) var running: Step?

    public init() {}

    /// The key is wanted: its steps run when their turn comes (keys go in the order they were first asked for). `lensOn`: a lens
    /// is on now; a key not seen before gets no steps then (its read compiles for it, and may do it faster). It can still be
    /// wanted later with `lensOn: false`. True if steps were added.
    @discardableResult
    public mutating func want(_ key: String, lensOn: Bool) -> Bool {
        guard !keys.contains(key) else { return false }
        if lensOn { skipped.insert(key); return false }
        skipped.remove(key)
        keys.append(key)
        states[Step(.lines, key)] = .pending
        states[Step(.docs, key)] = .pending
        return true
    }

    public func isWanted(_ key: String) -> Bool { keys.contains(key) }
    public func isSkipped(_ key: String) -> Bool { skipped.contains(key) }

    public func state(_ step: Step) -> StepState? { states[step] }

    /// The step to start now, if any. Nothing starts while one runs, and a pending step is never jumped: the first pending step in
    /// the order (key by key, Lines then Docs) either goes now, if its worker has an idle slot, or nothing does. A failed step
    /// is passed over until `retry()`; Docs does not wait for a Lines step that failed (nothing compiles there any more).
    /// `idleSlots`: the workers with nothing in flight and nothing queued.
    public func nextDue(idleSlots: Set<WorkerRole>) -> Step? {
        guard running == nil else { return nil }
        for key in keys {
            for role in [WorkerRole.lines, .docs] {
                let step = Step(role, key)
                switch states[step] ?? .pending {
                case .done, .failed: continue
                case .running: return nil
                case .pending: return idleSlots.contains(role) ? step : nil
                }
            }
        }
        return nil
    }

    /// The workers a step may go to: nothing in flight (a `cold` one counts: the step starts it) and nothing queued.
    public static func idleSlots(lines: WorkerHealth, docs: WorkerHealth, scheduler: ReadScheduler) -> Set<WorkerRole> {
        var slots: Set<WorkerRole> = []
        if lines.canDispatch, scheduler.slotIsFree(.lines) { slots.insert(.lines) }
        if docs.canDispatch, scheduler.slotIsFree(.docs) { slots.insert(.docs) }
        return slots
    }

    /// The step is being started. Call before the work runs: it can end before the caller has seen it return.
    public mutating func started(_ step: Step, now: TimeInterval) {
        guard states[step] != nil else { return }
        running = step
        states[step] = .running(since: now)
    }

    /// The running step ended; `failure` is why it did not succeed. A report with nothing running changes nothing.
    public mutating func finished(failure: String?, now: TimeInterval) {
        guard let step = running else { return }
        running = nil
        if let failure {
            states[step] = .failed(failure)
        } else if case let .running(since) = states[step] {
            states[step] = .done(seconds: max(0, now - since))
        }
    }

    /// Every failed step is due again (the user pressed retry, or the next launch). Never called by the plan itself.
    public mutating func retry() {
        for (step, state) in states { if case .failed = state { states[step] = .pending } }
    }

    /// Every step of every wanted key is done.
    public var allDone: Bool {
        !keys.isEmpty && states.values.allSatisfy { if case .done = $0 { true } else { false } }
    }

    /// Some step failed and has not been retried.
    public var hasFailed: Bool {
        states.values.contains { if case .failed = $0 { true } else { false } }
    }

    /// Steps not yet done or failed (the menu's "Preparing text recognition…" is up while this is not zero).
    public var remaining: Int {
        states.values.filter { switch $0 { case .pending, .running: true; default: false } }.count
    }
}
