import CoreGraphics

/// What a lens shows of a block that crosses one of its edges (round edges117, docs/design/recognition.md §16.2). The lens is a window on the
/// translated page: a line of text is shown whole or not at all, and the translation keeps its place while the lens moves.
///
/// | Edge | What the lens shows | Owner of the picture |
/// |---|---|---|
/// | top, bottom | the translation's lines that stand wholly in it (`shown`); the others are masked, the mask moves with the lens | the overlay, per frame of a drag: no re-read, no re-render |
/// | left, right | the translation laid out again in the part of the block the lens covers (`plan`); not drawn when that is too little | the pipeline, once per settle |
/// | none | the block as it was drawn, byte for byte | |
///
/// All rects are one unit and one space (the caller maps them): pixels of the capture for `plan`, whatever the layer uses for `shown`.
public enum LensWindow {
    /// A block that crosses a side edge of the lens and is covered by less than this share of its text's width is not drawn (the page's own text
    /// shows): a translation laid out in a strip of a few words a line is no reading. By the lines the source has, because a block of one line cannot
    /// wrap its translation into the room and shrinks it, and a paragraph wraps. Measured with the fitter (`MWOYEO_LENS_SWEEP`, `tools/lens-window/sweep.py`,
    /// the paper bench's 29 renders, 983 blocks, 2026-10-23): the narrowest share, down to which at most 10 % of the blocks that read at the full width
    /// stop reading (the fitter returns the smallest size it may, or the translation is cut to "…"). One line 0.70 (581 blocks), two 0.45 (123), three to
    /// five 0.35 (149), six and more 0.35 (87); the paragraphs of three lines and more first fail more than 10 % at 0.30 (28 %).
    public static let minShares: [(lines: Int, share: CGFloat)] = [(1, 0.70), (2, 0.45), (3, 0.35)]

    /// The floor for a block whose source has `lines` lines.
    public static func minShare(lines: Int) -> CGFloat { minShares.last { $0.lines <= max(1, lines) }?.share ?? 0 }

    /// A line is shown when the lens's edge has not cut into its ink by more than a little. The ink of a Hangul line stands inside its box (the line box holds the
    /// font's ascent and descent: the ink starts 0.13 of the box's height from its top and ends 0.04 from its bottom, medians), and an edge that takes the tops of a few
    /// glyphs takes next to nothing of what is read. `wholeInset` is how far into a line's box, as a share of its height, the lens's top edge and its bottom edge may
    /// stand and the line still be shown: the depth at which the edge has cut 10 % of the line's ink, such that at most 10 % of the lines have cut more (the allowance `minShare` is measured with too), measured on the
    /// translations of the paper bench's pages (968 lines, 13 pages, `tools/lens-window/sweep.py --ink`, docs/design/recognition.md §16.5): the top 0.209, the bottom 0.148,
    /// rounded down. Round edges117b, film4 F16: with 0.12 at both edges a line whose ink stood 1 pt (0.055 of its height) outside the lens was masked, and the page's English
    /// line showed in its place, so that the Korean seen started in the middle of the sentence.
    public static let wholeInset: (top: CGFloat, bottom: CGFloat) = (0.20, 0.14)

    /// A translation laid out in the part of its block that the lens covers keeps this far from the lens's edge, in line heights: the first
    /// syllable does not touch the frame, and the lens's clip has a 12 pt corner.
    public static let edgeInset: CGFloat = 0.3

    /// Where in its block a translation is laid out.
    public enum Plan: Equatable, Sendable {
        /// The block's own layout: its text lies in the lens, or none of it does. Drawn as it always was.
        case whole
        /// Laid out again between these x (the part of the block's text that the lens covers, less `edgeInset` at each side it cuts).
        case narrowed(ClosedRange<CGFloat>)
        /// Not drawn: the lens covers less than `minShare` of the text's width.
        case hidden
    }

    /// The rule for the lens's left and right edges. `text` is the block's source text (the union of its `lines` lines, of `lineHeight` each): what the
    /// translation stands for. Only x counts; the lens's top and bottom are `shown`'s.
    public static func plan(text: CGRect, lens: CGRect, lineHeight: CGFloat, lines: Int = 3) -> Plan {
        guard text.width > 0 else { return .whole }
        let covered = min(text.maxX, lens.maxX) - max(text.minX, lens.minX)
        if text.minX >= lens.minX, text.maxX <= lens.maxX { return .whole }
        // Nothing of it stands in the lens: it is laid out as it is, ready for a lens that comes over it (the overscan's point).
        guard covered > 0 else { return .whole }
        guard covered / text.width >= minShare(lines: lines) else { return .hidden }
        let inset = edgeInset * lineHeight
        var lower = max(text.minX, lens.minX), upper = min(text.maxX, lens.maxX)
        if text.minX < lens.minX { lower += inset }
        if text.maxX > lens.maxX { upper -= inset }
        guard upper > lower else { return .hidden }
        return .narrowed(lower...upper)
    }

    /// What the lens shows of a translation's lines, whole ones only.
    public enum Shown: Equatable, Sendable {
        /// Every line stands in the lens: nothing is masked.
        case all
        /// The lines that stand in it are the band from `top` to `bottom` (the first whole line's top, the last whole line's bottom: they are neighbours, a lens is a rect).
        /// A side of the lens that cuts no line of the block has no edge in the band: it is nil, and the layer shows to its own end there (round edges117b, film4 F1: a
        /// lens that cut the block at the bottom only masked its erased background at the top too, and the page's English line above the first Korean line showed).
        case band(top: CGFloat?, bottom: CGFloat?)
        /// No line does.
        case none
    }

