import Foundation

/// Parts of a source line that the translator must carry through as written, or whose rendering must be replaced: a formula, a
/// glossary term. Apple Translation (macOS 26.4) hands a marked range back in place with the attributes it was given, so a span
/// is marked with its index and found again by it. A formula is also marked `skipsTranslation` and comes back as it was sent. A
/// glossary term is not (measured, 2026-10-18, `docs/research/apple-glossary-spans-*.txt`): low latency ignores the mark for words, and
/// high fidelity honours it but writes bits of its own rendering beside the forced word ("손실실은", "인encoder"); so the run of
/// a glossary term is the engine's rendering plus the particle it attached, and the glossary target replaces the rendering.
/// Where the rendering ends and the particle begins is read from the engine's own rendering of the term, asked alone
/// (`resolve(renderings:)`); a run that does not start with it is cut from how it looks (`KoreanParticle.wordEnd`).
///
/// This type is pure: it says which ranges to mark, and, given the target text and the marked runs that came back, puts the
/// glossary targets in and says where the other spans stand. The app turns it into an `AttributedString` and back.
///
/// Offsets are in `Character`s.
public struct ProtectedSpans: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A glossary source term: the engine carries it through, and `target` takes its place in the translation. `term` is the
        /// glossary entry it was found as ("token" for "Tokens"), the key of the engine's rendering of it (`resolve(renderings:)`).
        case glossary(target: String, term: String = "")
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

        public var isGlossary: Bool { if case .glossary = kind { true } else { false } }
        public var isMath: Bool { if case .math = kind { true } else { false } }
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
        /// In `Resolution.text`: what stands for the span there, the glossary target or the span as the engine returned it.
        public let range: Range<Int>
        public let text: String
        /// What the engine had written there: the span itself, or its own rendering of a glossary term.
        public let was: String
        /// How the end of `was` was found (a glossary term in Korean: how the engine's rendering was told from its particle).
        public let cut: Cut
    }

    public enum Cut: Equatable, Sendable {
        /// The run started with the span as it was written (a formula, a name the engine kept), or `was` is the whole of it.
        case span
        /// The run started with the engine's rendering of the term asked alone: the word ends where that does.
        case rendering
        /// No rendering to compare with: the word ends before what looks like a particle (`KoreanParticle.wordEnd`).
        case look
    }

    public struct Resolution: Equatable, Sendable {
        /// The translation with every resolved glossary span replaced by its target.
        public let text: String
        public let resolved: [Resolved]
        /// Missing from the runs, marked on more than one run, or not at the start of its run.
        public let unresolved: [Span]
        public var math: [Resolved] { resolved.filter(\.span.isMath) }
    }

    public let source: String
    /// In source order, none overlapping.
    public let spans: [Span]

    public var isEmpty: Bool { spans.isEmpty }

    /// The glossary entries the spans were found as, each once, in source order.
    public var glossaryTerms: [String] {
        var seen = Set<String>()
        return spans.compactMap { span in
            if case let .glossary(_, term) = span.kind, !term.isEmpty, seen.insert(term).inserted { term } else { nil }
        }
    }

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

    // MARK: - Glossary terms in a source

    /// Every place a glossary term stands in `source`, longest term first, none overlapping. A term written in Latin letters
    /// matches whole words (and their plural: "tokens"); one that starts in lowercase also matches with a capital, as at the
    /// start of a sentence. A term in any other script matches wherever it stands, as `applyGlossary` always did.
    public static func glossarySpans(in source: String, pairs: [(String, String)]) -> [(range: Range<Int>, kind: Kind)] {
        let chars = Array(source)
        var taken = [Bool](repeating: false, count: chars.count)
        var found: [(range: Range<Int>, kind: Kind)] = []
        for (term, target) in pairs.sorted(by: { $0.0.count > $1.0.count }) where term != target && !term.isEmpty {
            let base = Array(term)
            var variants = [base]
            if let first = base.first, first.isLowercase, first.uppercased() != String(first) {
                variants.append(Array(first.uppercased()) + base.dropFirst())
            }
            let wordLeft = isWordLetter(base.first!), wordRight = isWordLetter(base.last!)
            var i = 0
            scan: while i + base.count <= chars.count {
                for v in variants where Array(chars[i..<i + base.count]) == v {
                    if wordLeft, i > 0, isWordChar(chars[i - 1]) { continue }
                    var end = i + base.count
                    if wordRight, end < chars.count, isWordChar(chars[end]) {
                        // "tokens", "boxes": the plural belongs to the word.
                        let tail = String(chars[end...].prefix(while: { isWordChar($0) }))
                        guard ["s", "es"].contains(tail) else { continue }
                        end += tail.count
                    }
                    guard !taken[i..<end].contains(true) else { continue }
                    for k in i..<end { taken[k] = true }
                    found.append((i..<end, .glossary(target: target, term: term)))
                    i = end
                    continue scan
                }
                i += 1
            }
        }
        return found
    }

    /// A letter or digit of a script that puts spaces between words (not Han, kana or hangul).
    private static func isWordLetter(_ c: Character) -> Bool {
        (c.isLetter || c.isNumber) && !(c.unicodeScalars.first.map(TranslationFilter.isCJK) ?? false)
    }
    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    // MARK: - The engine's rendering of a term

    /// What the engine answered for a glossary term translated alone, as a rendering to look for at the start of a run: trimmed of
    /// space and closing punctuation. nil when it is no rendering: empty, several lines, far longer than a term, or the term itself
    /// (the engine kept it: "softmax"), which the span-text rule already handles.
    public static func usableRendering(_ answer: String, ofTerm term: String) -> String? {
        var chars = Array(answer.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = chars.last, ".,;:!?…。、，！？".contains(last) || last.isWhitespace { chars.removeLast() }
        let rendering = String(chars)
        func squeezed(_ s: String) -> String { s.filter { !$0.isWhitespace }.lowercased() }
        guard !rendering.isEmpty, !rendering.contains("\n"), rendering.count <= max(24, term.count * 3),
              squeezed(rendering) != squeezed(term) else { return nil }
        return rendering
    }

    // MARK: - Resolving

    /// Finds each span in the translation and puts the glossary targets in.
    ///
    /// `runs` are the marked runs of the target in order. A span is resolved when exactly one run carries its marker and
    /// - the run starts with the span's text (spaces apart: the engine respaced "q · k" to "q·k"); the rest of the run is
    ///   translated text, the particle the engine attached ("dk의", "√dk로 "); or
    /// - for a glossary term, the run is the engine's own rendering of it and its particle ("토큰으로", "모델에 ", "카메라는"):
    ///   the word ends where `renderings[term]`, the engine's rendering of the term asked alone, ends when the run starts with it
    ///   and only a particle or the like follows ("카메라" ends in a syllable that is also a particle, and only the rendering says
    ///   it is not one; "정확" of "정확도가" is the front of a word), or, for a term in Korean (target and run), before the particle by
    ///   how the run looks (`KoreanParticle.wordEnd`). The word is replaced, unless it is one word of a longer target ("헤드" of
    ///   "어텐션 헤드": the rest of the rendering stands outside the run, and replacing the piece would say it twice).
    /// The run is looked for in `target` from where the last one ended, so two runs with the same text are two places. An
    /// unresolved span adds nothing to `text`; the caller handles its term another way. A glossary target's particle is put in
    /// the form its last sound asks for unless `fixParticles` is false (the probe measures how often it was wrong).
    /// `renderings`: glossary term → what the engine writes for it alone (`usableRendering`), per language pair and strategy.
    public func resolve(target: String, runs: [Run], fixParticles: Bool = true, renderings: [String: String] = [:]) -> Resolution {
        let t = Array(target)
        var count: [Int: Int] = [:]
        for r in runs { count[r.marker, default: 0] += 1 }
        var hits: [(span: Span, start: Int, end: Int, cut: Cut)] = []
        var seen = Set<Int>()
        var cursor = 0
        for run in runs {
            guard spans.indices.contains(run.marker), count[run.marker] == 1 else { continue }
            let span = spans[run.marker]
            let rc = Array(run.text)
            guard let at = Self.find(rc, in: t, from: cursor) else { continue }
            var extent = Self.prefix(of: Array(span.text), in: rc)
            var cut = Cut.span
            if extent == nil, case let .glossary(replacement, term) = span.kind {
                // Where the word ends: by the engine's rendering of the term asked alone, when the run starts with it and only what
                // may follow a word comes after it (any script; for a term in Korean `KoreanParticle.isTail` says what may); else,
                // for a term in Korean, by how the run looks (the word before the particle). Korean only for the look: where a
                // run ends and its particle begins is not known for other languages, and cutting the particle off a Japanese
                // or Chinese run would leave the sentence broken.
                var word: (from: Int, to: Int, cut: Cut)?
                let korean = Self.hasHangul(replacement)
                if let asked = renderings[term], let found = Self.prefix(of: Array(asked), in: rc),
                   !korean || KoreanParticle.isTail(String(rc[found.1...])) {
                    word = (found.0, found.1, .rendering)
                } else if korean, rc.contains(where: Self.isHangul) {
                    let from = rc.prefix { $0.isWhitespace }.count
                    if from < rc.count { word = (from, from + KoreanParticle.wordEnd(in: String(rc[from...])), .look) }
                }
                if let w = word {
                    // One word of a longer target ("헤드" of "어텐션 헤드"): the rest of the rendering is outside the run.
                    let words = replacement.split(separator: " ")
                    if !(words.count > 1 && words.contains(Substring(String(rc[w.from..<w.to])))) { extent = (w.from, w.to); cut = w.cut }
                }
            }
            guard let (from, to) = extent else { continue }
            hits.append((span, at + from, at + to, cut))
            seen.insert(span.marker)
            cursor = at + rc.count
        }

        var out: [Character] = []
        var resolved: [Resolved] = []
        var pos = 0
        for (k, h) in hits.enumerated() {
            out += t[pos..<h.start]
            let piece: [Character]
            switch h.span.kind {
            case let .glossary(replacement, _): piece = Array(replacement)
            case .math: piece = Array(t[h.start..<h.end])
            }
            let from = out.count
            out += piece
            resolved.append(Resolved(span: h.span, range: from..<out.count, text: String(piece), was: String(t[h.start..<h.end]), cut: h.cut))
            // What the engine wrote after the span is kept up to the next span; a glossary target's particle follows its sound.
            let limit = k + 1 < hits.count ? hits[k + 1].start : t.count
            let rest = String(t[h.end..<max(h.end, limit)])
            out += Array(h.span.isGlossary && fixParticles ? KoreanParticle.agree(rest, with: String(piece)) : rest)
            pos = max(h.end, limit)
        }
        out += t[min(pos, t.count)...]
        return Resolution(text: String(out), resolved: resolved, unresolved: spans.filter { !seen.contains($0.marker) })
    }

    private static func isHangul(_ c: Character) -> Bool { c.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
    private static func hasHangul(_ s: String) -> Bool { s.contains(where: isHangul) }

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
