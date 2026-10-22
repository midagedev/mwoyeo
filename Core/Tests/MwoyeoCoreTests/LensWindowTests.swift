import XCTest
@testable import MwoyeoCore

/// What a lens shows of a block that crosses one of its edges (round edges117, docs/design/recognition.md §16.2, film4 F1 and F2).
final class LensWindowTests: XCTestCase {
    /// F1's paragraph: 432 pt wide, its text from x 100 to 532 (pixels of the capture, one unit per point here), lines 20 high.
    private let text = CGRect(x: 100, y: 200, width: 432, height: 120)
    private let lineHeight: CGFloat = 20

    private func plan(_ lens: CGRect) -> LensWindow.Plan { LensWindow.plan(text: text, lens: lens, lineHeight: lineHeight) }

    // MARK: Left and right (plan)

    func testABlockWhollyInTheLensIsLaidOutAsItWas() {
        XCTAssertEqual(plan(CGRect(x: 80, y: 150, width: 480, height: 300)), .whole)
        // A lens whose edge is exactly the text's edge still holds the text.
        XCTAssertEqual(plan(CGRect(x: 100, y: 150, width: 432, height: 300)), .whole)
    }

    func testALensShortOfTheParagraphLaysItOutInTheWidthItCovers() {
        // F1: the lens starts 30 inside the paragraph's left edge and ends 50 short of its right: 352 of 432 covered (82 %).
        let lens = CGRect(x: 130, y: 150, width: 352, height: 300)
        guard case let .narrowed(range) = plan(lens) else { return XCTFail("a lens that covers 82 % lays the text out again") }
        let inset = LensWindow.edgeInset * lineHeight
        XCTAssertEqual(range.lowerBound, 130 + inset, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 482 - inset, accuracy: 0.001)
        // The width of the layout is the covered width less the room kept from the two edges the lens cuts.
        XCTAssertEqual(range.upperBound - range.lowerBound, 352 - 2 * inset, accuracy: 0.001)
    }

    func testAnEdgeTheLensDoesNotCutKeepsTheTextsOwn() {
        // Only the right edge is cut: the layout starts where the text does.
        guard case let .narrowed(range) = plan(CGRect(x: 80, y: 150, width: 400, height: 300)) else { return XCTFail("narrowed") }
        XCTAssertEqual(range.lowerBound, 100, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 480 - LensWindow.edgeInset * lineHeight, accuracy: 0.001)
        // Only the left edge is cut.
        guard case let .narrowed(left) = plan(CGRect(x: 160, y: 150, width: 460, height: 300)) else { return XCTFail("narrowed") }
        XCTAssertEqual(left.lowerBound, 160 + LensWindow.edgeInset * lineHeight, accuracy: 0.001)
        XCTAssertEqual(left.upperBound, 532, accuracy: 0.001)
    }

    func testABlockCoveredByLessThanTheFloorIsNotDrawn() {
        // F2: the lens overshoots 22 into the next column, whose block is 200 wide: 11 % covered.
        let next = CGRect(x: 600, y: 200, width: 200, height: 120)
        XCTAssertEqual(LensWindow.plan(text: next, lens: CGRect(x: 339, y: 150, width: 283, height: 300), lineHeight: lineHeight, lines: 5), .hidden)
        // Just under and just over the floor, at one block.
        let floor = LensWindow.minShare(lines: 5)
        let under = text.minX + text.width * (1 - floor) + 1, over = text.minX + text.width * (1 - floor) - 1
        XCTAssertEqual(LensWindow.plan(text: text, lens: CGRect(x: under, y: 150, width: 1000, height: 300), lineHeight: lineHeight, lines: 5), .hidden)
        guard case .narrowed = LensWindow.plan(text: text, lens: CGRect(x: over, y: 150, width: 1000, height: 300), lineHeight: lineHeight, lines: 5) else { return XCTFail("over the floor it is laid out again") }
    }

