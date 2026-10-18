import Foundation

public struct SpeedSummary: Equatable, Sendable {
    /// Median batch time.
    public var seconds: Double
    /// Share of lines that were already in memory, 0...1.
    public var fromMemory: Double

    public init(seconds: Double, fromMemory: Double) {
        self.seconds = seconds
        self.fromMemory = fromMemory
    }
}

/// Speed of one engine and language pair, as numbers only.
public struct PaceStat: Sendable {
    /// The cache namespace without the glossary: language pair | engine identity.
    public let key: String
    /// First-result samples taken, and the current estimates (s): until the first line, then per further line.
    public let samples: Int
    public let first: Double?
    public let perLine: Double?
    /// Latency of whole successful batches over the last 200 (s).
    public let batchP50: Double?
    public let batchP90: Double?
    public let batches: Int
    public let cancelled: Int
    /// Lines answered from the cache and lines the engine returned, since launch.
    public let cachedLines: Int
    public let translatedLines: Int

    public init(key: String, samples: Int, first: Double?, perLine: Double?, batchP50: Double?, batchP90: Double?, batches: Int,
                cancelled: Int, cachedLines: Int, translatedLines: Int) {
        self.key = key
        self.samples = samples
        self.first = first
        self.perLine = perLine
        self.batchP50 = batchP50
        self.batchP90 = batchP90
        self.batches = batches
        self.cancelled = cancelled
        self.cachedLines = cachedLines
        self.translatedLines = translatedLines
    }
}

/// The one owner of engine speed, per cache namespace (language pair + engine identity; the glossary does not change
/// speed): what the scheduler expects a batch to cost, what the logs print, and what the engine list shows per engine
/// (the sum over that engine's pairs). Numbers only, never screen text. Lock-guarded so regions and the settings view
/// can read it from outside the actor.
public final class PaceStats: @unchecked Sendable {
    public struct Slot: Sendable {
        public let key: String
        /// The added engine this namespace belongs to; nil for Apple's.
        public let engine: UUID?
        public init(key: String, engine: UUID?) {
            self.key = key
            self.engine = engine
        }
    }

    private struct Entry {
        var engine: UUID?
        var pace = TranslationPace()
        /// Seconds of the last 200 successful batches.
        var batches: [Double] = []
        var okBatches = 0
        var cancelled = 0
        var hits = 0
        var lookups = 0
        var lines = 0
    }

    public init() {}

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var current = Slot(key: "", engine: nil)
    /// While an added engine rests after a failure: Apple's slot, whose pace applies to the groups that run until `until`.
    private var stand: (slot: Slot, until: TimeInterval)?
    private static let ringSize = 200

    /// The engine and pair in use now. A change of namespace ends a fallback.
    public func use(_ slot: Slot) {
        lock.withLock {
            if slot.key != current.key { stand = nil }
            current = slot
        }
    }
    public func useFallback(_ slot: Slot, until: TimeInterval) { lock.withLock { stand = (slot, until) } }
    public func clearFallback() { lock.withLock { stand = nil } }

    private func entry(_ slot: Slot) -> Entry { entries[slot.key] ?? Entry(engine: slot.engine) }

    /// One streamed line's arrival: since the call began (`isFirst`) or since the previous line.
    public func record(_ seconds: Double, isFirst: Bool, slot: Slot) {
        lock.withLock {
            var e = entry(slot)
            e.pace.record(seconds: seconds, isFirst: isFirst)
            e.lines += 1
            entries[slot.key] = e
        }
    }

    /// A whole batch's latency, outside a call to `finish` (a probe).
    public func recordBatch(_ seconds: Double, slot: Slot) {
        lock.withLock {
            var e = entry(slot)
            Self.add(seconds, to: &e)
            entries[slot.key] = e
        }
    }

    /// An attempt ended: successful ones count as batch latencies, cancelled ones are counted.
    public func finish(slot: Slot, total: Double, ok: Bool, cancelled: Bool) {
        lock.withLock {
            var e = entry(slot)
            if ok { Self.add(total, to: &e) }
            if cancelled { e.cancelled += 1 }
            entries[slot.key] = e
        }
    }

    private static func add(_ seconds: Double, to e: inout Entry) {
        e.batches.append(seconds)
        if e.batches.count > ringSize { e.batches.removeFirst(e.batches.count - ringSize) }
        e.okBatches += 1
    }

    /// A lookup in the cache for the engine and pair in use (one line of text).
    public func recordLookup(hit: Bool) {
        lock.withLock {
            var e = entry(current)
            e.lookups += 1
            if hit { e.hits += 1 }
            entries[current.key] = e
        }
    }

    public func expectedSeconds(lines: Int) -> Double? {
        lock.withLock {
            let slot = stand.flatMap { ProcessInfo.processInfo.systemUptime < $0.until ? $0.slot : nil } ?? current
            return entries[slot.key]?.pace.expectedSeconds(lines: lines)
        }
    }

    /// What a running call still needs on the engine and pair in use (see `TranslationPace.remainingSeconds`).
    public func remainingSeconds(lines: Int, delivered: Int, elapsed: Double) -> Double? {
        lock.withLock {
            let slot = stand.flatMap { ProcessInfo.processInfo.systemUptime < $0.until ? $0.slot : nil } ?? current
            return entries[slot.key]?.pace.remainingSeconds(lines: lines, delivered: delivered, elapsed: elapsed)
        }
    }

    /// Median seconds of an engine's batches over all its pairs.
    public func medianSeconds(for id: UUID) -> Double? {
        lock.withLock { Self.median(entries.values.filter { $0.engine == id }.flatMap(\.batches)) }
    }

    public func summary(for id: UUID, minBatches: Int) -> SpeedSummary? {
        lock.withLock {
            let mine = entries.values.filter { $0.engine == id }
            guard mine.reduce(0, { $0 + $1.okBatches }) >= minBatches, let median = Self.median(mine.flatMap(\.batches)) else { return nil }
            let total = mine.reduce(0) { $0 + $1.lookups }, hits = mine.reduce(0) { $0 + $1.hits }
            return SpeedSummary(seconds: median, fromMemory: total == 0 ? 0 : Double(hits) / Double(total))
        }
    }

    public func stats() -> [PaceStat] {
        lock.withLock {
            entries.sorted { $0.key < $1.key }.map { k, e in
                let sorted = e.batches.sorted()
                func q(_ p: Double) -> Double? { sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
                return PaceStat(key: k, samples: e.pace.firstSamples, first: e.pace.first, perLine: e.pace.next ?? e.pace.first,
                                batchP50: q(0.5), batchP90: q(0.9), batches: e.okBatches, cancelled: e.cancelled,
                                cachedLines: e.hits, translatedLines: e.lines)
            }
        }
    }

    private static func median(_ seconds: [Double]) -> Double? {
        seconds.isEmpty ? nil : seconds.sorted()[seconds.count / 2]
    }
}
