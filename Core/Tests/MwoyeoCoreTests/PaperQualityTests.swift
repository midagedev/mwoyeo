import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// Three rules for a paper page read in Safari (arXiv 1706.03762, v1.1.1 RC, live, 2026-10-18 13:09): a line with subscripts is not
/// drawn larger than the lines around it, a line the capture cuts in two is left alone, and a translation that does not fit
/// ends in "…" instead of being cut through a line.
@Suite struct PaperQualityTests {
    private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
    private func body(_ size: CGFloat?, characters: Int = 120, lines: Int = 2) -> BodySize.Block {
        BodySize.Block(fontSize: size, characters: characters, lines: lines)
    }

    // MARK: BodySize

    @Test func aBodyLineWithScriptsIsDrawnAtMostOneFifteenthLargerThanItsNeighbours() {
        // Page 5, live: "여기서 투영은 매개변수 행렬인 W ∈ R dmodel × dk…" was drawn 1.5 times as large as the paragraphs around it.
        let screen = [body(30), body(31), body(30), body(29), body(45, characters: 140), body(30)]
        let ceiling = BodySize.ceiling(among: screen)
        #expect(ceiling == 30 * BodySize.ceilingFactor)
        #expect(BodySize.capped(screen[4], ceiling: ceiling) == 34.5)
        #expect(BodySize.capped(screen[0], ceiling: ceiling) == 30 && BodySize.capped(screen[1], ceiling: ceiling) == 31)
    }

    @Test func aTitleOrHeadingKeepsItsOwnSize() {
        let screen = [body(30), body(30), body(31), body(60, characters: 24, lines: 1), body(36, characters: 39, lines: 1)]
        let ceiling = BodySize.ceiling(among: screen)
        #expect(BodySize.capped(screen[3], ceiling: ceiling) == 60)
        #expect(BodySize.capped(screen[4], ceiling: ceiling) == 36)
    }

    @Test func bodyLikeIsTheAverageOfALinesCharacters() {
        #expect(body(30, characters: 100, lines: 2).isBody && !body(30, characters: 79, lines: 2).isBody)
        #expect(body(30, characters: 40, lines: 1).isBody && !body(30, characters: 39, lines: 1).isBody)
    }

    @Test func theCeilingIsTheLowerMiddleSizeAndNeedsTwoBodyBlocks() {
        #expect(BodySize.ceiling(among: [body(20), body(30)]) == 20 * BodySize.ceilingFactor)
        #expect(BodySize.ceiling(among: [body(20), body(30), body(24)]) == 24 * BodySize.ceilingFactor)
        #expect(BodySize.ceiling(among: [body(30)]) == nil)
        #expect(BodySize.ceiling(among: [body(30), body(60, characters: 20, lines: 1), body(nil)]) == nil)
        #expect(BodySize.capped(body(45), ceiling: nil) == 45 && BodySize.capped(body(nil), ceiling: 34) == nil)
    }

    // MARK: CaptureEdge

    @Test func aShortLineAtTheTopOrBottomOfTheCaptureIsCut() {
        let capture = r(0, 0, 1634, 1000)
        let body = r(200, 400, 900, 30), second = r(200, 450, 900, 30)
        // Measured on the paper bench's crops: the visible half of a cut line, its box ending at the edge or 3 px short of it.
        for line in [r(715, 0, 208, 14), r(200, 1.5, 900, 16), r(200, 980, 900, 20), r(1047, 981, 63, 16)] {
            #expect(CaptureEdge.cut([body, second, line], in: capture) == [2], "\(line)")
        }
    }

    @Test func aLineClearOfTheEdgesIsWholeAndSoIsOneThatMerelyStandsThere() {
        let capture = r(0, 0, 1634, 1000)
        let body = r(200, 400, 900, 30), second = r(200, 450, 900, 30)
        #expect(CaptureEdge.cut([body, second, r(200, 6, 900, 30), r(200, 964, 900, 30)], in: capture).isEmpty, "5+ px from the edge")
        #expect(CaptureEdge.cut([body, second, r(200, 0, 900, 29)], in: capture).isEmpty, "a whole line that touches it")
        #expect(CaptureEdge.cut([body, second, r(0, 400, 1634, 30)], in: capture).isEmpty, "the sides are not this rule")
    }

    @Test func aPictureCroppedToItsTextCutsNothing() {
        // A subtitle or a caption cropped to its line: the box touches both edges and there is no line to compare it with.
        let capture = r(0, 0, 600, 40)
        #expect(CaptureEdge.cut([r(20, 2, 560, 36)], in: capture).isEmpty)
        #expect(CaptureEdge.cut([r(20, 1, 560, 38), r(20, 0, 300, 39)], in: capture).isEmpty)
        #expect(CaptureEdge.cut([], in: capture).isEmpty)
    }

