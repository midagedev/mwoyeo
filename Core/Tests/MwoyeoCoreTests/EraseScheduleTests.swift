import XCTest
@testable import MwoyeoCore

/// When a pass's erased blocks reach the screen and the order their patches are filled in (round erase117, docs/design/first-lens.md §14).
final class EraseScheduleTests: XCTestCase {
    private let lens = CGRect(x: 100, y: 100, width: 400, height: 300)

    private func c(_ x: CGFloat, _ y: CGFloat, w: CGFloat = 200, h: CGFloat = 30, translated: Bool = false) -> EraseSchedule.Candidate {
        .init(rect: CGRect(x: x, y: y, width: w, height: h), translated: translated)
    }

    /// The order a pass fills all of `candidates` in: `next` again and again, each one taken out as it is filled.
    private func order(_ candidates: [EraseSchedule.Candidate], lead: CGVector = .zero) -> [Int] {
        var left = Array(candidates.indices), out: [Int] = []
        while let k = EraseSchedule.next(left.map { candidates[$0] }, lens: lens, lead: lead) { out.append(left.remove(at: k)) }
        return out
    }

    func testAReadThatReplacesNoBlockPutsEachBlockUpWhenItsPatchIsIn() {
        // A lens's first read, a read after a reset, the strip a scroll uncovered: nothing stands where the blocks go.
        XCTAssertEqual(EraseSchedule.install(replacing: 0), .eachWhenFilled)
    }

    func testAReadThatReplacesBlocksSwapsThemAllAtOnce() {
        // The old blocks may be on the screen: they stay until every new patch is in (lens-hold: nothing drawn goes blank).
        XCTAssertEqual(EraseSchedule.install(replacing: 1), .allAtOnce)
        XCTAssertEqual(EraseSchedule.install(replacing: 40), .allAtOnce)
    }

    func testTheLensIsFilledTopFirst() {
        XCTAssertEqual(order([c(120, 300), c(120, 110), c(120, 200)]), [1, 2, 0])
    }

    func testTheLensComesBeforeTheOverscan() {
        // Above the lens and nearer the top of the capture than anything in it, but not seen.
        XCTAssertEqual(order([c(120, 40), c(120, 350)]), [1, 0])
    }

    func testTheOverscanIsFilledNearestFirst() {
        // 300, 50 and 10 px from the lens.
        XCTAssertEqual(order([c(120, 700), c(120, 450), c(120, 60)]), [2, 1, 0])
    }

    func testABlockWhoseTranslationLandedIsFilledFirstInTheLens() {
        // Its Korean is drawn the moment its patch is in; the one above it still waits for its own translation.
        XCTAssertEqual(order([c(120, 110), c(120, 300, translated: true), c(120, 200)]), [1, 0, 2])
    }

    func testATranslatedBlockOutsideTheLensDoesNotGoBeforeTheLens() {
        // Filling it first would draw nothing the person sees.
        XCTAssertEqual(order([c(120, 20, translated: true), c(120, 300)]), [1, 0])
        // Within the overscan it goes first.
        XCTAssertEqual(order([c(120, 450), c(120, 700, translated: true)]), [1, 0])
    }

    func testTheSideThingsAreHeadingToComesFirstInTheOverscan() {
        // As far below as above; the lens is dragged down (text comes from below).
        XCTAssertEqual(order([c(120, 20), c(120, 450)], lead: CGVector(dx: 0, dy: 1)), [1, 0])
        XCTAssertEqual(order([c(120, 20), c(120, 450)], lead: CGVector(dx: 0, dy: -1)), [0, 1])
    }

    func testTiesKeepTheOrderGiven() {
        XCTAssertEqual(order([c(120, 200), c(320, 200)]), [0, 1])
    }

    func testNothingToFillIsNil() {
        XCTAssertNil(EraseSchedule.next([], lens: lens, lead: .zero))
    }

    func testTheEraseOrderIsTheTranslationQueuesOrderWhenNothingHasLanded() {
        // The first batch's blocks are the first filled: the queue sorts by the same priority.
        let rects = [c(120, 700), c(120, 300), c(120, 20), c(120, 110), c(600, 150)]
        let queue = rects.indices.sorted { TranslationScheduling.priority(of: rects[$0].rect, lens: lens, lead: .zero) < TranslationScheduling.priority(of: rects[$1].rect, lens: lens, lead: .zero) }
        XCTAssertEqual(order(rects), queue)
    }
}
