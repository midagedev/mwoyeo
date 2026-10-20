import Foundation

/// Formulas inside a sentence of prose ("divide each by √dk", "h = 8", "W^O ∈ R^{hdv×dmodel}", "LayerNorm(x + Sublayer(x))"),
/// found from the signs they are written with, for `ProtectedSpans`. Deliberately narrow: a bare "dk" with no sign beside it is
/// not found, and a span is never cut in half; a missed formula costs what it cost before, a wrong cut costs the sentence.
public enum InlineMath {
    public static func spans(in text: String) -> [(range: Range<Int>, kind: ProtectedSpans.Kind)] {
        let chars = Array(text)
        let tokens = tokenize(chars)
        var found: [(range: Range<Int>, kind: ProtectedSpans.Kind)] = []
        var i = 0
        while i < tokens.count {
            guard tokens[i].kind.isTerm else { i += 1; continue }
            var j = i
            var math = tokens[i].kind == .formula
            while j + 2 < tokens.count, case .op(let strong) = tokens[j + 1].kind, tokens[j + 2].kind.isTerm {
                math = math || strong || tokens[j + 2].kind == .formula
                j += 2
            }
            if math, j > i || tokens[i].kind == .formula {
                found.append((tokens[i].range.lowerBound..<tokens[j].range.upperBound, .math(id: found.count)))
                i = j + 1
            } else {
                i += 1
            }
        }
        return found
    }

    private struct Token {
        enum Kind: Equatable {
            case formula, operand, prose
            /// `strong`: an operator that means mathematics where a dash or a slash may only be punctuation.
            case op(strong: Bool)
            var isTerm: Bool { self == .formula || self == .operand }
        }
        var range: Range<Int>
        var kind: Kind
    }

    /// Whitespace separates tokens except inside matched brackets ("LayerNorm(x + Sublayer(x))" is one). Japanese has no spaces, so the
    /// edge between CJK text and anything else separates them too: an identifier glued to a sentence is its own token ("TOKEN_ATに作った…").
    private static func tokenize(_ chars: [Character]) -> [Token] {
        var match = [Int: Int]()
        var stack: [Int] = []
        for (i, c) in chars.enumerated() {
            if "([{".contains(c) { stack.append(i) }
            else if ")]}".contains(c), let open = stack.popLast() { match[open] = i }
        }
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            var end = i
            var closeAt = -1
            while end < chars.count {
                if let close = match[end], close > closeAt { closeAt = close }
                if chars[end].isWhitespace || isCJKText(chars[end]) != isCJKText(chars[i]), end > closeAt { break }
                end += 1
            }
            var trimmed = end
            while trimmed > i + 1, ".,;:!?".contains(chars[trimmed - 1]) { trimmed -= 1 }
            tokens.append(Token(range: i..<trimmed, kind: classify(Array(chars[i..<trimmed]))))
            i = end
        }
        return tokens
    }

    /// Kana, han, hangul and the punctuation block of CJK text: what a sentence in Japanese, Chinese or Korean is written in.
    private static func isCJKText(_ c: Character) -> Bool {
        c.unicodeScalars.contains { TranslationFilter.isCJK($0) || (0x3000...0x303F).contains($0.value) }
    }

    private static let strongOperators = Set("=<>+±×÷·⋅∘∈∉⊂⊆⊃⊇∪∩≈≠≤≥→←⇒⇔∝∼~")
    private static let weakOperators = Set("-−–/*")
    /// A token holding one of these is a formula ("W_i^Q", "√dk", "x=1", "q·k"); "+", "<" and "~" are in prose too ("C++", "<3").
    private static let signs = Set("^_√∑∏∫∂∇∞∀∃=±×÷·⋅∘∈∉⊂⊆⊃⊇∪∩≈≠≤≥→←⇒⇔∝")

    private static func classify(_ t: [Character]) -> Token.Kind {
        if t.allSatisfy({ strongOperators.contains($0) }) { return .op(strong: true) }
        if t.allSatisfy({ strongOperators.contains($0) || weakOperators.contains($0) }) { return .op(strong: false) }
        let s = String(t)
        if s.contains("://") || s.contains("@") || t.contains(where: isCJKText) { return .prose }
        // A bracket that opens the token and holds a word is a remark ("(where x = 1)"), not a formula.
        if let first = t.first, "([{".contains(first), t.count > 2, t.contains(where: \.isWhitespace),
           tokenize(Array(t.dropFirst().dropLast())).contains(where: { $0.kind == .prose }) { return .prose }
        if t.contains(where: { signs.contains($0) || isGreek($0) || isScript($0) }) { return .formula }
        if isCall(t) { return .formula }
        return isOperand(t) ? .operand : .prose
    }

    private static func isGreek(_ c: Character) -> Bool { c.unicodeScalars.first.map { (0x370...0x3FF).contains($0.value) } ?? false }
    /// Super and subscript digits and letters, arrows and the mathematical operators block.
    private static func isScript(_ c: Character) -> Bool {
        c.unicodeScalars.first.map { (0x2070...0x209F).contains($0.value) || (0x2200...0x22FF).contains($0.value) || ["²", "³", "¹"].contains(c) } ?? false
    }

    /// `Name(…)` closed at the end, holding nothing but variables: one letter per run, apart from the names of inner calls.
    private static func isCall(_ t: [Character]) -> Bool {
        guard let open = t.firstIndex(of: "("), open > 0, t.last == ")", t[0].isLetter, t[..<open].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        let name = String(t[..<open])
        if ["s", "es"].contains(String(t[(open + 1)...].dropLast())) { return false } // "token(s)"
        guard !name.isEmpty else { return false }
        var widest = 0, run = 0
        var k = open + 1
        while k < t.count - 1 {
            if t[k].isLetter || t[k].isNumber || t[k] == "_" {
                var e = k
                while e < t.count, t[e].isLetter || t[e].isNumber || t[e] == "_" { e += 1 }
                if e < t.count, t[e] == "(" { k = e + 1; continue } // an inner call's name
                run = e - k
                widest = max(widest, run)
                k = e
            } else {
                k += 1
            }
        }
        return widest <= 1
    }

    /// A number, a single letter, or letters with no vowel ("k", "x1", "dk", "QKT", "8", "0.9").
    private static func isOperand(_ t: [Character]) -> Bool {
        if t.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }), t.contains(where: \.isNumber) { return true }
        let letters = t.filter(\.isLetter)
        guard letters.count >= 1, letters.count <= 3, t.allSatisfy({ $0.isLetter || $0.isNumber }) else { return false }
        return letters.count == 1 || !letters.contains { "aeiouyAEIOUY".contains($0) }
    }
}
