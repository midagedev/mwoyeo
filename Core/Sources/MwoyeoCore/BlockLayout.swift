import CoreGraphics
import Foundation

/// Rules for translated blocks that sit close together on one picture (a paper page, a long thread): which recognized
/// blocks are one block, what area each block may paint, and where its column ends. `LayoutCheck` counts what is left of
/// the problem on a finished picture. All rects are image pixels, top-left origin; the pipeline calls these and owns no rule.

/// Recognized blocks that are one block. A line the recognizer could not read across (an inline sum with limits, a fraction)
/// comes back as two lines on one text row, in two blocks; and a tall line (a fraction inside it) reaches up into the
/// block above. Translated apart, the pieces read badly and their patches paint over each other.
public enum BlockMerge {
    /// Two lines are on one text row when their vertical overlap exceeds this fraction of the shorter one.
    static let rowOverlap = 0.5
    /// The widest gap between two lines of one row that still reads as one run of text, in heights of the taller line (a sum
    /// with limits is about one and a half heights wide; columns of a table or items of a menu are further apart).
    static let rowGap = 2.0
    /// Lines of one row may overlap this much horizontally, in heights: the limits of a sum are stacked over and under its sign,
    /// so the box of the text before it and the box of the text after it reach into each other (measured: 1 height).
    static let rowSlop = 1.5
    /// Of the two lines of a split line one is a run of text, at least this many heights wide: the labels of a figure ("Q", "K"
    /// under an arrow) are narrow and stand a little apart, and are no split line.
    static let wideLine = 4.0
    /// Two blocks interlock when their line boxes overlap vertically by more than this fraction of the shorter line and
    /// horizontally by more than half of the narrower one (stacked in one column, not side by side).
    static let interlock = 0.5

    /// Groups of block indices (ascending) that are one block; `lines[i]` are the line boxes of block `i`. Blocks that
    /// join nothing come back alone, in order of their first index.
    public static func groups(_ lines: [[CGRect]]) -> [[Int]] {
        var parent = Array(lines.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in lines.indices {
            for j in lines.indices where j > i && joins(lines[i], lines[j]) {
                parent[find(j)] = find(i)
            }
        }
        var order: [Int: Int] = [:], out: [[Int]] = []
        for i in lines.indices {
            let root = find(i)
            if let k = order[root] { out[k].append(i) } else { order[root] = out.count; out.append([i]) }
        }
        return out
    }

    /// Whether two blocks, given by their lines, are one: they interlock, or one is a paragraph whose last line has the other, a
    /// lone line, beside it. A lone line beside the first or a middle line of a paragraph is a cell of a table or a label, and a
    /// lone line beside another lone line is a menu, a table row, a name and its time: the document reader groups those as
    /// they are.
    static func joins(_ a: [CGRect], _ b: [CGRect]) -> Bool {
        for x in a { for y in b where interlocks(x, y) { return true } }
        return endsWithPiece(a, b) || endsWithPiece(b, a)
    }

    /// `piece` is one line that starts inside the width of `paragraph` and shares a text row with its last line.
    private static func endsWithPiece(_ paragraph: [CGRect], _ piece: [CGRect]) -> Bool {
        guard paragraph.count > 1, piece.count == 1, let last = paragraph.last else { return false }
        let core = paragraph.dropFirst().reduce(paragraph[0]) { $0.union($1) }
        return piece[0].minX < core.maxX && sharesRow(last, piece[0])
    }

    /// Two lines side by side on one text row, close enough to be one run of text.
    static func sharesRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let tall = max(a.height, b.height), short = min(a.height, b.height)
        guard short > 0, max(a.width, b.width) >= wideLine * tall,
              overlap(a.minY, a.maxY, b.minY, b.maxY) > rowOverlap * short else { return false }
        let gap = max(a.minX - b.maxX, b.minX - a.maxX)
        return gap >= -rowSlop * tall && gap <= rowGap * tall
    }

    /// Two lines stacked in one column whose boxes overlap in height: neither is below the other.
    static func interlocks(_ a: CGRect, _ b: CGRect) -> Bool {
        let short = min(a.height, b.height)
        guard short > 0 else { return false }
        let across = overlap(a.minX, a.maxX, b.minX, b.maxX)
        return overlap(a.minY, a.maxY, b.minY, b.maxY) > interlock * short && across > 0.5 * min(a.width, b.width)
    }

