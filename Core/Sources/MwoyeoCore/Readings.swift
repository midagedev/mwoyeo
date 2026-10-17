import CoreFoundation
import Foundation

/// Reading aids for learner mode: furigana and romaji for Japanese, pinyin for Chinese,
/// romanization for Korean. Everything runs on the system tokenizer and ICU transforms,
/// so readings of names and rare kanji can be wrong.
public enum Readings {
    public struct RubySegment: Equatable, Sendable {
        public var base: String
        /// nil when the base needs no reading (kana, Latin, punctuation, digits).
        public var reading: String?

        public init(base: String, reading: String? = nil) {
            self.base = base
            self.reading = reading
        }
    }

    // MARK: Japanese

    /// Hiragana readings over kanji. Concatenating the bases gives the input back exactly.
    /// Okurigana is split off as its own segment: 食べる becomes [食|た] [べる].
    public static func furigana(_ japanese: String) -> [RubySegment] {
        var out: [RubySegment] = []
        var cursor = japanese.startIndex
        for token in tokens(japanese, locale: "ja") {
            if token.range.lowerBound > cursor {
                out.append(RubySegment(base: String(japanese[cursor..<token.range.lowerBound])))
            }
            let base = String(japanese[token.range])
            cursor = token.range.upperBound
            guard base.unicodeScalars.contains(where: isKanji), let latin = token.latin,
                  let reading = transformed(latin, kCFStringTransformLatinHiragana), !reading.isEmpty
            else {
                out.append(RubySegment(base: base))
                continue
            }
            out.append(contentsOf: trimOkurigana(base: base, reading: reading))
        }
        if cursor < japanese.endIndex { out.append(RubySegment(base: String(japanese[cursor...]))) }
        return merged(out)
    }

    /// Lowercase romaji, one space between tokens.
    public static func romaji(_ japanese: String) -> String {
        tokens(japanese, locale: "ja").compactMap { $0.latin?.lowercased() }.joined(separator: " ")
    }

    // MARK: Chinese

    /// Pinyin with tone marks, one segment per Han character when the syllable count matches the
    /// token, otherwise one segment for the whole token with space-separated syllables.
    public static func pinyin(_ chinese: String) -> [RubySegment] {
        var out: [RubySegment] = []
        var cursor = chinese.startIndex
        for token in tokens(chinese, locale: "zh") {
            if token.range.lowerBound > cursor {
                out.append(RubySegment(base: String(chinese[cursor..<token.range.lowerBound])))
            }
            cursor = token.range.upperBound
            let base = String(chinese[token.range])
            guard base.unicodeScalars.contains(where: isKanji),
                  let latin = transformed(base, kCFStringTransformMandarinLatin)
            else {
                out.append(RubySegment(base: base))
                continue
            }
            let syllables = latin.split(separator: " ").map(String.init)
            let chars = Array(base)
            let hanCount = chars.filter { $0.unicodeScalars.contains(where: isKanji) }.count
            guard syllables.count == hanCount else {
                out.append(RubySegment(base: base, reading: syllables.joined(separator: " ")))
                continue
            }
            var next = syllables.makeIterator()
            var plain = ""
            for c in chars {
                if c.unicodeScalars.contains(where: isKanji) {
                    if !plain.isEmpty { out.append(RubySegment(base: plain)); plain = "" }
                    out.append(RubySegment(base: String(c), reading: next.next()))
                } else {
                    plain.append(c)
                }
            }
            if !plain.isEmpty { out.append(RubySegment(base: plain)) }
        }
        if cursor < chinese.endIndex { out.append(RubySegment(base: String(chinese[cursor...]))) }
        return out
    }

    // MARK: Korean

    /// ICU `Hangul-Latin`. This is a mechanical jamo transliteration, not Revised Romanization:
    /// it does not apply sound changes between syllables (see the fixture notes in the tests).
    public static func romanizedKorean(_ korean: String) -> String {
        korean.applyingTransform(StringTransform("Hangul-Latin"), reverse: false) ?? korean
    }

    // MARK: Internals

