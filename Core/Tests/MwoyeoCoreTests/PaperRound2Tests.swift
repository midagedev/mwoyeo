import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// What was left of the Attention paper (arXiv 1706.03762) read in Safari after the first paper round: the author header's
/// columns were one block, the one-word labels of a figure were drawn too large, the two-letter words of the rotated sentence of
/// pages 14 and 15 were translated, and the boxes a PDF viewer draws round citations stayed over the translation.
@Suite struct PaperRound2Tests {
    private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    // MARK: Columns of the author header

    @Test func theColumnsOfTheAuthorHeaderAreNotOneBlock() {
        // Page 1 at 2x, recorded (trace of the paper bench, 2026-10-18): the reader made "University of Toronto / aidan@cs.toronto.edu"
        // one block of two lines, "llion@google.com" of the column to the left a block of its own, 57 px (1.7 heights) before it on
        // the same row. The old rule took that for the end of the paragraph's last line and made one block of three lines, whose
        // patch cut off "Google Research" above it.
        let toronto = [r(647, 788, 242, 30), r(625, 819, 286, 26)]
        let llion = [r(334, 818, 234, 34)]
        let research = [r(356, 787, 190, 34)]
        #expect(BlockMerge.groups([toronto, llion, research]) == [[0], [1], [2]])
    }

    @Test func aLoneLineWhollyToTheLeftOfTheParagraphIsNotItsEnd() {
        // The same shapes with the gutter narrowed to 0.8 heights: still the cell of the column beside, not a piece of the last line.
        let toronto = [r(647, 788, 242, 30), r(625, 819, 286, 26)]
        let near = [r(364, 818, 234, 34)]
        #expect(BlockMerge.groups([toronto, near]) == [[0], [1]])
    }

    @Test func aPieceInsideTheParagraphsWidthJoinsOnlyUpToOneAndAHalfEm() {
        let paragraph = [r(320, 100, 1190, 36), r(320, 140, 700, 36)]
        #expect(BlockMerge.groups([paragraph, [r(1020 + 36, 144, 300, 36)]]) == [[0, 1]], "a gap of one height: a sum's sign")
        #expect(BlockMerge.groups([paragraph, [r(1020 + 50, 144, 300, 36)]]) == [[0], [1]], "1.4 heights: the next cell of the row")
    }

    // MARK: Link boxes

    private let white = RGBA(255, 255, 255), black = RGBA(0, 0, 0)
    /// The frame Safari draws round a citation, measured on a live capture of page 5 (2026-10-18 13:09): 1 px, (117, 251, 76).
    private let green = RGBA(117, 251, 76)

    /// 80×30 patch, a 10 px ring, two digit-like bars 6 px wide inside the text rect (x 12...60, y 7...22).
    private func citation(frame: RGBA? = nil, frameInset: Int = 3) -> RGBAImage {
        var img = RGBAImage(width: 80, height: 30, color: white)
        for x in [16, 22, 34, 40] { for y in 9..<20 { img.set(x: x, y: y, black); img.set(x: x + 1, y: y, black) } }
        if let frame {
            for x in (13 - frameInset)...(44 + frameInset) {
                img.set(x: x, y: 9 - frameInset, frame); img.set(x: x, y: 19 + frameInset, frame)
            }
            for y in (9 - frameInset)...(19 + frameInset) {
                img.set(x: 13 - frameInset, y: y, frame); img.set(x: 44 + frameInset, y: y, frame)
            }
        }
        return img
    }
    private let inner = PixelRect(x: 12, y: 7, width: 48, height: 16)

    @Test func theLightFrameRoundACitationIsErasedWithIt() {
        let m = TextEraser.mask(for: citation(frame: green), textRect: inner, dilation: 0, frames: true)
        #expect(m.bits[6 * 80 + 20] == 1, "the frame's top edge goes with the digits")
        #expect(m.bits[15 * 80 + 10] == 1 && m.bits[15 * 80 + 47] == 1, "and its sides")
        #expect(m.bits[12 * 80 + 16] == 1, "the digits are masked as before")
        // What measures the source is the glyphs, not the frame: it would make the translation larger than the text it replaces.
        #expect(m.glyphBounds == PixelRect(x: 16, y: 9, width: 26, height: 11))
        #expect(m.appearance.textColor == black)
    }

    @Test func theColourRunsOfALineDoNotSeeTheFrame() {
        // `frames` is for erasing: the runs of one text colour (`TextEraser.clusters`) are cut from the plain mask.
        let m = TextEraser.mask(for: citation(frame: green), textRect: inner, dilation: 0)
        #expect(m.bits[6 * 80 + 20] == 0 && m.count == 4 * 2 * 11)
    }

