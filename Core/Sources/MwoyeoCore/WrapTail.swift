import CoreGraphics
import Foundation

/// The last line of a wrapped paragraph that is one to three characters long ("イだわ" under "マジでここが今までで一番いいコミュニテ")
/// comes back from the document reader as a block of its own in some captures and inside the paragraph in others, and a tail that
/// stands alone is translated alone: a broken sentence above, a fragment below. The pieces are one block when the tail sits where the
/// paragraph's next line would (`ParagraphGrouper.continuation`, the one geometry of "the next line"), and the line above it was
/// full: it ends where the column ends, which the other lines of the column show, so that it wrapped and did not stop. A message that
/// ends short and one that ends at a full stop are followed by a message of their own. Design: docs/design/recognition.md section 14.
public enum WrapTail {
    /// The longest tail, in characters.
    static let maxCharacters = 3
    /// How far a full line's right end may stand from the column's edge, in heights: a line of Japanese text wraps before a closing
    /// mark, and one character short of the edge is a full line.
    static let slack = 1.0
    /// Two lines are in one column when they overlap horizontally by this share of the narrower one.
    static let sameColumn = 0.5

    /// A tail: the block `tail` is the last line of the block `head`.
    public struct Pair: Equatable, Sendable {
        public var head: Int
        public var tail: Int
    }

    /// The tails among `lines` (`lines[i]` and `texts[i]` are the boxes and the texts of block `i`'s lines): each a block of one line,
    /// short, made of letters and the marks of a sentence, that continues the last line of one block whose line is full. A block
    /// takes one tail.
    public static func pairs(lines: [[CGRect]], texts: [[String]]) -> [Pair] {
        let all = lines.enumerated().flatMap { b, rects in rects.indices.map { (block: b, rect: rects[$0]) } }
        var out: [Pair] = []
        for (t, rects) in lines.enumerated() where rects.count == 1 && isTail(texts[t].first ?? "") {
            let tail = rects[0]
            var best: (head: Int, cost: Double)?
            for (h, headRects) in lines.enumerated() where h != t && !out.contains(where: { $0.head == h }) {
                guard let last = headRects.last, let lastText = texts[h].last, !endsSentence(lastText),
                      tail.maxX <= last.maxX, let cost = ParagraphGrouper.continuation(of: last, by: tail, text: texts[t][0]),
                      best.map({ cost < $0.cost }) ?? true,
                      isFull(last, among: all.filter { $0.block != h && $0.block != t }.map(\.rect)) else { continue }
                best = (h, cost)
            }
            if let best { out.append(Pair(head: best.head, tail: t)) }
        }
        return out
    }

    /// One to `maxCharacters` characters, at least one a letter, the others letters or the marks that close a sentence or a quotation
    /// ("it.", "だわ。", "ね！"): a number, a time, a sign or a list marker is not the end of a sentence.
    static func isTail(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard (1...maxCharacters).contains(t.count), t.contains(where: \.isLetter) else { return false }
        return t.allSatisfy { $0.isLetter || marks.contains($0) }
    }

    private static let marks: Set<Character> = [".", ",", "!", "?", "…", "。", "、", "！", "？", "ー", "~", "〜", ")", "）", "」", "』", "\"", "”", "’"]

    /// A line that ends at a full stop is not wrapped, whatever its width.
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？", ":", "：", ";", "；"]

    private static func endsSentence(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespaces).last.map(sentenceEnds.contains) ?? true
    }

    /// `line` ends where its column ends: the lines of `others` that share the column (`sameColumn`) end at the far edge of it, and
    /// `line` and at least one of them end within `slack` heights of it. A column of one line has no edge to be full to, and a column
    /// whose other lines end short (a list, a log) has none either: the longest line of those is not wrapped.
    private static func isFull(_ line: CGRect, among others: [CGRect]) -> Bool {
        let column = others.filter { overlap(line.minX, line.maxX, $0.minX, $0.maxX) > sameColumn * min(line.width, $0.width) }
        let edge = column.reduce(line.maxX) { max($0, $1.maxX) }
        let reach = slack * line.height
        return line.maxX >= edge - reach && column.contains { $0.maxX >= edge - reach }
    }

    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat { min(a1, b1) - max(a0, b0) }
}
