import XCTest
@testable import MwoyeoCore

/// What a block read again shows until its translation arrives (docs/design/lens-hold.md §2, targets 1 to 3).
final class TranslationCarryTests: XCTestCase {
    /// The text each new block draws meanwhile.
    private func carried(old: [TranslationCarry.Old], new: [CGRect]) -> [String?] { TranslationCarry.assign(old: old, new: new).map { $0?.text } }

    private func old(_ rect: CGRect, _ shown: String?, unchanged: Bool = true) -> TranslationCarry.Old {
        .init(rect: rect, shown: shown, unchanged: unchanged)
    }

    func testAReadThatLongerTextShowsTheOldTranslation() {
        // The paragraph the capture's edge cut now reads longer: its rect grew to the right.
        let was = CGRect(x: 10, y: 10, width: 300, height: 60), now = CGRect(x: 10, y: 10, width: 380, height: 60)
        XCTAssertEqual(carried(old: [old(was, "안녕")], new: [now]), ["안녕"])
    }

    func testAPageThatChangedShowsNothing() {
        let r = CGRect(x: 10, y: 10, width: 300, height: 60)
        XCTAssertEqual(carried(old: [old(r, "안녕", unchanged: false)], new: [r]), [nil])
    }

    func testABlockThatDrewNothingGivesNothing() {
        let r = CGRect(x: 10, y: 10, width: 300, height: 60)
        XCTAssertEqual(carried(old: [old(r, nil), old(r, "")], new: [r]), [nil])
    }

    func testPiecesMergedIntoOneBlockAreJoinedInReadingOrder() {
        // The fast reader made two blocks of a paragraph (the first line, the rest); the document reader makes one. Given out of order.
        let first = CGRect(x: 10, y: 10, width: 300, height: 20), rest = CGRect(x: 10, y: 34, width: 300, height: 60)
        let merged = CGRect(x: 10, y: 10, width: 300, height: 84)
        XCTAssertEqual(carried(old: [old(rest, "둘째"), old(first, "첫째")], new: [merged]), ["첫째 둘째"])
    }

    func testABlockSplitGivesItsTextToThePieceThatHoldsMostOfIt() {
        let was = CGRect(x: 10, y: 10, width: 300, height: 100)
        let big = CGRect(x: 10, y: 10, width: 300, height: 75), small = CGRect(x: 10, y: 85, width: 300, height: 25)
        XCTAssertEqual(carried(old: [old(was, "전체")], new: [small, big]), [nil, "전체"])
    }

    func testAnOldBlockIsTakenOnce() {
        // Two new blocks each hold half of the old one: the better-covering one takes it, the other gets nothing.
        let was = CGRect(x: 0, y: 0, width: 100, height: 100)
        let a = CGRect(x: 0, y: 0, width: 100, height: 55), b = CGRect(x: 0, y: 55, width: 100, height: 45)
        XCTAssertEqual(carried(old: [old(was, "하나")], new: [a, b]), ["하나", nil])
    }

    func testAnOldBlockThatTheNewOnesBarelyTouchIsLeftOut() {
        let was = CGRect(x: 0, y: 0, width: 100, height: 100), elsewhere = CGRect(x: 0, y: 80, width: 100, height: 100)
        XCTAssertEqual(carried(old: [old(was, "하나")], new: [elsewhere]), [nil])
    }

    func testTheChangeMapLeavesOutTheStripsAGrownCaptureOnlyNowShows() {
        // A 32×16 page, 24 px of it read before: the reference is that part in the new canvas, black where the capture only now shows the page.
        // One tile of 16 px is cut by the strip (columns 16 to 31, the strip from column 24).
        let page = GrayImage(width: 32, height: 16, fill: 200)
        let read = page.cropped(to: PixelRect(x: 0, y: 0, width: 24, height: 16)).reframed(dx: 0, dy: 0, width: 32, height: 16)
        let strip = PixelRect(x: 24, y: 0, width: 8, height: 16)
        XCTAssertTrue(FrameDiff.changeMap(from: read, to: page).changed[1], "the strip makes the tile it cuts look changed")
        XCTAssertFalse(FrameDiff.changeMap(from: read, to: page, ignoring: [strip]).changed[1], "and the pixels the reference had say it is not")
        // A real edit in the covered part of that tile still counts.
        var edited = page
        edited.pixels[2 * 32 + 18] = 20; edited.pixels[2 * 32 + 19] = 20
        XCTAssertTrue(FrameDiff.changeMap(from: read, to: edited, ignoring: [strip]).changed[1])
        XCTAssertEqual(FrameDiff.changeMap(from: read, to: page, ignoring: []), FrameDiff.changeMap(from: read, to: page))
    }

    func testTheOldBlockThatHoldsMostOfTheNewOneGivesItsPlace() {
        // Two old blocks under one new block: the larger one is the one the new block stands in the place of.
        let big = CGRect(x: 0, y: 0, width: 100, height: 60), small = CGRect(x: 0, y: 60, width: 100, height: 20)
        let merged = CGRect(x: 0, y: 0, width: 100, height: 80)
        let carry = TranslationCarry.assign(old: [old(small, "작은"), old(big, "큰")], new: [merged])
        XCTAssertEqual(carry.first??.primary, 1)
        XCTAssertEqual(carry.first??.text, "큰 작은")
    }

    func testANewBlockInsideADrawnOneIsAPieceOfIt() {
        // The capture's edge cuts a title the lens has moved off: the new block is the part still in the capture, inside the old block.
        let title = CGRect(x: -150, y: 20, width: 900, height: 70), piece = CGRect(x: 0, y: 24, width: 320, height: 48)
        let olds = [old(title, "제목")], new = [piece]
        XCTAssertEqual(TranslationCarry.fragments(old: olds, new: new, carry: TranslationCarry.assign(old: olds, new: new)), [0])
    }

    func testANewBlockThatTakesTheOldOnesTextIsNotAPiece() {
        // A longer reading holds the old block: the old one is carried to it, it does not stay beside it.
        let was = CGRect(x: 10, y: 10, width: 300, height: 60), now = CGRect(x: 10, y: 10, width: 380, height: 60)
        let olds = [old(was, "안녕")], new = [now]
        XCTAssertEqual(TranslationCarry.fragments(old: olds, new: new, carry: TranslationCarry.assign(old: olds, new: new)), [nil])
    }

    func testAnOldBlockThatTheNewOneStandsAcrossIsNotItsMother() {
        let was = CGRect(x: 0, y: 0, width: 100, height: 100), across = CGRect(x: 60, y: 0, width: 100, height: 100)
        let olds = [old(was, "하나")], new = [across]
        XCTAssertEqual(TranslationCarry.fragments(old: olds, new: new, carry: TranslationCarry.assign(old: olds, new: new)), [nil])
    }

    func testAPageThatChangedKeepsNoOldBlock() {
        let title = CGRect(x: -150, y: 20, width: 900, height: 70), piece = CGRect(x: 0, y: 24, width: 320, height: 48)
        let olds = [old(title, "제목", unchanged: false)], new = [piece]
        XCTAssertEqual(TranslationCarry.fragments(old: olds, new: new, carry: TranslationCarry.assign(old: olds, new: new)), [nil])
    }
}
