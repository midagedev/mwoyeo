import Foundation
import Testing
@testable import MwoyeoCore

/// Translate Text (docs/design/text-translation.md §2): the units a text is translated in, and the gaps the translation is put back between.
@Suite struct TextParagraphsTests {
    private func texts(_ parts: [TextParagraphs.Part], unit: Bool) -> [String] { parts.filter { $0.isUnit == unit }.map(\.text) }

    @Test func testALineIsAUnitAndItsBreaksAreGaps() {
        let parts = TextParagraphs.split("Hello there.\n\nSecond paragraph\nThird")
        #expect(texts(parts, unit: true) == ["Hello there.", "Second paragraph", "Third"])
        #expect(texts(parts, unit: false) == ["\n\n", "\n"])
    }

    @Test func testIndentsAndTrailingSpaceStayInTheGaps() {
        let parts = TextParagraphs.split("  indented line \t\n   \nnext")
        #expect(texts(parts, unit: true) == ["indented line", "next"])
        #expect(parts.first == TextParagraphs.Part(text: "  ", isUnit: false))
        #expect(TextParagraphs.join(parts, [:]) == "  indented line \t\n   \nnext")
    }

    @Test func testJoinReplacesUnitsAndKeepsEveryGap() {
        let source = "A\n\n  B\r\nA\n"
        let parts = TextParagraphs.split(source)
        #expect(TextParagraphs.units(parts) == ["A", "B"])
        #expect(TextParagraphs.join(parts, ["A": "가", "B": "나"]) == "가\n\n  나\r\n가\n")
        #expect(TextParagraphs.join(parts, ["A": "가"]) == "가\n\n  B\r\n가\n")
    }

    @Test func testSplitThenJoinIsTheIdentityOnAwkwardText() {
        let awkward = ["", " ", "\n", "\n\n\n", "x", " x ", "one\ntwo\r\nthree\r", "a. b? c! d… e", "日本語。二文目。\n\n三", "tab\there",
                       String(repeating: "word ", count: 600), String(repeating: "あ", count: 2500), "e\u{301}\u{301} 👨‍👩‍👧‍👦 ok"]
        for text in awkward {
            for limit in [1, 3, 17, 1_000] {
                #expect(TextParagraphs.join(TextParagraphs.split(text, limit: limit), [:]) == text, "limit \(limit): \(text.prefix(20))")
            }
        }
    }

    @Test func testNoTwoGapsAreNextToEachOtherAndNoUnitIsEmptyOrPadded() {
        for text in ["a \n b", "\n\n a \n\n", "x. y. z. w", String(repeating: "ab cd. ", count: 40)] {
            let parts = TextParagraphs.split(text, limit: 9)
            #expect(zip(parts, parts.dropFirst()).allSatisfy { $0.isUnit || $1.isUnit })
            #expect(parts.filter(\.isUnit).allSatisfy { !$0.text.isEmpty && $0.text.first?.isWhitespace == false && $0.text.last?.isWhitespace == false })
        }
    }

    @Test func testALongLineIsCutAtSentenceEnds() {
        let line = "First sentence is here. Second one follows it! Third is a question? Fourth ends."
        let parts = TextParagraphs.split(line, limit: 30)
        #expect(texts(parts, unit: true) == ["First sentence is here.", "Second one follows it!", "Third is a question?", "Fourth ends."])
        #expect(texts(parts, unit: false) == [" ", " ", " "])
        #expect(TextParagraphs.join(parts, [:]) == line)
    }

    @Test func testAFullStopInsideAWordIsNoSentenceEnd() {
        let parts = TextParagraphs.split("see version 1.2.3 of the tool and then stop", limit: 20)
        #expect(texts(parts, unit: true).allSatisfy { $0.count <= 20 } && !texts(parts, unit: true).contains("see version 1."))
    }

