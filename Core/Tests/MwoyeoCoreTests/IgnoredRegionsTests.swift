import XCTest
@testable import MwoyeoCore

/// The mask of a lens's ignored regions (design games-and-video §1): lens units, pixels of a capture, and the gray picture the changes are
/// found in. Points are global Quartz points, y down, as the lens and the capture are.
final class IgnoredRegionsTests: XCTestCase {
    private let lens = CGRect(x: 100, y: 200, width: 400, height: 200)

    func testADragInsideTheLensIsKeptAsFractionsOfIt() {
        let r = IgnoredRegions.region(dragged: CGRect(x: 120, y: 220, width: 80, height: 40), in: lens)
        XCTAssertEqual(r, UnitRect(x: 0.05, y: 0.1, width: 0.2, height: 0.2))
    }

    func testADragOverTheEdgeIsCutAtTheLens() {
        let r = IgnoredRegions.region(dragged: CGRect(x: 450, y: 380, width: 200, height: 100), in: lens)
        XCTAssertEqual(r, UnitRect(x: 0.875, y: 0.9, width: 0.125, height: 0.1))
    }

    func testADragOutsideOrTooSmallIsNoRegion() {
        XCTAssertNil(IgnoredRegions.region(dragged: CGRect(x: 600, y: 220, width: 80, height: 40), in: lens), "outside the lens")
        XCTAssertNil(IgnoredRegions.region(dragged: CGRect(x: 120, y: 220, width: 5, height: 40), in: lens), "5 pt wide is a click")
        XCTAssertNil(IgnoredRegions.region(dragged: CGRect(x: 120, y: 220, width: 80, height: 40), in: .zero))
    }

    func testTheRegionFollowsAResizeOfTheLens() {
        let r = UnitRect(x: 0.05, y: 0.1, width: 0.2, height: 0.2)
        XCTAssertEqual(r.rect(in: lens), CGRect(x: 120, y: 220, width: 80, height: 40))
        let bigger = CGRect(x: 100, y: 200, width: 800, height: 300)
        XCTAssertEqual(r.rect(in: bigger), CGRect(x: 140, y: 230, width: 160, height: 60))
        let moved = lens.offsetBy(dx: 1000, dy: -50)
        XCTAssertEqual(r.rect(in: moved), CGRect(x: 1120, y: 170, width: 80, height: 40))
    }

    func testPixelsOfACaptureThatIsLargerThanTheLens() {
        // The capture takes a margin around the lens; the picture is at 2 pixels per point.
        let capture = CGRect(x: 60, y: 170, width: 480, height: 260)
        let px = IgnoredRegions.pixels([UnitRect(x: 0.05, y: 0.1, width: 0.2, height: 0.2)], lens: lens, capture: capture, scale: 2, imageWidth: 960, imageHeight: 520)
        XCTAssertEqual(px, [PixelRect(x: 120, y: 100, width: 160, height: 80)])
    }

    func testPixelsAreRoundedOutAndKeptInsideThePicture() {
        let capture = CGRect(x: 100, y: 200, width: 400, height: 200)
        let px = IgnoredRegions.pixels([UnitRect(x: 0.333, y: 0.333, width: 0.1, height: 0.1), UnitRect(x: 0.9, y: 0.9, width: 0.1, height: 0.1)],
                                       lens: lens, capture: capture, scale: 1, imageWidth: 400, imageHeight: 200)
        XCTAssertEqual(px[0], PixelRect(x: 133, y: 66, width: 41, height: 21))
        XCTAssertEqual(px[1], PixelRect(x: 360, y: 180, width: 40, height: 20))
        // A capture that has slid away from the lens: the part outside the picture is cut, nothing is left over when none is inside.
        let off = IgnoredRegions.pixels([UnitRect(x: 0, y: 0, width: 0.1, height: 0.1)], lens: lens, capture: capture.offsetBy(dx: 300, dy: 0), scale: 1, imageWidth: 400, imageHeight: 200)
        XCTAssertEqual(off, [])
    }

    func testGrayPixelsCoverWhatTheImagePixelsDo() {
        XCTAssertEqual(IgnoredRegions.gray([PixelRect(x: 6, y: 5, width: 10, height: 7)], step: 4, width: 100, height: 100), [PixelRect(x: 1, y: 1, width: 3, height: 2)])
    }

    func testFlatGrayLeavesNoChangeInsideTheRegion() {
        // A timer ticking inside the region changes no pixel of the gray picture, so it wakes no read.
        var a = GrayImage(width: 64, height: 64, fill: 50), b = a
        for y in 10..<20 { for x in 10..<30 { a[x, y] = 250; b[x, y] = 20 } }
        let area = PixelRect(x: 8, y: 8, width: 26, height: 16)
        XCTAssertFalse(FrameDiff.changeMap(from: a, to: b).isUnchanged)
        XCTAssertTrue(FrameDiff.changeMap(from: a.filled([area]), to: b.filled([area])).isUnchanged)
        XCTAssertEqual(a.filled([area])[12, 12], 128)
        XCTAssertEqual(a.filled([area])[40, 40], 50, "outside the region the picture is as it was")
    }