    func testTheFloorRisesAsTheBlockHasFewerLines() {
        // A line that cannot wrap shrinks into the room it has: a heading half covered is not drawn where a paragraph half covered is.
        XCTAssertGreaterThan(LensWindow.minShare(lines: 1), LensWindow.minShare(lines: 2))
        XCTAssertGreaterThan(LensWindow.minShare(lines: 2), LensWindow.minShare(lines: 3))
        XCTAssertEqual(LensWindow.minShare(lines: 3), LensWindow.minShare(lines: 40))
        let lens = CGRect(x: text.minX + text.width * 0.5, y: 150, width: 1000, height: 300)   // 50 % of the text covered
        XCTAssertEqual(LensWindow.plan(text: text, lens: lens, lineHeight: lineHeight, lines: 1), .hidden)
        guard case .narrowed = LensWindow.plan(text: text, lens: lens, lineHeight: lineHeight, lines: 2) else { return XCTFail("two lines at 50 % are laid out again") }
        guard case .narrowed = LensWindow.plan(text: text, lens: lens, lineHeight: lineHeight, lines: 6) else { return XCTFail("six lines at 50 % are laid out again") }
    }

    func testABlockOutsideTheLensKeepsItsLayoutForALensThatComesOverIt() {
        // The overscan reads and draws what lies beside the lens, so that a drag only reveals it: nothing is cut or hidden there.
        XCTAssertEqual(plan(CGRect(x: 700, y: 150, width: 100, height: 300)), .whole)
        XCTAssertEqual(plan(CGRect(x: 0, y: 150, width: 100, height: 300)), .whole)
    }

    func testTheLensCoveringTheMiddleOfAWideBlockCutsBothSides() {
        let lens = CGRect(x: 200, y: 150, width: 250, height: 300)   // 58 % of 432
        guard case let .narrowed(range) = plan(lens) else { return XCTFail("narrowed") }
        XCTAssertEqual(range.lowerBound, 200 + 6, accuracy: 0.001)
        XCTAssertEqual(range.upperBound, 450 - 6, accuracy: 0.001)
    }

    // MARK: Top and bottom (shown)

    /// Six translation lines, 20 high, from y 200 (the line boxes of a block, pixels of one space).
    private let lines = (0..<6).map { CGRect(x: 100, y: 200 + CGFloat($0) * 20, width: 400, height: 20) }

