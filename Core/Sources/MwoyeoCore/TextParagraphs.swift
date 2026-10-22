import Foundation

/// A text typed or pasted into the Translate Text window, cut into what goes to the translator (units) and what stays as it was (gaps:
/// line breaks, blank lines, indents, the space between two pieces of a long line). `join` puts the translations back between the very
/// gaps of the source, so the shape of the text survives (docs/design/text-translation.md §2).
///
/// A unit is one non-empty line with its leading and trailing white space taken into the gaps, or, where a paragraph is wrapped by hard
/// line breaks (text copied from a PDF or a mail), the lines of that paragraph read as one (`Seam`). A line over `limit` characters is cut
/// at sentence ends (a full stop, a question or exclamation mark and an ellipsis before a space; the full-width ones of Chinese and
/// Japanese at once), else at the last space, else at `limit`; a piece is a unit of its own. The cut never ends inside a character.
public enum TextParagraphs {
    /// The longest unit: what one engine call can be asked to translate as a "line" without the answer losing its place. The agent tool's
    /// line limit is twice this.
    public static let pieceLimit = 1_000
    /// What the window translates at most; a text editor and an engine's bill are the reasons (design §2).
    public static let maxCharacters = 50_000

    public struct Part: Equatable, Sendable {
        public var text: String
        /// True for what is translated; false for a gap.
        public var isUnit: Bool
        /// What a unit was in the source when `text` is not it: the lines of a wrapped paragraph, with the breaks between them. A unit with
        /// no translation comes back as this, so `join(split(t), [:]) == t` holds for wrapped text too.
        public var source: String?
        public init(text: String, isUnit: Bool, source: String? = nil) {
            self.text = text
            self.isUnit = isUnit
            self.source = source
        }
    }

    /// What stands between two neighbouring lines of one block (lines with no blank line between): the paragraph goes on, or something else
    /// begins. Text has no geometry; the lens's own join (`ParagraphGrouper`, by the boxes) has no counterpart here, so the evidence is the
    /// text's: how wide the upper line is (`BodySize.bodyCharacters`, what a line of body text holds), whether it ends its sentence, whether
    /// the lower one opens a list item (`ParagraphGrouper.startsListItem`) and whether the block is code (`CodeRegion.readsAsCode`).
    public enum Seam: Equatable, Sendable {
        /// One paragraph wrapped here; `glue` is what stands where the break was (a space; nothing after a hyphen or between two Han or kana
        /// characters).
        case wrapped(glue: String)
        /// The lower line opens a list item.
        case listItem
        /// The upper line is shorter than a line of body text: a heading, a label, a short typed line, the end of a paragraph.
        case short
        /// The upper line ends its sentence (or a clause, with a colon or a semicolon) and the lower one does not go on in lower case.
        case sentenceEnd
        /// A line set in columns (a tab or three spaces inside it): a table row, not a wrapped line.
        case columns
        /// The block is code, a log or a terminal.
        case code
    }

    /// The gaps and units of `text`, in order; `join(split(t), [:]) == t` for every `t`. Two gaps are never next to each other.
    public static func split(_ text: String, limit: Int = pieceLimit) -> [Part] {
        precondition(limit > 0, "a unit needs room for a character")
        let rows = rows(of: text)
        let seams = seams(between: rows)
        var parts: [Part] = []
        func gap(_ s: Substring) {
            guard !s.isEmpty else { return }
            if let last = parts.last, !last.isUnit { parts[parts.count - 1].text += s } else { parts.append(Part(text: String(s), isUnit: false)) }
        }
        var i = 0
        while i < rows.count {
            gap(rows[i].lead)
            // The lines of one wrapped paragraph make one unit, while it fits in a piece; a line over `limit` is cut below.
            var last = i
            var joined = String(rows[i].content)
            while last + 1 < rows.count, case .wrapped(let glue) = seams[last], joined.count + glue.count + rows[last + 1].content.count <= limit {
                joined += glue + rows[last + 1].content
                last += 1
            }
            if last > i {
                parts.append(Part(text: joined, isUnit: true, source: String(text[rows[i].content.startIndex..<rows[last].content.endIndex])))
            } else {
                for piece in pieces(of: rows[i].content, limit: limit) {
                    gap(piece.before)
                    if !piece.text.isEmpty { parts.append(Part(text: String(piece.text), isUnit: true)) }
                }
            }
            gap(rows[last].trail)
            gap(rows[last].newline)
            i = last + 1
        }
        return parts
    }

    /// The units of `parts`, each text once, in the order they first appear.
    public static func units(_ parts: [Part]) -> [String] {
        var seen = Set<String>()
        return parts.compactMap { $0.isUnit && seen.insert($0.text).inserted ? $0.text : nil }
    }

    /// `parts` with each unit replaced by its translation (the unit itself when it has none), the gaps as they were.
    public static func join(_ parts: [Part], _ translations: [String: String]) -> String {
        parts.map { $0.isUnit ? (translations[$0.text] ?? $0.source ?? $0.text) : $0.text }.joined()
    }

    /// How many line breaks of the source `parts` read as no break: the soft wraps of paragraphs that are one unit now.
    public static func wrapsJoined(_ parts: [Part]) -> Int {
        parts.reduce(0) { $0 + ($1.source?.filter(\.isNewline).count ?? 0) }
    }

    // MARK: Lines and the seams between them

    /// One line of the text: what stands before its words, the words, what stands after them, and the line break.
    private struct Row {
        var lead: Substring
        var content: Substring
        var trail: Substring
        /// The line break that ends the row; empty on the last one.
        var newline: Substring
    }