    @Test func testFullWidthSentenceEndsCutWithoutASpace() {
        let line = "今日は晴れです。明日は雨でしょう。明後日は曇りです。"
        let parts = TextParagraphs.split(line, limit: 10)
        #expect(texts(parts, unit: true) == ["今日は晴れです。", "明日は雨でしょう。", "明後日は曇りです。"])
        #expect(texts(parts, unit: false).isEmpty)
        #expect(TextParagraphs.join(parts, [:]) == line)
    }

    @Test func testWithoutASentenceEndALongLineIsCutAtASpaceThenAtTheLimit() {
        let spaced = TextParagraphs.split("alpha beta gamma delta epsilon", limit: 12)
        #expect(texts(spaced, unit: true) == ["alpha beta", "gamma delta", "epsilon"])
        let solid = TextParagraphs.split(String(repeating: "x", count: 25), limit: 10)
        #expect(texts(solid, unit: true) == [String(repeating: "x", count: 10), String(repeating: "x", count: 10), String(repeating: "x", count: 5)])
        #expect(texts(solid, unit: false).isEmpty)
    }

    @Test func testNoUnitIsLongerThanTheLimitAndACharacterIsNeverSplit() {
        let family = "👨‍👩‍👧‍👦"
        let text = String(repeating: family + "a", count: 40)
        let parts = TextParagraphs.split(text, limit: 7)
        #expect(texts(parts, unit: true).allSatisfy { $0.count <= 7 })
        #expect(TextParagraphs.join(parts, [:]) == text)
    }

    @Test func testUnitsAreEachTextOnceInFirstSeenOrder() {
        #expect(TextParagraphs.units(TextParagraphs.split("b\na\nb\nc\na")) == ["b", "a", "c"])
        #expect(TextParagraphs.units(TextParagraphs.split("  \n\n")).isEmpty)
        #expect(TextParagraphs.split("").isEmpty)
    }

    @Test func testTheLimitsAreThoseTheDesignNames() {
        #expect(TextParagraphs.pieceLimit == 1_000 && TextParagraphs.maxCharacters == 50_000)
    }
}

/// The wait after typing and the choice of who may translate by themselves, on a fake clock: no test waits for a real one. The times are
/// exact in binary floating point, so the waits compare equal.
@Suite struct TypingPauseTests {
    @Test func testNothingWaitsUntilAnEdit() {
        var pause = TypingPause()
        #expect(pause.step(at: 0) == .idle && pause.step(at: 100) == .idle)
    }

    @Test func testAPauseFiresOnceAfterTheDelay() {
        var pause = TypingPause(delay: 1)
        pause.edited(at: 10)
        #expect(pause.step(at: 10.25) == .wait(0.75))
        #expect(pause.step(at: 11) == .fire)
        #expect(pause.step(at: 12) == .idle)
    }

    @Test func testEachKeystrokeStartsTheWaitAgain() {
        var pause = TypingPause(delay: 1)
        pause.edited(at: 0)
        pause.edited(at: 0.75)
        #expect(pause.step(at: 1) == .wait(0.75))
        pause.edited(at: 1.5)
        #expect(pause.step(at: 2.25) == .wait(0.25))
        #expect(pause.step(at: 2.5) == .fire)
    }

    @Test func testCancelEndsTheWait() {
        var pause = TypingPause(delay: 1)
        pause.edited(at: 0)
        pause.cancel()
        #expect(pause.step(at: 5) == .idle)
    }

    @Test func testAZeroDelayFiresAtOnce() {
        var pause = TypingPause(delay: 0)
        pause.edited(at: 3)
        #expect(pause.step(at: 3) == .fire)
    }

    @Test func testOnlyAnAddedEngineWaitsToBeAsked() {
        #expect(TextTrigger.forEngine(added: false) == .onPause)
        #expect(TextTrigger.forEngine(added: true) == .onRequest)
        #expect(TypingPause.standard == 0.8)
    }
}