    @Test func theIndicesAreThoseOfTheLinesPassed() {
        let capture = r(0, 0, 800, 600)
        let lines = [r(40, 0, 600, 12), r(40, 30, 700, 30), r(40, 70, 700, 30), r(40, 590, 500, 10)]
        #expect(CaptureEdge.cut(lines, in: capture) == [0, 3])
    }

    // MARK: rotated words of a figure

    @Test func aWordTurnedOnItsSideIsRotatedText() {
        // The attention figure of pages 14 and 15 (2x screen): the words of the sentence stand over it, turned 90 degrees.
        // Boxes as the recognizer gave them (pixels, width × height).
        for (w, h, n) in [(23.0, 123.0, 11), (18.0, 74.0, 5), (49.0, 933.0, 38), (21.0, 45.0, 3), (21.0, 52.0, 3), (19.0, 37.0, 3),
                          (19.0, 37.0, 2), (18.0, 35.0, 2), (18.0, 39.0, 2), (21.0, 59.0, 4)] {
            #expect(VerticalText.isRotatedLine(CGRect(x: 0, y: 0, width: w, height: h), characters: n), "\(w)×\(h) \(n)")
        }
    }

    @Test func horizontalLinesAndSingleLettersAreNot() {
        #expect(!VerticalText.isRotatedLine(CGRect(x: 0, y: 0, width: 60, height: 26), characters: 3))
        #expect(!VerticalText.isRotatedLine(CGRect(x: 0, y: 0, width: 26, height: 26), characters: 4), "a word set in a column of its own is square at most")
        #expect(!VerticalText.isRotatedLine(CGRect(x: 0, y: 0, width: 16, height: 21), characters: 3), "iii, ill")
        #expect(!VerticalText.isRotatedLine(CGRect(x: 0, y: 0, width: 17, height: 21), characters: 2), "it")
        #expect(!VerticalText.isRotatedLine(CGRect(x: 0, y: 0, width: 10, height: 40), characters: 1), "one letter has no direction")
    }

    // MARK: TextFitter.truncating

    @Test func aTranslationThatFitsIsUntouched() {
        #expect(TextFitter.truncating("짧은 번역", fits: { $0.count <= 12 }) == "짧은 번역")
    }

    @Test func aTranslationThatDoesNotFitEndsInAnEllipsisAtAWord() {
        // "…" counts: 12 characters at most.
        #expect(TextFitter.truncating("alpha beta gamma delta epsilon", fits: { $0.count <= 12 }) == "alpha beta…")
        #expect(TextFitter.truncating("다중 헤드 어텐션은 모델이 서로 다른 위치에 있는", fits: { $0.count <= 12 }) == "다중 헤드 어텐션은…")
    }

    @Test func aLongRunWithoutASpaceIsCutWhereItFits() {
        #expect(TextFitter.truncating("abcdefghijklmnopqrstuvwxyz", fits: { $0.count <= 12 }) == "abcdefghijk…")
    }

    @Test func thePunctuationBeforeTheCutIsDropped() {
        #expect(TextFitter.truncating("one two, three four", fits: { $0.count <= 9 }) == "one two…")
    }

    @Test func aRoomForLessThanACharacterLeavesTheTextAsItIs() {
        // Less than one line of room: fewer characters would not be shorter. Nor is "…" alone a translation.
        #expect(TextFitter.truncating("alpha beta", fits: { _ in false }) == "alpha beta")
        #expect(TextFitter.truncating("alpha beta", fits: { $0.count <= 1 && $0 != "…" }) == "alpha beta")
        #expect(TextFitter.truncating("alpha beta", fits: { $0.count <= 1 }) == "alpha beta")
    }

    @Test func aRoomForOneCharacterAndTheEllipsisKeepsThem() {
        #expect(TextFitter.truncating("alpha beta", fits: { $0.count <= 2 }) == "a…")
    }

    @Test func theLinesOfAWrappedTranslationAreCountedByTheCaller() {
        // Two lines of ten characters (20 with the "…"): what `fits` measures is the caller's, here a count of wrapped lines.
        let lines = { (s: String) in Int((Double(s.count) / 10).rounded(.up)) }
        let out = TextFitter.truncating("가나다라마 바사아자차 카타파하가 나다라마바 사아자차카", fits: { lines($0) <= 2 })
        #expect(out == "가나다라마 바사아자차 카타파하가…" && lines(out) <= 2)
    }
}
