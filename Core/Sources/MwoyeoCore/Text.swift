import CoreGraphics
import CoreText
import Foundation

public enum TextSimilarity {
    /// Levenshtein distance over Characters (grapheme clusters, so Hangul/emoji count as one).
    public static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// 1 = identical, 0 = nothing in common.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let n = max(a.count, b.count)
        return n == 0 ? 1 : 1 - Double(editDistance(a, b)) / Double(n)
    }

    public static func iou(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let inter = i.width * i.height
        return Double(inter / (a.width * a.height + b.width * b.height - inter))
    }
}

/// Matches text boxes between two OCR passes so the same on-screen line keeps its identity
/// (its translation and overlay layer) despite OCR jitter in box position and text.
public enum BlockMatcher {
    public struct Item: Sendable {
        public var rect: CGRect
        public var text: String
        public init(rect: CGRect, text: String) { self.rect = rect; self.text = text }
    }

    /// For each element of `new`, the index of its partner in `old`, or nil. Greedy on a combined score,
    /// each old item used at most once. A pair qualifies when boxes overlap well, or overlap somewhat
    /// and the texts are close.
    public static func match(old: [Item], new: [Item]) -> [Int?] {
        var candidates: [(score: Double, n: Int, o: Int)] = []
        for (ni, n) in new.enumerated() {
            for (oi, o) in old.enumerated() {
                let iou = TextSimilarity.iou(n.rect, o.rect)
                guard iou > 0.2 else { continue }
                let sim = TextSimilarity.similarity(n.text, o.text)
                guard iou >= 0.6 || sim >= 0.6 else { continue }
                candidates.append((iou + sim, ni, oi))
            }
        }
        candidates.sort { $0.score > $1.score }
        var result = [Int?](repeating: nil, count: new.count)
        var usedOld = Set<Int>()
        for c in candidates where result[c.n] == nil && !usedOld.contains(c.o) {
            result[c.n] = c.o
            usedOld.insert(c.o)
        }
        return result
    }
}

/// Least-recently-used cache. Not thread-safe; own it from one actor.
public final class LRUCache<Key: Hashable, Value> {
    private final class Node {
        let key: Key
        var value: Value
        var prev: Node?
        var next: Node?
        init(key: Key, value: Value) { self.key = key; self.value = value }
    }

    /// Lowering it drops the least recently used entries.
    public var capacity: Int {
        didSet {
            precondition(capacity > 0)
            while map.count > capacity, let lru = tail { unlink(lru); map[lru.key] = nil }
        }
    }
    private var map: [Key: Node] = [:]
    private var head: Node? // most recent
    private var tail: Node? // least recent

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    public var count: Int { map.count }

    public subscript(key: Key) -> Value? {
        get {
            guard let node = map[key] else { return nil }
            moveToFront(node)
            return node.value
        }
        set {
            if let value = newValue { insert(key, value) } else { remove(key) }
        }
    }

    public func removeAll() {
        map.removeAll()
        head = nil
        tail = nil
    }

    private func insert(_ key: Key, _ value: Value) {
        if let node = map[key] {
            node.value = value
            moveToFront(node)
            return
        }
        let node = Node(key: key, value: value)
        map[key] = node
        pushFront(node)
        if map.count > capacity, let lru = tail {
            unlink(lru)
            map[lru.key] = nil
        }
    }

    private func remove(_ key: Key) {
        guard let node = map.removeValue(forKey: key) else { return }
        unlink(node)
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        pushFront(node)
    }

    private func pushFront(_ node: Node) {
        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }
}

public enum TextFitter {
    /// Largest font size in [minSize, maxSize] (0.5pt resolution) whose laid-out text fits `box`.
    /// Returns minSize when nothing fits — the caller decides whether to overflow or shrink the box.
    public static func fitFontSize(in box: CGSize, minSize: CGFloat, maxSize: CGFloat, measure: (CGFloat) -> CGSize) -> CGFloat {
        guard maxSize > minSize else { return minSize }
        func fits(_ s: CGFloat) -> Bool {
            let m = measure(s)
            return m.width <= box.width + 0.5 && m.height <= box.height + 0.5
        }
        if fits(maxSize) { return maxSize }
        var lo = minSize, hi = maxSize
        while hi - lo > 0.5 {
            let mid = (lo + hi) / 2
            if fits(mid) { lo = mid } else { hi = mid }
        }
        return lo
    }