    func testALensHoldingEveryLineMasksNothing() {
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 190, width: 900, height: 300)), .all)
        // Lines the lens's edge touches exactly are whole.
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 200, width: 900, height: 120)), .all)
    }

    func testTheLineTheBottomEdgeCutsIsHiddenAndTheOnesAboveStay() {
        // F1: the last Korean line sits on the bottom edge. The lens ends in the middle of line 5 (y 300..320).
        // The top is not cut (every line starts inside the lens), so the band has no top: the layer shows from its own edge (edges117b, F1).
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 150, width: 900, height: 160)), .band(top: nil, bottom: 300))
    }

    func testTheLineTheTopEdgeCutsIsHiddenAndTheOnesBelowStay() {
        // The lens starts in the middle of line 1 (y 220..240).
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 230, width: 900, height: 300)), .band(top: 240, bottom: nil))
    }

    func testF1TheBandOfALensThatCutsOnlyTheBottomHasNoTop() {
        // F1 (film4 take o2-drawn, edges117b): seven Korean lines of 17.5 pt in a block whose patch is a line taller than they are (the paragraph had eight English lines),
        // the lens ending in the seventh. The erased background above the first line is the block's: the band started at the first line's box and the page's English line
        // above it showed through, whole, over its own Korean.
        let seven = (0..<7).map { CGRect(x: 0, y: 22 + CGFloat($0) * 17.5, width: 330, height: 17.5) }
        let lens = CGRect(x: 0, y: 0, width: 400, height: 22 + 6 * 17.5 + 9)   // ends 9 pt into the seventh line
        XCTAssertEqual(LensWindow.shown(lines: seven, lens: lens), .band(top: nil, bottom: 22 + 6 * 17.5))
        // The same block with the lens cutting its top only: the layer shows to its own bottom.
        XCTAssertEqual(LensWindow.shown(lines: seven, lens: CGRect(x: 0, y: 22 + 17.5 + 9, width: 400, height: 400)), .band(top: 22 + 2 * 17.5, bottom: nil))
    }

    func testALensCuttingBothEdgesShowsTheLinesBetween() {
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 230, width: 900, height: 70)), .band(top: 240, bottom: 300))
    }

    func testALensTooLowForAnyLineShowsNone() {
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 205, width: 900, height: 25)), .none)
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 400, width: 900, height: 25)), .none)
    }

    func testALineOnePointOutIsWholeAndALineHalfOutIsNot() {
        // The ink of a line stands inside its box (`wholeInset`): one point of 20 is empty line box, ten is a cut glyph.
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 201, width: 900, height: 119)), .all)
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 210, width: 900, height: 110)), .band(top: 220, bottom: nil))
        // Where the top edge starts to cut more than the allowance of the ink: 0.20 of 20 = 4 from the line's top.
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 203.9, width: 900, height: 200)), .all)
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 204.1, width: 900, height: 200)), .band(top: 220, bottom: nil))
        // The bottom edge: 0.14 of 20 = 2.8 from the line's bottom (the ink of a Hangul line ends nearer to it than it starts to its top).
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 150, width: 900, height: 317.3 - 150)), .all)
        XCTAssertEqual(LensWindow.shown(lines: lines, lens: CGRect(x: 0, y: 150, width: 900, height: 316.9 - 150)), .band(top: nil, bottom: 300))
    }

    func testF16ALineWhoseInkStandsOnePointOutsideTheLensIsShown() {
        // F16 (film4, edges117b): the first Korean line's ink stood 1 pt above the lens (a 18 pt line: 0.055 of its height) and the line was masked, the page's English
        // showing in its place. The ink starts 0.13 of the box's height from its top (the paper bench's median), so the lens's top edge stood 0.186 inside the box.
        let box = CGRect(x: 0, y: 100, width: 300, height: 18)
        let inkTop = box.minY + 0.13 * box.height
        let lens = CGRect(x: 0, y: inkTop + 1, width: 400, height: 300)
        XCTAssertEqual(LensWindow.shown(lines: [box], lens: lens), .all)
        // Deeper cuts stay hidden: an edge 0.25 into the box has cut a quarter of the ink or more; and one at the bottom, 0.20 into the box, likewise.
        XCTAssertEqual(LensWindow.shown(lines: [box], lens: CGRect(x: 0, y: box.minY + 0.25 * box.height, width: 400, height: 300)), .none)
        XCTAssertEqual(LensWindow.shown(lines: [box], lens: CGRect(x: 0, y: 0, width: 400, height: box.maxY - 0.20 * box.height)), .none)
        // What the bench says of the lines: the first line of a block that sticks out of the lens by 0.2 of its height is shown, by 0.3 it is not.
        let two = [box, box.offsetBy(dx: 0, dy: 17)]
        XCTAssertEqual(LensWindow.shown(lines: two, lens: CGRect(x: 0, y: box.minY + 0.19 * box.height, width: 400, height: 300)), .all)
        XCTAssertEqual(LensWindow.shown(lines: two, lens: CGRect(x: 0, y: box.minY + 0.30 * box.height, width: 400, height: 300)), .band(top: 117, bottom: nil))
    }

    func testABlockWithNoLinesMasksNothing() {
        XCTAssertEqual(LensWindow.shown(lines: [], lens: CGRect(x: 0, y: 0, width: 10, height: 10)), .all)
    }

    // MARK: What the trace counts

    func testTheCountOfF1BeforeAndAfter() {
        // F1: six Korean lines laid out at the paragraph's width, the lens 30 inside its left edge and 50 short of the right: all six cut at a side.
        let wide = (0..<6).map { CGRect(x: 100, y: 200 + CGFloat($0) * 20, width: 432, height: 20) }
        let lens = CGRect(x: 130, y: 150, width: 352, height: 300)
        let before = LensWindow.census([.init(text: text, lineHeight: lineHeight, lines: wide)], lens: lens, masksRows: false)
        XCTAssertEqual(before.lines, 6)
        XCTAssertEqual(before.cut, 6)
        XCTAssertEqual(before.shown, 6)
        // Laid out again in the covered width: seven lines, all between the sides; the last one stands on the bottom edge, which the overlay masks.
        let narrow = (0..<7).map { CGRect(x: 136, y: 200 + CGFloat($0) * 20, width: 340, height: 20) }
        let after = LensWindow.census([.init(text: text, lineHeight: lineHeight, lines: narrow)], lens: CGRect(x: 130, y: 150, width: 352, height: 180), masksRows: true)
        XCTAssertEqual(after.lines, 7)
        XCTAssertEqual(after.cut, 1)
        XCTAssertEqual(after.shown, 0)
        XCTAssertEqual(after.blocksCut, 1)
    }

    func testAFragmentIsABlockTheLensCoversTooLittleOfThatIsDrawn() {
        let next = CGRect(x: 600, y: 200, width: 200, height: 120)
        let census = LensWindow.census([.init(text: next, lineHeight: lineHeight, lines: [CGRect(x: 600, y: 200, width: 200, height: 20)])], lens: CGRect(x: 339, y: 150, width: 283, height: 300), masksRows: true)
        XCTAssertEqual(census.fragments, 1)
        XCTAssertEqual(LensWindow.census([.init(text: text, lineHeight: lineHeight, lines: [])], lens: CGRect(x: 0, y: 0, width: 900, height: 900), masksRows: true).fragments, 0)
    }

    // MARK: The capture reaches the column

    func testTheCaptureGrowsOnceAndAReadThatIsStillCutDoesNotAskAgain() {
        // A column that runs past the display: every read of it is cut, the wider one too.
        var widened = false, asked = 0
        for _ in 0..<5 {   // five reads, all cut
            if Reach.wants(cut: true, widened: widened, probing: false, handOn: false) {
                asked += 1
                widened = true   // the session takes the band
            }
        }
        XCTAssertEqual(asked, 1)
        // The lens is moved: the band is given up, and the next cut read asks once more.
        widened = false
        XCTAssertTrue(Reach.wants(cut: true, widened: widened, probing: false, handOn: false))
    }

    func testALensSitsInTheCutParagraphItIsOverAndNotInOneItBrushes() {
        // F16: a lens 300 wide over the start of a column whose read part (the capture's cut) is 393 wide: all of the lens's width is in it.
        let column = CGRect(x: 769, y: 250, width: 393, height: 200)
        XCTAssertTrue(LensWindow.sitsIn(text: column, lens: CGRect(x: 772, y: 250, width: 300, height: 395), lineHeight: 20, lines: 8))
        // hold117's gate: a lens 520 wide that ends 71 into a cut column of 160 read: 44 % of the part read (over the floor of 0.35) but 14 % of the lens's own width.
        let next = CGRect(x: 559, y: 250, width: 160, height: 200)
        let lens = CGRect(x: 110, y: 130, width: 520, height: 350)
        XCTAssertGreaterThan(71 / next.width, LensWindow.minShare(lines: 8))
        XCTAssertFalse(LensWindow.sitsIn(text: next, lens: lens, lineHeight: 20, lines: 8))
        // A lens that only touches the column's first point, a column beside the lens, and the lens above it.
        XCTAssertFalse(LensWindow.sitsIn(text: next, lens: CGRect(x: 110, y: 130, width: 450, height: 350), lineHeight: 20, lines: 8))
        XCTAssertFalse(LensWindow.sitsIn(text: next, lens: CGRect(x: 0, y: 130, width: 100, height: 350), lineHeight: 20, lines: 8))
        XCTAssertFalse(LensWindow.sitsIn(text: column, lens: CGRect(x: 772, y: 0, width: 300, height: 100), lineHeight: 20, lines: 8))
        // The share that makes a column "under the lens" is the one Fit uses.
        let narrow = CGRect(x: 769, y: 250, width: 300, height: 200)   // 0.4 of it is 40 % of the lens's width, over the floor of its own
        let edge = narrow.minX + ColumnFit.need * 300
        XCTAssertTrue(LensWindow.sitsIn(text: narrow, lens: CGRect(x: edge - 300, y: 250, width: 300, height: 100), lineHeight: 20, lines: 8))
        XCTAssertFalse(LensWindow.sitsIn(text: narrow, lens: CGRect(x: edge - 300 - 1, y: 250, width: 300, height: 100), lineHeight: 20, lines: 8))
    }

    func testAColumnThePlanLeavesUndrawnIsNotOneTheLensSitsIn() {
        // The lens holds most of its own width of a paragraph whose read part it covers under the floor: reading it whole would only be hidden again.
        let wide = CGRect(x: 100, y: 200, width: 2000, height: 100)
        let lens = CGRect(x: 100, y: 150, width: 600, height: 300)   // 30 % of the part read, all of the lens
        XCTAssertEqual(LensWindow.plan(text: wide, lens: lens, lineHeight: 20, lines: 5), .hidden)
        XCTAssertFalse(LensWindow.sitsIn(text: wide, lens: lens, lineHeight: 20, lines: 5))
    }

    func testTheCaptureDoesNotGrowWithoutACutOrUnderAHandOrAProbe() {
        XCTAssertFalse(Reach.wants(cut: false, widened: false, probing: false, handOn: false))
        XCTAssertFalse(Reach.wants(cut: true, widened: false, probing: false, handOn: true))
        XCTAssertFalse(Reach.wants(cut: true, widened: false, probing: true, handOn: false))
    }
}

