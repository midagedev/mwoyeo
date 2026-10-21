import Foundation

// The names and terms written into the source before translation: the replace mode (design §10), every kind's, Apple Translation's first.
//
// Apple Translation takes no glossary, no context and no instruction. The measured way to give it a word is to put the final
// word into the source ("The 협력 event starts at 9") and let the engine write the sentence around it: it picks the particle
// for the word that really stands there, and nothing is cut out of its answer or refitted afterwards
// (`docs/research/apple-glossary-preinsert.md`, 2026-10-18, en>ko/ja/zh: the target stood in the answer for 88 of 88 terms with
// the language pack and 98 of 102 with Apple Intelligence). Attributes on the word do not help (a marker leaves the answer as it
// was; `skipsTranslation` makes Apple Intelligence drop the particle), so there are none.
//
// This file holds the source side only: what to hand to the engine. Reading the answer (does it hold every target, ask again
// for a line that does not) stays with the caller. Which rows go is not decided here (`ContextMemory.replaceRows(chain:)`): with no
// replace row the source is untouched, which is the zero-setup default.

/// A source line prepared for Apple Translation: `source` with every pinned term replaced by its target.
public struct ApplePreinsertion: Equatable, Sendable {
    /// One place where a target was put in.
    public struct Span: Equatable, Sendable {
        /// What stood in the source there ("tokens" for the term "token").
        public let matched: String
        public let target: String
        /// Where `target` stands in `text`, in UTF-16 units (an `NSRange` over `text`).
        public let range: Range<Int>
    }

    public let source: String
    /// What to translate: `source` with every term replaced by its target; `source` itself when nothing was replaced.
    public let text: String
    /// The places, in the order they stand in `text`.
    public let spans: [Span]

    public var isEmpty: Bool { spans.isEmpty }
    /// The targets put in, in the order they stand in `text`.
    public var targets: [String] { spans.map(\.target) }

    /// Writes the replace rows (`ContextMemory.replaceRows(chain:)`) into `source`.
    ///
    /// Only the entries the user wrote or pinned (`origin == .user`) count; a learned entry is a hint and never goes into a source
    /// text. No entry, no change.
    ///
    /// A term in Latin letters matches whole words and their plural ("tokens", "boxes"), and one that starts in lowercase
    /// also with a capital, as at the start of a sentence. A term in any other script matches wherever it stands. The
    /// longest term wins where two overlap, and the first entry where two are as long. An entry whose term is its target,
    /// or is empty, is ignored. A plural in the source is replaced together with its term, so the plural is not carried over.
    public static func insert(into source: String, entries: [MemoryEntry]) -> ApplePreinsertion {
        let pairs = entries.filter { $0.origin == .user }.map { ($0.src, $0.dst) }
        return insert(into: source, pairs: pairs)
    }

    static func insert(into source: String, pairs: [(String, String)]) -> ApplePreinsertion {
        let chars = Array(source)
        var taken = [Bool](repeating: false, count: chars.count)
        var found: [(range: Range<Int>, target: String)] = []
        let ordered = pairs.enumerated().sorted { a, b in
            a.element.0.count != b.element.0.count ? a.element.0.count > b.element.0.count : a.offset < b.offset
        }
        for (_, pair) in ordered where pair.0 != pair.1 && !pair.0.isEmpty {
            let (term, target) = pair
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
                        let tail = String(chars[end...].prefix(while: { isWordChar($0) }))
                        guard ["s", "es"].contains(tail) else { continue }
                        end += tail.count
                    }
                    guard !taken[i..<end].contains(true) else { continue }
                    for k in i..<end { taken[k] = true }
                    found.append((i..<end, target))
                    i = end
                    continue scan
                }
                i += 1
            }
        }
        found.sort { $0.range.lowerBound < $1.range.lowerBound }
        var text = ""
        var length = 0
        var spans: [Span] = []
        var pos = 0
        for f in found {
            let before = String(chars[pos..<f.range.lowerBound])
            text += before
            length += before.utf16.count
            text += f.target
            spans.append(Span(matched: String(chars[f.range]), target: f.target, range: length..<length + f.target.utf16.count))
            length += f.target.utf16.count
            pos = f.range.upperBound
        }
        text += String(chars[pos...])
        return ApplePreinsertion(source: source, text: text, spans: spans)
    }

    /// A letter or digit of a script that puts spaces between words (not Han, kana or hangul).
    private static func isWordLetter(_ c: Character) -> Bool {
        (c.isLetter || c.isNumber) && !(c.unicodeScalars.first.map(TranslationFilter.isCJK) ?? false)
    }

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
}
