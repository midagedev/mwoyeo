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

/// Text copied from a PDF or a mail keeps its hard line breaks, and a sentence the breaks cut in two must be translated as one (round text2,
/// F15: the film's "…median of" and "the ring." came back as 「…중앙값입니다.」 and 「그 반지」). The sources are the Mwoyeo method paper's page 5
/// as a PDF reader hands it over, and the film's selection.
@Suite struct TextParagraphsWrapTests {
    static let film = "The background colour is the per-channel median of\nthe ring."
    static let filmJoined = "The background colour is the per-channel median of the ring."

    static let caption = """
        Table 3. MI-GAN 512 prediction time by compute unit,
        one patch, median of 20 timed runs after 3 warm-up runs
        (inpaint bench, M4 Pro).
        """
    static let paragraph = """
        Core ML runs the model on the CPU, the GPU or
        the Neural Engine. The inpaint bench measured the
        three on a 512 patch (Table 3), and the application
        selects the GPU: the default setting that lets Core ML
        choose among all units was four times slower there. The
        14.2 MB model is not loaded at launch; it loads at the
        first fill, and is released after 60 s without one.
        """
    static let listing = """
        static func verdict(_ members: [Info]) -> Reason? {
        let tinted = members.contains { $0.tinted }
        let f = features(of: members.flatMap(\\.lines), tinted:
        tinted)
        guard keeps, hasDensity(members, tinted: tinted) else
        { return nil }
        }
        """
    static let page = "4.2\nFill and inpainting\n\n" + paragraph + "\n\n" + caption + "\n\n" + listing

    private func units(_ text: String) -> [String] { TextParagraphs.units(TextParagraphs.split(text)) }
    private func seam(_ a: String, _ b: String) -> TextParagraphs.Seam { TextParagraphs.seam(Substring(a), Substring(b)) }

    @Test func testTheFilmsSentenceIsOneUnit() {
        let parts = TextParagraphs.split(Self.film)
        #expect(TextParagraphs.units(parts) == [Self.filmJoined])
        #expect(TextParagraphs.join(parts, [Self.filmJoined: "배경 색상은 링의 채널별 중앙값입니다."]) == "배경 색상은 링의 채널별 중앙값입니다.")
        // Nothing translated yet: the pane shows the source as it was, breaks and all.
        #expect(TextParagraphs.join(parts, [:]) == Self.film)
        #expect(TextParagraphs.wrapsJoined(parts) == 1)
    }

    @Test func testAWrappedParagraphIsOneUnitAndTheGapsAroundItStay() {
        let parts = TextParagraphs.split("Intro line.\n\n" + Self.paragraph + "\r\n\nLast.")
        let units = TextParagraphs.units(parts)
        #expect(units.count == 3 && units[0] == "Intro line." && units[2] == "Last.")
        #expect(units[1].hasPrefix("Core ML runs the model on the CPU, the GPU or the Neural Engine. The inpaint") && units[1].hasSuffix("released after 60 s without one."))
        #expect(!units[1].contains("\n"))
        #expect(parts.filter { !$0.isUnit }.map(\.text) == ["\n\n", "\r\n\n"])
        let joined = TextParagraphs.join(parts, [units[1]: "단락"])
        #expect(joined == "Intro line.\n\n단락\r\n\nLast.")
        #expect(TextParagraphs.wrapsJoined(parts) == 6)
    }

