import CoreGraphics
import XCTest
@testable import MwoyeoCore

/// What a pass has read (`ReadArea`, round edges117b, film4 F5).
final class ReadAreaTests: XCTestCase {
    /// F5's capture: a lens at 772..1072 pt on the page with margins of 90 pt (30 % of 300): 682..1162, 480 x 632 pt, on a display 1512 pt across.
    private let narrow = CGSize(width: 480, height: 632)
    private let band = CGSize(width: 1512, height: 632)

    func testAPassThatNothingMovedHasReadItsFrame() {
        XCTAssertEqual(ReadArea.read(frame: narrow, moves: [], capture: narrow), CGRect(x: 0, y: 0, width: 480, height: 632))
    }

    func testAPassRebasedOntoTheBandHasReadTheNarrowCaptureNotTheBand() {
        // The Reach made the capture the band (0..1512) while the pass read the narrow one: the content moved right by 682 in the new capture's space.
        let read = ReadArea.read(frame: narrow, moves: [CGVector(dx: 682, dy: 0)], capture: band)
        XCTAssertEqual(read, CGRect(x: 682, y: 0, width: 480, height: 632))
        XCTAssertNotEqual(read, CGRect(origin: .zero, size: band), "the strips the growth uncovered are not read")
    }

    func testTheColumnTheNarrowReadCutIsUnknownAtItsRightEdgeAndTheWholeReadMakesItLookKnown() {
        // F5: the column at 771.5..1160.5 stands 1.5 pt inside the narrow read's right edge (1162), the display ends at 1512.
        let column = ColumnFit.Column(left: 771.5, right: 1160.5, top: 300, bottom: 600, blocks: 3, lines: 12)
        let display = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let read = ReadArea.read(frame: narrow, moves: [CGVector(dx: 682, dy: 0)], capture: band)
        XCTAssertFalse(ColumnFit.marked([column], capture: read, display: display)[0].rightKnown, "Fit must read wider first")
        // Called a read of the whole band (what the pipeline did), the same column looked whole, and the Fit took 1160.5 for its edge: 35 pt short of the ink (1201.5).
        XCTAssertTrue(ColumnFit.marked([column], capture: CGRect(origin: .zero, size: band), display: display)[0].rightKnown)
    }

    func testTheReadFollowsTheContentAndIsCutToTheCapture() {
        // A scroll of 100 pt up while the pass read: what was read has moved up, and its top 100 pt are outside the capture.
        XCTAssertEqual(ReadArea.read(frame: narrow, moves: [CGVector(dx: 0, dy: -100)], capture: narrow), CGRect(x: 0, y: 0, width: 480, height: 532))
        // Two moves are added.
        XCTAssertEqual(ReadArea.read(frame: narrow, moves: [CGVector(dx: 10, dy: 0), CGVector(dx: 20, dy: 0)], capture: band), CGRect(x: 30, y: 0, width: 480, height: 632))
    }
}