    func testAnAreaPastTheEdgeIsCutNotTrapped() {
        let g = GrayImage(width: 16, height: 16, fill: 9).filled([PixelRect(x: 10, y: 10, width: 50, height: 50), PixelRect(x: -5, y: -5, width: 8, height: 8)])
        XCTAssertEqual(g[15, 15], 128)
        XCTAssertEqual(g[0, 0], 128)
        XCTAssertEqual(g[5, 5], 9)
    }

    func testAddingKeepsTheListSmallAndFree() {
        let big = UnitRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let small = UnitRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1)
        XCTAssertEqual(IgnoredRegions.adding(small, to: [big]), [big], "inside one already ignored")
        XCTAssertEqual(IgnoredRegions.adding(big, to: [small]), [big], "a region inside the new one goes")
        var list: [UnitRect] = []
        for i in 0..<(IgnoredRegions.limit + 5) { list = IgnoredRegions.adding(UnitRect(x: Double(i) * 0.05, y: 0, width: 0.04, height: 0.04), to: list) }
        XCTAssertEqual(list.count, IgnoredRegions.limit)
        XCTAssertEqual(list.last?.x ?? 0, Double(IgnoredRegions.limit + 4) * 0.05, accuracy: 1e-9, "the newest is kept, the oldest go")
    }

    func testASoundRegionIsNotTouchedByBeingChecked() {
        // A region made by a drag has fractions that are not round; saving and reading a lens must give back the same ones (game-checks: 2026-10-22).
        let r = UnitRect(x: 80.0 / 320, y: 60.0 / 180, width: 80.0 / 320, height: 40.0 / 180)
        XCTAssertEqual(IgnoredRegions.sanitized([r]), [r], "a region that lies inside the lens changed")
        let edge = UnitRect(x: 0.7, y: 0.1, width: 0.3, height: 0.9)
        XCTAssertEqual(IgnoredRegions.sanitized([edge]), [edge], "a region that ends at the lens's edge changed")
    }

    func testASavedListThatIsNotSoundIsMended() {
        let bad = [UnitRect(x: -0.2, y: 0.5, width: 0.4, height: 0.2), UnitRect(x: 0.5, y: 0.5, width: 0, height: 0.2),
                   UnitRect(x: .nan, y: 0, width: 0.1, height: 0.1), UnitRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5)]
        let mended = IgnoredRegions.sanitized(bad)
        XCTAssertEqual(mended.count, 2)
        XCTAssertEqual(mended[0].x, 0, accuracy: 1e-9); XCTAssertEqual(mended[0].width, 0.2, accuracy: 1e-9)
        XCTAssertEqual(mended[1].width, 0.1, accuracy: 1e-9); XCTAssertEqual(mended[1].height, 0.1, accuracy: 1e-9)
        XCTAssertEqual(IgnoredRegions.sanitized((0..<30).map { UnitRect(x: 0, y: 0, width: 0.1 + Double($0) / 100, height: 0.1) }).count, IgnoredRegions.limit)
    }

    func testThePictureTheReaderGetsHasTheAreaInTheColourAroundIt() {
        // A light page with dark "glyphs" in the area and a strip of darker page beside it: the area takes the colour of the ring, not a fixed one.
        var page = RGBAImage(width: 40, height: 30, color: RGBA(240, 240, 240))
        for y in 10..<20 { for x in 10..<30 where (x + y) % 3 == 0 { page.set(x: x, y: y, RGBA(0, 0, 0)) } }
        let area = PixelRect(x: 10, y: 10, width: 20, height: 10)
        let filled = page.filled([area])
        for y in 10..<20 { for x in 10..<30 { XCTAssertEqual(filled.color(x: x, y: y), RGBA(240, 240, 240), "(\(x), \(y)) still has what was there") } }
        XCTAssertEqual(filled.color(x: 9, y: 10), page.color(x: 9, y: 10), "a pixel outside the area changed")
        XCTAssertEqual(filled.color(x: 30, y: 19), page.color(x: 30, y: 19))
        XCTAssertEqual(page.color(x: 11, y: 10), RGBA(0, 0, 0), "the source picture changed")
    }

    func testTheAreaAtThePictureEdgeTakesWhatRingThereIsAndAWholePictureTakesGray() {
        var page = RGBAImage(width: 20, height: 20, color: RGBA(10, 20, 30))
        page.set(x: 2, y: 2, RGBA(255, 255, 255))
        let corner = page.filled([PixelRect(x: 0, y: 0, width: 4, height: 4)])
        XCTAssertEqual(corner.color(x: 2, y: 2), RGBA(10, 20, 30), "a corner area has two sides of ring")
        let whole = page.filled([PixelRect(x: -3, y: -3, width: 40, height: 40)])
        XCTAssertEqual(whole.color(x: 7, y: 7), RGBA(128, 128, 128))
        XCTAssertEqual(page.filled([PixelRect(x: 30, y: 30, width: 4, height: 4)]), page, "an area outside the picture changed it")
    }
}