    /// `text` cut to what fits, ending in "…": the longest start of it, at a word where there is one, whose cut `fits`
    /// ("…" included). `text` itself when it fits, and when not even one character and "…" do (the room is less than a line:
    /// cutting characters gains nothing). A translation that does not fit its room at the smallest size would otherwise be cut
    /// through a line at the edge of its patch.
    public static func truncating(_ text: String, fits: (String) -> Bool) -> String {
        if fits(text) || !fits("…") { return text }
        let chars = Array(text)
        var lo = 0, hi = chars.count - 1   // the most characters kept that still fit, between lo (always fits) and hi
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if fits(String(chars[..<mid]) + "…") { lo = mid } else { hi = mid - 1 }
        }
        guard lo > 0 else { return text }
        var kept = Array(chars[..<lo])
        // Back to the end of a word, unless that gives up more than a third of what fits (a long unbroken run).
        if let space = kept.lastIndex(where: { $0 == " " }), space * 3 >= kept.count * 2 { kept = Array(kept[..<space]) }
        while let last = kept.last, last.isWhitespace || ",.;:·-–—".contains(last) { kept.removeLast() }
        return String(kept) + "…"
    }

    /// CoreText breaks Hangul between any two syllables (it treats them like ideographs) and ignores
    /// `lineBreakStrategy`, so "노스필드" can wrap as "노스필/드". A word joiner between two syllables of one word
    /// forbids the break there; a word longer than the line still breaks, as CoreText falls back to any position.
    public static func keepingWordsTogether(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var prevHangul = false
        for u in text.unicodeScalars {
            let hangul = (0xAC00...0xD7A3).contains(u.value)
            if hangul, prevHangul { out.append("\u{2060}") }
            out.append(u)
            prevHangul = hangul
        }
        return String(out)
    }

    /// Size CoreText needs to lay out `string` wrapped at `width`.
    public static func measure(_ string: NSAttributedString, width: CGFloat) -> CGSize {
        let setter = CTFramesetterCreateWithAttributedString(string)
        return CTFramesetterSuggestFrameSizeWithConstraints(
            setter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    }
}

public enum TranslationCleanup {
    /// Lone leading consonants (U+1100…) that are not followed by a vowel, as in "ᄏᄏ" for "lol", are meant to
    /// be the compatibility letters ("ㅋㅋ"); fonts often draw the former as broken half-syllables.
    public static func standaloneJamo(_ s: String) -> String {
        let compat: [UInt32] = [0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143, 0x3145,
                                0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D, 0x314E]
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, c) in scalars.enumerated() {
            let isVowelNext = i + 1 < scalars.count && (0x1161...0x1175).contains(scalars[i + 1].value)
            if (0x1100...0x1112).contains(c.value), !isVowelNext, let m = Unicode.Scalar(compat[Int(c.value - 0x1100)]) {
                out.append(m)
            } else {
                out.append(c)
            }
        }
        return String(out)
    }

    /// Translators capitalise the first letter of a sentence, which turns "s/starfallvalley" into
    /// "S/starfallvalley". Latin tokens copied from the source get their original spelling back.
    public static func restoreSourceTokens(_ translated: String, source: String) -> String {
        let tokens = source.matches(of: /[A-Za-z][A-Za-z0-9_\/.\-]*/).map { String($0.output) }
        guard !tokens.isEmpty else { return translated }
        var out = translated
        for token in Set(tokens) {
            var start = out.startIndex
            while let r = out.range(of: token, options: .caseInsensitive, range: start..<out.endIndex) {
                if out[r] != token { out.replaceSubrange(r, with: token) }
                start = out.index(r.lowerBound, offsetBy: token.count)
            }
        }
        return out
    }

    /// Models asked to translate a numbered list often echo the numbering ("3. 게임 종료"). Strip it,
    /// but only when the source line did not itself start with that number.
    public static func stripEchoedNumbering(_ translated: String, index: Int, source: String) -> String {
        let marker = "\(index)"
        let trimmedSource = source.trimmingCharacters(in: .whitespaces)
        guard !trimmedSource.hasPrefix(marker) else { return translated }
        let t = translated.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix(marker) else { return translated }
        var rest = t.dropFirst(marker.count)
        guard let sep = rest.first, ".)：:、".contains(sep) else { return translated }
        rest = rest.dropFirst()
        return rest.trimmingCharacters(in: .whitespaces)
    }
}