    @Test func aFrameThatIsNotAnOutlineRoundGlyphsStays() {
        // A rule under the digits, a dot, a badge that fills its box: none is a frame round the glyphs.
        var rule = citation()
        for x in 10..<50 { rule.set(x: x, y: 24, green) }
        #expect(TextEraser.mask(for: rule, textRect: inner, dilation: 0, frames: true).bits[24 * 80 + 30] == 0)
        var badge = citation()
        for y in 5..<25 { for x in 8..<53 where badge.color(x: x, y: y) == white { badge.set(x: x, y: y, green) } }
        #expect(TextEraser.mask(for: badge, textRect: inner, dilation: 0, frames: true).bits[6 * 80 + 20] == 0, "the badge is the background")
    }

    @Test func aFrameThePatchCutsOffIsALargerBoxAndStays() {
        // The frame reaches the patch's edge: its ring is not all in the patch, so it is the border of something larger.
        var cut = citation(frame: green, frameInset: 3)
        for y in 0..<30 { cut.set(x: 0, y: y, green) }
        for x in 0..<14 { cut.set(x: x, y: 6, green) }
        #expect(TextEraser.mask(for: cut, textRect: inner, dilation: 0, frames: true).bits[6 * 80 + 20] == 0)
    }

    @Test func aFrameWithoutGlyphsInsideIsLeftAlone() {
        // An empty box beside the glyphs (a checkbox, an icon's outline): the glyphs are not in it.
        var empty = RGBAImage(width: 80, height: 30, color: white)
        for x in 8...30 { empty.set(x: x, y: 6, green); empty.set(x: x, y: 23, green) }
        for y in 6...23 { empty.set(x: 8, y: y, green); empty.set(x: 30, y: y, green) }
        for x in [40, 46] { for y in 9..<20 { empty.set(x: x, y: y, black); empty.set(x: x + 1, y: y, black) } }
        let m = TextEraser.mask(for: empty, textRect: inner, dilation: 0, frames: true)
        #expect(m.bits[6 * 80 + 20] == 0 && m.bits[15 * 80 + 30] == 0)
        #expect(m.bits[12 * 80 + 40] == 1)
    }

    // MARK: Label sizes

    @Test func aLabelInABoxTallerThanItsTextIsNotDrawnAtTheBoxsSize() {
        // Page 3 of the bench, "Positional Encoding" of figure 1 read as "Positiona" in a box 95×43 (two lines of 22 px glyphs): the
        // translation came out at 45.8 px beside labels of 23 px.
        let size = LabelSize.capped(45.8, text: "Positiona", width: 95, lines: 1)!
        #expect(abs(size - 2.6 * 95 / 9) < 0.01 && size < 28)
    }

    @Test func theLabelsOfTheFiguresKeepTheirSizes() {
        // Drawn sizes of labels (text, width, size) measured on the paper bench's pages: none is above 2.6 widths of its characters.
        let measured: [(String, CGFloat, CGFloat)] = [("Multi-Head", 93, 19.9), ("Attention", 77, 15.1), ("Self-Attention", 150, 25.0), ("Inputs", 61, 23.2),
                                                      ("Scaled Dot-Product", 172, 22.2), ("Recurrent", 104, 22.9), ("Abstract", 118, 30.6)]
        for (text, width, size) in measured {
            #expect(LabelSize.capped(size, text: text, width: width, lines: 1) == size, "\(text)")
        }
        #expect(LabelSize.capped(nil, text: "Attention", width: 77, lines: 1) == nil)
    }

    @Test func onlyOneShortLineOfLettersIsALabel() {
        #expect(LabelSize.isLabel("Add & Norm", lines: 1) && LabelSize.isLabel("Positional", lines: 1))
        #expect(!LabelSize.isLabel("Positional Encoding Layer", lines: 1), "three words")
        #expect(!LabelSize.isLabel("Scaled Dot-Product Attention", lines: 1), "over sixteen characters")
        #expect(!LabelSize.isLabel("Positional Encoding", lines: 2), "two lines")
        #expect(!LabelSize.isLabel("be", lines: 1) && !LabelSize.isLabel("I", lines: 1), "no average width of two letters")
        // Not a label: its size stays whatever the glyphs said.
        #expect(LabelSize.capped(45.8, text: "Positional Encoding Layer", width: 95, lines: 1) == 45.8)
        #expect(LabelSize.capped(45.8, text: "Positiona", width: 95, lines: 2) == 45.8)
    }