    @Test func testThePageOfThePaperIsItsParagraphsAndItsListingKeepsItsLines() {
        let parts = TextParagraphs.split(Self.page)
        let units = TextParagraphs.units(parts)
        #expect(units.prefix(4) == ["4.2", "Fill and inpainting",
                                    "Core ML runs the model on the CPU, the GPU or the Neural Engine. The inpaint bench measured the three on a 512 patch (Table 3), and the application selects the GPU: the default setting that lets Core ML choose among all units was four times slower there. The 14.2 MB model is not loaded at launch; it loads at the first fill, and is released after 60 s without one.",
                                    "Table 3. MI-GAN 512 prediction time by compute unit, one patch, median of 20 timed runs after 3 warm-up runs (inpaint bench, M4 Pro)."])
        #expect(Array(units.dropFirst(4)) == Self.listing.split(separator: "\n").map(String.init))
        #expect(TextParagraphs.join(parts, [:]) == Self.page)
    }

    @Test func testAHyphenAtTheBreakKeepsTheWordAndLosesTheSpace() {
        #expect(units("Glyph pixels are one of the two classes of Otsu's thresh-\nold [7], computed on the luma") == ["Glyph pixels are one of the two classes of Otsu's thresh-old [7], computed on the luma"])
        #expect(units("The background colour of the ring is the per-\nchannel median of its pixels") == ["The background colour of the ring is the per-channel median of its pixels"])
        // A dash that is not a hyphen is a word of its own.
        #expect(units("The background colour is the median of the ring -\nthe rest is not read") == ["The background colour is the median of the ring - the rest is not read"])
    }

    @Test func testPlainTypedTextIsUnchanged() {
        for text in ["Hello there.\n\nSecond paragraph\nThird", "Dear John,\nI hope you are well.\nSee you soon\nBest", "one\ntwo\nthree",
                     "Meeting at 10\nBring the report\nLunch is on me", "Thanks for the update.\nI will look at it tomorrow morning when I am in."] {
            let parts = TextParagraphs.split(text)
            #expect(TextParagraphs.wrapsJoined(parts) == 0, "\(text.prefix(20))")
            #expect(TextParagraphs.units(parts) == text.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.map(String.init), "\(text.prefix(20))")
        }
    }

    @Test func testWhatIsNotAWrapIsNotJoined() {
        let full = "This line is as long as a line of body text goes"
        #expect(seam(full, "the rest of it") == .wrapped(glue: " "))
        #expect(seam("Heading of a section", "the rest of it") == .short)
        #expect(seam(full + ".", "Another sentence starts here") == .sentenceEnd)
        #expect(seam(full + ".", "and it goes on in lower case") == .wrapped(glue: " "))
        #expect(seam(full + ".\"", "And a new one") == .sentenceEnd)
        #expect(seam(full + ":", "Item") == .sentenceEnd)
        #expect(seam(full, "- a list item") == .listItem)
        #expect(seam(full, "2. a numbered item") == .listItem)
        #expect(seam(full, "3.5 million more than that") == .wrapped(glue: " "))
        #expect(seam(full, "• a bullet") == .listItem)
        #expect(seam(full, "Name\tPrice\tQty") == .columns)
        #expect(seam("Name   Price  Qty and a long long tail", "the rest of it") == .columns)
    }

    @Test func testCodeAndLogsKeepTheirLines() {
        let code = "func f(a: Int) -> Int {\n    let total = a + 1; return total\n}\nlet answer = f(a: 41) // the answer to everything and more"
        #expect(units(code).count == 4)
        let log = "2026-10-22 10:55:01 INFO the translation service answered the request\n2026-10-22 10:55:02 INFO the translation service answered again"
        #expect(units(log).count == 2)
        let terminal = "$ git status --short and then a long tail of a command line\n$ swift test --filter TextParagraphs and another long tail"
        #expect(units(terminal).count == 2)
    }

    @Test func testChineseAndJapaneseJoinWithoutASpaceAndKoreanWithOne() {
        let ja = "リリースノートには、新しい機能の一覧と既知の問題が書かれていて、読む人が最初に\n見るべき場所です"
        #expect(units(ja) == ["リリースノートには、新しい機能の一覧と既知の問題が書かれていて、読む人が最初に見るべき場所です"])
        let ko = "번역기는 화면에서 글자를 읽어 같은 자리에 번역을 다시 그려 주는 앱입니다 그래서\n스크롤 중에도 따라갑니다"
        #expect(units(ko) == ["번역기는 화면에서 글자를 읽어 같은 자리에 번역을 다시 그려 주는 앱입니다 그래서 스크롤 중에도 따라갑니다"])
        #expect(units("今日は晴れです。\n明日は雨でしょう。") == ["今日は晴れです。", "明日は雨でしょう。"])
    }

    @Test func testAParagraphLongerThanAPieceIsCutBetweenLinesNotInsideOne() {
        let line = "This is a line of body text that goes on and on"
        let text = Array(repeating: line, count: 5).joined(separator: "\n")
        let parts = TextParagraphs.split(text, limit: 3 * line.count + 3)
        let units = TextParagraphs.units(parts)
        #expect(units.count == 2 && units[0] == Array(repeating: line, count: 3).joined(separator: " ") && units[1] == line + " " + line)
        #expect(units.allSatisfy { $0.count <= 3 * line.count + 3 })
        #expect(TextParagraphs.join(parts, [:]) == text)
    }

    @Test func testSplitThenJoinIsTheIdentityOnWrappedText() {
        for text in [Self.film, Self.page, Self.film + "\n", "  " + Self.paragraph + "  \r\n  next line that is long enough to be a body line\n  of two lines", "日本語の長い行は、ここで折り返されて次の行に続きます。これはもう一文です\n続き"] {
            for limit in [1, 17, 80, 1_000] {
                #expect(TextParagraphs.join(TextParagraphs.split(text, limit: limit), [:]) == text, "limit \(limit): \(text.prefix(20))")
            }
        }
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
