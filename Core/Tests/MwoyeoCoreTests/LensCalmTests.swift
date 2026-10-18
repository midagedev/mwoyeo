import XCTest
@testable import MwoyeoCore

final class LensCalmTests: XCTestCase {
    private func changes(_ d: inout BusyDebounce, flips: Int, step: TimeInterval) -> Int {
        var last = d.shown, n = 0
        for i in 0..<flips {
            let s = d.update(i % 2 == 0, now: Double(i) * step)
            if s != last { n += 1; last = s }
        }
        return n
    }

    func testFlipsOneHundredMsApartChangeAtMostOnce() {
        var d = BusyDebounce()
        XCTAssertLessThanOrEqual(changes(&d, flips: 20, step: 0.1), 1)
    }

    func testShortTranslationShowsNothing() {
        var d = BusyDebounce()
        XCTAssertFalse(d.update(true, now: 0))
        XCTAssertFalse(d.update(false, now: 0.5))
        XCTAssertNil(d.nextChange)
        XCTAssertFalse(d.update(false, now: 5))
    }

    func testOnAfter600AndOffAfter1500() {
        var d = BusyDebounce()
        d.update(true, now: 10)
        XCTAssertEqual(d.nextChange, 10.6)
        XCTAssertFalse(d.update(true, now: 10.59))
        XCTAssertTrue(d.update(true, now: 10.61))
        d.update(false, now: 20)
        XCTAssertEqual(d.nextChange, 21.5)
        XCTAssertTrue(d.update(false, now: 21.49))
        XCTAssertFalse(d.update(false, now: 21.51))
    }

    func testBlipDuringShownDoesNotTurnOff() {
        var d = BusyDebounce()
        d.update(true, now: 0)
        d.update(true, now: 1)
        d.update(false, now: 2)
        XCTAssertTrue(d.update(true, now: 2.5))
        XCTAssertTrue(d.update(true, now: 9))
    }

    func testSameHeadlineWaitsSixtySeconds() {
        var g = NoticeGate()
        XCTAssertTrue(g.allow("A", now: 0))
        XCTAssertFalse(g.allow("A", now: 59))
        XCTAssertTrue(g.allow("A", now: 60))
    }

    func testDifferentHeadlineAtMostOncePerTenSeconds() {
        var g = NoticeGate()
        XCTAssertTrue(g.allow("A", now: 0))
        XCTAssertFalse(g.allow("B", now: 9.9))
        XCTAssertTrue(g.allow("B", now: 10))
        XCTAssertFalse(g.allow("A", now: 30))
        XCTAssertTrue(g.allow("A", now: 70))
    }

    func testEmptyHeadlineIsNeverShown() {
        var g = NoticeGate()
        XCTAssertFalse(g.allow("", now: 0))
        XCTAssertTrue(g.allow("A", now: 1))
    }
}
