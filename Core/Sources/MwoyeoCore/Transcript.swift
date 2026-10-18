import Foundation

/// Turns the per-snapshot stream of what a lens reads into transcript events: an entry when a line
/// first has a usable translation, and a cue (with start and end) once the line is gone for good.
public struct TranscriptRecorder: Sendable {
    public struct Observed: Sendable, Equatable {
        public var source: String
        public var translation: String?
        public var inLens: Bool
        public init(source: String, translation: String?, inLens: Bool) {
            self.source = source
            self.translation = translation
            self.inLens = inLens
        }
    }

    public struct Entry: Sendable, Equatable {
        public var time: TimeInterval
        public var source: String
        public var translation: String
    }

    public struct Cue: Sendable, Equatable {
        public var start: TimeInterval
        public var end: TimeInterval
        public var source: String
        public var translation: String
    }

    public enum TranscriptEvent: Sendable, Equatable {
        case entry(Entry)
        case cue(Cue)
    }

    /// A source absent from the lens for at least this long is a new line when it returns.
    public static let gap: TimeInterval = 10

    private struct Open {
        /// The order lines were first seen in; lines seen together keep the order they were given in.
        var order: Int
        var start: TimeInterval
        var lastSeen: TimeInterval
        var translation: String?
    }

    private var open: [String: Open] = [:]
    private var lastTime: TimeInterval = 0
    private var opened = 0

    public init() {}

    private static func usable(_ o: Observed) -> String? {
        guard o.inLens, let t = o.translation, !t.isEmpty, t != o.source else { return nil }
        return t
    }

    private func cue(_ source: String, _ o: Open) -> (order: Int, cue: Cue)? {
        guard let t = o.translation else { return nil }
        return (o.order, Cue(start: o.start, end: o.lastSeen, source: source, translation: t))
    }

    private static func inOrder(_ cues: [(order: Int, cue: Cue)]) -> [TranscriptEvent] {
        cues.sorted { ($0.cue.start, $0.order) < ($1.cue.start, $1.order) }.map { .cue($0.cue) }
    }

    public mutating func observe(time: TimeInterval, lines: [Observed]) -> [TranscriptEvent] {
        lastTime = time
        var entries: [TranscriptEvent] = []
        var cues: [(order: Int, cue: Cue)] = []
        var inLensNow = Set<String>()
        for line in lines where line.inLens {
            let s = line.source
            inLensNow.insert(s)
            if let o = open[s], time - o.lastSeen >= Self.gap {
                if let c = cue(s, o) { cues.append(c) }
                open[s] = nil
            }
            var o = open[s] ?? Open(order: opened, start: time, lastSeen: time, translation: nil)
            if open[s] == nil { opened += 1 }
            o.lastSeen = time
            if let t = Self.usable(line) {
                if o.translation == nil { entries.append(.entry(Entry(time: time, source: s, translation: t))) }
                o.translation = t
            }
            open[s] = o
        }
        for (s, o) in open where !inLensNow.contains(s) && time - o.lastSeen >= Self.gap {
            if let c = cue(s, o) { cues.append(c) }
            open[s] = nil
        }
        return entries + Self.inOrder(cues)
    }

    /// Closes every open cue at the last time it was seen in the lens.
    public mutating func finish(time: TimeInterval) -> [TranscriptEvent] {
        let cues = open.compactMap { cue($0.key, $0.value) }
        open = [:]
        return Self.inOrder(cues)
    }
}

public enum TranscriptFormat {
    public enum Track: Sendable { case source, translation }

    private static func clock(_ date: Date, _ pattern: String, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = pattern
        return f.string(from: date)
    }

    public static func markdownHeader(lens: String, date: Date, timeZone: TimeZone) -> String {
        "## \(lens) · \(clock(date, "yyyy-MM-dd HH:mm", timeZone))\n\n"
    }

    public static func markdownEntry(_ e: TranscriptRecorder.Entry, start: Date, timeZone: TimeZone) -> String {
        let quoted = e.source.split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }
        let stamp = clock(start.addingTimeInterval(e.time), "HH:mm:ss", timeZone)
        return "**\(stamp)**\n\(quoted.joined(separator: "\n"))\n\(e.translation)\n\n"
    }

    public static func srtCue(index: Int, cue: TranscriptRecorder.Cue, origin: TimeInterval, track: Track) -> String {
        let start = max(0, cue.start - origin)
        let end = max(max(0, cue.end - origin), start + 0.3)
        let text = track == .source ? cue.source : cue.translation
        return "\(index)\n\(srtTime(start)) --> \(srtTime(end))\n\(text)\n\n"
    }

    /// One line of the JSON Lines log: an object per translated line, keys in this order, no line break inside. `app` is the
    /// bundle ID of the app in the lens (null when unknown); `engine` is "apple" or an added engine's name.
    public static func jsonlLine(time: Date, timeZone: TimeZone, lens: String, app: String?, source: String, target: String,
                                 engine: String, original: String, translation: String) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fields: [(String, String?)] = [("time", f.string(from: time)), ("lens", lens), ("app", app), ("source", source), ("target", target),
                                           ("engine", engine), ("original", original), ("translation", translation)]
        let body = fields.map { "\(json($0.0)):\($0.1.map(json) ?? "null")" }.joined(separator: ",")
        return "{\(body)}\n"
    }

    private static func json(_ s: String) -> String {
        guard let d = try? JSONEncoder().encode(s) else { return "\"\"" }
        return String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\\/", with: "/")
    }

    static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

