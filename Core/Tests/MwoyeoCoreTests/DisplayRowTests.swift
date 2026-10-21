import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// A row of a display the document reader glued to a paragraph (round d14, 2026-10-21; D14 of film3: page 6 of the method paper, eq (10),
/// the lens at 150,256,590,514 took the row into the paragraph above and redrew it as Korean text, the lens at 150,366,590,400 kept it).
/// The first window is the block of the film's take (the `ocr-block` trace of take equation-paper-p6b, px of the 3024x1964 screen); the
/// second and third are the blocks of a render of the same screen with a capture 3 and 4 pt lower (`[keepfeed]`, build 1d7e0ab). The
/// display windows E and F of D8 (`EquationRowTests`) are glued to their neighbours the same way, from their own boxes.
@Suite struct DisplayRowTests {
    typealias L = (text: String, rect: CGRect)
    private static func line(_ text: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> L { (text, CGRect(x: x, y: y, width: w, height: h)) }
    private let page = RGBA(255, 255, 255)

    /// The seven lines of the paragraph above eq (10), then the row: one block of the film's take (the row's text is the take's transcript).
    static let gluedToTheSentenceAbove: [L] = [
        line("Size. The size of the old text is read from the height hg", 298, 295, 1169, 66),
        line("of its glyphs: the em size is hg/0.88 for Chinese, Japanese", 299, 365, 1174, 55),
        line("and Korean text, whose glyphs fill about 88% of the em,", 299, 419, 1182, 58),
        line("and for Latin text hg/0.72 (cap height) or hg/0.95 when", 299, 480, 1171, 58),
        line("the text has descenders. The translation is then set at", 296, 537, 1177, 44),
        line("the largest size that fits the room. With measure(s) the", 299, 595, 1174, 49),
        line("size of the laid-out text at font size s,", 295, 642, 802, 65),
        line("s* = max { s € [Smin, Smax] : measure(s) ≤ box},", 346, 747, 1077, 63),
    ]

    /// The row first, the three lines of the paragraph below it after (a capture 3 pt lower than the take's).
    static let gluedToTheParagraphBelow: [L] = [
        line("s* = max { s € [Smin, Smax] : measure(s) ≤ box},", 352, 747, 1062, 64),
        line("which is found by bisection to a resolution of 0.5 pt", 297, 865, 1170, 53),
        line("(TextFitter.fitFontSize); when nothing fits, Smin is", 297, 925, 1171, 58),
        line("returned and the caller wraps the text or lets it overflow.", 300, 982, 1174, 55),
    ]

    /// Real paragraphs of the same page that hold no row.
    static let prose: [[L]] = [
        [line("As a last resort a translation that does not fit at the", 298, 1041, 1169, 41),
         line("smallest size is cut at a word boundary and ends in an", 300, 1099, 1168, 48),
         line("ellipsis. The ellipsis is counted by the paper bench (Sec-", 300, 1158, 1175, 48),
         line("tion 6), because it is a loss: the person reads a shorter", 300, 1210, 1169, 58),
         line("sentence than the engine returned.", 300, 1274, 721, 48)],
        [line("Place and colour. The text starts where the old text", 301, 1397, 1166, 45),
         line("started: the patch reaches the erase margin r past the", 300, 1456, 1167, 48),
         line("original on every side, and the text area is the original", 300, 1514, 1168, 51)],
    ]

    private func window(_ name: String) -> EquationRowTests.Window { EquationRowTests.windows.first { $0.name == name }! }
    private func lines(_ w: EquationRowTests.Window, _ rows: [Int]) -> [L] {
        rows.flatMap { w.rows[$0].block.lines.map { ($0.text, $0.rect) } }
    }
    private func texts(_ block: [L], _ piece: [Int]) -> String { piece.map { block[$0].text }.joined(separator: " ") }

    // MARK: the cut

    @Test func theRowGluedToTheSentenceAboveIsCutOut() {
        #expect(DisplayRow.pieces(Self.gluedToTheSentenceAbove) == [[0, 1, 2, 3, 4, 5, 6], [7]])
    }

    @Test func theRowGluedToTheParagraphBelowIsCutOut() {
        #expect(DisplayRow.pieces(Self.gluedToTheParagraphBelow) == [[0], [1, 2, 3]])
    }

    @Test func theRowBetweenTwoParagraphsIsCutOutOfBothSides() {
        // The block the reader makes when the sentence above, the display and the paragraph below are one: the take's lines up to the row,
        // then the capture's lines below it (the row stands at y 747 in both).
        let block = Self.gluedToTheSentenceAbove + Self.gluedToTheParagraphBelow.dropFirst()
        #expect(DisplayRow.pieces(block) == [[0, 1, 2, 3, 4, 5, 6], [7], [8, 9, 10]])
    }

    @Test func theRowsOfD8GluedToTheirNeighboursAreCutOut() {
        // E (eq 7): the paragraph above (4 lines), the row `ô = 1.4826 medianpering| l(p) - l|,` (a word the text rules read as prose), the line below.
        let e = lines(window("E"), [0, 1, 3])
        #expect(DisplayRow.pieces(e) == [[0, 1, 2, 3], [4], [5]])
        // F (eq 6): the line above, three rows that stand one above the other (`V prompt V S≥2 ^ D(R),` is the last), the paragraph below.
        let f = lines(window("F"), [0, 1, 2, 3, 5])
        #expect(DisplayRow.pieces(f) == [[0], [1, 2, 3], [4, 5, 6, 7, 8, 9, 10]])
    }

    @Test func aDisplayWithoutAnOperatorIsCutOutToo() {
        // A (eq 12): `Uc(to, t1)` is a call, no sign of mathematics in it (the text rules keep it as a formula), `k: Ck =C` stands under it.
        let a = lines(window("A"), [1, 2, 4, 5])
        #expect(DisplayRow.pieces(a) == [[0, 1], [2, 3], [4, 5]])
    }

    // MARK: what is not a display row

    @Test func aParagraphOfProseIsNotCut() {
        for p in Self.prose { #expect(DisplayRow.pieces(p) == [Array(p.indices)]) }
    }

    @Test func aBlockWithOneLineIsNotCut() {
        #expect(DisplayRow.pieces([Self.gluedToTheParagraphBelow[0]]) == [[0]])
    }

    @Test func aRowThatIsTheWholeBlockHasNoProseToBeCutFrom() {
        let rows = [Self.line("V prompt V S≥2 ^ D(R),", 178, 172, 364, 47), Self.line("keep(R) = I V C|S≥1]", 36, 72, 562, 42)]
        #expect(DisplayRow.pieces(rows) == [[0, 1]])
    }

    @Test func aLineOfProseThatHoldsAFormulaIsNotARow() {
        // The line of window C: a sentence cut at a formula; the text rules translate it (prose words), and set off like a display it is still prose.
        let sentence = "k that is on screen at time t is, with s = t - tk - 1,"
        #expect(!TranslationFilter.isLiteral(sentence) && !DisplayRow.isRow(sentence))
        var below = Self.gluedToTheParagraphBelow
        below[0].text = sentence
        #expect(DisplayRow.pieces(below) == [Array(below.indices)], "set off on every side, and prose")
        var heading = Self.gluedToTheParagraphBelow
        heading[0].text = "Scroll prediction"
        #expect(DisplayRow.pieces(heading) == [Array(heading.indices)], "a heading stands off as well; it holds no sign")
    }

    @Test func aRowNotSetOffOnEverySideStaysInItsBlock() {
        let above = Self.gluedToTheSentenceAbove
        // closer to the line above than 0.5 line heights (a formula that wraps under its sentence)
        var tightAbove = above; tightAbove[7].rect.origin.y = tightAbove[6].rect.maxY + 12
        #expect(DisplayRow.pieces(tightAbove) == [Array(above.indices)])
        let below = Self.gluedToTheParagraphBelow
        var tightBelow = below; tightBelow[1].rect.origin.y = tightBelow[0].rect.maxY + 12
        #expect(DisplayRow.pieces(tightBelow) == [Array(below.indices)])
        // flush with the left margin of the prose (a formula that goes on after a word: a wrapped line)
        var flushLeft = above; flushLeft[7].rect.origin.x = 299
        #expect(DisplayRow.pieces(flushLeft) == [Array(above.indices)])
        // reaching the right margin
        var flushRight = above; flushRight[7].rect.size.width = 1182 - (346 - 299)
        #expect(DisplayRow.pieces(flushRight) == [Array(above.indices)])
    }

    @Test func theLinesOfAListingAreNotCut() {
        // Nested statements, tight, as a document read hands a listing over as one block: indented, shorter than the longest line, signs, one word each.
        let code: [L] = [
            Self.line("while i < n {", 100, 100, 400, 40),
            Self.line("    x = y + 1;", 100 + 80, 144, 300, 40),
            Self.line("    i += 1;", 100 + 80, 188, 240, 40),
            Self.line("    z = (x * 2) / 3;", 100 + 80, 232, 360, 40),
            Self.line("}", 100, 276, 30, 40),
        ]
        #expect(DisplayRow.pieces(code) == [Array(code.indices)])
    }

    // MARK: what the cut gives the rules that judge a block

    private func block(_ lines: [L]) -> CodeRegion.Block {
        let rect = lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) }
        return CodeRegion.Block(text: lines.map(\.text).joined(separator: " "), rect: rect,
                                lines: lines.map { CodeRegion.Line(text: $0.text, rect: $0.rect) }, background: page)
    }

