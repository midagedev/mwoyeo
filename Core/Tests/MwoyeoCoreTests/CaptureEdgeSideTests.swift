import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// The lines a capture cuts at its left and right edge (round read117, A5/F2: a lens that overshoots into the next column made the
/// capture end inside that column, and the cut line starts were translated word by word and drawn over the English). The boxes are the
/// paper bench's side-cut crop of page 12 (`p12-s1`, 1265 x 1000 px, the document reader's lines): the crop's left edge runs through the
/// words of the left column (every line starts at x = 0), its right edge through those of the right column (`656 + 606 = 1262`).
@Suite struct CaptureEdgeSideTests {
    private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    private let crop = CGRect(x: 0, y: 0, width: 1265, height: 1000)

    /// The 14 lines of the left column that the crop's left edge cuts (they start at x = 0 and end where the column's text does).
    private var leftColumn: [CGRect] {
        [r(0, 383, 610, 29), r(0, 414, 612, 27), r(0, 447, 139, 22), r(0, 651, 612, 31), r(0, 685, 610, 29), r(0, 716, 612, 27),
         r(0, 745, 617, 31), r(0, 778, 610, 34), r(0, 812, 610, 29), r(0, 843, 610, 29), r(0, 877, 610, 22), r(0, 908, 610, 29),
         r(0, 937, 617, 32), r(0, 972, 610, 24)]
    }

    /// Lines of the right column: four end at the crop's edge (the text goes on), the others end short of it.
    private var rightColumn: [CGRect] {
        [r(656, 129, 606, 25), r(656, 158, 425, 27), r(656, 300, 606, 30), r(654, 335, 608, 27), r(652, 365, 594, 33),
         r(656, 545, 591, 27), r(656, 577, 606, 31)]
    }

    /// Lines the edges do not touch: the authors, a heading, a figure's words.
    private var clear: [CGRect] { [r(14, 29, 596, 31), r(14, 60, 602, 31), r(37, 312, 190, 32), r(36, 531, 585, 42)] }

    private func cut(_ lines: [CGRect]) -> Set<Int> { CaptureEdge.cutAtSides(lines, in: crop) }

    // MARK: A column the edge runs through

    @Test func theLinesOfAColumnCutAtTheLeftEdgeAreCut() {
        let lines = clear + leftColumn
        #expect(cut(lines) == Set(clear.count..<lines.count))
    }

    @Test func theLinesOfAColumnCutAtTheRightEdgeAreTheOnesThatReachIt() {
        let lines = clear + rightColumn
        // Re-pinned 2026-10-23 (round edges117b, `CaptureEdge.rightSlack` 0.7): this expected only the four lines that end 3 px short of the crop's edge and called the two that end 19 and 18 px
        // short (indices 4 and 5) whole. They are cut: the uncut page of this paper (`p12`) reads the line 'Each result is produced' 656 px wide where the crop's box is 591 px, so
        // that line goes on past the crop's edge; the document reader's box ended 18 px (0.67 of the 27 px line) short of the glyph the edge cut. Both stand within 0.7 of their height of the edge
        // (19 of 33 px: 0.58, 18 of 27: 0.67). Only the one-line last paragraph line (ends 184 px short) is whole. FAIL-first: with `rightSlack = 0` this finds four lines, not six.
        #expect(cut(lines) == Set([clear.count, clear.count + 2, clear.count + 3, clear.count + 4, clear.count + 5, clear.count + 6]))
    }

    @Test func bothEdgesAtOnce() {
        let lines = clear + leftColumn + rightColumn
        let right = clear.count + leftColumn.count
        let expected = Set(clear.count..<right).union([right, right + 2, right + 3, right + 4, right + 5, right + 6])
        #expect(cut(lines) == expected)
    }

    @Test func theIndicesAreThoseOfTheLinesPassed() {
        let lines = leftColumn.prefix(3).map { $0 } + clear
        #expect(cut(lines) == [0, 1, 2])
    }

