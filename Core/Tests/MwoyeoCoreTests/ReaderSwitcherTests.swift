import Testing
@testable import MwoyeoCore

@Suite struct ReaderSwitcherTests {
    private let doc = ReaderPick(reader: .documentLayout, reason: "doc")
    private let lines = ReaderPick(reader: .lineGrouping, reason: "lines")

    @Test func firstFrameTakesThePickWithoutCountingAsASwitch() {
        var s = ReaderSwitcher()
        let r = s.settle(doc, app: "a", text: 1)
        #expect(r.pick.reader == .documentLayout && !r.switched)
    }

    @Test func switchesOnlyAfterThreeFramesOfDifferentText() {
        var s = ReaderSwitcher()
        _ = s.settle(doc, app: "a", text: 1)
        #expect(s.settle(lines, app: "a", text: 2).pick.reader == .documentLayout)
        #expect(s.settle(lines, app: "a", text: 3).pick.reader == .documentLayout)
        let third = s.settle(lines, app: "a", text: 4)
        #expect(third.pick.reader == .lineGrouping && third.switched)
    }

    @Test func theSameTextReadAgainIsNoNewEvidence() {
        var s = ReaderSwitcher()
        _ = s.settle(doc, app: "a", text: 1)
        for _ in 0..<6 { #expect(s.settle(lines, app: "a", text: 2).pick.reader == .documentLayout) }
    }

    @Test func aFrameThatAgreesStartsTheCountOver() {
        var s = ReaderSwitcher()
        _ = s.settle(doc, app: "a", text: 1)
        _ = s.settle(lines, app: "a", text: 2)
        _ = s.settle(lines, app: "a", text: 3)
        #expect(s.settle(doc, app: "a", text: 4).pick.reader == .documentLayout)
        _ = s.settle(lines, app: "a", text: 5)
        #expect(s.settle(lines, app: "a", text: 6).pick.reader == .documentLayout)
    }

    @Test func aNewAppTakesTheNewPickAtOnce() {
        var s = ReaderSwitcher()
        _ = s.settle(doc, app: "a", text: 1)
        #expect(s.settle(lines, app: "b", text: 2).pick.reader == .lineGrouping)
        // Still one choice per lens: the old app's count does not carry over.
        #expect(s.settle(doc, app: "b", text: 3).pick.reader == .lineGrouping)
    }
}