    @Test func theGluedRowIsTranslatedAndTheCutRowIsKept() throws {
        // eq (10): glued, the text rules read the block as prose; cut, the row alone is mostly mathematics (isMathHeavy).
        for glued in [Self.gluedToTheSentenceAbove, Self.gluedToTheParagraphBelow] {
            let whole = glued.map(\.text).joined(separator: " ")
            #expect(!TranslationFilter.isLiteral(whole))
            let pieces = DisplayRow.pieces(glued)
            let row = try #require(pieces.first { $0.count == 1 }, "the row is a piece of its own")
            #expect(TranslationFilter.isLiteral(glued[row[0]].text))
            for p in pieces where p != row { #expect(!TranslationFilter.isLiteral(texts(glued, p)), "\(texts(glued, p))") }
        }
    }

    @Test func theCutRowOfD8IsKeptAsAnEquationAndTheGluedBlockIsNot() {
        // E: before the cut no rule keeps the block; after it, the row is a block of its own that stands off the body text of its column.
        let e = lines(window("E"), [0, 1, 3])
        let glued = CodeRegion.keep(blocks: [block(e)], frameBackground: page)
        #expect(glued == [nil], "glued: the region rules see one block of prose")
        let pieces = DisplayRow.pieces(e)
        let blocks = pieces.map { block($0.map { e[$0] }) }
        // the body text the display stands off: the paragraphs above and below, as the window had them
        let reasons = CodeRegion.keep(blocks: blocks + [window("E").rows[4].block, window("E").rows[6].block], frameBackground: page)
        #expect(reasons[1] == .equation, "cut: the row is kept as an equation")
        #expect(reasons[0] == nil && reasons[2] == nil, "the prose around it is translated")
    }
}
