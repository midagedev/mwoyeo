import Foundation

/// The last few translated lines that left the lens, for a lens that keeps them on screen (design games-and-video §2: chat, visual novels).
///
/// What changed is the transcript recorder's to say (`TranscriptRecorder`: a line's first usable translation, or a new one); this reads its
/// events and the lines in the lens now and keeps the rest. A line in the lens is not in the stack: it is already on screen.
public struct RecentLines: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var source: String
        public var translation: String
        /// When the recorder first reported it.
        public var time: TimeInterval
    }

    /// How many lines a lens may keep (the setting `recentLineCount`).
    public static let range = 1...8
    public static let standard = 3
    /// Lines remembered, the ones in the lens included.
    private static let memory = 64

    public private(set) var capacity: Int
    /// Every line reported, oldest first.
    private var lines: [Line] = []
    private var present: Set<String> = []

    public init(capacity: Int = standard) { self.capacity = min(max(capacity, Self.range.lowerBound), Self.range.upperBound) }

    public mutating func setCapacity(_ n: Int) { capacity = min(max(n, Self.range.lowerBound), Self.range.upperBound) }

    /// One look at the lens: what the recorder reported for it, and the lines it was given.
    public mutating func observe(_ events: [TranscriptRecorder.TranscriptEvent], lines observed: [TranscriptRecorder.Observed]) {
        present = Set(observed.filter(\.inLens).map(\.source))
        for case .entry(let e) in events { add(e) }
    }

    private mutating func add(_ e: TranscriptRecorder.Entry) {
        func size(_ s: String) -> Int { s.filter { $0.isLetter || $0.isNumber }.count }
        if let i = lines.firstIndex(where: { $0.source == e.source }) {
            lines[i].translation = e.translation
        } else if let i = lines.firstIndex(where: { TranscriptMerger.related($0.source, e.source) }) {
            // A reading of a line the lens already had in pieces: the fuller one stands for it, where the first stood.
            if size(e.source) > size(lines[i].source) { lines[i] = Line(source: e.source, translation: e.translation, time: lines[i].time) }
        } else {
            lines.append(Line(source: e.source, translation: e.translation, time: e.time))
        }
        if lines.count > Self.memory { lines.removeFirst(lines.count - Self.memory) }
    }

    /// The lines that left the lens, newest first, at most `capacity`.
    public var stack: [Line] { Array(lines.reversed().lazy.filter { !present.contains($0.source) }.prefix(capacity)) }

    /// Forgets every line (another language or engine, the lens closed).
    public mutating func clear() {
        lines = []
        present = []
    }

    /// How opaque the line `rank` places from the lens (0 = the newest) is drawn of `count`: 1 for the newest, 0.6 for the oldest.
    /// 2026-10-22 (game117 vision): the floor was 0.45, about 2.2:1 on the light popover material; 0.6 reads about 2.9:1 light, 5.4:1 dark.
    public static func opacity(rank: Int, of count: Int) -> Double {
        1 - 0.4 * Double(min(max(rank, 0), max(count - 1, 0))) / Double(max(count - 1, 1))
    }
}
