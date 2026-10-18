import Foundation

// The size and text helpers every context budget shares (design docs/design/context-translation.md §2).

/// A token count without a tokenizer: a CJK character is 1 token, any other character 1 / 3.5 token, rounded up.
///
/// Latin text runs "three to four characters per token" (Apple TN3193), and 3.5 is the middle. CJK is about one token per
/// character on the providers we measured. The number is for budgets only (card, sheet rows, notes, context lines): it is
/// never billed or compared with a provider's `usage`. Every budget in `TranslationContext*.swift` goes through this one
/// function, so changing the ratio changes them together.
public func approxTokens(_ text: String) -> Int {
    var cjk = 0, other = 0
    for scalar in text.unicodeScalars {
        if ContextText.isCJK(scalar) { cjk += 1 } else { other += 1 }
    }
    return Int((Double(cjk) + Double(other) / 3.5).rounded(.up))
}

/// Small pure text helpers for the context engine.
public enum ContextText {
    /// Han, kana, Hangul, bopomofo, CJK punctuation and the full-width forms.
    public static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x1100...0x11FF, 0x2E80...0x312F, 0x3130...0x318F, 0x31A0...0x4DBF, 0x4E00...0x9FFF,
             0xA960...0xA97F, 0xAC00...0xD7FF, 0xF900...0xFAFF, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
            true
        default:
            false
        }
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.first.map(isCJK) ?? false
    }

    /// Whitespace runs (and newlines) become one space; the ends are trimmed; zero-width and bidi controls are dropped.
    public static func collapse(_ s: String) -> String {
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { !isInvisible($0) }))
        return cleaned.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    private static func isInvisible(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x2069, 0xFEFF, 0x0000...0x0008, 0x000E...0x001F, 0x007F:
            true
        default:
            false
        }
    }

    /// The text cut to at most `maxTokens` (by `approxTokens`), with "…" when something was cut. Cuts on a character.
    public static func truncated(_ s: String, toTokens maxTokens: Int) -> String {
        guard maxTokens > 0 else { return "" }
        if approxTokens(s) <= maxTokens { return s }
        var out = ""
        var cjk = 0.0, other = 0.0
        // One token is kept for the ellipsis.
        let budget = Double(maxTokens - 1)
        for ch in s {
            var c = cjk, o = other
            for scalar in ch.unicodeScalars { if isCJK(scalar) { c += 1 } else { o += 1 } }
            if c + o / 3.5 > budget { break }
            cjk = c; other = o
            out.append(ch)
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "…"
    }

    /// The text cut to at most `maxCharacters` Characters, with "…" when something was cut.
    public static func truncated(_ s: String, toCharacters maxCharacters: Int) -> String {
        guard s.count > maxCharacters else { return s }
        return String(s.prefix(max(0, maxCharacters - 1))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The key two names are compared by: case, accents and width are ignored, ends trimmed.
    public static func foldedKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// True when `needle` occurs in `haystack`, ignoring case, accents and width.
    ///
    /// A needle that starts or ends with an ASCII letter or digit must not touch another ASCII letter or digit there:
    /// "Al" is not in "Also", but "Alice" is in "Alice가" (Korean and Japanese attach particles, so only ASCII
    /// neighbours count as part of the word).
    public static func occurs(_ needle: String, in haystack: String) -> Bool {
        let n = foldedKey(needle)
        guard !n.isEmpty else { return false }
        let h = haystack.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let guardStart = n.first.map(isASCIIWordChar) ?? false
        let guardEnd = n.last.map(isASCIIWordChar) ?? false
        var from = h.startIndex
        while let r = h.range(of: n, range: from..<h.endIndex) {
            let okStart = !guardStart || r.lowerBound == h.startIndex || !isASCIIWordChar(h[h.index(before: r.lowerBound)])
            let okEnd = !guardEnd || r.upperBound == h.endIndex || !isASCIIWordChar(h[r.upperBound])
            if okStart && okEnd { return true }
            from = h.index(after: r.lowerBound)
        }
        return false
    }

    private static func isASCIIWordChar(_ c: Character) -> Bool {
        c.isASCII && (c.isLetter || c.isNumber)
    }

    /// FNV-1a, 64 bit, as 16 hex digits. Stable across runs and machines (unlike `hashValue`).
    public static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let hex = String(h, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
