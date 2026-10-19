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
    /// The widest gap between two lines of one row that still reads as one run of text, in heights of the taller line (1.5 em).
    /// The pieces of a line the recognizer could not read across stand against each other (a fraction: 0.1 heights, a sum with
    /// limits: their boxes overlap) or across a sign no wider than an em with its spaces; a wider gap is the gutter between columns,
    /// items of a menu or cells of a table. The author header of the Attention paper has its columns 1.5 to 2.9 heights apart.
    static let rowGap = 1.2
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

    /// `piece` is one line that starts inside the width of `paragraph` (a line wholly to the left of it is the cell of the column
    /// beside, not the end of the last line) and shares a text row with its last line.
    private static func endsWithPiece(_ paragraph: [CGRect], _ piece: [CGRect]) -> Bool {
        guard paragraph.count > 1, piece.count == 1, let last = paragraph.last else { return false }
        let core = paragraph.dropFirst().reduce(paragraph[0]) { $0.union($1) }
        return piece[0].minX < core.maxX && piece[0].maxX > core.minX && sharesRow(last, piece[0])
    }

    /// Two lines side by side on one text row, close enough to be one run of text.
    static func sharesRow(_ a: CGRect, _ b: CGRect) -> Bool {
        guard let gap = rowGapBetween(a, b) else { return false }
        return gap >= -rowSlop && gap <= rowGap
    }

    /// The horizontal gap between two lines on one text row, in heights of the taller one (negative: their boxes overlap); nil
    /// when they are not on one row or neither is a run of text (`wideLine`). `sharesRow` bounds it; the pipeline's trace prints
    /// it for the pairs just outside the bounds.
    public static func rowGapBetween(_ a: CGRect, _ b: CGRect) -> CGFloat? {
        let tall = max(a.height, b.height), short = min(a.height, b.height)
        guard short > 0, max(a.width, b.width) >= wideLine * tall,
              overlap(a.minY, a.maxY, b.minY, b.maxY) > rowOverlap * short else { return nil }
        return max(a.minX - b.maxX, b.minX - a.maxX) / tall
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

    /// Background around a block's text (pixels) that its patch takes in, for the glyph mask's ring: 0.18 of the line height, at least 3.
    public static func ring(lineHeight: CGFloat) -> Int { max(3, Int(lineHeight * 0.18)) }

    /// A territory smaller than this share of its block's core leaves part of the source unerased or the translation without room.
    public static let squeezedShare: CGFloat = 0.5

    /// Whether `territory` covers less than `squeezedShare` of `core`: nothing is wrong with the cut itself, but the block is
    /// drawn in half of its place or not at all (a patch of 0-1 px has no text area). `layout.squeezed` counts these.
    public static func squeezed(core: CGRect, territory: CGRect) -> Bool {
        let kept = core.intersection(territory)
        guard core.width > 0, core.height > 0 else { return false }
        return kept.isNull || kept.width * kept.height < squeezedShare * core.width * core.height
    }

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

/// The size body text is drawn at. A translation's size starts from the glyphs of its source (`emSize`), and the glyphs of a
/// line with subscripts and superscripts ("W ∈ R dmodel × dk", "dk = dv = dmodel/h") stand taller than the letters beside them:
/// the translation of such a line came out 1.5 times as large as the lines around it. Body text is set in one size on a
/// screen, so a body-like block is not drawn larger than the body-like blocks beside it; titles and headings keep theirs.
public enum BodySize {
    /// A block is body-like when its lines hold this many characters on average: a title, a heading, a caption or a label
    /// is shorter, and is set in its own size.
    public static let bodyCharacters = 40
    /// How much larger than the median of the body-like blocks a body-like block may be drawn (a line of a paragraph
    /// differs by a few percent on its own).
    public static let ceilingFactor: CGFloat = 1.15

    /// One block, as far as its size is concerned.
    public struct Block: Sendable, Equatable {
        public var fontSize: CGFloat?
        public var characters: Int
        public var lines: Int

        public init(fontSize: CGFloat?, characters: Int, lines: Int) {
            self.fontSize = fontSize
            self.characters = characters
            self.lines = lines
        }

        public var isBody: Bool { characters >= bodyCharacters * max(1, lines) }
    }

    /// The largest size a body-like block may be drawn at among `blocks` (every block on the screen, the new and the kept):
    /// `ceilingFactor` times the median size of the body-like ones, the lower of the two middle ones when their number is
    /// even (scripts only ever make a size larger). Nil when fewer than two blocks are body-like: one block has nothing to be
    /// compared with.
    public static func ceiling(among blocks: [Block]) -> CGFloat? {
        let sizes = blocks.filter(\.isBody).compactMap(\.fontSize).filter { $0 > 0 }.sorted()
        guard sizes.count >= 2 else { return nil }
        return sizes[(sizes.count - 1) / 2] * ceilingFactor
    }

    /// `block`'s size under `ceiling`: a body-like block is capped, any other block keeps its size.
    public static func capped(_ block: Block, ceiling: CGFloat?) -> CGFloat? {
        guard let size = block.fontSize, let ceiling, block.isBody else { return block.fontSize }
        return min(size, ceiling)
    }
}

/// The size a lone label is drawn at. A label of a figure ("Positional", "Attention", "Add & Norm") is one short line, and its
/// source size is estimated from the glyphs in its box and from the box's height. When the recognizer's box holds more than the
/// line it read (the box of "Positional Encoding" with the text of its first line only, 43 px tall for glyphs 22 px tall), both
/// say twice the size, and the translation came out at 45.8 px beside labels of 23 px. What a line's own width says is more
/// reliable for a short line of letters: a Latin letter is about 0.4 to 0.5 em wide on average, and labels drawn from their
/// source measure 1.5 to 2.4 times as large (em) as the average width of their characters, 2.85 at the most (200 labels of the
/// paper bench's pages, 2026-10-18); a Han, kana or hangul glyph is one em wide, so for those the cap never binds.
public enum LabelSize {
    /// A label is at most this many words and characters, and at least `minCharacters` (one letter or two has no average width).
    public static let maxWords = 2
    public static let maxCharacters = 16
    public static let minCharacters = 4
    /// The largest size (em) of a label, in widths of its characters: above anything measured on a source label but "This" (2.85).
    public static let advanceCeiling: CGFloat = 2.6

    /// One line of at most two words and sixteen characters.
    public static func isLabel(_ text: String, lines: Int) -> Bool {
        guard lines == 1 else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A sign between two words is no word ("Add & Norm").
        let words = trimmed.split(whereSeparator: \.isWhitespace).filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }
        return (minCharacters...maxCharacters).contains(trimmed.count) && words.count <= maxWords
    }

    /// `size` of a block, held to what the width of its line says when it is a label (`width` is the line's, in pixels).
    public static func capped(_ size: CGFloat?, text: String, width: CGFloat, lines: Int) -> CGFloat? {
        guard let size, width > 0, isLabel(text, lines: lines) else { return size }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return min(size, advanceCeiling * width / CGFloat(trimmed.count))
    }
}

