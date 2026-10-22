import Foundation

// The first paint of a lens's first batch (docs/design/first-lens.md §13; the setting `fastFirstPaint`). Apple's low-latency model answers a batch in a
// fraction of high fidelity's time, so its text is painted at once as a provisional first paint, and high fidelity's translation replaces it. Three pieces,
// each the one owner of its part: `FirstPaintPlan` (which groups get it), `FirstPaint.run` (how the two models are run) and `FirstPaintBook` (what a
// source shows meanwhile, and what that cost). All pure: callers pass `now` (any monotonic clock, in seconds) and the runners.

/// Which of the groups sent to Apple Translation are answered twice.
public enum FirstPaintPlan: Equatable, Sendable {
    /// Today's path: the model the lens chose answers, and nothing is painted before it.
    case finalOnly
    /// The low-latency model's text is painted first and the high-fidelity text replaces it.
    case provisionalThenFinal

    /// Whether the group could be answered twice, from what is known without asking the system: `flag`: the setting. `asked`: the caller took a provisional
    /// text (the first batch of a lens). `finalIsHighFidelity`: high fidelity is what the lens's engine settles on (with the pack installed and `auto`, the
    /// final is low latency already: nothing is faster than it, so nothing is painted before it). Only a group that wants it asks whether the pack is there.
    public static func wants(flag: Bool, asked: Bool, finalIsHighFidelity: Bool) -> Bool { flag && asked && finalIsHighFidelity }

    /// `quickInstalled`: the pair's low-latency pack is installed, so a quick text exists.
    public static func decide(flag: Bool, asked: Bool, finalIsHighFidelity: Bool, quickInstalled: Bool) -> Self {
        wants(flag: flag, asked: asked, finalIsHighFidelity: finalIsHighFidelity) && quickInstalled ? .provisionalThenFinal : .finalOnly
    }
}

public enum FirstPaint {
    /// Told a source and a text as each one lands.
    public typealias Sink = @Sendable (_ source: String, _ text: String) -> Void
    /// A model asked for `items`: it tells the sink as each one lands and returns what it answered.
    public typealias Runner = @Sendable (_ items: [String], _ sink: @escaping Sink) async throws -> [String: String]

    /// Runs `quick` and `final` over `items` at once and returns what `final` answered, which is the translation: the cache, the log and the credit take it
    /// and nothing else. `quick`'s texts reach `provisional` only. A quick failure costs the first paint and nothing more (it is not thrown, and the final
    /// model does not wait for it);
    /// `final`'s failure is thrown as it would be alone. When `final` is done the quick model is cancelled, and once this returns neither sink is called again.
    public static func run(items: [String], quick: @escaping Runner, final: @escaping Runner,
                           provisional: @escaping Sink, onFinal: @escaping Sink) async throws -> [String: String] {
        try await withThrowingTaskGroup(of: [String: String]?.self) { group in
            group.addTask {
                _ = try? await quick(items, provisional)
                return nil
            }
            group.addTask { try await final(items, onFinal) }
            var answer: [String: String] = [:]
            while let part = try await group.next() {
                if let part {
                    answer = part
                    group.cancelAll()
                }
            }
            return answer
        }
    }
}

/// What each source of a lens shows between the quick text and the final one: none, a provisional text, then the final. Owned by the pipeline that draws it.
/// The final always wins: a quick text that lands after it is dropped, whatever order the two tasks that carried them ran in.
public struct FirstPaintBook: Equatable, Sendable {
    /// What the screen shows of one source.
    public struct Line: Equatable, Sendable {
        public var provisional: String?
        public var paintedAt: TimeInterval?
        public var final: String?
        public var settledAt: TimeInterval?
        /// How long the provisional text was the one shown (nil until both are in).
        public var shownFor: TimeInterval? {
            guard let paintedAt, let settledAt, provisional != nil else { return nil }
            return max(0, settledAt - paintedAt)
        }
    }

    /// What the final text did to a provisional one.
    public enum Settled: Equatable, Sendable {
        /// The final text is not what the screen shows: draw it (the block cross-fades).
        case repaint
        /// The final text is the provisional one: the screen is right and nothing is drawn again.
        case keep
    }

    /// The numbers of a lens's first paint, for the trace and the harness.
    public struct Stats: Equatable, Sendable {
        /// Sources that were painted provisionally.
        public var painted = 0
        /// Of those, whose final text differed (and was drawn again) and whose did not.
        public var repainted = 0, kept = 0
        /// Characters the final texts changed in the repainted ones (edit distance), and the characters of those final texts.
        public var charsChanged = 0, charsFinal = 0
        /// Seconds each settled provisional text was shown.
        public var shownFor: [TimeInterval] = []
        /// Painted and not (yet) settled.
        public var open: Int { painted - repainted - kept }
    }

    public private(set) var lines: [String: Line] = [:]
    public init() {}

    /// Offers the quick text of `source`. Returns the text to paint, or nil: the final text is in already, the text says nothing (empty, or the source
    /// back), or it is what is shown.
    public mutating func offer(_ text: String, for source: String, at now: TimeInterval) -> String? {
        guard lines[source]?.final == nil, !text.isEmpty, text != source, lines[source]?.provisional != text else { return nil }
        var line = lines[source] ?? Line()
        line.provisional = text
        line.paintedAt = line.paintedAt ?? now
        lines[source] = line
        return text
    }

    /// The text `source` shows while it has no translation of its own.
    public func shown(for source: String) -> String? {
        lines[source].flatMap { $0.final == nil ? $0.provisional : nil }
    }

    /// Takes the final text of `source`. A source that was never painted provisionally simply gets its text drawn.
    public mutating func settle(_ text: String, for source: String, at now: TimeInterval) -> Settled {
        var line = lines[source] ?? Line()
        let shown = line.final == nil ? line.provisional : nil
        line.final = text
        line.settledAt = now
        lines[source] = line
        return shown == text ? .keep : .repaint
    }

    public mutating func removeAll() { lines = [:] }

    public var stats: Stats {
        var s = Stats()
        for line in lines.values {
            guard let provisional = line.provisional else { continue }
            s.painted += 1
            guard let final = line.final else { continue }
            if final == provisional {
                s.kept += 1
            } else {
                s.repainted += 1
                s.charsChanged += Self.distance(provisional, final)
                s.charsFinal += final.count
            }
            if let shown = line.shownFor { s.shownFor.append(shown) }
        }
        return s
    }

    /// The edit distance between two texts in characters (insert, delete, replace): how much of the text the final one changed.
    public static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var diagonal = row[0]
            row[0] = i + 1
            for (j, y) in b.enumerated() {
                let above = row[j + 1]
                row[j + 1] = min(above + 1, row[j] + 1, diagonal + (x == y ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }
}
