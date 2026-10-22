import CoreGraphics
import Foundation

/// OCR reads a chat header — a coloured name, a badge, a small grey timestamp — as one line, and an avatar or emoji
/// in front of text as a letter. Splitting a line into runs of one style lets each run be translated and drawn in
/// its own colour and size, and leaves names and icons alone.
public enum StyleRuns {
    public struct Token: Sendable {
        public var text: String
        public var minX: CGFloat
        public var maxX: CGFloat
        /// Glyph colour; nil when the token has too little ink to tell (a dot, a comma).
        public var color: RGBA?
        /// A filled shape (avatar, emoji) rather than strokes of text.
        public var solid: Bool

        public init(text: String, minX: CGFloat, maxX: CGFloat, color: RGBA?, solid: Bool) {
            self.text = text
            self.minX = minX
            self.maxX = maxX
            self.color = color
            self.solid = solid
        }
    }

    /// A word's token from the ink clusters (image x) under its OCR box. The word takes the colour most of its
    /// clusters share; clusters at its ends in another colour, or solid ones, are an icon the box took in (an
    /// emoji just before "Today") and are left out of its extent. A word that is all solid shape is `solid`.
    public static func token(text: String, minX: CGFloat, maxX: CGFloat, clusters: [InkCluster], lineHeight: CGFloat) -> Token {
        var mine = clusters.filter { CGFloat($0.minX + $0.maxX) / 2 >= minX && CGFloat($0.minX + $0.maxX) / 2 <= maxX }
        guard !mine.isEmpty else { return Token(text: text, minX: minX, maxX: maxX, color: nil, solid: false) }
        let strokes = mine.filter { !$0.solid }
        guard let main = strokes.max(by: { a, b in
            let sa = strokes.count { $0.color.distance(to: a.color) < 60 }, sb = strokes.count { $0.color.distance(to: b.color) < 60 }
            return (sa, a.ink) < (sb, b.ink)
        }) else {
            // A bold or haloed CJK glyph fills its box like a shape does ("君" in a glowing title), but it is text.
            if text.unicodeScalars.contains(where: TranslationFilter.isCJK) {
                return Token(text: text, minX: minX, maxX: maxX, color: mine.max { $0.ink < $1.ink }?.color, solid: false)
            }
            return Token(text: text, minX: CGFloat(mine[0].minX), maxX: CGFloat(mine[mine.count - 1].maxX), color: nil, solid: true)
        }
        func foreign(_ c: InkCluster) -> Bool { c.solid || c.color.distance(to: main.color) > 60 }
        while mine.count > 1, foreign(mine[0]) { mine.removeFirst() }
        while mine.count > 1, foreign(mine[mine.count - 1]) { mine.removeLast() }
        // Too little ink (a dot, a comma) for a trustworthy colour.
        let ink = mine.reduce(0) { $0 + $1.ink }
        return Token(text: text, minX: CGFloat(mine[0].minX), maxX: CGFloat(mine[mine.count - 1].maxX),
                     color: CGFloat(ink) >= 0.015 * lineHeight * lineHeight ? main.color : nil, solid: false)
    }

    /// Token index ranges of the line's runs, in order, with icons and decoration trimmed off their ends. Runs
    /// break where the colour changes, around solid shapes, and at gaps wider than 1.5 line heights (separate
    /// buttons read as one line). Runs left with nothing are dropped. A coloured stretch with the same colour on
    /// both sides ("hey @junpark are you coming", a link mid-sentence) is inline and stays in its sentence.
    public static func runs(_ tokens: [Token], lineHeight: CGFloat) -> [Range<Int>] {
        guard !tokens.isEmpty else { return [] }
        // Each segment: its start, colour, and whether it began only because the colour changed.
        var segs: [(start: Int, color: RGBA?, byColor: Bool)] = [(0, tokens[0].color, false)]
        for i in 1..<tokens.count {
            let a = tokens[i - 1], b = tokens[i]
            let colorChange = segs[segs.count - 1].color.flatMap { c in b.color.map { c.distance(to: $0) > 60 } } ?? false
            let hard = a.solid || b.solid || b.minX - a.maxX > 1.5 * lineHeight
            if hard || colorChange {
                segs.append((i, b.color, !hard))
            } else if segs[segs.count - 1].color == nil {
                segs[segs.count - 1].color = b.color
            }
        }
        var i = 1
        while i + 1 < segs.count {
            if segs[i].byColor, segs[i + 1].byColor, let a = segs[i - 1].color, let c = segs[i + 1].color, a.distance(to: c) <= 60 {
                segs.removeSubrange(i...(i + 1))
            } else {
                i += 1
            }
        }
        let bounds = segs.map(\.start) + [tokens.count]
        return zip(bounds, bounds.dropFirst()).compactMap { trimmed(tokens, $0..<$1) }
    }

