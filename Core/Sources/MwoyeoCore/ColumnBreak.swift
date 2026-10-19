import CoreGraphics
import Foundation

/// A block is a column of text read top to bottom. A paragraph that goes on at the top of the next column comes back from the
/// document reader as one block of lines in two columns, and its rect (the union of its lines) is as large as the two columns
/// together: it holds the other blocks of the page, and `Territory.trim` cuts every one of them against it (page 2 of our paper:
/// 33 of 33 drawn translations wrong). The block is cut where its lines climb, but only when its rect holds half of another
/// block: a block that climbs and holds nothing (the rotated words of a figure) paints no wrong pixel and is left as it is.
/// Design: docs/design/recognition.md section 11.
public enum ColumnBreak {
    /// Another block is "held" when the intersection of the two rects is this share of the smaller one (`score.py` cross_col).
    public static let heldShare: CGFloat = 0.5

    /// The lines of one block (reading order) that start a new column: the line's middle is above the top of the line before it.
    public static func climbs(_ lines: [CGRect]) -> [Int] {
        lines.indices.dropFirst().filter { lines[$0].midY < lines[$0 - 1].minY }
    }

    /// `blocks[i]` are the line boxes of block `i`. The result has, for every block, its pieces as runs of line indices (ascending);
    /// a block that is not cut comes back as one run.
    public static func pieces(_ blocks: [[CGRect]]) -> [[[Int]]] {
        let unions = blocks.map { $0.dropFirst().reduce($0.first ?? .null) { $0.union($1) } }
        return blocks.indices.map { i in
            let cuts = climbs(blocks[i])
            guard !cuts.isEmpty, blocks.indices.contains(where: { $0 != i && holds(unions[i], unions[$0]) }) else {
                return [Array(blocks[i].indices)]
            }
            var runs: [[Int]] = [], from = 0
            for c in cuts + [blocks[i].count] { runs.append(Array(from..<c)); from = c }
            return runs
        }
    }

    /// The two rects overlap by `heldShare` of the smaller one.
    public static func holds(_ a: CGRect, _ b: CGRect) -> Bool {
        let i = a.intersection(b)
        guard !i.isNull, a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
        return i.width * i.height >= heldShare * min(a.width * a.height, b.width * b.height)
    }

    /// Characters that close a quotation or a bracket, which may stand between a sentence's full stop and the end of its line.
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "”", "’", "»", "」", "』", "）", "】"]
    private static let sentenceEnds: Set<Character> = [".", "!", "?", "。", "！", "？", "…", ":"]

    /// Whether the piece that starts with `nextFirst` goes on with the sentence of the one that ended with `previousLast` (they
    /// share one translation) or is a paragraph of its own (a prompt, a heading, a code line: its own translation, or none). It goes
    /// on when the sentence was not ended and the next line starts with a lowercase letter, or with a letter of a script without case.
    public static func continues(previousLast: String, nextFirst: String) -> Bool {
        let end = previousLast.trimmingCharacters(in: .whitespaces).last { !closers.contains($0) }
        let start = nextFirst.trimmingCharacters(in: .whitespaces).first
        guard let end, let start, start.isLetter, !sentenceEnds.contains(end) else { return false }
        return start.isLowercase || !start.isUppercase
    }

    /// The pieces of one block (`first` and `last` are the text of each piece's first and last line), as chains: the result
    /// numbers the pieces 0, 1, ... and a piece that goes on with the one before it (`continues`) takes its number. Pieces with
    /// one number share one translation (`FlowSplit`); a piece alone in its chain is a paragraph of its own.
    public static func chains(_ pieces: [(first: String, last: String)]) -> [Int] {
        var ids: [Int] = []
        for (k, piece) in pieces.enumerated() {
            guard k > 0 else { ids.append(0); continue }
            ids.append(continues(previousLast: pieces[k - 1].last, nextFirst: piece.first) ? ids[k - 1] : ids[k - 1] + 1)
        }
        return ids
    }
}