    /// The lines of a joined block in reading order: rows from the top, left to right within a row.
    public static func readingOrder(_ lines: [CGRect]) -> [Int] {
        ReadingOrder.sorted(Array(lines.indices), frame: { lines[$0] })
    }

    private static func overlap(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> CGFloat { min(a1, b1) - max(a0, b0) }
}

/// What each block may paint. A patch is the block's text with a margin on every side (and a strip for descenders below), so
/// the patches of two blocks that stand close overlap in their margins, and the one drawn later covers the other's translation.
/// Trimmed here so that no two patches share a pixel: the draw order stops mattering, and the images stay opaque rectangles.
public enum Territory {
    /// A glyph's tail below the baseline, in line heights: a line's box may end at the baseline (a line of "game" has no
    /// descender to include), and the tails of "g, p, y, ," under it still have to be erased with the line.
    static let descender = 0.3

    /// The depth under a line's box that is erased with the line: room for descenders, never less than `ring`.
    public static func below(lineHeight: CGFloat, ring: CGFloat) -> CGFloat { max(ring, (lineHeight * descender).rounded(.up)) }

    /// What a block with these source lines would paint: `core` (the union of its lines) with `ring` on top and at the sides,
    /// and room below for descenders.
    public static func want(core: CGRect, lineHeight: CGFloat, ring: CGFloat) -> CGRect {
        CGRect(x: core.minX - ring, y: core.minY - ring, width: core.width + 2 * ring,
               height: core.height + ring + below(lineHeight: lineHeight, ring: ring))
    }

    /// The part of `patch` the translation is laid out in: the source text with `ring` around it, and the free background
    /// `spare` to its right that a longer translation may take. The strip under it that `want` added for descenders is erased
    /// with the block but not written in, so the text sits where the source sat.
    public static func textArea(core: CGRect, ring: CGFloat, spare: CGFloat, in patch: CGRect) -> CGRect {
        CGRect(x: core.minX - ring, y: core.minY - ring, width: core.width + 2 * ring + spare, height: core.height + 2 * ring)
            .intersection(patch)
    }

    /// `wants[i]` is what block `i` would paint (its `cores[i]`, the union of its source lines, plus margins). Each pair
    /// whose wants meet is cut apart along the axis they are further apart on, inside the gap between the cores: the gap is
    /// shared in proportion to what each asked for there (the middle of the overlap when the cores themselves overlap).
    public static func trim(cores: [CGRect], wants: [CGRect]) -> [CGRect] {
        var out = wants
        for i in wants.indices {
            for j in wants.indices where j > i && meet(wants[i], wants[j]) {
                let ci = cores[i], cj = cores[j]
                let gapY = max(ci.minY - cj.maxY, cj.minY - ci.maxY), gapX = max(ci.minX - cj.maxX, cj.minX - ci.maxX)
                if gapY >= gapX {
                    let (up, down) = ci.midY <= cj.midY ? (i, j) : (j, i)
                    let cut = cutPoint(upperCore: cores[up].maxY, lowerCore: cores[down].minY,
                                       upperWant: wants[up].maxY, lowerWant: wants[down].minY)
                    out[up] = clip(out[up], maxY: cut)
                    out[down] = clip(out[down], minY: cut)
                } else {
                    let (left, right) = ci.midX <= cj.midX ? (i, j) : (j, i)
                    let cut = cutPoint(upperCore: cores[left].maxX, lowerCore: cores[right].minX,
                                       upperWant: wants[left].maxX, lowerWant: wants[right].minX)
                    out[left] = clip(out[left], maxX: cut)
                    out[right] = clip(out[right], minX: cut)
                }
            }
        }
        return out
    }

    private static func meet(_ a: CGRect, _ b: CGRect) -> Bool {
        let r = a.intersection(b)
        return !r.isNull && r.width > 0 && r.height > 0
    }

