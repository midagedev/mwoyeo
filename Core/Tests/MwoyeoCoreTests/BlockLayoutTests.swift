import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// Shapes of page 4 of arXiv 1706.03762 at 3 px per point (line boxes about 36 px tall on a 40 px pitch, a text column from
/// x=320 to x=1512): modelled on the translated render and the `.fast` reading of the page, not a recorded revision 3 output.
/// A block here is just its line boxes.
@Suite struct BlockLayoutTests {
    private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    // MARK: Merge

    @Test func aLineCutByAnInlineSumIsOneBlock() {
        // Footnote 4, recorded (revision 3 + ParagraphGrouper, this page, 3 px per point): the first block is two lines, the second
        // ends with "q · k = ak"; "i=1 9iki, has mean 0 and variance dk." is a block of its own that starts 34 px before the
        // first block's second line ends (the limits of the sum are stacked, so the boxes reach into each other).
        let a = [r(358, 2106, 1152, 27), r(320, 2137, 811, 35)]
        let b = [r(1097, 2138, 414, 34)]
        #expect(BlockMerge.groups([a, b]) == [[0, 1]])
    }

    @Test func theFootnoteLinesTheDocumentModelReadsApartAreTwoBlocks() {
        // The same footnote as the document model reads it (recorded): its first line and the rest, their boxes 4 px into each other.
        // Two paragraphs the reader chose; the patches are cut apart (below) instead.
        let a = [r(361, 2103, 1158, 34)], b = [r(321, 2133, 1192, 39)]
        #expect(BlockMerge.groups([a, b]) == [[0], [1]])
    }

    @Test func twoItemsOnOneRowFarApartStayApart() {
        // A menu: items three heights apart are two things.
        let a = [r(100, 40, 120, 30)], b = [r(310, 41, 90, 30)]
        #expect(BlockMerge.groups([a, b]) == [[0], [1]])
    }

    @Test func aTallLineThatReachesIntoTheBlockAboveJoinsIt() {
        // "of 1/√dk. Additive attention computes ..." starts with a fraction: its box reaches up over the descenders of the
        // line above, which ends the block above.
        let above = [r(320, 1470, 1190, 34), r(320, 1510, 1190, 40)]
        let below = [r(320, 1525, 1190, 66), r(320, 1590, 1190, 34)]
        #expect(BlockMerge.groups([above, below]) == [[0, 1]])
    }

    @Test func stackedParagraphsStayApart() {
        // 30 px between paragraphs of 36 px lines.
        let a = [r(320, 100, 1190, 36), r(320, 140, 1190, 36)]
        let b = [r(320, 206, 1190, 36), r(320, 246, 800, 36)]
        #expect(BlockMerge.groups([a, b]) == [[0], [1]])
    }

    @Test func linesOfOneParagraphThatTouchDoNotMakeTheBlocksAboveAndBelowOne() {
        // Neighbouring lines overlap by a few pixels (descenders into ascenders): not an interlock.
        let a = [r(320, 100, 1190, 36)], b = [r(320, 132, 1190, 36)]
        #expect(BlockMerge.groups([a, b]) == [[0], [1]])
    }

    @Test func columnsSideBySideStayApartEvenWithANarrowGutter() {
        // The gutter is under two heights, but the columns share row after row, not one.
        let left = [r(100, 100, 500, 36), r(100, 140, 500, 36)]
        let right = [r(660, 100, 500, 36), r(660, 140, 500, 36)]
        #expect(BlockMerge.groups([left, right]) == [[0], [1]])
    }

    @Test func aLoneLineBesideALoneLineIsNotJoined() {
        // A name and its time, a toolbar: one line each, close together, the way the document reader groups them.
        let a = [r(100, 40, 120, 30)], b = [r(240, 44, 80, 24)]
        #expect(BlockMerge.groups([a, b]) == [[0], [1]])
    }

    @Test func labelsOfAFigureBesideEachOtherStayApart() {
        // Recorded under the attention diagram: "→" and "Q" read as a two-line block, "K" beside "Q" one line further right.
        let arrowAndQ = [r(548, 607, 17, 20), r(548, 635, 31, 20)], k = [r(610, 635, 31, 24)]
        #expect(BlockMerge.groups([arrowAndQ, k]) == [[0], [1]])
    }

    @Test func aFractionAtTheEndOfTheParagraphsLastLineJoinsIt() {
        // Recorded: "... we scale the dot products by" ends at x=1314; "1/√dk" is read apart as "Vari" at its end.
        let paragraph = [r(324, 1786, 1194, 34), r(324, 1812, 990, 34)]
        let fraction = [r(1318, 1830, 62, 31)]
        #expect(BlockMerge.groups([paragraph, fraction]) == [[0, 1]])
    }