    /// The rule for the lens's top and bottom edges: `lines` are the translation's line boxes, `lens` the lens, in one space. A line is shown when it is whole in the
    /// lens (`wholeInset`); the band ends at a line's box on the side where the lens cuts a line, and nowhere on the side where it does not.
    public static func shown(lines: [CGRect], lens: CGRect) -> Shown {
        guard !lines.isEmpty else { return .all }
        var whole: [CGRect] = [], cutAbove = false, cutBelow = false
        for l in lines {
            let above = l.minY + l.height * wholeInset.top < lens.minY, below = l.maxY - l.height * wholeInset.bottom > lens.maxY
            cutAbove = cutAbove || above
            cutBelow = cutBelow || below
            if !above, !below { whole.append(l) }
        }
        guard cutAbove || cutBelow else { return .all }
        guard let first = whole.map(\.minY).min(), let last = whole.map(\.maxY).max() else { return .none }
        return .band(top: cutAbove ? first : nil, bottom: cutBelow ? last : nil)
    }

    /// What the lens does to the blocks it meets, counted (`RegionPipeline` puts it in the trace; the numbers of film4's F1 and F2): of the translation's
    /// lines that the lens meets, how many it cuts, how many of those it shows anyway (a cut at a side always, one at the top or bottom unless the overlay
    /// masks it: `masksRows`), and the blocks that stand in it as fragments (drawn as they stand, the lens covering `minShare` of their text's width or less).
    public struct Census: Equatable, Sendable {
        public var lines = 0, cut = 0, shown = 0, blocksCut = 0, fragments = 0
        public init() {}
    }

    /// One drawn block: its source text, the height of its source lines and its translation's line boxes, in the space of the lens.
    public struct Drawn: Sendable {
        public var text: CGRect
        public var lineHeight: CGFloat
        public var sourceLines: Int
        public var lines: [CGRect]
        public init(text: CGRect, lineHeight: CGFloat, sourceLines: Int = 3, lines: [CGRect]) {
            self.text = text
            self.lineHeight = lineHeight
            self.sourceLines = sourceLines
            self.lines = lines
        }
    }

    public static func census(_ blocks: [Drawn], lens: CGRect, masksRows: Bool) -> Census {
        var c = Census()
        for b in blocks {
            if b.text.intersects(lens), plan(text: b.text, lens: lens, lineHeight: b.lineHeight, lines: b.sourceLines) == .hidden { c.fragments += 1 }
            var any = false
            for l in b.lines where l.intersects(lens) {
                c.lines += 1
                let side = l.minX < lens.minX - 1 || l.maxX > lens.maxX + 1, row = shown(lines: [l], lens: lens) != .all
                guard side || row else { continue }
                c.cut += 1
                any = true
                if side || !masksRows { c.shown += 1 }
            }
            if any { c.blocksCut += 1 }
        }
        return c
    }
}

extension LensWindow {
    /// Whether the lens sits in a paragraph that the capture's side cut: the paragraph is the column the lens is over, so that it stands in `ColumnFit.columns` (Fit
    /// finds it, film4 F17) and a read of the whole column is worth asking for (`Reach`). `text` is the part the capture read. The lens holds `ColumnFit.need` of its
    /// own width of it (the share `ColumnFit.under` calls "under the lens": a lens that only brushes the next column's start, a hand drawn a few points over, is not in
    /// it, and a read of that column would only be hidden below `minShare`), and `plan` does not leave it undrawn (the covered part of what was read is `minShare` or more:
    /// the share of the whole column is smaller or equal, so a paragraph the plan hides now stays hidden when it is read whole). Measured on hold117's gate (round edges117,
    /// 2026-10-23): a lens 71 pt into a cut column, 14 % of its width and 44 % of the part read, took the capture to the display's width and read the page again at each hand
    /// resize that followed (a column that holds 0.4 of the lens's width is where F16's lens is: 100 %).
    public static func sitsIn(text: CGRect, lens: CGRect, lineHeight: CGFloat, lines: Int = 3) -> Bool {
        guard lens.width > 0, text.intersects(lens) else { return false }
        let covered = min(text.maxX, lens.maxX) - max(text.minX, lens.minX)
        guard covered / lens.width >= ColumnFit.need else { return false }
        return plan(text: text, lens: lens, lineHeight: lineHeight, lines: lines) != .hidden
    }
}

/// Whether a lens asks its capture to grow to the column of a paragraph the capture's side cut (round edges117, film4 F16: a lens drawn short of its column by more than
/// the capture's margin showed the page's English, since every line of its paragraph ended at the capture's edge and was left out). One answer for the session, so that
/// the rule that stops a loop is one that a test can break: the capture grows once (the band, `Overscan.band`), and a read that is still cut after it, because the
/// column runs past the display, does not ask again. The next ask is after the lens has been moved or resized, which gives the band up.
public enum Reach {
    public static func wants(cut: Bool, widened: Bool, probing: Bool, handOn: Bool) -> Bool { cut && !widened && !probing && !handOn }
}

