import CoreGraphics
import Foundation

/// The document reader puts a row of a displayed equation into the paragraph beside it: with the sentence above ("... at font size s," +
/// "s* = max { s ∈ [smin, smax] : measure(s) ≤ box },") or the one below ("s* = max { ... }, which is found by bisection ..."). Taken
/// into a block of prose the row is translated with it and drawn as text over the typeset equation, and no rule that judges the row
/// (`TranslationFilter.isLiteral`, `CodeRegion.Reason.equation`) ever sees it alone. The same display on the same page came back whole
/// or glued to a paragraph by where the lens fell (D14, film3's take of page 6 of the method paper: crops 3 pt apart; the paragraph
/// above in one, the one below in another). Design: docs/design/keep-boundary.md section 10, docs/design/recognition.md section 11.
///
/// A line of a block is cut out of it when the text of the line is a row of mathematics (`isRow`) and it stands off the prose of its
/// block as a display does: white space above and below it, and in from both edges of the prose. A line of prose that holds a formula
/// ("... where x = 3 and y") is none of this, and neither is a wrapped line of a sentence (flush with the margin) or a code line
/// (no white space around it).
public enum DisplayRow {
    /// The room a display leaves around it, in line heights of the prose of its block: the gap to the line above and the line below
    /// (the ones the block has), and its distance from the left and from the right edge of the prose. Measured on the rows of the
    /// method paper that the reader merged: 0.69 to 1.16 above or below, 0.88 to 1.09 in from either side; the lines of a paragraph
    /// stand 0.0 to 0.2 apart and flush with the margin.
    public static let standOff = 0.5

    /// What the text of a row of mathematics is: a formula, a line that is mostly inline mathematics, or a sign of mathematics beside
    /// at most a word of prose (the same text rules as the block that stands alone, `TranslationFilter.isLiteral` and `CodeRegion.isEquationRow`).
    static func isRow(_ text: String) -> Bool {
        TranslationFilter.isFormula(text) || TranslationFilter.isMathHeavy(text) || CodeRegion.holdsMathNotProse(text)
    }

    /// `lines[i]` are the text and box of line `i` of one block, reading order. The pieces the block is cut into, as runs of line
    /// indices (ascending, together all of them): the rows of a display that stand off the prose are a piece of their own, the
    /// prose before and after them are the others. A block with no such row comes back as one run.
    public static func pieces(_ lines: [(text: String, rect: CGRect)]) -> [[Int]] {
        let all = Array(lines.indices)
        let rows = lines.map { isRow($0.text) }
        let prose = all.filter { !rows[$0] }
        guard let left = prose.map({ lines[$0].rect.minX }).min(), let right = prose.map({ lines[$0].rect.maxX }).max() else { return [all] }
        let heights = lines.map(\.rect.height).sorted()
        let room = standOff * heights[heights.count / 2]

        var out: [[Int]] = [], current: [Int] = []
        var i = 0
        while i < lines.count {
            guard rows[i] else { current.append(i); i += 1; continue }
            var end = i
            while end + 1 < lines.count, rows[end + 1] { end += 1 }
            let run = Array(i...end)
            let box = run.dropFirst().reduce(lines[i].rect) { $0.union(lines[$1].rect) }
            let above = i > 0 ? box.minY - lines[i - 1].rect.maxY : .infinity
            let below = end + 1 < lines.count ? lines[end + 1].rect.minY - box.maxY : .infinity
            if min(above, below, box.minX - left, right - box.maxX) >= room {
                if !current.isEmpty { out.append(current); current = [] }
                out.append(run)
            } else {
                current += run
            }
            i = end + 1
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