    private struct Token {
        var range: Range<String.Index>
        var latin: String?
    }

    private static func tokens(_ text: String, locale: String) -> [Token] {
        guard !text.isEmpty else { return [] }
        let cf = text as CFString
        let length = CFStringGetLength(cf)
        let tokenizer = CFStringTokenizerCreate(
            nil, cf, CFRangeMake(0, length),
            CFOptionFlags(kCFStringTokenizerUnitWordBoundary), Locale(identifier: locale) as CFLocale)
        var out: [Token] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard let range = Range(NSRange(location: r.location, length: r.length), in: text) else { continue }
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, CFOptionFlags(kCFStringTokenizerAttributeLatinTranscription)) as? String
            out.append(Token(range: range, latin: latin))
        }
        return out
    }

    private static func transformed(_ s: String, _ transform: CFString) -> String? {
        let m = NSMutableString(string: s)
        guard CFStringTransform(m, nil, transform, false) else { return nil }
        return m as String
    }

    private static func isKanji(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x3005, 0x3007, 0x3006: true
        default: false
        }
    }

    private static func isKana(_ s: Unicode.Scalar) -> Bool {
        (0x3041...0x309F).contains(s.value) || (0x30A0...0x30FF).contains(s.value)
    }

    /// Katakana folded to hiragana so okurigana compares equal to the reading.
    private static func hira(_ c: Character) -> Character {
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1,
              (0x30A1...0x30F6).contains(s.value), let h = Unicode.Scalar(s.value - 0x60) else { return c }
        return Character(h)
    }

    /// Splits `base` into kanji and kana runs and aligns each kana run with the reading, so only
    /// the kanji runs carry a reading. Falls back to one segment for the whole token.
    private static func trimOkurigana(base: String, reading: String) -> [RubySegment] {
        var runs: [(text: [Character], kanji: Bool)] = []
        for c in base {
            let k = c.unicodeScalars.contains(where: isKanji)
            if k == runs.last?.kanji { runs[runs.count - 1].text.append(c) } else { runs.append(([c], k)) }
        }
        guard runs.contains(where: { !$0.kanji }) else { return [RubySegment(base: base, reading: reading)] }
        let rd = Array(reading)
        var pos = 0
        var out: [RubySegment] = []
        for (i, run) in runs.enumerated() {
            if run.kanji {
                // This kanji run takes the reading up to where the next kana run starts.
                let end: Int
                if i + 1 < runs.count {
                    let next = run.kanji ? runs[i + 1].text.map(hira) : []
                    let isLast = i + 2 >= runs.count
                    if isLast {
                        guard rd.count - next.count > pos, Array(rd.suffix(next.count)) == next else { return [RubySegment(base: base, reading: reading)] }
                        end = rd.count - next.count
                    } else {
                        guard let at = find(next, in: rd, from: pos + 1) else { return [RubySegment(base: base, reading: reading)] }
                        end = at
                    }
                } else {
                    end = rd.count
                }
                guard end > pos else { return [RubySegment(base: base, reading: reading)] }
                out.append(RubySegment(base: String(run.text), reading: String(rd[pos..<end])))
                pos = end
            } else {
                let t = run.text.map(hira)
                guard pos + t.count <= rd.count, Array(rd[pos..<(pos + t.count)]) == t else {
                    return [RubySegment(base: base, reading: reading)]
                }
                out.append(RubySegment(base: String(run.text)))
                pos += t.count
            }
        }
        return pos == rd.count ? out : [RubySegment(base: base, reading: reading)]
    }

    private static func find(_ needle: [Character], in hay: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        var i = from
        while i + needle.count <= hay.count {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    /// Adjacent reading-less segments become one, so [べ][る] reads as [べる].
    private static func merged(_ segments: [RubySegment]) -> [RubySegment] {
        var out: [RubySegment] = []
        for s in segments {
            if s.reading == nil, let last = out.last, last.reading == nil {
                out[out.count - 1].base += s.base
            } else {
                out.append(s)
            }
        }
        return out
    }
}
