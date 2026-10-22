import Foundation

/// The lines of a block become the one text that is translated. A line is followed by a space, unless a script that is set without spaces
/// (CJK) meets the join. A line that ends in a hyphen was either broken inside a word by the typesetter ("noth-" "ing") or ends a
/// compound at its own hyphen ("sequence-" "aligned"); the reader cannot tell which, and read as one text the broken word came back
/// from the engine as "noth-ing" (film3's take of page 6 of the method paper; the paper bench carries 40 more). `Hyphens.word` drops the
/// hyphen where the joined form is a word and keeps it where it is not: "nothing", "transduction", but "sequence-aligned",
/// "position-wise", "co-occurrence". Design: docs/design/recognition.md section 13.
public enum LineJoin {
    /// What the hyphen at the end of a line does to the line after it.
    public enum Hyphens {
        /// Kept, and no space after it: the join before 1.1.7 ("noth-ing").
        case kept
        /// Dropped where `isWord` calls the two pieces one word (see `joinsWord`); the check takes the joined form, "nothing".
        case word(isWord: (String) -> Bool)
    }

    /// The lines as one text, and the words whose hyphen was dropped on the way (for the trace).
    public struct Joined: Equatable, Sendable {
        public var text: String
        public var words: [String]
    }

    /// `lines` in reading order as one text. `isCJK` says which characters are set without spaces (the caller's, the reader's own table).
    public static func join(_ lines: [String], hyphens: Hyphens = .kept, isCJK: (Character) -> Bool) -> Joined {
        var out = Joined(text: "", words: [])
        for (i, line) in lines.enumerated() {
            if i > 0, let last = out.text.last, let first = line.first, !(isCJK(last) || isCJK(first)) {
                if last == "-" {
                    if case let .word(isWord) = hyphens, let word = joinedWord(out.text, next: line, isWord: isWord) {
                        out.text = word.text
                        out.words.append(word.word)
                    }
                } else {
                    out.text += " "
                }
            }
            out.text += line
        }
        return out
    }

    public static func text(_ lines: [String], hyphens: Hyphens = .kept, isCJK: (Character) -> Bool) -> String {
        join(lines, hyphens: hyphens, isCJK: isCJK).text
    }

    /// The marks of a clause that may follow the first word of a line without a space ("transduc-" "tion," / "tion)." / "tion:"). A word
    /// that goes on in `-` is a compound ("to-German"); one that goes on in a letter, a digit, `_ / @` or a dot and a letter ("ing.swift")
    /// is a name or code.
    private static let clauseMarks: Set<Character> = [",", ".", ";", ":", ")", "]", "!", "?", "\"", "”", "’"]

    /// `text` ends in the hyphen; `next` is the line after. The text with the hyphen taken out (`next` goes on from there) and the word
    /// it makes, or nil when the pieces are not one word. The pieces are one word when
    /// - the stem is a run of two or more letters that starts at a space, a bracket or the start of the text (not a name that goes on to
    ///   the left: `state-of-the-` "art", `pre_` / `no.` are not stems) and is not camelCase,
    /// - the first word of `next` is a run of two or more lowercase letters that ends there (a space, or only `clauseMarks` up to one,
    ///   after a possessive "'s" if there is one), and
    /// - `isWord` says the stem and the run make a word.
    /// The last is the table of the rule: a dictionary is what tells "con-text" from "sequence-aligned".
    static func joinedWord(_ text: String, next: String, isWord: (String) -> Bool) -> (text: String, word: String)? {
        var body = text
        body.removeLast()
        let stem = String(body.reversed().prefix { $0.isLetter && $0.isASCII }.reversed())
        guard stem.count >= 2, stem.dropFirst().allSatisfy(\.isLowercase) else { return nil }
        let before = body.dropLast(stem.count).last
        guard before == nil || before == " " || openers.contains(before!) else { return nil }
        let rest = String(next.prefix { $0.isLetter && $0.isASCII })
        guard rest.count >= 2, rest.allSatisfy(\.isLowercase) else { return nil }
        var tail = next.dropFirst(rest.count).prefix { $0 != " " }
        if let quote = tail.first, "'’".contains(quote), tail.dropFirst().first == "s" { tail = tail.dropFirst(2) }   // "plat-" "form's"
        guard tail.allSatisfy(clauseMarks.contains) else { return nil }
        guard isWord(stem + rest) else { return nil }
        return (body, stem + rest)
    }

    private static let openers: Set<Character> = ["(", "[", "{", "\"", "“", "‘"]
}
