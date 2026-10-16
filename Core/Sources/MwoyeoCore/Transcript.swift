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
        var start: TimeInterval
        var lastSeen: TimeInterval
        var translation: String?
    }

    private var open: [String: Open] = [:]
    private var lastTime: TimeInterval = 0

    public init() {}

    private static func usable(_ o: Observed) -> String? {
        guard o.inLens, let t = o.translation, !t.isEmpty, t != o.source else { return nil }
        return t
    }

    private func cue(_ source: String, _ o: Open) -> Cue? {
        guard let t = o.translation else { return nil }
        return Cue(start: o.start, end: o.lastSeen, source: source, translation: t)
    }

    public mutating func observe(time: TimeInterval, lines: [Observed]) -> [TranscriptEvent] {
        lastTime = time
        var entries: [TranscriptEvent] = []
        var cues: [Cue] = []
        var inLensNow = Set<String>()
        for line in lines where line.inLens {
            let s = line.source
            inLensNow.insert(s)
            if let o = open[s], time - o.lastSeen >= Self.gap {
                if let c = cue(s, o) { cues.append(c) }
                open[s] = nil
            }
            var o = open[s] ?? Open(start: time, lastSeen: time, translation: nil)
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
        return entries + cues.sorted { $0.start < $1.start }.map { .cue($0) }
    }

    /// Closes every open cue at the last time it was seen in the lens.
    public mutating func finish(time: TimeInterval) -> [TranscriptEvent] {
        let cues = open.compactMap { cue($0.key, $0.value) }.sorted { $0.start < $1.start }
        open = [:]
        return cues.map { .cue($0) }
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

    static func srtTime(_ t: TimeInterval) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}