    @Test func aLineThatIsFarFromBothEdgesIsNotCut() {
        #expect(cut(clear + [r(4.5, 700, 300, 30)]).isEmpty, "4.5 px is not touching (the tolerance is 4)")
        #expect(cut(clear + [r(0, 700, 300, 30), r(0, 740, 300, 30), r(5, 780, 300, 30)]).isEmpty, "two touching lines are not a column")
    }

    @Test func theBoxOfACutLineEndsWithinFourPixelsOfTheEdgeAsOftenAsAtIt() {
        // Measured as for the top and bottom (`CaptureEdge.tolerance`): the recognizer's boxes follow the glyphs it saw.
        let left = [r(3, 400, 600, 30), r(4, 440, 600, 30), r(0, 480, 600, 30)]
        #expect(cut(clear + left) == [clear.count, clear.count + 1, clear.count + 2])
        let right = [r(600, 400, 1262 - 600, 30), r(600, 440, 1261 - 600, 30), r(600, 480, 1265 - 600, 30)]
        #expect(cut(clear + right) == [clear.count, clear.count + 1, clear.count + 2])
        #expect(cut(clear + [r(4.5, 400, 600, 30), r(5, 440, 600, 30), r(0, 480, 600, 30)]).isEmpty, "4.5 px is not touching")
        // Re-pinned 2026-10-23 (round edges117b, `CaptureEdge.rightSlack`): these right ends stood 4.5 px from the edge and were "not touching" at a tolerance of 4 px. The right edge reaches
        // 0.7 of a glyph (21 px for these 30 px lines, derived there); the lines that stay clear end 30 px (one line height) short of it.
        #expect(cut(clear + [r(600, 400, 1235 - 600, 30), r(600, 440, 1235 - 600, 30), r(600, 480, 1235 - 600, 30)]).isEmpty, "1235 px, 30 short of the edge, is not touching")
    }

    @Test func aLineSixPixelsFromTheEdgeIsClearOfIt() {
        // The picture's only clear line: with it the column is cut, as it is with any other line (no edge, no tight crop).
        let lines = [r(0, 400, 600, 30), r(2, 440, 600, 30), r(0, 480, 600, 30), r(6, 520, 300, 30)]
        #expect(cut(lines) == [0, 1, 2])
    }

    @Test func aCutLineOfTheRightEdgeEndsUpToAGlyphShortOfIt() {
        // F5 (film4 take, edges117b): the lines reader as the app runs it ends the lines of a cut paragraph 1, 10, 16 and 17 px short of the capture's right edge (1000 px) for lines
        // 28 and 29 px high (`lens-window-checks`' paragraph): one line reached it within the 4 px tolerance, the paragraph was not flagged cut, and its translation was drawn.
        let capture = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let heading = r(81, 20, 300, 29)
        // The ends: 999, 990, 984 and 983 px, 1, 10, 16 and 17 px short of the edge (0.03, 0.36, 0.55 and 0.61 of the lines' 28 and 29 px).
        let paragraph = [r(81, 67, 918, 29), r(81, 111, 909, 28), r(81, 154, 903, 29), r(81, 199, 902, 28)]
        let lines = [heading] + paragraph
        #expect(CaptureEdge.cutAtSides(lines, in: capture) == [1, 2, 3, 4])
        // The reach grows with the line, the left edge keeps the tolerance, and a small label keeps the floor.
        #expect(abs(CaptureEdge.reach(r(0, 0, 100, 30), .right) - 21) < 0.001)
        #expect(CaptureEdge.reach(r(0, 0, 100, 30), .left) == CaptureEdge.tolerance)
        #expect(CaptureEdge.reach(r(0, 0, 100, 4), .right) == CaptureEdge.tolerance)
        // A column of vertical text (a tall, narrow box) reaches by its glyph, not by its length: 0.7 of 55 px, not of 914.
        #expect(abs(CaptureEdge.reach(r(1172, 83, 55, 914), .right) - 38.5) < 0.001)
    }

    // MARK: What is not a column cut by the capture