/// A line the capture cuts. The recognizer reads what the picture holds: a line that stands half inside the capture is read
/// from its upper or lower half, and its translation, drawn over the visible half, is of half a sentence. The capture is
/// larger than the lens (overscan), so such a line is out of sight unless the capture ends at the edge of the display; it is
/// left as it is (not translated, not erased) until the capture holds the whole line.
public enum CaptureEdge {
    /// A line's box this close to the top or bottom of the capture (pixels) touches it: the recognizer's boxes follow the
    /// glyphs it saw, and a line cut through the middle of its letters ends 3 px short of the edge as often as at it (measured
    /// on the paper bench's crops, 2 px missed five of eighteen).
    public static let tolerance: CGFloat = 4
    /// A touching line is cut when its box is shorter than this share of the median height of the lines that do not touch: the
    /// visible half of a cut line is about half as tall, while a line of a picture cropped to its text (one subtitle line, a
    /// caption) touches the edge whole.
    public static let shortShare: CGFloat = 0.85

    /// Whether `line` reaches the top or bottom edge of `bounds`.
    public static func touches(_ line: CGRect, in bounds: CGRect) -> Bool {
        line.minY <= bounds.minY + tolerance || line.maxY >= bounds.maxY - tolerance
    }

    /// The indices of the lines of one capture that it cuts. With no line clear of the edges there is nothing to compare with,
    /// and none is cut.
    public static func cut(_ lines: [CGRect], in bounds: CGRect) -> Set<Int> {
        let clear = lines.filter { !touches($0, in: bounds) }.map(\.height).sorted()
        guard !clear.isEmpty else { return [] }
        let reference = clear[clear.count / 2]
        return Set(lines.indices.filter { touches(lines[$0], in: bounds) && lines[$0].height < shortShare * reference })
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
    /// The translation's font size (pixels) and the source lines it replaces.
    public var fontSize: CGFloat
    public var lines: Int
    /// The translation needed more room than its patch has at the smallest size, and whether it was cut to fit and ends in "…".
    public var clipped: Bool
    public var ellipsis: Bool

    public init(source: String, core: CGRect, patch: CGRect, text: CGRect, fontSize: CGFloat = 0, lines: Int = 1, clipped: Bool = false,
                ellipsis: Bool = false) {
        self.source = source
        self.core = core
        self.patch = patch
        self.text = text
        self.fontSize = fontSize
        self.lines = lines
        self.clipped = clipped
        self.ellipsis = ellipsis
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
        /// Drawn translations that did not fit their patch at the smallest size.
        public var clipped: [Int] = []
        /// Pairs of blocks where one block's source rect holds half of the other's (`ColumnBreak.holds`): a block that spans two
        /// columns, or a join of lines across a gutter. The drawn translations need not touch, but the territories were cut
        /// against the large rect.
        public var holds: [(Int, Int)] = []

        public static func == (a: Report, b: Report) -> Bool {
            a.blocks == b.blocks && a.spill == b.spill && a.clipped == b.clipped && a.overlaps.elementsEqual(b.overlaps, by: ==) && a.cut.elementsEqual(b.cut, by: ==)
                && a.holds.elementsEqual(b.holds, by: ==)
        }

        /// The one line the gates read. `holds` is appended: `score.py` reads the fields before it by name.
        public var summary: String {
            "layout: blocks=\(blocks) overlaps=\(overlaps.count) spill=\(spill.count) cut=\(cut.count) clipped=\(clipped.count) holds=\(holds.count)"
        }
    }

    public static func check(_ drawn: [DrawnBlock]) -> Report {
        var r = Report()
        r.blocks = drawn.count
        for i in drawn.indices {
            if drawn[i].clipped { r.clipped.append(i) }
            if let limit = ColumnEdge.right(of: drawn[i].core, among: drawn.indices.filter { $0 != i }.map { drawn[$0].core }),
               drawn[i].text.maxX > limit + tolerance {
                r.spill.append(i)
            }
            for j in drawn.indices where j > i {
                if crosses(drawn[i].text, drawn[j].text) { r.overlaps.append((i, j)) }
                if crosses(drawn[i].text, drawn[j].patch) { r.cut.append((i, j)) }
                if ColumnBreak.holds(drawn[i].core, drawn[j].core) { r.holds.append((i, j)) }
            }
        }
        return r
    }

    private static func crosses(_ a: CGRect, _ b: CGRect) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > tolerance && min(a.maxY, b.maxY) - max(a.minY, b.minY) > tolerance
    }
}
