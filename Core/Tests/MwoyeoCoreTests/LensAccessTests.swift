import CoreGraphics
import Testing
@testable import MwoyeoCore

/// 2026-10-19 mas-d-a11y: a lens placed with the keyboard, and the words a screen reader gets for it.
@Suite struct LensAccessTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test func theDefaultLensIsTheClickSizeCentredOnTheScreen() {
        let p = KeyboardLens(bounds: screen)
        #expect(p.rect.size == KeyboardLens.defaultSize)
        #expect(p.rect.midX == screen.midX && p.rect.midY == screen.midY)
    }

    @Test func aSmallScreenShrinksTheDefaultToFit() {
        let p = KeyboardLens(bounds: CGRect(x: 100, y: 50, width: 400, height: 200))
        #expect(p.rect == CGRect(x: 100, y: 50, width: 400, height: 200))
    }

    @Test func anArrowMovesTenPointsAndOptionOne() {
        var p = KeyboardLens(bounds: screen)
        let start = p.rect
        var changed = p.press(.right)
        #expect(changed && p.rect.minX == start.minX + 10 && p.rect.minY == start.minY)
        changed = p.press(.up)
        #expect(changed && p.rect.minY == start.minY + 10)
        changed = p.press(.left, fine: true)
        #expect(changed && p.rect.minX == start.minX + 9)
        changed = p.press(.down, fine: true)
        #expect(changed && p.rect.minY == start.minY + 9)
        #expect(p.rect.size == start.size)
    }

    @Test func aLensStopsAtTheEdgeOfTheScreen() {
        var p = KeyboardLens(bounds: screen)
        for _ in 0..<500 { p.press(.left) }
        #expect(p.rect.minX == screen.minX)
        let stuck = p.press(.left)
        #expect(!stuck)
        for _ in 0..<500 { p.press(.up) }
        #expect(p.rect.maxY == screen.maxY)
        for _ in 0..<500 { p.press(.right) }
        #expect(p.rect.maxX == screen.maxX)
        for _ in 0..<500 { p.press(.down) }
        #expect(p.rect.minY == screen.minY)
    }

    @Test func shiftResizesFromTheBottomRightKeepingTheTopLeft() {
        var p = KeyboardLens(bounds: screen)
        let start = p.rect
        p.press(.right, resize: true)
        #expect(p.rect.width == start.width + 10 && p.rect.minX == start.minX)
        p.press(.down, resize: true)
        #expect(p.rect.height == start.height + 10 && p.rect.maxY == start.maxY)
        p.press(.left, resize: true, fine: true)
        #expect(p.rect.width == start.width + 9)
        p.press(.up, resize: true, fine: true)
        #expect(p.rect.height == start.height + 9 && p.rect.maxY == start.maxY)
    }

    @Test func aLensNeitherShrinksBelowTheMinimumNorGrowsOffTheScreen() {
        var p = KeyboardLens(bounds: screen)
        for _ in 0..<200 { p.press(.left, resize: true); p.press(.up, resize: true) }
        #expect(p.rect.width >= KeyboardLens.minSize.width && p.rect.height >= KeyboardLens.minSize.height)
        #expect(p.rect.width - KeyboardLens.minSize.width < 10)
        var q = KeyboardLens(bounds: screen)
        for _ in 0..<500 { q.press(.right, resize: true); q.press(.down, resize: true) }
        #expect(q.rect.maxX <= screen.maxX && q.rect.minY >= screen.minY)
        let grew = q.press(.right, resize: true)
        #expect(!grew)
    }

    @Test func theStateWordsFollowThePillsOrder() {
        func state(notice: String? = nil, original: Bool = false, hint: String? = nil, busy: Bool = false, translated: Bool = false) -> LensAccessState {
            LensAccessState(notice: notice, original: original, hint: hint, busy: busy, translated: translated)
        }
        #expect(state() == .waiting)
        #expect(state(translated: true) == .translated)
        #expect(state(busy: true, translated: true) == .reading)
        #expect(state(hint: "Allow screen recording", busy: true) == .hint("Allow screen recording"))
        #expect(state(notice: "Copied", original: true, hint: "x") == .notice("Copied"))
        #expect(state(original: true, hint: "x", busy: true) == .showingOriginal)
        #expect(state(notice: "") == .waiting)
    }

    @Test func theExcerptIsTheFirstTwoHundredCharactersCutAtAWord() {
        #expect(LensAccessSummary.excerpt([]) == "")
        #expect(LensAccessSummary.excerpt(["  ", ""]) == "")
        #expect(LensAccessSummary.excerpt(["Hello", "world"]) == "Hello world")
        let words = Array(repeating: "alpha", count: 60)
        let cut = LensAccessSummary.excerpt(words)
        #expect(cut.hasSuffix("…") && cut.count <= 201)
        #expect(!cut.dropLast().hasSuffix(" ") && cut.dropLast().split(separator: " ").allSatisfy { $0 == "alpha" })
        // No spaces (Japanese): cut at the limit.
        #expect(LensAccessSummary.excerpt([String(repeating: "あ", count: 300)]).count == 201)
    }
}