    /// Drops leading and trailing tokens that are icons or stray marks rather than text: solid shapes, and tokens
    /// without letters or digits other than punctuation that belongs there ("#general", "(1)", "really?").
    static func trimmed(_ tokens: [Token], _ r: Range<Int>) -> Range<Int>? {
        var lo = r.lowerBound, hi = r.upperBound
        while lo < hi, isDecoration(tokens[lo], keep: "#@$€£¥¿¡([{「『【〈《\"'“‘«<+-") { lo += 1 }
        while hi > lo, isDecoration(tokens[hi - 1], keep: ".,!?…)]}」』】〉》\"'”’»>:;%。！？") { hi -= 1 }
        return lo < hi ? lo..<hi : nil
    }

    private static func isDecoration(_ t: Token, keep: String) -> Bool {
        t.solid || !t.text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
            && !t.text.contains { keep.contains($0) }
    }
}

/// Names, handles and badges sit next to other text in a different style — "Maya [MOD] Today at 8:12 PM" — and are
/// not to be translated: "Maya" is not "마야" and a "MOD" badge is not "그 복장".
public enum LabelRule {
    public struct Item: Sendable {
        public var rect: CGRect
        public var text: String
        public var color: RGBA
        /// Height of one line of the text; `rect.height` when the item is a single line.
        public var lineHeight: CGFloat

        public init(rect: CGRect, text: String, color: RGBA, lineHeight: CGFloat? = nil) {
            self.rect = rect
            self.text = text
            self.color = color
            self.lineHeight = lineHeight ?? rect.height
        }
    }

    /// Indices of items that are labels: one word (or a short CJK run without sentence punctuation) followed on
    /// the same row, at most 2.5 line heights away (room for an emoji), by text in another colour. Names and badges
    /// lead a row and the timestamp ends it, so a word at the end ("Yesterday", "5時間前") is still translated, as
    /// is a word alone on its row ("Today", "INFO") or among same-style neighbours (tabs, buttons).
    public static func labels(_ items: [Item]) -> Set<Int> {
        var out = Set<Int>()
        for (i, a) in items.enumerated() where isWordShaped(a.text) {
            let h = a.rect.height
            if items.indices.contains(where: { j in
                let b = items[j]
                let overlap = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
                let gap = b.rect.minX - a.rect.maxX
                return j != i && overlap > 0.5 * min(h, b.rect.height) && gap > -0.5 * h && gap < 2.5 * h
                    && a.color.distance(to: b.color) > 60
            }) {
                out.insert(i)
            }
        }
        for (i, a) in items.enumerated() where !out.contains(i) && isNameTag(a) {
            if items.indices.contains(where: { j in j != i && stands(items[j], under: a) && a.color.distance(to: items[j].color) > 60 }) {
                out.insert(i)
            }
        }
        return out
    }

    /// Indices of the name tags of `items` by where they stand alone: a name on a line of its own with a longer text under it (a message
    /// bubble, a dialogue box). The colour is not asked: a game's name tag has the ink of its box, and `labels` keeps only the ones that
    /// differ from it.
    public static func nameTags(_ items: [Item]) -> Set<Int> {
        Set(items.indices.filter { i in
            isNameTag(items[i]) && items.indices.contains { j in j != i && stands(items[j], under: items[i]) }
        })
    }

    /// Whether `b` stands under `a` the way a message or a dialogue box stands under its name: close below it, over the same columns, with
    /// more text and a line no smaller.
    private static func stands(_ b: Item, under a: Item) -> Bool {
        let h = a.lineHeight, gap = b.rect.minY - a.rect.maxY
        let aligned = b.rect.minX < a.rect.maxX + 3 * h && b.rect.maxX > a.rect.minX - 3 * h
        return gap > -0.3 * h && gap < 2.5 * h && aligned && b.rect.midY > a.rect.midY
            && b.text.count > a.text.count && a.lineHeight <= 1.15 * b.lineHeight
    }

    /// A name above a message bubble or a dialogue box: one to three CJK words on a line of their own. Names in
    /// Latin script come back from the engine as they went in; a CJK name does not ("민지" → "The intellect of
    /// the people").
    static func isNameTag(_ a: Item) -> Bool {
        let t = a.text.trimmingCharacters(in: .whitespaces)
        guard a.rect.height <= 1.6 * a.lineHeight, t.count <= 8, t.split(separator: " ").count <= 3,
              t.unicodeScalars.contains(where: TranslationFilter.isCJK),
              !t.contains(where: { "。、，．！？!?,.~…:：".contains($0) }), !t.unicodeScalars.contains(where: CharacterSet.decimalDigits.contains)
        else { return false }
        return true
    }

    static func isWordShaped(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !t.contains(where: \.isWhitespace), t.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return false }
        if t.unicodeScalars.contains(where: TranslationFilter.isCJK) {
            return t.count <= 8 && !t.contains { "。、，．！？!?,.".contains($0) }
        }
        return t.count <= 24
    }
}