    @Test func aPieceBesideAMiddleLineIsLeftToTheTerritory() {
        // An inline formula in the third line of a four-line paragraph: its right half is a block of its own, and stays one (the
        // patches are cut apart); only the end of a paragraph is told from a cell of a table by its position.
        let paragraph = [r(320, 100, 1190, 36), r(320, 140, 1190, 36), r(320, 180, 900, 36), r(320, 220, 1190, 36)]
        let piece = [r(1280, 184, 230, 36)]
        #expect(BlockMerge.groups([paragraph, piece]) == [[0], [1]])
    }

    @Test func aTableHeaderWithATwoLineCellBesideSingleLineCellsStaysApart() {
        // Recorded, Table 1 of the paper: "Complexity per Layer", "Sequential / Operations", "Maximum Path Length", the tops aligned.
        let complexity = [r(707, 351, 282, 34)], sequential = [r(1019, 351, 133, 29), r(1014, 385, 138, 30)], path = [r(1167, 351, 296, 34)]
        #expect(BlockMerge.groups([complexity, sequential, path]) == [[0], [1], [2]])
    }

    @Test func aLoneLineInTheNextColumnBesideTheLastLineStaysApart() {
        let left = [r(100, 100, 500, 36), r(100, 140, 500, 36), r(100, 180, 300, 36)]
        let heading = [r(660, 182, 500, 36)]
        #expect(BlockMerge.groups([left, heading]) == [[0], [1]])
    }

    @Test func joinedLinesReadRowsLeftToRight() {
        // The piece on the right has the taller box and so the smaller top.
        let lines = [r(1385, 2118, 125, 48), r(320, 2085, 1190, 36), r(320, 2125, 1020, 40)]
        #expect(BlockMerge.readingOrder(lines) == [1, 2, 0])
    }

    // MARK: Territory

    @Test func patchesOfBlocksInTheSameColumnAreCutApartInTheGap() {
        // Two paragraphs 12 px apart, each asking for 8 px of margin on top and 12 below (descenders).
        let cores = [r(320, 100, 1190, 76), r(320, 188, 1190, 76)]
        let wants = cores.map { Territory.want(core: $0, lineHeight: 36, ring: 8) }
        #expect(wants[0].maxY > wants[1].minY)
        let out = Territory.trim(cores: cores, wants: wants)
        #expect(out[0].maxY <= out[1].minY)
        // The upper block keeps the larger share: it asked for the descender strip.
        #expect(out[0].maxY - cores[0].maxY > cores[1].minY - out[1].minY)
        // Nothing but the contested strip is taken.
        #expect(out[0].minY == wants[0].minY && out[1].maxY == wants[1].maxY)
    }

    @Test func patchesThatDoNotMeetStayAsAsked() {
        let cores = [r(320, 100, 1190, 76), r(320, 300, 1190, 76)]
        let wants = cores.map { Territory.want(core: $0, lineHeight: 36, ring: 8) }
        #expect(Territory.trim(cores: cores, wants: wants) == wants)
    }

    @Test func coresThatOverlapAreCutInTheMiddleOfTheOverlap() {
        let cores = [r(320, 100, 1190, 40), r(320, 130, 1190, 40)]
        let wants = cores.map { $0.insetBy(dx: -8, dy: -8) }
        let out = Territory.trim(cores: cores, wants: wants)
        #expect(out[0].maxY == 135 && out[1].minY == 135)
    }

    @Test func theFootnoteLinesOfTheDocumentModelDoNotShareAPixel() {
        // Recorded: 361,2103,1158,34 and 321,2133,1192,39 (rings of 6 px, descenders 10 px).
        let cores = [r(361, 2103, 1158, 34), r(321, 2133, 1192, 39)]
        let wants = cores.map { Territory.want(core: $0, lineHeight: 34, ring: 6) }
        let out = Territory.trim(cores: cores, wants: wants)
        #expect(out[0].maxY <= out[1].minY)
        #expect(out[0].maxY == 2135)   // the boxes overlap by 4 px (2133...2137): the cut runs through the middle of that
    }

    @Test func blocksSideBySideAreCutAlongTheOtherAxis() {
        let cores = [r(100, 100, 300, 40), r(410, 100, 300, 40)]
        let wants = cores.map { $0.insetBy(dx: -8, dy: -8) }
        let out = Territory.trim(cores: cores, wants: wants)
        #expect(out[0].maxX <= out[1].minX)
        #expect(out[0].minY == wants[0].minY && out[0].maxY == wants[0].maxY)
    }