/// Decides which recognised lines are worth translating. Lines that are not in the source language at all —
/// handles, brand names, counters like "2.4k", icon glyphs read as digits — are left on screen untouched.
public enum TranslationFilter {
    /// `cjkSource`: the source (configured, or the page's dominant language) is Japanese, Chinese or Korean.
    public static func needsTranslation(_ text: String, cjkSource: Bool) -> Bool {
        if isLiteral(text) { return false }
        let scalars = text.unicodeScalars
        if cjkSource { return scalars.contains(where: isCJK) }
        guard scalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.contains("://") || t.hasPrefix("@") || t.range(of: #"^[a-z]{1,2}/\S+$"#, options: .regularExpression) != nil { return false }
        // One token mixing letters with digits or code punctuation ("2.4k", "user_42", "v1.4.2").
        if !t.contains(" "), t.range(of: #"[0-9_./]"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// Text that is read as written in any language and must stay on screen as it is: a shell prompt with its command
    /// ("$ npm run build"), a standalone time or date stamp ("10:42 AM", "2026-10-14"), a URL or bare domain, a
    /// fragment of a formula (`isFormula`), an identifier written in camelCase (`isIdentifier`) and prose that is mostly
    /// inline mathematics (`isMathHeavy`).
    public static func isLiteral(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return matchesLiteralPattern(t) || isFormula(t) || isIdentifier(t) || isMathHeavy(t)
    }

    static func matchesLiteralPattern(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return literalPatterns.contains { t.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private static let literalPatterns = [
        #"^[$%❯]\s+\S"#, // shell prompt + command ("$ ls", "% make"); "# general" is a channel, "» Read more" a link
        #"^[\w.-]*[@:~/][\w.@~:/-]*[$#%]\s+\S"#, // "user@host:~$ ls": a host or path before the sigil, so "C# is" and "50% off" are text
        #"^\d{1,2}:\d{2}(:\d{2})?\s*([ap]\.?m\.?)?$"#, // 10:42, 10:42 AM, 22:15:03
        #"^(오전|오후|午前|午後|上午|下午)\s*\d{1,2}:\d{2}$"#,
        #"^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}(\s+\d{1,2}:\d{2}(:\d{2})?\s*([ap]\.?m\.?)?)?$"#, // 2026-10-14 [10:42]
        #"^\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}(\s+\d{1,2}:\d{2}(:\d{2})?\s*([ap]\.?m\.?)?)?$"#, // 14/10/2026
        #"^(https?://|ftp://|www\.)\S+$"#,
        #"^[a-z0-9][a-z0-9-]*(\.[a-z0-9-]+)*\.(com|org|net|io|dev|app|ai|co|kr|jp|cn|uk|de|fr|edu|gov|me|tv|us)(/\S*)?$"#,
    ]

    /// A figure label or a formula the page typesets as symbols ("K", "QKT", "N×", "O(n² · d)",
    /// "Attention(Q, K,V) = softmax"): no sentence is in it, so the engine can only invent one ("K" came back as "1천")
    /// and the overlay would paint text over the typeset symbols. Decided from the letters, not from a list of
    /// examples. A body line that holds one formula ("i=1 9iki, has mean 0 and variance dk.") is not this: it has words.
    ///
    /// A formula has letters of Latin, Greek or Cyrillic only, and
    /// - one letter in all ("K", "-)V", "(a)", "O(1)"); or
    /// - no prose word and a sign of mathematics: a symbol, a Greek letter used as one, `_` in a name, a call `name(…)`, or
    ///   one run mixing Latin and Cyrillic (a sign misread by OCR); or
    /// - no prose word and every part of it a letter, a digit-letter run or a consonant-only run ("x1 x2", "QKT", "Nx"),
    ///   so that "ok", "OK", "Hi!", "Go to 3D", "Q&A" and "WTF" are text.
    /// A prose word is a run of three letters or more with a vowel ("has"), or a contraction, that is not an operand.
    /// Operands are the name of a call whose arguments are variables ("Sublayer(x)"), the name of any call when the line
    /// holds an `=`, and the words inside such a call or lowercase beside an `=` ("headi = Attention(Q)"): a word that
    /// is capital-first ("Mode = Fast") stays prose. One prose word is the label of a typeset line when the rest holds
    /// an `=` and twice its letters ("where headi = Attention(QWQ i, …)"); two, the first two words of the line, when the rest
    /// holds a call too and one and a half times their letters ("where head; = Attention (QW®, KW, VW!)": the space before
    /// the parenthesis and the arguments read as runs of letters are the OCR's).
    public static func isFormula(_ text: String) -> Bool {
        FormulaScan(text.trimmingCharacters(in: .whitespacesAndNewlines)).isFormula
    }

    /// A block of prose that is mostly inline mathematics ("Where the projections are parameter matrices WQ ∈ R dmodel × dk, WK ∈ …",
    /// read off a typeset page as "W° € Be xx, WK € Raux, WY € Eden xed and WO E RhdXdm"): the engine copies the symbols as they
    /// come (Apple Translation changed none in 26 sentences) and the garbling is the recognizer's, so a translation only
    /// sets garbled symbols between a few translated words, where the original has them typeset. It stays as written.
    /// Decided from the share of the block's letters and digits that are mathematics (`MathShare`): at least `mathShareLimit` of
    /// them, with two or more signs of mathematics in it. Measured on the paper bench (page 5): the garbled blocks stand at 0.38
    /// and 0.45, a sentence that opens with a formula ("dk = dv = dmodel/h = 64. Due to the reduced …") at 0.21 and below.
    public static func isMathHeavy(_ text: String) -> Bool {
        let m = MathShare(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return m.supported && m.signs >= mathSignLimit && m.characters >= 20 && m.share >= mathShareLimit
    }

    /// The share of a block's letters and digits that are mathematics, and its signs of mathematics.
    public static func mathShare(of text: String) -> (share: Double, signs: Int) {
        let m = MathShare(text.trimmingCharacters(in: .whitespacesAndNewlines))
        return (m.share, m.signs)
    }

    static let mathShareLimit = 0.30
    static let mathSignLimit = 2

    /// One identifier written in camelCase with an inner capital ("MatMul", "SoftMax", "ReLU", "LayerNorm"): a name from
    /// code or a figure, or a brand ("YouTube"). A single plain word ("Scale", "Linear") is not one, and neither is a
    /// brand run into Japanese ("YouTubeで見る").
    public static func isIdentifier(_ text: String) -> Bool {
        let core = text.trimmingCharacters(in: CharacterSet.letters.inverted)
        let scalars = Array(core.unicodeScalars)
        guard scalars.count >= 3, scalars.allSatisfy({ CharacterSet.letters.contains($0) && !isCJK($0) }) else { return false }
        return zip(scalars, scalars.dropFirst()).contains { CharacterSet.lowercaseLetters.contains($0) && CharacterSet.uppercaseLetters.contains($1) }
    }

    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9D, // kana, han, half-width kana
             0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: true                                 // hangul
        default: false
        }
    }
}

/// The letters, digits and signs of one line, as `TranslationFilter.isFormula` reads them. A run is a stretch of
/// letters, digits and `_` (an apostrophe between two letters stays in it); everything else is a sign.
private struct FormulaScan {
    fileprivate enum Script { case latin, greek, cyrillic, math }

    private var letters = 0
    private var proseWords = 0       // words that are not operands
    private var proseLetters = 0
    private var relation = false     // an `=` or a comparison somewhere in the line
    private var sign = false         // a sign of mathematics: symbol, Greek letter, `_`, a call, mixed Latin and Cyrillic
    private var digitLetter = false  // a run holding both ("x1", "9iki")
    private var capsCluster = false  // a consonant-only run with a capital ("QKT", "Nx")
    private var onlyAtoms = true     // no run of two or more letters with a vowel in it, apart from digits
    private var digit = false
    private var latin = false, greek = false, cyrillic = false
    private var bracket = false      // a slash, bar, bracket, comparison or arithmetic sign
    private var callSeen = false     // a name followed by its arguments in parentheses
    private var runs = 0             // runs of letters so far
    private var proseRuns: [Int] = []  // which runs (counted from 0) are prose words
    private var supported = true     // every letter is Latin, Greek or Cyrillic

    /// Consonant-only words that are chat, not symbols; a capital in them does not make them a formula.
    private static let consonantWords: Set<String> = ["wtf", "brb", "lmk", "tbh", "smh", "fml", "btw", "tbd", "nvm", "pls", "thx", "ppl",
                                                       "hmm", "hm", "mmm", "mm", "mhm", "kk", "shh", "brr", "grr", "psst"]
    fileprivate static let vowels = Set("aeiouyıøæœаеёиоуыэюяіїєαεηιουω")

    fileprivate static func script(_ v: UInt32) -> Script? {
        switch v {
        case 0xB5, 0x370...0x3FF, 0x1F00...0x1FFF: .greek  // µ is the micro sign, a Latin-1 letter that is a Greek mu
        case 0..<0x2B0, 0x1E00...0x1EFF: .latin
        case 0x400...0x52F: .cyrillic
        case 0x1D400...0x1D7FF: .math
        default: nil
        }
    }

    fileprivate static func isMathSign(_ v: UInt32) -> Bool {
        switch v {
        case 0x3D, 0x5E, 0xB1, 0xB2, 0xB3, 0xB9, 0xD7, 0xF7: true  // = ^ ± ² ³ ¹ × ÷
        case 0x2070...0x209F, 0x2190...0x21FF, 0x2200...0x22FF: true // super and subscripts, arrows, mathematical operators
        default: false
        }
    }

    private static func isRelation(_ v: UInt32) -> Bool { [0x3D, 0x2208, 0x2248, 0x2260, 0x2261, 0x2264, 0x2265].contains(v) }
    private static let bracketSigns = Set("/\\|<>[]{}()+*~".unicodeScalars)

    init(_ text: String) {
        let s = Array(text.decomposedStringWithCanonicalMapping.unicodeScalars)
        relation = s.contains { Self.isRelation($0.value) }
        let isLetter = { (v: Unicode.Scalar) in CharacterSet.letters.contains(v) }
        let isMark = { (v: Unicode.Scalar) in (0x300...0x36F).contains(v.value) }
        let isDigit = { (v: Unicode.Scalar) in CharacterSet.decimalDigits.contains(v) }
        let isRunScalar = { (v: Unicode.Scalar) in v == "_" || isMark(v) || isDigit(v) || isLetter(v) }
        func neighbour(from i: Int, step: Int) -> Unicode.Scalar? {
            var k = i + step
            while s.indices.contains(k), CharacterSet.whitespacesAndNewlines.contains(s[k]) { k += step }
            return s.indices.contains(k) ? s[k] : nil
        }

        /// A call's arguments are plain variables: one letter at most in each run, at least one letter ("Sublayer(x)").
        func argumentsAreVariables(_ open: Int) -> Bool {
            var depth = 0, run = 0, widest = 0
            for k in open..<s.count where !isMark(s[k]) {
                if s[k] == "(" { depth += 1 } else if s[k] == ")" { depth -= 1; if depth == 0 { break } }
                run = isLetter(s[k]) ? run + 1 : 0
                widest = max(widest, run)
            }
            return widest == 1
        }

        /// A call's arguments hold no prose word: no run of three letters or more with a vowel in it ("x, y", "QWQ i, KWK i").
        func argumentsHoldNoProse(_ open: Int) -> Bool {
            var depth = 0, run = 0, vowel = false
            for k in open..<s.count where !isMark(s[k]) {
                if s[k] == "(" { depth += 1 } else if s[k] == ")" { depth -= 1; if depth == 0 { break } }
                if isLetter(s[k]) {
                    run += 1
                    vowel = vowel || (String(s[k]).lowercased().first.map { Self.vowels.contains($0) } ?? false)
                    if run >= 3, vowel { return false }
                } else {
                    run = 0
                    vowel = false
                }
            }
            return true
        }

        var openParens: [Bool] = []  // per open "(": is a call's name right before it, and are its words operands
        var callOpensAt = -1, callExempt = false
        var i = 0
        while i < s.count {
            let v = s[i]
            guard isRunScalar(v) else {
                if Self.bracketSigns.contains(v) { bracket = true }
                if v == "(" {
                    openParens.append(i == callOpensAt && callExempt)
                } else if v == ")" {
                    _ = openParens.popLast()
                } else if Self.isMathSign(v.value) {
                    sign = true
                }
                i += 1
                continue
            }
            var j = i + 1
            var contraction = false
            while j < s.count {
                if isRunScalar(s[j]) { j += 1 }
                else if s[j] == "'" || s[j] == "\u{2019}", j + 1 < s.count, isLetter(s[j - 1]), isLetter(s[j + 1]) { contraction = true; j += 1 }
                else { break }
            }

            var count = 0, digits = 0, underscore = false, vowel = false, capital = false, camel = false
            var scripts = Set<Script>()
            var previousLower = false
            let run = s[i..<j]
            for c in run where !isMark(c) {
                if isDigit(c) { digits += 1 }
                else if c == "_" { underscore = true }
                else if isLetter(c) {
                    guard let script = Self.script(c.value) else { supported = false; return }
                    scripts.insert(script)
                    count += 1
                    let lower = CharacterSet.lowercaseLetters.contains(c), upper = CharacterSet.uppercaseLetters.contains(c)
                    if let l = String(c).lowercased().first, Self.vowels.contains(l) { vowel = true }
                    if upper { capital = true; if previousLower { camel = true } }
                    previousLower = lower
                }
            }
            letters += count
            if digits > 0 { digit = true }
            if underscore { sign = true }
            i = j
            guard count > 0 else { continue }
            let runIndex = runs
            runs += 1

            let lettersOnly = digits == 0 && !underscore
            let plural = { () -> Bool in
                let tail = String(String.UnicodeScalarView(s[j...].prefix(4)))
                return tail.hasPrefix("(s)") || tail.hasPrefix("(es)")
            }
            // OCR may read a space before the parenthesis ("Attention (Q, K, V) = softmax"): on a line with a relation, a name
            // followed by arguments that hold no prose word in parentheses is still a call. The arguments of a typeset call
            // come back as runs of letters ("QWQ i", "KWK"): subscripts and superscripts read as letters beside the name.
            var open = j
            while relation, open < s.count, s[open] == " " { open += 1 }
            if open > j, !(open < s.count && s[open] == "(" && argumentsHoldNoProse(open)) { open = j }
            let call = open < s.count && s[open] == "(" && isLetter(s[run.startIndex]) && !plural()
            let word = lettersOnly && scripts.count == 1 && !scripts.contains(.math) && (contraction || (count >= 3 && vowel))
            if call {
                sign = true
                callSeen = true
                callOpensAt = open
                callExempt = relation || camel || !word || argumentsAreVariables(open)
            }
            if digits > 0 { digitLetter = true }
            if scripts.contains(.math) { sign = true }
            if scripts.contains(.greek) { greek = true; if count == 1 || scripts.count > 1 || !lettersOnly { sign = true } }
            if scripts.contains(.cyrillic) { cyrillic = true }
            if scripts.contains(.latin) { latin = true }
            if scripts.contains(.latin) && scripts.contains(.cyrillic) { sign = true }

            if word {
                let beside = [neighbour(from: run.startIndex, step: -1), neighbour(from: run.endIndex - 1, step: 1)]
                    .contains { $0.map { Self.isRelation($0.value) } ?? false }
                let lowerFirst = CharacterSet.lowercaseLetters.contains(s[run.startIndex])
                let operand = (call && callExempt) || openParens.contains(true) || (relation && lowerFirst && beside)
                if !operand { proseWords += 1; proseLetters += count; proseRuns.append(runIndex) }
            }
            if lettersOnly && count >= 2 && vowel == false && capital && !Self.consonantWords.contains(String(String.UnicodeScalarView(run.filter { !isMark($0) })).lowercased()) {
                capsCluster = true
            }
            if count >= 2 && lettersOnly && vowel { onlyAtoms = false }
        }
    }

    var isFormula: Bool {
        guard supported, letters > 0 else { return false }
        if letters == 1 { return true }
        // One or two words of prose among many symbols ("where headi = Attention(QWQ i, …)") are the label of a typeset line: one
        // when the rest holds an `=` and twice its letters; two, the first two words of the line, when the rest holds a call as
        // well and one and a half times its letters (the OCR drops the subscripts of the arguments: "QW®, KW, VW!").
        if proseWords > 2 { return false }
        if proseWords > 0 {
            let rest = letters - proseLetters
            let one = proseWords == 1 && relation && rest >= 2 * proseLetters
            let two = proseWords == 2 && relation && callSeen && proseRuns == [0, 1] && 2 * rest >= 3 * proseLetters
            if !(one || two) { return false }
        }
        if sign { return true }
        if onlyAtoms && (digitLetter || (capsCluster && !digit)) { return true }
        // A short Cyrillic fragment beside a slash or bracket: a "√dk" read as "/ак".
        return cyrillic && !latin && !greek && letters <= 3 && bracket
    }
}

/// What part of one block is mathematics, as `TranslationFilter.isMathHeavy` reads it. The block's letters and digits are
/// counted in two kinds, apart from the neutral ones that count in neither:
/// - prose: a word of three letters or more with a vowel and no inner capital ("projections"), not standing beside a sign;
/// - mathematics: a sign (`=`, `∈`, `×`, `^`, a super or subscript, and `€` for what the recognizer reads `∈` as), a variable of
///   one letter (not "a" and "I"), a run of consonants ("dk", "xx") or with an inner capital ("EdEn", "xEd"), a name with `_`, a
///   number beside a sign, any word beside a sign ("Raux" after `€`, "model" in "R model × dx"), and a mark the recognizer reads
///   for a superscript (`°`, `®`) right after such a variable ("W°").
/// Neutral are numbers, names of letters with digits or capitals alone ("K80", "LSTM", "2016"), two-letter words, punctuation,
/// arrows, and marks after a word ("Parmar®", "Jones†"). A `€` next to a number is a price. Latin, Greek and Cyrillic only: a
/// block with any other script is not read.
private struct MathShare {
    private var prose = 0, math = 0
    private(set) var signs = 0
    private(set) var supported = true

    var characters: Int { prose + math }
    var share: Double { characters > 0 ? Double(math) / Double(characters) : 0 }

    private enum Token {
        /// An operator, relation or the `€` read for `∈`: its neighbours are its operands.
        case sign
        /// A mark read for a superscript, and whether it touches the token before it.
        case mark(attached: Bool)
        case run(letters: Int, digits: Int, shape: Shape)
        case punctuation
    }

    private enum Shape { case lone, aOrI, underscore, digitsOnly, mixed, caps, twoLetters, consonants, capitalInside, plain }

    private static func isOperator(_ v: UInt32) -> Bool { FormulaScan.isMathSign(v) && !(0x2190...0x21FF).contains(v) }
    private static func isCurrency(_ v: UInt32) -> Bool { [0xA2, 0xA3, 0xA5, 0x20AC].contains(v) }
    private static func isMark(_ v: UInt32) -> Bool { [0xA9, 0xAE, 0xB0].contains(v) }

    init(_ text: String) {
        let s = Array(text.decomposedStringWithCanonicalMapping.unicodeScalars)
        let isLetter = { (v: Unicode.Scalar) in CharacterSet.letters.contains(v) }
        let isCombining = { (v: Unicode.Scalar) in (0x300...0x36F).contains(v.value) }
        let isDigit = { (v: Unicode.Scalar) in CharacterSet.decimalDigits.contains(v) }
        let isRunScalar = { (v: Unicode.Scalar) in v == "_" || isCombining(v) || isDigit(v) || isLetter(v) }
        let isSpace = { (v: Unicode.Scalar) in CharacterSet.whitespacesAndNewlines.contains(v) }
        /// The nearest scalar on either side of `i` that is not a space.
        func solid(_ i: Int, step: Int) -> Unicode.Scalar? {
            var k = i + step
            while s.indices.contains(k), isSpace(s[k]) { k += step }
            return s.indices.contains(k) ? s[k] : nil
        }

        var tokens: [Token] = []
        var i = 0
        while i < s.count {
            let v = s[i]
            if isSpace(v) { i += 1; continue }
            guard isRunScalar(v) else {
                if Self.isOperator(v.value) {
                    tokens.append(.sign)
                } else if Self.isCurrency(v.value) {
                    // A price: a number on either side, spaces aside.
                    let price = [solid(i, step: -1), solid(i, step: 1)].contains { $0.map(isDigit) ?? false }
                    tokens.append(price ? .punctuation : .sign)
                } else if Self.isMark(v.value) {
                    tokens.append(.mark(attached: i > 0 && !isSpace(s[i - 1])))
                } else {
                    tokens.append(.punctuation)
                }
                i += 1
                continue
            }
            var j = i + 1
            while j < s.count {
                if isRunScalar(s[j]) { j += 1 }
                else if s[j] == "'" || s[j] == "\u{2019}", j + 1 < s.count, isLetter(s[j - 1]), isLetter(s[j + 1]) { j += 1 }
                else { break }
            }
            var letters: [Unicode.Scalar] = [], digits = 0, underscore = false
            for c in s[i..<j] where !isCombining(c) {
                if isDigit(c) { digits += 1 } else if c == "_" { underscore = true } else if isLetter(c) { letters.append(c) }
            }
            i = j
            var scripts = Set<FormulaScan.Script>()
            for c in letters {
                guard let script = FormulaScan.script(c.value) else { supported = false; return }
                scripts.insert(script)
            }
            let lower = { (c: Unicode.Scalar) in CharacterSet.lowercaseLetters.contains(c) }
            let upper = { (c: Unicode.Scalar) in CharacterSet.uppercaseLetters.contains(c) }
            let vowel = letters.contains { c in String(c).lowercased().first.map { FormulaScan.vowels.contains($0) } ?? false }
            let inner = zip(letters, letters.dropFirst()).contains { lower($0) && upper($1) }
            let shape: Shape
            if letters.isEmpty { shape = digits > 0 ? .digitsOnly : .plain }
            else if underscore { shape = .underscore }
            else if digits > 0 { shape = .mixed }
            else if letters.count == 1 {
                // Words of one letter in Cyrillic ("и", "в") and the article "a" and the pronoun "I" are not variables.
                shape = scripts == [.cyrillic] || "aAI".unicodeScalars.contains(letters[0]) ? .aOrI : .lone
            }
            else if inner { shape = .capitalInside }
            else if letters.allSatisfy(upper) { shape = .caps }
            else if !vowel { shape = .consonants }
            else if letters.count == 2 { shape = .twoLetters }
            else { shape = .plain }
            tokens.append(.run(letters: letters.count, digits: digits, shape: shape))
        }

        // Neighbours are the tokens before and after, punctuation aside.
        let core = tokens.filter { if case .punctuation = $0 { return false } else { return true } }
        func isSign(_ k: Int) -> Bool { if case .sign = core[k] { return true } else { return false } }
        for (k, token) in core.enumerated() {
            switch token {
            case .punctuation: break
            case .sign:
                signs += 1
                math += 1
            case let .mark(attached):
                // "W°", "QW®": a superscript read as a mark after a variable; after a word ("Parmar®") it is a footnote mark.
                guard attached, k > 0, case let .run(_, _, shape) = core[k - 1], [.lone, .caps, .consonants, .capitalInside, .underscore, .mixed].contains(shape) else { break }
                signs += 1
                math += 1
            case let .run(letters, digits, shape):
                let beside = (k > 0 && isSign(k - 1)) || (k + 1 < core.count && isSign(k + 1))
                let size = letters + digits
                switch shape {
                case .digitsOnly, .aOrI, .mixed, .caps, .twoLetters: if beside { math += size }
                case .lone, .underscore, .consonants, .capitalInside: math += size
                case .plain: if beside { math += size } else { prose += size }
                }
            }
        }
    }
}

public enum LineAlignment {
    /// Lines whose centres line up while their left edges do not are centred (subtitles, captions, titles). One line
    /// cannot say, so an outlined line (the subtitle look) counts as centred and any other as left-aligned.
    public static func isCentered(_ lines: [(minX: CGFloat, maxX: CGFloat)], outlined: Bool) -> Bool {
        guard lines.count >= 2 else { return outlined && lines.count == 1 }
        let widest = lines.map { $0.maxX - $0.minX }.max() ?? 0
        let tol = max(4, widest * 0.04)
        let centres = lines.map { ($0.minX + $0.maxX) / 2 }, lefts = lines.map(\.minX)
        let centreSpread = (centres.max() ?? 0) - (centres.min() ?? 0)
        let leftSpread = (lefts.max() ?? 0) - (lefts.min() ?? 0)
        return centreSpread <= tol && leftSpread > 2 * tol
    }
}

/// Vertical text (tategaki, manga balloons) is not read yet: its columns are tall and narrow where lines of
/// horizontal text are wide and short. Decided from the boxes a text-rectangle detector reports.
public enum VerticalText {
    /// True when at least three boxes are at least 2.2 times taller than wide and they are at least 60 % of
    /// all boxes: a lone "I" or a narrow icon does not make a page vertical.
    public static func isVertical(_ boxes: [CGRect]) -> Bool {
        let usable = boxes.filter { $0.width > 4 && $0.height > 4 }
        let tall = usable.filter { $0.height >= 2.2 * $0.width }
        return tall.count >= 3 && Double(tall.count) >= 0.6 * Double(usable.count)
    }

    /// One line of text turned on its side among horizontal text (a word of a figure, an axis label, the stamp in a margin): its
    /// box is taller than wide by 1.4 times with three characters or more, by 1.7 times with two. A horizontal line is wider than
    /// it is tall (a word of three letters is as wide as it is tall at the least), and the recognizer's boxes of the rotated
    /// words of a figure measure 1.8 to 2.8 (the paper bench, page 15: "The" 21×45, "we" 19×37, "application" 23×123). Translated,
    /// such a word comes out as a column of syllables.
    public static func isRotatedLine(_ box: CGRect, characters: Int) -> Bool {
        guard box.width > 0, characters >= 2 else { return false }
        return box.height >= (characters >= 3 ? 1.4 : 1.7) * box.width
    }
}

/// Whether two neighbouring lines of one block are set in different sizes (a heading over body text). An OCR line
/// box follows the letters it holds — ascenders and descenders make the same font's boxes differ by 1.35 times
/// ("A new processor design … their" 50 px, "price, according …" 37 px, both 12.6 px per character) — so Latin
/// text is compared by the advance per character, which only the font size sets. Han, kana and hangul are
/// squares as wide as the font is tall, and their boxes are compared as they are.
public enum LineSize {
    public struct Line: Sendable {
        public var height: CGFloat
        public var width: CGFloat
        public var text: String

        public init(height: CGFloat, width: CGFloat, text: String) {
            self.height = height
            self.width = width
            self.text = text
        }

        var characters: Int { text.count }
        var isCJK: Bool { text.unicodeScalars.filter(TranslationFilter.isCJK).count * 2 >= max(1, characters) }
        var advance: CGFloat { width / CGFloat(max(1, characters)) }
    }

    public static func differ(_ a: Line, _ b: Line) -> Bool {
        let heights = max(a.height, b.height) / max(1, min(a.height, b.height))
        if a.isCJK != b.isCJK || (a.isCJK && b.isCJK) { return heights > 1.3 }
        guard min(a.characters, b.characters) >= 12 else { return heights > 1.5 }
        // Both measures must agree: a justified line's advance moves by 25 % on its own (1.26 on the magazine page).
        return max(a.advance, b.advance) / max(0.1, min(a.advance, b.advance)) > 1.25 && heights > 1.2
    }
}

/// A line that opens with a note or list marker starts its own paragraph even when the line before it is full:
/// footnotes "2 The authors …" and "3 Corresponding author.", references "[4] K. He …", bullets.
public enum ParagraphMarker {
    public static func startsItem(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.range(of: #"^(\[\d{1,3}\]\s*\S|\d{1,2}\s+\p{Lu}\p{Ll}|[•·▪◦‣]\s*\S|[*†‡§]\s*\p{Lu})"#, options: .regularExpression) != nil
    }
}
