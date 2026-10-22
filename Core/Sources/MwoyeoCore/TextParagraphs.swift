import Foundation

/// A text typed or pasted into the Translate Text window, cut into what goes to the translator (units) and what stays as it was (gaps:
/// line breaks, blank lines, indents, the space between two pieces of a long line). `join` puts the translations back between the very
/// gaps of the source, so the shape of the text survives (docs/design/text-translation.md §2).
///
/// A unit is one non-empty line with its leading and trailing white space taken into the gaps. A line over `limit` characters is cut at
/// sentence ends (a full stop, a question or exclamation mark and an ellipsis before a space; the full-width ones of Chinese and Japanese
/// at once), else at the last space, else at `limit`; a piece is a unit of its own. The cut never ends inside a character.
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
        public init(text: String, isUnit: Bool) {
            self.text = text
            self.isUnit = isUnit
        }
    }

    /// The gaps and units of `text`, in order; `join(split(t), [:]) == t` for every `t`. Two gaps are never next to each other.
    public static func split(_ text: String, limit: Int = pieceLimit) -> [Part] {
        precondition(limit > 0, "a unit needs room for a character")
        var parts: [Part] = []
        func gap(_ s: Substring) {
            guard !s.isEmpty else { return }
            if let last = parts.last, !last.isUnit { parts[parts.count - 1].text += s } else { parts.append(Part(text: String(s), isUnit: false)) }
        }
        var start = text.startIndex
        while start < text.endIndex {
            let newline = text[start...].firstIndex(where: \.isNewline)
            let lineEnd = newline ?? text.endIndex
            let line = text[start..<lineEnd]
            let lead = line.prefix(while: \.isWhitespace)
            var end = line.endIndex
            while end > lead.endIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
            gap(lead)
            for piece in pieces(of: line[lead.endIndex..<end], limit: limit) {
                gap(piece.before)
                if !piece.text.isEmpty { parts.append(Part(text: String(piece.text), isUnit: true)) }
            }
            gap(line[end...])
            start = newline.map { text.index(after: $0) } ?? text.endIndex
            if let newline { gap(text[newline..<start]) }
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
        parts.map { $0.isUnit ? (translations[$0.text] ?? $0.text) : $0.text }.joined()
    }

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
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
