import Foundation
import Testing
@testable import MwoyeoCore

/// The rows Apple Translation pre-inserts (design §1.3, G7): the app's own user rows first, then the global glossary's pairs whose
/// source the app's memory does not have. The app's row wins: one source has one row, and it is the app's.
@Suite struct AppleGlossaryPinsTests {
    private func app(_ src: String, _ dst: String, kind: EntryKind = .term, origin: EntryOrigin = .user) -> MemoryEntry {
        MemoryEntry(src: src, dst: dst, kind: kind, origin: origin)
    }

    // MARK: the app's row wins

    @Test func theAppsRowWinsOverTheGlossaryRowOfTheSameSource() {
        let mine = app("token", "앱의 토큰")
        let merged = ContextMemory.applePins(appRows: [mine], glossary: [("token", "전역의 토큰")])
        #expect(merged == [mine])
        #expect(merged.first?.dst == "앱의 토큰")
    }

    @Test func theSameSourceIsOneRowWhateverItsCaseAndWidth() {
        let mine = app("Token", "앱의 토큰")
        let merged = ContextMemory.applePins(appRows: [mine], glossary: [("token", "전역의 토큰"), ("TOKEN", "또 다른 토큰")])
        #expect(merged == [mine])
    }

    @Test func aGlossaryRowWithAnotherSourceJoins() {
        let mine = app("token", "앱의 토큰")
        let merged = ContextMemory.applePins(appRows: [mine], glossary: [("token", "전역의 토큰"), ("model", "모델")])
        #expect(merged.map(\.src) == ["token", "model"])
        #expect(merged.map(\.dst) == ["앱의 토큰", "모델"])
    }

    // MARK: the glossary alone

    @Test func theGlossaryAloneIsEnough() {
        let merged = ContextMemory.applePins(appRows: [], glossary: [("token", "토큰")])
        #expect(merged.count == 1)
        #expect(merged.first?.src == "token" && merged.first?.dst == "토큰")
        // A glossary pair is a user row of kind `term`.
        #expect(merged.first?.origin == .user && merged.first?.kind == .term)
    }

    @Test func nothingToInsertIsNothing() {
        #expect(ContextMemory.applePins(appRows: [], glossary: []).isEmpty)
        #expect(ContextMemory.applePins(appRows: [app("token", "토큰")], glossary: []).count == 1)
    }

    @Test func aPairWithoutASourceOrATranslationIsNoRow() {
        let merged = ContextMemory.applePins(appRows: [], glossary: [("", "토큰"), ("token", ""), ("model", "모델")])
        #expect(merged.map(\.src) == ["model"])
    }

    @Test func oneSourceIsOneRowInTheGlossaryToo() {
        let merged = ContextMemory.applePins(appRows: [], glossary: [("token", "토큰"), ("token", "다른 토큰")])
        #expect(merged.count == 1 && merged.first?.dst == "토큰")
    }

    // MARK: the order

    @Test func theAppsRowsComeFirstAndTheGlossaryKeepsItsOrder() {
        let first = app("alpha", "알파"), second = app("beta", "베타")
        let merged = ContextMemory.applePins(appRows: [first, second], glossary: [("gamma", "감마"), ("delta", "델타")])
        #expect(merged.map(\.src) == ["alpha", "beta", "gamma", "delta"])
    }

    // MARK: what never goes in

    @Test func aLearnedRowIsNoRow() {
        let learned = app("token", "토큰", origin: .learned)
        #expect(ContextMemory.applePins(appRows: [learned], glossary: []).isEmpty)
    }

    @Test func anEmptyRowIsNoRow() {
        #expect(ContextMemory.applePins(appRows: [app("", "토큰")], glossary: []).isEmpty)
        #expect(ContextMemory.applePins(appRows: [app("token", "")], glossary: []).isEmpty)
    }
}
