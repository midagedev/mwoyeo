import Foundation

/// Whether Vision's newest text model (accurate revision 3 of `VNRecognizeTextRequest`) is answering. On some Macs it never
/// does (its compiler service spins and the request hangs for good), and a hung request cannot be cancelled. This is the
/// bookkeeping that notices, routes reads away from it, and notices when it answers again. Pure: callers pass `now` (any monotonic clock, in seconds) and do
/// the work and the side effects.
public struct OCRHealth: Sendable, Equatable {
    /// A request on the newest model that has not answered after this long is late: the next read does not queue behind it.
    public static let lateAfter: TimeInterval = 8
    /// How long a read waits for a cold model when no other recognizer could read it instead (the first load is slow).
    /// A model that has not answered this long is reported as not responding; before that it is only still preparing.
    public static let giveUpAfter: TimeInterval = 180
    public static let coldWait: TimeInterval = giveUpAfter
    /// While stalled, one small image goes to the newest model this often to see whether it answers again.
    public static let probeEvery: TimeInterval = 120

    public enum Plan: Equatable, Sendable {
        /// Ask the newest model and give up after `seconds`.
        case run(seconds: TimeInterval)
        /// An older recognizer reads this one; the newest model is not asked.
        case fallback
        /// The newest model is stalled and nothing older reads these languages.
        case refuse
    }

    /// The newest model has answered at least once in this process.
    public private(set) var warm = false
    /// A request missed its deadline and none has answered since.
    public private(set) var stalled = false
    /// True while a task is probing a stalled model; a stall that starts meanwhile joins it instead of starting another.
    public private(set) var probing = false
    private var stalledSince: TimeInterval?
    private var running: [Int: TimeInterval] = [:]
    private var issued = 0

    public init() {}

    /// What to do with a read that an older recognizer can (`canFallBack`) or cannot read.
    public func plan(canFallBack: Bool, now: TimeInterval) -> Plan {
        let late = running.values.min().map { now - $0 > Self.lateAfter } ?? false
        if stalled || late {
            if canFallBack { return .fallback }
            if stalled { return .refuse }
        }
        return .run(seconds: warm || canFallBack ? Self.lateAfter : Self.coldWait)
    }

    /// A request on the newest model starts; the id goes back to `answered` or `failed`.
    public mutating func begin(now: TimeInterval) -> Int {
        issued += 1
        running[issued] = now
        return issued
    }

    /// The request returned. Returns true if that ended a stall. Requests started before it are abandoned: it came back
    /// past them, so they no longer say anything about the model.
    @discardableResult
    public mutating func answered(_ id: Int) -> Bool {
        if let started = running[id] { running = running.filter { $0.value > started } }
        running[id] = nil
        warm = true
        defer { stalled = false; stalledSince = nil }
        return stalled
    }

    /// The request threw before it was answered: the model did not hang on it, so health is unchanged.
    public mutating func failed(_ id: Int) { running[id] = nil }

    /// Request `id` missed its deadline; it keeps running. Returns true if this starts a stall (not one already counted).
    /// The stall dates from when that request started.
    @discardableResult
    public mutating func missed(_ id: Int, now: TimeInterval) -> Bool {
        defer { stalled = true }
        if !stalled { stalledSince = running[id] ?? now }
        return !stalled
    }

    /// How long the stall has lasted, nil if there is none.
    public func stalledFor(now: TimeInterval) -> TimeInterval? { stalledSince.map { now - $0 } }

    /// A probe may start: a stall is on and no request on the newest model started within `probeEvery`. A request that
    /// is still loading is never stacked on or cancelled; it is the probe.
    public func probeDue(now: TimeInterval) -> Bool {
        stalled && (running.values.max().map { now - $0 >= Self.probeEvery } ?? true)
    }

    /// Takes the probing role if a stall is on and nobody has it.
    public mutating func startProbing() -> Bool {
        guard stalled, !probing else { return false }
        probing = true
        return true
    }

    /// The prober looks again after a probe: it stops (and gives the role up) only if the model is healthy.
    public mutating func stopProbing() -> Bool {
        guard !stalled else { return false }
        probing = false
        return true
    }
}