    @Test func aHeadingOrTwoAtTheEdgeOfAPictureIsNotACutColumn() {
        // The use-case bench's pictures cropped to the top left of a page: the title stands at x = 0 (d01, d02, d04, d05).
        let page = CGRect(x: 0, y: 0, width: 1440, height: 1120)
        let headings = [r(0, 4, 203, 46), r(2, 219, 200, 47)]
        let body = [r(120, 100, 503, 30), r(120, 140, 480, 30), r(120, 290, 500, 30)]
        #expect(CaptureEdge.cutAtSides(headings + body, in: page).isEmpty)
        #expect(CaptureEdge.cutAtSides([r(0, 5, 287, 62)] + body, in: CGRect(x: 0, y: 0, width: 1600, height: 1040)).isEmpty)
    }

    @Test func aPictureCroppedToItsTextCutsNothing() {
        // Every line touches the edges: there is no line to say the capture ends inside the text, and a picture cropped to a justified
        // paragraph (or to a log) looks the same.
        let strip = CGRect(x: 0, y: 0, width: 600, height: 140)
        let lines = [r(0, 2, 600, 30), r(0, 36, 600, 30), r(1, 70, 598, 30), r(0, 104, 600, 30)]
        #expect(CaptureEdge.cutAtSides(lines, in: strip).isEmpty)
        #expect(CaptureEdge.cutAtSides([], in: strip).isEmpty)
    }

    @Test func aFullWidthLineIsNoSideCut() {
        // The top and bottom rule's own case (`CaptureEdge.cut`): one line across the whole capture.
        #expect(cut(clear + [r(0, 400, 1265, 30)]).isEmpty)
    }

    // MARK: Which old blocks a capture's cut leaves in place

    @Test func aBlockThatEndsAtTheEdgeWasReadCutAndOneThatGoesOnPastItWasReadWhole() {
        // F5 (film4, edges117b): the capture is 960 x 1264 px, its right edge runs through a column. The first read drew its line ends ('The predictor keeps ... posi',
        // 'delivery la') and the later reads, which cut the column, kept them in place for the wide read: they end at the edge (957 of 960), nothing lies beyond to hold for.
        let frame = CGRect(x: 0, y: 0, width: 960, height: 1264)
        #expect(!CaptureEdge.continuesPastSide(CGRect(x: 173, y: 239, width: 957 - 173, height: 127), in: frame), "a paragraph read cut ends at the edge")
        #expect(!CaptureEdge.continuesPastSide(CGRect(x: 793, y: 371, width: 957 - 793, height: 32), in: frame), "so does the fragment 'delivery la'")
        #expect(!CaptureEdge.continuesPastSide(CGRect(x: 173, y: 239, width: 964 - 173, height: 127), in: frame), "the tolerance of the other rules is 4 px")
        // A paragraph that the wide capture read whole (it ends at 1201.5 pt, 1039 px from this capture's left edge) is cut by this one: its text goes on.
        #expect(CaptureEdge.continuesPastSide(CGRect(x: 173, y: 239, width: 1039 - 173, height: 127), in: frame))
        #expect(CaptureEdge.continuesPastSide(CGRect(x: 173, y: 239, width: 964.5 - 173, height: 127), in: frame), "just past the tolerance")
        // And the left edge.
        #expect(CaptureEdge.continuesPastSide(CGRect(x: -200, y: 239, width: 500, height: 127), in: frame))
        #expect(!CaptureEdge.continuesPastSide(CGRect(x: -1, y: 239, width: 500, height: 127), in: frame))
    }

    @Test func theTopAndBottomRuleIsAsBefore() {
        // `cutAtSides` is the sides' rule only: the lines of a side-cut column that stand at the top or bottom edge are not its business.
        let lines = clear + [r(0, 0, 610, 14), r(0, 400, 610, 30), r(0, 440, 610, 30), r(0, 480, 610, 30)]
        #expect(CaptureEdge.cutAtSides(lines, in: crop) == [clear.count, clear.count + 1, clear.count + 2, clear.count + 3])
        #expect(CaptureEdge.cut(lines, in: crop) == [clear.count])
    }
}
