import CoreGraphics
import Foundation

/// The last few translated lines that left the lens, for a lens that keeps them on screen (design games-and-video §2: chat, visual novels).
///
/// What changed is the transcript recorder's to say (`TranscriptRecorder`: a line's first usable translation, or a new one); this reads its
/// events and the lines in the lens now and keeps the rest. A line in the lens is not in the stack: it is already on screen.
///
/// The recorder reports everything the lens read, and a game's lens reads a line while it is typed out: the first characters on their own,
/// each translated alone, then the line. The log may keep every one of them; the stack is what a reader read, so it keeps a reading only
/// when `reading(of:)` calls it a line (design games-and-video §2, the table under "What the stack holds").
public struct RecentLines: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public var source: String
        public var translation: String
        /// When the recorder first reported it.
        public var time: TimeInterval
    }

    /// What the stack makes of a line the lens read. The one table of the rule: a reading is a line unless a row above it says otherwise; a row
    /// needs where the block stood (`TranscriptRecorder.Observed.frame`), so a reading with no place is a line.
    public enum Reading: Sendable, Equatable {
        /// A whole line of the text: kept once it left the lens.
        case line
        /// Read inside a region the person ignored (a HUD, a timer): the lens does not read it any more, and what it read of it is not text.
        case ignored
        /// A name on a line of its own over the text it speaks (`LabelRule.nameTags`), or a name-shaped read where such a name stood (the plate read
        /// again as it fades in, or misread): the speaker, not a line.
        case label
        /// A part of the line `of`, read while the line was being typed out: it stood where the line stands, the line first showed with it or
        /// just after it (`reach`), and the line holds its text. The line stands for it.
        case piece(of: String)
    }

    /// How long a line that left the lens, and that stood somewhere, waits before the stack shows it: a part of a line can leave one read
    /// before the line that holds it shows, and the part must be folded into the line before anyone sees it (`Reading.piece`).
    /// [provisional — backlog] 2026-10-23 (recent117, film 4 take t4-game, the `render` lines of its app.err): 'ヴ' was read, then '肩を' 0.29 s
    /// later (the look at which 'ヴ' left), then the line that holds both 0.67 s after that; so a part waits 0.67 s at least. 1 s covers it with
    /// room for the pipeline's own cadence (0.2-0.4 s a read). A line that is not folded shows after exactly this long (`nextLift` says when, so
    /// the panel need not wait for a look).
    public static let hold: TimeInterval = 1.0
    /// How many lines a lens may keep (the setting `recentLineCount`).
    public static let range = 1...8
    public static let standard = 3
    /// Lines remembered, the ones in the lens included.
    private static let memory = 64
    /// How many changes of what the lens shows a line may first appear after the part of it that was read before it (`Reading.piece`): the
    /// reads of a typed-out line come one after another, a few between the first characters and the line.
    /// 2026-10-23 (recent117, film 4 take t4-game, the `render` lines of its app.err): the line first showed 1 change after its first part
    /// ('ュザ', 'い') or 2 after it ('ヴ', then '肩を', then the line); 3 leaves room for one read more.
    static let reach = 3

    public private(set) var capacity: Int
    /// How long a line that stood somewhere waits after it left (`RecentLines.hold`); the checks run it at 0.
    public var hold: TimeInterval
    /// The clock of the last look (nil: the caller has none, and nothing waits).
    private var looked: TimeInterval?
    /// Every line reported, oldest first.
    private var lines: [Line] = []
    private var present: Set<String> = []
    /// Where and when the lens showed each text, the ones that were not reported (not translated yet, or never) included.
    private var sights: [String: Sight] = [:]
    /// How many times the lens showed another set of lines than before: the clock of `Sight`. A read that repeats the one before is nothing.
    private var epoch = 0
    /// The regions the person ignored, in the frame of `TranscriptRecorder.Observed.frame`, as of the last look.
    private var ignored: [CGRect] = []

    private struct Sight: Sendable, Equatable {
        var first: Int
        var last: Int
        var frame: CGRect?
        var label = false
        /// When the lens first did not show it any more, on the clock of `observe`; nil while it shows (or when there is no clock).
        var left: TimeInterval?
    }

    public init(capacity: Int = standard, hold: TimeInterval = RecentLines.hold) {
        self.capacity = min(max(capacity, Self.range.lowerBound), Self.range.upperBound)
        self.hold = hold
    }

    public mutating func setCapacity(_ n: Int) { capacity = min(max(n, Self.range.lowerBound), Self.range.upperBound) }

    /// One look at the lens: what the recorder reported for it, the lines it was given, the regions the lens ignores now, and the time of the look
    /// (the recorder's clock; nil is a caller with none, for which no line waits).
    public mutating func observe(_ events: [TranscriptRecorder.TranscriptEvent], lines observed: [TranscriptRecorder.Observed],
                                 ignored regions: [CGRect] = [], at time: TimeInterval? = nil) {
        let shown = observed.filter(\.inLens)
        let showing = Set(shown.map(\.source))
        if showing != present { epoch += 1 }
        for source in present.subtracting(showing) { sights[source]?.left = time }
        present = showing
        ignored = regions
        looked = time
        for o in shown {
            var s = sights[o.source] ?? Sight(first: epoch, last: epoch)
            s.last = epoch
            s.left = nil
            if let f = o.frame { s.frame = f }
            sights[o.source] = s
        }
        // Whether a line is a name is decided over the lines the lens shows together; the box under the name may not be read at the next look.
        let framed = shown.filter { $0.frame != nil }
        let items = framed.map { LabelRule.Item(rect: $0.frame ?? .zero, text: $0.source, color: RGBA(0, 0, 0)) }
        for i in LabelRule.nameTags(items) { sights[framed[i].source]?.label = true }
        for case .entry(let e) in events { add(e) }
        if sights.count > 4 * Self.memory {
            let kept = Set(lines.map(\.source))
            let drop = sights.filter { !showing.contains($0.key) && !kept.contains($0.key) }.sorted { $0.value.last < $1.value.last }
                .prefix(sights.count - 2 * Self.memory)
            for (k, _) in drop { sights[k] = nil }
        }
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

    /// What `line` is to the stack. The rows run in this order; the first that holds decides.
    public func reading(of line: Line) -> Reading {
        guard let sight = sights[line.source], let frame = sight.frame else { return .line }
        if ignored.contains(where: { Self.holds($0, frame, share: 0.5) }) { return .ignored }
        if sight.label || standsWhereANameStood(line.source, frame) { return .label }
        let key = TranscriptMerger.key(line.source)
        let whole = sights.filter { source, other in
            guard source != line.source, let place = other.frame, other.first >= sight.first, other.first <= sight.last + Self.reach,
                  Self.holds(place, frame, share: 0.8) else { return false }
            let longer = TranscriptMerger.key(source)
            return longer.count > key.count && longer.contains(key)
        }.min { ($0.value.first, $0.key) < ($1.value.first, $1.key) }
        return whole.map { .piece(of: $0.key) } ?? .line
    }

    /// A name plate is read again and again as it fades in, and read alone while the box under it is not: 'シュサンヌ' for 'シュザンヌ' at a look with
    /// no box has nothing under it to be a name by. A name-shaped text over the place a name stood is the name.
    private func standsWhereANameStood(_ source: String, _ frame: CGRect) -> Bool {
        LabelRule.isNameTag(.init(rect: frame, text: source, color: RGBA(0, 0, 0)))
            && sights.contains { $0.value.label && $0.value.frame.map { Self.holds($0, frame, share: 0.5) } == true }
    }

    /// Whether `inner` lies in `outer` for at least `share` of its area.
    private static func holds(_ outer: CGRect, _ inner: CGRect, share: CGFloat) -> Bool {
        let area = inner.width * inner.height
        let cut = outer.intersection(inner)
        return area > 0 && !cut.isNull && cut.width * cut.height >= share * area
    }

    /// The lines that left the lens, newest first, at most `capacity`: the ones `reading(of:)` calls lines and that have been away `hold` seconds
    /// (a line with no place is never held: nothing could fold it). As of the last look.
    public var stack: [Line] { stack(at: looked) }

    /// The stack at `time` on the clock of `observe` (nil: nothing waits).
    public func stack(at time: TimeInterval?) -> [Line] {
        Array(lines.reversed().lazy.filter { !present.contains($0.source) && reading(of: $0) == .line && wait(of: $0, at: time) == 0 }.prefix(capacity))
    }

    /// How long `line` still waits at `time` before the stack may show it.
    private func wait(of line: Line, at time: TimeInterval?) -> TimeInterval {
        guard let time, let sight = sights[line.source], sight.frame != nil, let left = sight.left else { return 0 }
        return max(0, left + hold - time)
    }

    /// Seconds from `time` until the next line that waits is shown (nil: none waits), for whoever draws the stack and has no look to wait for.
    public func nextLift(at time: TimeInterval) -> TimeInterval? {
        lines.compactMap { line -> TimeInterval? in
            guard !present.contains(line.source), reading(of: line) == .line else { return nil }
            let w = wait(of: line, at: time)
            return w > 0 ? w : nil
        }.min()
    }

    /// What the stack shows and what it holds back (the lines that left, with the row of the table that says they are not lines), for the
    /// trace and the checks.
    public func report(at time: TimeInterval?) -> String {
        let held = lines.filter { !present.contains($0.source) }.compactMap { line -> String? in
            let reading = reading(of: line)
            let w = wait(of: line, at: time)
            if reading == .line { return w > 0 ? "'\(line.source)' waits \(Int(w * 1000)) ms" : nil }
            return "'\(line.source)' \(reading)"
        }
        return "stack [\(stack(at: time).map { "'\($0.translation)'" }.joined(separator: ", "))] held back [\(held.joined(separator: ", "))]"
    }

    /// Forgets every line (another language or engine, the lens closed).
    public mutating func clear() {
        lines = []
        present = []
        sights = [:]
        epoch = 0
        ignored = []
        looked = nil
    }

    /// How opaque the line `rank` places from the lens (0 = the newest) is drawn of `count`: 1 for the newest, 0.6 for the oldest.
    /// 2026-10-22 (game117 vision): the floor was 0.45, about 2.2:1 on the light popover material; 0.6 reads about 2.9:1 light, 5.4:1 dark.
    public static func opacity(rank: Int, of count: Int) -> Double {
        1 - 0.4 * Double(min(max(rank, 0), max(count - 1, 0))) / Double(max(count - 1, 1))
    }
}