    /// Where the cut runs along one axis. `upperCore`/`lowerCore` are the near edges of the two cores (upper = the one
    /// before, left or top), `upperWant`/`lowerWant` the far edges of what each asked for.
    static func cutPoint(upperCore: CGFloat, lowerCore: CGFloat, upperWant: CGFloat, lowerWant: CGFloat) -> CGFloat {
        let gap = lowerCore - upperCore
        guard gap > 0 else { return (upperCore + lowerCore) / 2 }
        let a = max(0, upperWant - upperCore), b = max(0, lowerCore - lowerWant)
        guard a + b > 0 else { return upperCore + gap / 2 }
        return upperCore + gap * a / (a + b)
    }

    private static func clip(_ r: CGRect, minX: CGFloat? = nil, maxX: CGFloat? = nil, minY: CGFloat? = nil, maxY: CGFloat? = nil) -> CGRect {
        let x0 = max(r.minX, minX ?? r.minX), x1 = max(x0, min(r.maxX, maxX ?? r.maxX))
        let y0 = max(r.minY, minY ?? r.minY), y1 = max(y0, min(r.maxY, maxY ?? r.maxY))
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

/// Where a block's column ends on the right. A translation longer than its source may spill into free background to the
/// right; on a page that background is the margin, which is not the block's to take.
public enum ColumnEdge {
    /// Two blocks are in one column when their x-ranges overlap by at least this fraction of the narrower one.
    static let sharedWidth = 0.5

    /// The right edge of the column `core` stands in: the furthest right edge among the blocks of `others` that share its
    /// columns, never less than its own. Nil when no block shares its column (a lone label or caption): nothing says
    /// where its column ends.
    public static func right(of core: CGRect, among others: [CGRect]) -> CGFloat? {
        var edge: CGFloat?
        for o in others {
            let across = min(core.maxX, o.maxX) - max(core.minX, o.minX)
            guard across > 0, across >= sharedWidth * min(core.width, o.width) else { continue }
            edge = max(edge ?? core.maxX, o.maxX)
        }
        return edge
    }
}

/// One drawn translation, for `LayoutCheck`.
public struct DrawnBlock: Sendable, Equatable {
    public var source: String
    /// The source text: the union of its lines.
    public var core: CGRect
    /// Everything the block paints (an opaque patch).
    public var patch: CGRect
    /// Where its translation is drawn, inside `patch`.
    public var text: CGRect

    public init(source: String, core: CGRect, patch: CGRect, text: CGRect) {
        self.source = source
        self.core = core
        self.patch = patch
        self.text = text
    }
}

/// What is wrong with the layout of a finished picture: drawn translations that intersect, that run past their column's
/// right edge, or that a later block's patch paints over. Blocks are drawn in array order.
public enum LayoutCheck {
    /// Intersections up to this many pixels across are not counted (anti-aliasing, rounding).
    public static let tolerance: CGFloat = 1

    public struct Report: Sendable, Equatable {
        public var blocks = 0
        /// Pairs of drawn translations that intersect.
        public var overlaps: [(Int, Int)] = []
        /// Drawn translations past the right edge of their column.
        public var spill: [Int] = []
        /// (painted, by): a drawn translation and the later block whose patch covers part of it.
        public var cut: [(Int, Int)] = []

        public static func == (a: Report, b: Report) -> Bool {
            a.blocks == b.blocks && a.spill == b.spill && a.overlaps.elementsEqual(b.overlaps, by: ==) && a.cut.elementsEqual(b.cut, by: ==)
        }

        /// The one line the gates read.
        public var summary: String { "layout: blocks=\(blocks) overlaps=\(overlaps.count) spill=\(spill.count) cut=\(cut.count)" }
    }

    public static func check(_ drawn: [DrawnBlock]) -> Report {
        var r = Report()
        r.blocks = drawn.count
        for i in drawn.indices {
            if let limit = ColumnEdge.right(of: drawn[i].core, among: drawn.indices.filter { $0 != i }.map { drawn[$0].core }),
               drawn[i].text.maxX > limit + tolerance {
                r.spill.append(i)
            }
            for j in drawn.indices where j > i {
                if crosses(drawn[i].text, drawn[j].text) { r.overlaps.append((i, j)) }
                if crosses(drawn[i].text, drawn[j].patch) { r.cut.append((i, j)) }
            }
        }
        return r
    }

    private static func crosses(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > tolerance && min(a.maxY, b.maxY) - max(a.minY, b.minY) > tolerance
    }
}