/// Merges the variants of one line the recorder reports as several. A lens reads a wrapped paragraph as line
/// fragments while the page moves and as the whole paragraph once it is still ("Patch 1.4 finally fixed the double
/// jump bug. What else are you hoping" and "… hoping they fix next?"); OCR also differs by a punctuation mark between
/// reads. Entries are held a few seconds so a fragment is replaced by the fuller text instead of written beside it, and
/// the cues of the fragments fold into the cue of the line they belong to, so entries and cues stay one to one.
public struct TranscriptMerger: Sendable {
    private struct Held {
        var entry: TranscriptRecorder.Entry
        var arrived: TimeInterval
    }

    /// How long an entry waits for a fuller reading of its line.
    public var hold: TimeInterval
    private var held: [Held] = []
    /// A merged-away source → the text that survived.
    private var into: [String: (source: String, translation: String)] = [:]
    /// Every closed cue, sorted by start.
    public private(set) var cues: [TranscriptRecorder.Cue] = []

    public init(hold: TimeInterval = 3) { self.hold = hold }

    /// Letters and digits only, lowercased: two readings of a line differ in punctuation and spacing.
    private static func key(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Whether `a` and `b` read the same line: equal, or one is a fragment of the other. A short fragment only counts at
    /// the start or end of a line at least five times longer than it ("game" ends a paragraph; "1h ago" does not end "11h ago").
    static func related(_ a: String, _ b: String) -> Bool {
        let x = key(a), y = key(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        if short == long { return true }
        guard long.contains(short) else { return false }
        return short.count >= 8 || (short.count >= 4 && long.count >= 5 * short.count && (long.hasPrefix(short) || long.hasSuffix(short)))
    }

    /// Feeds what the recorder reported at `now` (the recorder's clock); returns the entries now ready to write.
    /// A cue in `events` changes `cues`.
    public mutating func add(_ events: [TranscriptRecorder.TranscriptEvent], now: TimeInterval) -> [TranscriptRecorder.Entry] {
        for event in events {
            switch event {
            case .entry(let e): holdEntry(e, now: now)
            case .cue(let c): close(c)
            }
        }
        guard let last = held.lastIndex(where: { $0.arrived <= now - hold }) else { return [] }
        defer { held.removeSubrange(0...last) }
        return held[0...last].map(\.entry)
    }

    /// The lens closed: everything held is ready.
    public mutating func finish() -> [TranscriptRecorder.Entry] {
        defer { held = [] }
        return held.map(\.entry)
    }

    private mutating func holdEntry(_ e: TranscriptRecorder.Entry, now: TimeInterval) {
        guard let i = held.firstIndex(where: { Self.related($0.entry.source, e.source) }) else {
            held.append(Held(entry: e, arrived: now))
            return
        }
        let old = held[i].entry
        let fuller = Self.key(e.source).count > Self.key(old.source).count ? e : old
        let gone = fuller.source == e.source ? old : e
        into[gone.source] = (fuller.source, fuller.translation)
        held[i] = Held(entry: .init(time: min(old.time, e.time), source: fuller.source, translation: fuller.translation), arrived: now)
    }

    private mutating func close(_ c: TranscriptRecorder.Cue) {
        var cue = c
        let own = into[c.source] == nil
        if let t = into[c.source] { (cue.source, cue.translation) = t }
        let gap = TranscriptRecorder.gap
        if let i = cues.firstIndex(where: { $0.source == cue.source && $0.start <= cue.end + gap && cue.start <= $0.end + gap }) {
            var k = cues.remove(at: i)
            k.start = min(k.start, cue.start)
            k.end = max(k.end, cue.end)
            // The line's own cue carries its last translation.
            if own { k.translation = cue.translation }
            cue = k
        }
        cues.insert(cue, at: cues.firstIndex { $0.start > cue.start } ?? cues.endIndex)
    }
}
