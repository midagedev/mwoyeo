import Foundation

/// Parts of a source line that the translator must carry through as written: a formula. Apple Translation (macOS 26.4) hands a
/// marked range back in place with the attributes it was given, so a span is marked with its index and found again by it, and
/// marked `skipsTranslation` so it comes back as it was sent (`docs/research/paper-translation.md` §4).
///
/// This type is pure: it says which ranges to mark and, given the target text and the marked runs that came back, where the
/// spans stand in it. The app turns it into an `AttributedString` and back.
///
/// Offsets are in `Character`s.
public struct ProtectedSpans: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A formula the page typesets as symbols: it stays as the engine returned it, to be drawn over later.
        case math(id: Int)
    }

    public struct Span: Equatable, Sendable {
        /// The value the marked run carries back: the span's index.
        public let marker: Int
        /// In `source`.
        public let range: Range<Int>
        public let text: String
        public let kind: Kind
    }

    /// A marked run of the translation as it came back: its text and the marker it carried.
    public struct Run: Equatable, Sendable {
        public let marker: Int
        public let text: String
        public init(marker: Int, text: String) {
            self.marker = marker
            self.text = text
        }
    }

    /// A span found again in the translation.
    public struct Resolved: Equatable, Sendable {
        public let span: Span
        /// In the target text.
        public let range: Range<Int>
        /// The span as the engine returned it there (spaces may differ from `span.text`: "q · k" came back "q·k").
        public let text: String
    }

    public struct Resolution: Equatable, Sendable {
        public let resolved: [Resolved]
        /// Missing from the runs, marked on more than one run, or not at the start of its run.
        public let unresolved: [Span]
    }

    public let source: String
    /// In source order, none overlapping.
    public let spans: [Span]

    public var isEmpty: Bool { spans.isEmpty }

    /// Spans that overlap an earlier one (the longer wins at one start) or lie outside `source` are dropped.
    public init(source: String, spans wanted: [(range: Range<Int>, kind: Kind)]) {
        let chars = Array(source)
        var kept: [Span] = []
        var end = 0
        let ordered = wanted.sorted { ($0.range.lowerBound, $1.range.upperBound) < ($1.range.lowerBound, $0.range.upperBound) }
        for w in ordered where w.range.lowerBound >= end && w.range.upperBound <= chars.count && !w.range.isEmpty {
            let text = String(chars[w.range])
            guard !text.allSatisfy(\.isWhitespace) else { continue }
            kept.append(Span(marker: kept.count, range: w.range, text: text, kind: w.kind))
            end = w.range.upperBound
        }
        self.source = source
        spans = kept
    }

    // MARK: - The marker

    public static let markerScheme = "mwoyeo-span"

    /// The attribute value that goes on the span's range (a link, the one attribute that came back on every run tried).
    public func markerURL(_ span: Span) -> URL? { URL(string: "\(Self.markerScheme):\(span.marker)") }

    public static func marker(of url: URL) -> Int? {
        url.scheme == markerScheme ? Int(url.absoluteString.dropFirst(markerScheme.count + 1)) : nil
    }

    // MARK: - Resolving

    /// Finds each span in the translation.
    ///
    /// `runs` are the marked runs of the target in order. A span is resolved when exactly one run carries its marker and the run
    /// starts with the span's text (spaces apart: the engine respaced "q · k" to "q·k"); the rest of the run is translated text,
    /// the particle the engine attached ("dk의", "√dk로 "). The run is looked for in `target` from where the last one ended, so
    /// two runs with the same text are two places.
    public func resolve(target: String, runs: [Run]) -> Resolution {
        let t = Array(target)
        var count: [Int: Int] = [:]
        for r in runs { count[r.marker, default: 0] += 1 }
        var resolved: [Resolved] = []
        var seen = Set<Int>()
        var cursor = 0
        for run in runs {
            guard spans.indices.contains(run.marker), count[run.marker] == 1 else { continue }
            let span = spans[run.marker]
            let rc = Array(run.text)
            guard let at = Self.find(rc, in: t, from: cursor), let (from, to) = Self.prefix(of: Array(span.text), in: rc) else { continue }
            resolved.append(Resolved(span: span, range: at + from..<at + to, text: String(t[at + from..<at + to])))
            seen.insert(span.marker)
            cursor = at + rc.count
        }
        return Resolution(resolved: resolved, unresolved: spans.filter { !seen.contains($0.marker) })
    }

    /// Where `span` stands at the start of `run` (leading spaces skipped, spaces inside it ignored on both sides).
    private static func prefix(of span: [Character], in run: [Character]) -> (Int, Int)? {
        var i = 0
        while i < run.count, run[i].isWhitespace { i += 1 }
        let start = i
        for c in span where !c.isWhitespace {
            while i < run.count, run[i].isWhitespace { i += 1 }
            guard i < run.count, run[i] == c else { return nil }
            i += 1
        }
        return (start, i)
    }

    private static func find(_ needle: [Character], in hay: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        var i = from
        while i + needle.count <= hay.count {
            if hay[i] == needle[0], Array(hay[i..<i + needle.count]) == needle { return i }
            i += 1
        }
        return nil
    }
}
