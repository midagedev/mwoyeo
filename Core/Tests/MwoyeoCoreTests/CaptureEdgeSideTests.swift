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
        // Four lines end at the edge; the short last line and the lines that end 18 px short of it are whole.
        #expect(cut(lines) == Set([clear.count, clear.count + 2, clear.count + 3, clear.count + 6]))
    }

    @Test func bothEdgesAtOnce() {
        let lines = clear + leftColumn + rightColumn
        let expected = Set(clear.count..<(clear.count + leftColumn.count)).union([clear.count + leftColumn.count, clear.count + leftColumn.count + 2,
                                                                               clear.count + leftColumn.count + 3, clear.count + leftColumn.count + 6])
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
        #expect(cut(clear + [r(600, 400, 660.5 - 0, 30), r(600, 440, 660.5, 30), r(600, 480, 660.5, 30)]).isEmpty, "1260.5 px is not touching")
    }

    @Test func aLineSixPixelsFromTheEdgeIsClearOfIt() {
        // The picture's only clear line: with it the column is cut, as it is with any other line (no edge, no tight crop).
        let lines = [r(0, 400, 600, 30), r(2, 440, 600, 30), r(0, 480, 600, 30), r(6, 520, 300, 30)]
        #expect(cut(lines) == [0, 1, 2])
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

    @Test func theTopAndBottomRuleIsAsBefore() {
        // `cutAtSides` is the sides' rule only: the lines of a side-cut column that stand at the top or bottom edge are not its business.
        let lines = clear + [r(0, 0, 610, 14), r(0, 400, 610, 30), r(0, 440, 610, 30), r(0, 480, 610, 30)]
        #expect(CaptureEdge.cutAtSides(lines, in: crop) == [clear.count, clear.count + 1, clear.count + 2, clear.count + 3])
        #expect(CaptureEdge.cut(lines, in: crop) == [clear.count])
    }
}
