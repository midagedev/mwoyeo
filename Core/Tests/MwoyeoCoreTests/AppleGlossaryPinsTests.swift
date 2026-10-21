import Foundation
import Testing
@testable import MwoyeoCore

/// The rows Apple Translation pre-inserts (design §1.3, G7, §10): the app's own replacement rows first, then the global glossary's pairs
/// whose source the app's memory does not have. The app's row wins: one source has one row, and it is the app's.
///
/// 2026-10-21, round prof-file: `applePins` is gone; Apple takes `ContextMemory.replaceRows` like every kind (the switch is each row's
/// `apply` and `glossaryApply`). These cases were `applePins`'s, ported with the rows made `both` (the mode 1.1.4's switch converts to,
/// §5.2) and the glossary used `both`; the rows are what they were.
@Suite struct AppleGlossaryPinsTests {
    private func app(_ src: String, _ dst: String, kind: EntryKind = .term, origin: EntryOrigin = .user) -> MemoryEntry {
        MemoryEntry(src: src, dst: dst, kind: kind, origin: origin, apply: .both)
    }

    private func replaceRows(appRows: [MemoryEntry], glossary: [(String, String)]) -> [MemoryEntry] {
        ContextMemory.replaceRows(rows: appRows, glossary: glossary, glossaryApply: .both)
    }

    // MARK: the app's row wins

    @Test func theAppsRowWinsOverTheGlossaryRowOfTheSameSource() {
        let mine = app("token", "앱의 토큰")
        let merged = replaceRows(appRows: [mine], glossary: [("token", "전역의 토큰")])
        #expect(merged == [mine])
        #expect(merged.first?.dst == "앱의 토큰")
    }

    @Test func theSameSourceIsOneRowWhateverItsCaseAndWidth() {
        let mine = app("Token", "앱의 토큰")
        let merged = replaceRows(appRows: [mine], glossary: [("token", "전역의 토큰"), ("TOKEN", "또 다른 토큰")])
        #expect(merged == [mine])
    }

    @Test func aGlossaryRowWithAnotherSourceJoins() {
        let mine = app("token", "앱의 토큰")
        let merged = replaceRows(appRows: [mine], glossary: [("token", "전역의 토큰"), ("model", "모델")])
        #expect(merged.map(\.src) == ["token", "model"])
        #expect(merged.map(\.dst) == ["앱의 토큰", "모델"])
    }

    // MARK: the glossary alone

    @Test func theGlossaryAloneIsEnough() {
        let merged = replaceRows(appRows: [], glossary: [("token", "토큰")])
        #expect(merged.count == 1)
        #expect(merged.first?.src == "token" && merged.first?.dst == "토큰")
        // A glossary pair is a user row of kind `term`.
        #expect(merged.first?.origin == .user && merged.first?.kind == .term)
    }

    @Test func nothingToInsertIsNothing() {
        #expect(replaceRows(appRows: [], glossary: []).isEmpty)
        #expect(replaceRows(appRows: [app("token", "토큰")], glossary: []).count == 1)
    }

    @Test func aPairWithoutASourceOrATranslationIsNoRow() {
        let merged = replaceRows(appRows: [], glossary: [("", "토큰"), ("token", ""), ("model", "모델")])
        #expect(merged.map(\.src) == ["model"])
    }

    @Test func oneSourceIsOneRowInTheGlossaryToo() {
        let merged = replaceRows(appRows: [], glossary: [("token", "토큰"), ("token", "다른 토큰")])
        #expect(merged.count == 1 && merged.first?.dst == "토큰")
    }

    // MARK: the order

    @Test func theAppsRowsComeFirstAndTheGlossaryKeepsItsOrder() {
        let first = app("alpha", "알파"), second = app("beta", "베타")
        let merged = replaceRows(appRows: [first, second], glossary: [("gamma", "감마"), ("delta", "델타")])
        #expect(merged.map(\.src) == ["alpha", "beta", "gamma", "delta"])
    }

    // MARK: what never goes in

    @Test func aLearnedRowIsNoRow() {
        let learned = app("token", "토큰", origin: .learned)
        #expect(replaceRows(appRows: [learned], glossary: []).isEmpty)
    }

    @Test func anEmptyRowIsNoRow() {
        #expect(replaceRows(appRows: [app("", "토큰")], glossary: []).isEmpty)
        #expect(replaceRows(appRows: [app("token", "")], glossary: []).isEmpty)
    }
}