    @Test func aHanOrHangulLabelIsNeverHeldBelowItsGlyphs() {
        // A glyph is one em wide: the average width of six of them is six times that of a letter's half.
        #expect(LabelSize.capped(23, text: "입력 임베딩", width: 90, lines: 1) == 23)
    }

    // MARK: Two-letter words of the rotated sentence

    /// The sentence of the attention figure on page 15 (2x screen), as the recognizer read it: (x, top, width, height, text).
    /// "be" 22×35 and "is" 26×35 are as wide as the box of a word turned on its side gets when it has two letters.
    private let sentence: [(CGRect, String)] = [
        (CGRect(x: 325, y: 1453, width: 26, height: 48), "The"), (CGRect(x: 400, y: 1453, width: 26, height: 44), "will"),
        (CGRect(x: 444, y: 1457, width: 13, height: 61), "never"), (CGRect(x: 480, y: 1453, width: 22, height: 35), "be"),
        (CGRect(x: 514, y: 1452, width: 26, height: 84), "perfect"), (CGRect(x: 625, y: 1448, width: 26, height: 35), "is"),
        (CGRect(x: 660, y: 1452, width: 32, height: 129), "application"), (CGRect(x: 698, y: 1451, width: 31, height: 82), "should"),
        (CGRect(x: 739, y: 1453, width: 22, height: 35), "be"), (CGRect(x: 775, y: 1453, width: 26, height: 48), "just"),
    ]

    @Test func theShortWordsOfARotatedSentenceAreRotatedToo() {
        let lines = sentence.map { (box: $0.0, text: $0.1) }
        #expect(VerticalText.rotatedLines(lines) == Set(lines.indices))
        // The words alone are not told from horizontal ones by their boxes (the rule that read the box did not).
        for i in [3, 5, 8] { #expect(!VerticalText.isRotatedLine(lines[i].box, characters: 2), "\(lines[i].text) \(lines[i].box)") }
    }

    @Test func aRunOfShortWordsIsRotatedFromItsOneLongNeighbour() {
        // Page 14, the lower copy of the sentence, "are in my": the next long word was not read, and "my" stands 129 px
        // (5.4 widths) from "are" but 16 px from "in".
        let lines: [(box: CGRect, text: String)] = [(CGRect(x: 1013, y: 1115, width: 18, height: 39), "are"), (CGRect(x: 1117, y: 1133, width: 27, height: 27), "in"),
                                                    (CGRect(x: 1160, y: 1118, width: 24, height: 39), "my")]
        #expect(VerticalText.rotatedLines(lines) == [0, 1, 2])
        #expect(VerticalText.rotatedLines(Array(lines[1...])).isEmpty, "with no word it is the box rule that decides, and it let both through")
    }

    @Test func aShortWordAloneOrFarFromTheRotatedWordsIsText() {
        let be = (box: CGRect(x: 480, y: 1453, width: 22, height: 35), text: "be")
        #expect(VerticalText.rotatedLines([be]).isEmpty, "no rotated word beside it")
        // At the sentence's height, but 500 px past its last rotated word.
        let far = sentence.map { (box: $0.0, text: $0.1) }
        let apart = (box: CGRect(x: 1300, y: 1453, width: 26, height: 35), text: "is")
        #expect(!VerticalText.rotatedLines(far + [apart]).contains(far.count))
    }

    @Test func aHorizontalShortWordBesideTheSentenceStaysText() {
        let lines = sentence.map { (box: $0.0, text: $0.1) }
        // Not at the top of the words: a caption line of a figure under it.
        #expect(!VerticalText.rotatedLines(lines + [(box: CGRect(x: 560, y: 1700, width: 26, height: 30), text: "is")]).contains(lines.count))
        // A wider box than tall: "its" set horizontally.
        #expect(!VerticalText.rotatedLines(lines + [(box: CGRect(x: 560, y: 1453, width: 48, height: 30), text: "its")]).contains(lines.count))
        // Digits and signs are not words.
        #expect(!VerticalText.rotatedLines(lines + [(box: CGRect(x: 560, y: 1453, width: 26, height: 35), text: "15")]).contains(lines.count))
        // Four letters are not a short word: the box rule decides alone.
        #expect(!VerticalText.rotatedLines(lines + [(box: CGRect(x: 560, y: 1453, width: 26, height: 30), text: "that")]).contains(lines.count))
    }
}