    private static func rows(of text: String) -> [Row] {
        var rows: [Row] = []
        var start = text.startIndex
        while start < text.endIndex {
            let newline = text[start...].firstIndex(where: \.isNewline)
            let line = text[start..<(newline ?? text.endIndex)]
            let lead = line.prefix(while: \.isWhitespace)
            var end = line.endIndex
            while end > lead.endIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
            start = newline.map { text.index(after: $0) } ?? text.endIndex
            rows.append(Row(lead: lead, content: line[lead.endIndex..<end], trail: line[end...], newline: newline.map { text[$0..<start] } ?? text[start..<start]))
        }
        return rows
    }

    /// `seams[i]` is what stands between row `i` and row `i + 1`; a blank row on either side leaves a paragraph break (`.short`).
    private static func seams(between rows: [Row]) -> [Seam] {
        var seams = [Seam](repeating: .short, count: rows.count)
        var first = 0
        while first < rows.count {
            guard !rows[first].content.isEmpty else { first += 1; continue }
            var last = first
            while last + 1 < rows.count, !rows[last + 1].content.isEmpty { last += 1 }
            if last > first {
                let lines = rows[first...last].map(\.content)
                let code = CodeRegion.readsAsCode(lines.map(String.init))
                for i in first..<last { seams[i] = code ? .code : seam(lines[i - first], lines[i - first + 1]) }
            }
            first = last + 1
        }
        return seams
    }

    /// What stands between `upper` and the line under it (both are the words of a line, with no white space at either end).
    static func seam(_ upper: Substring, _ lower: Substring) -> Seam {
        if inColumns(upper) || inColumns(lower) { return .columns }
        if ParagraphGrouper.startsListItem(String(lower)) { return .listItem }
        if width(of: upper) < BodySize.bodyCharacters { return .short }
        if endsClause(upper), lower.first?.isLowercase != true { return .sentenceEnd }
        return .wrapped(glue: glue(upper, lower))
    }

    private static func inColumns(_ line: Substring) -> Bool { line.contains("\t") || line.contains("   ") }

    /// Characters, a Han, kana or hangul glyph counting two: a line of Japanese holds half the characters of one of English.
    private static func width(of line: Substring) -> Int { line.reduce(0) { $0 + (TranslationFilter.isCJKText($1) ? 2 : 1) } }

    /// The last character of `line` before any closing quote or bracket is the end of a sentence, or of a clause that a list or a formula follows.
    private static func endsClause(_ line: Substring) -> Bool {
        guard let last = line.last(where: { !closers.contains($0) }) else { return false }
        return sentenceEnds.contains(last) || clauseEnds.contains(last)
    }

    /// What stands where the break was: nothing after a hyphen (the word it cut keeps its hyphen: "per-" "channel" is "per-channel", "thresh-"
    /// "old" is "thresh-old") and beside Han or kana (no spaces between words), else a space.
    private static func glue(_ upper: Substring, _ lower: Substring) -> String {
        guard let end = upper.last, let start = lower.first else { return " " }
        if "-\u{2010}".contains(end), upper.dropLast().last?.isLetter == true { return "" }
        return spaceless(end) || spaceless(start) ? "" : " "
    }

    /// Han, kana and the CJK punctuation; hangul is written with spaces.
    private static func spaceless(_ c: Character) -> Bool {
        TranslationFilter.isCJKText(c) && !c.unicodeScalars.contains { (0x1100...0x11FF).contains($0.value) || (0x3130...0x318F).contains($0.value) || (0xAC00...0xD7AF).contains($0.value) }
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    /// A colon or a semicolon ends a line as a full stop does: a list, a formula or the next clause is a line of its own.
    private static let clauseEnds: Set<Character> = [":", ";", "：", "；"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»", "」", "』", "）"]
    /// Ends that need no space after them (the text has none between sentences).
    private static let fullWidthEnds: Set<Character> = ["。", "！", "？"]

    /// `line` cut into pieces of at most `limit` characters, each with the white space that lay before it.
    private static func pieces(of line: Substring, limit: Int) -> [(before: Substring, text: Substring)] {
        var out: [(Substring, Substring)] = []
        var rest = line
        var before = rest.prefix(0)
        while !rest.isEmpty {
            guard rest.count > limit else {
                out.append((before, rest))
                break
            }
            let window = rest.prefix(limit)
            let cut = sentenceCut(in: window, then: rest.dropFirst(limit).first) ?? spaceCut(in: window) ?? window.endIndex
            out.append((before, rest[..<cut]))
            let tail = rest[cut...]
            let spaces = tail.prefix(while: \.isWhitespace)
            before = spaces
            rest = tail[spaces.endIndex...]
        }
        return out
    }

    /// Just after the last sentence end of `window` that is followed by a space or is a full-width mark (the window's own last character
    /// is followed by `next`).
    private static func sentenceCut(in window: Substring, then next: Character?) -> Substring.Index? {
        var i = window.endIndex
        while i > window.startIndex {
            let at = window.index(before: i)
            let c = window[at]
            if sentenceEnds.contains(c) {
                let after = window.index(after: at)
                let following = after < window.endIndex ? window[after] : next
                if fullWidthEnds.contains(c) || following?.isWhitespace == true { return after }
            }
            i = at
        }
        return nil
    }

    /// At the last space of `window` that is not its first character.
    private static func spaceCut(in window: Substring) -> Substring.Index? {
        guard let space = window.lastIndex(where: \.isWhitespace), space > window.startIndex else { return nil }
        return space
    }
}