    @Test func noTwoPatchesShareAPixelOnADenseColumn() {
        // Ten one-line blocks 6 px apart, each asking for more than the gap.
        let cores = (0..<10).map { r(0, Double($0) * 46, 400, 40) }
        let out = Territory.trim(cores: cores, wants: cores.map { Territory.want(core: $0, lineHeight: 40, ring: 8) })
        for i in out.indices { for j in out.indices where j > i { #expect(out[i].intersection(out[j]).isNull || out[i].intersection(out[j]).height == 0) } }
        for i in out.indices { #expect(out[i].contains(cores[i].insetBy(dx: 0, dy: 3))) }
    }

    @Test func theTextAreaIsTheSourceWithItsMarginNotTheDescenderStrip() {
        let core = r(320, 100, 1190, 76)
        let want = Territory.want(core: core, lineHeight: 36, ring: 8)
        #expect(want.maxY - core.maxY == 11)   // the descender strip: 0.3 of 36, rounded up (more than the ring)
        let area = Territory.textArea(core: core, ring: 8, spare: 0, in: want)
        #expect(area == core.insetBy(dx: -8, dy: -8))
    }

    @Test func aTrimmedPatchLimitsTheTextArea() {
        let core = r(320, 100, 1190, 76)
        let trimmed = r(312, 92, 1206, 90)   // cut 2 px above the core's own margin below
        #expect(Territory.textArea(core: core, ring: 8, spare: 0, in: trimmed).maxY == 182)
        let roomy = r(312, 92, 1206, 110)    // 18 px under the core: the area still stops at the ring
        #expect(Territory.textArea(core: core, ring:8, spare: 0, in: roomy).maxY == 184)
    }

    @Test func theSpareToTheRightIsPartOfTheTextArea() {
        // The renderer takes the spare off the area's width to find the source's own width: the area has to hold it, or the text
        // wraps that much narrower than the source did (found on the first render of this round).
        let core = r(320, 100, 1190, 76)
        let patch = r(312, 92, 1206 + 315, 110)
        let area = Territory.textArea(core: core, ring: 8, spare: 315, in: patch)
        #expect(area.maxX == patch.maxX)
        #expect(area.width - 315 == core.width + 16)
    }

    // MARK: Column

    @Test func theFootnoteIsInTheBodyColumnWhichEndsAtTheBodysRightEdge() {
        let footnote = r(320, 2085, 1190, 80)
        let body = [r(320, 1560, 1192, 400), r(320, 1980, 1191, 60)]
        #expect(ColumnEdge.right(of: footnote, among: body) == 1512)
    }

    @Test func aLoneBlockHasNoColumn() {
        #expect(ColumnEdge.right(of: r(320, 100, 300, 40), among: [r(900, 100, 300, 40)]) == nil)
        #expect(ColumnEdge.right(of: r(320, 100, 300, 40), among: []) == nil)
    }

    @Test func twoColumnsEachEndAtTheirOwnEdge() {
        let left = r(100, 100, 500, 400), right = r(660, 100, 520, 400)
        #expect(ColumnEdge.right(of: left, among: [right, r(100, 520, 480, 100)]) == 600)
    }

    @Test func aBlockWiderThanItsColumnKeepsItsOwnEdge() {
        #expect(ColumnEdge.right(of: r(100, 100, 700, 40), among: [r(100, 200, 500, 40)]) == 800)
    }

    // MARK: Check

    private func drawn(_ core: CGRect, patch: CGRect? = nil, text: CGRect? = nil, _ source: String = "x") -> DrawnBlock {
        DrawnBlock(source: source, core: core, patch: patch ?? core, text: text ?? core)
    }

    @Test func aCleanPageHasNoFindings() {
        let a = drawn(r(320, 100, 1190, 76)), b = drawn(r(320, 200, 1190, 76))
        #expect(LayoutCheck.check([a, b]).summary == "layout: blocks=2 overlaps=0 spill=0 cut=0 clipped=0")
    }

    @Test func translationsThatIntersectAreCounted() {
        let a = drawn(r(320, 100, 1190, 76), text: r(320, 100, 1190, 90))
        let b = drawn(r(320, 170, 1190, 76))
        let report = LayoutCheck.check([a, b])
        #expect(report.overlaps.count == 1 && report.overlaps[0] == (0, 1))
    }

    @Test func aLaterPatchOverTheEarlierTextIsACut() {
        let a = drawn(r(320, 100, 1190, 76))
        let b = drawn(r(320, 200, 1190, 76), patch: r(312, 170, 1206, 120))
        let report = LayoutCheck.check([a, b])
        #expect(report.cut.count == 1 && report.cut[0] == (0, 1))
        // The other way round, the earlier patch is under the later text: nothing is cut.
        #expect(LayoutCheck.check([b, a]).cut.isEmpty)
    }

    @Test func textPastTheColumnEdgeIsSpill() {
        let body = drawn(r(320, 300, 1192, 400))
        let wide = drawn(r(320, 100, 1190, 40), text: r(320, 100, 1370, 40))
        let report = LayoutCheck.check([wide, body])
        #expect(report.spill == [0])
    }

    @Test func touchingEdgesAreNotAnIntersection() {
        let a = drawn(r(0, 0, 100, 40)), b = drawn(r(0, 40.5, 100, 40))
        #expect(LayoutCheck.check([a, b]).overlaps.isEmpty)
    }
}
