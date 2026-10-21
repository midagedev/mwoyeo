import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// A row of a displayed equation that holds a word, or letters the recognizer made a word of, is kept as written (round d8keep, 2026-10-21;
/// D8 of film3's A8): in the method paper (tools/paper-own/mwoyeo-method) 4 of the 8 windows with a display (E, F, G, H) redrew a row of it,
/// translated. The fifth, C, is a scorer artefact: its two drawn blocks are lines of prose that hold inline mathematics, rightly translated;
/// the rows of its eq (11) were kept.
/// The windows below are the blocks of the reads (`MWOYEO_TRACE_READS=1`, the `[keepfeed]` lines, build 258e76a + the trace, 2026-10-21): text and boxes
/// as the recognizer gave them, in the window's pixels.
@Suite struct EquationRowTests {
    struct Row {
        var text: String
        var x, y, w, h: Double
        var lines: Int
        var lineHeight: Double
        /// What 258e76a decides by the text alone: kept (a formula, mostly mathematics, or no letter at all) or translated.
        var keptToday: Bool

        init(_ text: String, _ x: Int, _ y: Int, _ w: Int, _ h: Int, lines: Int, lineHeight: Int, keptToday: Bool) {
            self.text = text
            (self.x, self.y, self.w, self.h) = (Double(x), Double(y), Double(w), Double(h))
            self.lines = lines
            self.lineHeight = Double(lineHeight)
            self.keptToday = keptToday
        }

        /// The lines of the block: words dealt out in order, one box per line, as tall as the row says.
        var block: CodeRegion.Block {
            let words = text.split(separator: " ").map(String.init)
            let per = max(1, Int((Double(words.count) / Double(lines)).rounded(.up)))
            let pitch = lines > 1 ? (h - lineHeight) / Double(lines - 1) : 0
            let ls = (0..<lines).map { i -> CodeRegion.Line in
                let part = words.dropFirst(i * per).prefix(per).joined(separator: " ")
                return CodeRegion.Line(text: part, rect: CGRect(x: x, y: y + Double(i) * pitch, width: w, height: lineHeight))
            }
            return CodeRegion.Block(text: text, rect: CGRect(x: x, y: y, width: w, height: h), lines: ls, background: RGBA(255, 255, 255))
        }
    }

    struct Window {
        var name: String
        var what: String
        var rows: [Row]
    }

    static let windows: [Window] = [
        Window(name: "E", what: "method paper p5 left column, eq (7)", rows: [
            Row("it, where h is the line height. The ring is the background sample. Let I(p) be the luma of pixel p and I the", 12, 26, 650, 128, lines: 4, lineHeight: 33, keptToday: false),
            Row("ô = 1.4826 medianpering| l(p) - l|,", 129, 181, 410, 36, lines: 1, lineHeight: 36, keptToday: false),
            Row("(7)", 631, 186, 28, 24, lines: 1, lineHeight: 24, keptToday: true),
            Row("where the factor makes the median absolute deviation", 11, 247, 647, 22, lines: 1, lineHeight: 22, keptToday: false),
            Row("consistent with the standard deviation of a Gaussian", 12, 277, 608, 32, lines: 1, lineHeight: 32, keptToday: false),
            Row("6].", 632, 277, 22, 32, lines: 1, lineHeight: 32, keptToday: true),
            Row("A median instead of a mean keeps a box edge, or a bit of another element of the page that falls in the ring,", 11, 312, 649, 63, lines: 2, lineHeight: 35, keptToday: false),
        ]),
        Window(name: "F", what: "method paper p4 right column, eq (6)", rows: [
            Row("region is kept when", 9, 13, 224, 30, lines: 1, lineHeight: 30, keptToday: false),
            Row("keep(R) = I V C|S≥1]", 36, 72, 562, 42, lines: 1, lineHeight: 42, keptToday: true),
            Row("V（［R|>1AS≥1AAI2", 178, 128, 320, 32, lines: 1, lineHeight: 32, keptToday: true),
            Row("V prompt V S≥2 ^ D(R),", 178, 172, 364, 47, lines: 1, lineHeight: 47, keptToday: false),
            Row("(6)", 628, 132, 28, 24, lines: 1, lineHeight: 24, keptToday: true),
            Row("where D(R) is the density test of Table 2: a long region needs a text feature in a share of its content", 8, 249, 651, 218, lines: 7, lineHeight: 30, keptToday: false),
            Row("Everything in this section reads text, geometry and", 35, 473, 620, 30, lines: 1, lineHeight: 30, keptToday: false),
        ]),
        Window(name: "G", what: "method paper p5 left column, eq (7), a second crop", rows: [
            Row("dian luma of the ring. The noise of the background is the robust spread of the ring,", 12, 14, 646, 60, lines: 2, lineHeight: 30, keptToday: false),
            Row("ô = 1.4826 medianpEring|l(p) - l],", 129, 100, 410, 43, lines: 1, lineHeight: 43, keptToday: false),
            Row("(7)", 631, 106, 28, 24, lines: 1, lineHeight: 24, keptToday: true),
            Row("where the factor makes the median absolute deviation", 11, 167, 647, 25, lines: 1, lineHeight: 25, keptToday: false),
            Row("consistent with the standard deviation of a Gaussian", 12, 197, 608, 32, lines: 1, lineHeight: 32, keptToday: false),
            Row("6].", 632, 197, 22, 32, lines: 1, lineHeight: 32, keptToday: true),
            Row("A median instead of a mean keeps a box edge, or a bit of another element of the page that falls in the ring,", 11, 232, 649, 95, lines: 3, lineHeight: 35, keptToday: false),
            Row("6. The background colour is the per-channel median of the ring.", 12, 326, 648, 62, lines: 2, lineHeight: 32, keptToday: false),
        ]),
        Window(name: "H", what: "method paper p3 right column, eq (3)", rows: [
            Row("are mathematics is high:", 9, 15, 282, 30, lines: 1, lineHeight: 30, keptToday: false),
            Row("Н(x)", 12, 80, 57, 28, lines: 1, lineHeight: 28, keptToday: true),
            Row("nmath", 174, 80, 52, 14, lines: 1, lineHeight: 14, keptToday: false),
            Row("nmath +Nprose", 138, 96, 125, 21, lines: 1, lineHeight: 21, keptToday: false),
            Row("≥0.30 A［hsigt", 278, 74, 176, 40, lines: 1, lineHeight: 40, keptToday: false),
            Row("≥2］A［n≥20", 465, 74, 168, 40, lines: 1, lineHeight: 40, keptToday: true),
            Row("(3)", 628, 120, 28, 26, lines: 1, lineHeight: 26, keptToday: true),
            Row("with n = Nmath + nprose• Mathematics are signs, variables of one letter (not \"a\" and \"I\"), runs of consonants", 8, 154, 649, 281, lines: 9, lineHeight: 28, keptToday: false),
        ]),
        Window(name: "A", what: "method paper p6 right column, eqs (12) and (13)", rows: [
            Row("5.2 Offset between two frames", 10, 22, 494, 28, lines: 1, lineHeight: 28, keptToday: false),
            Row("The wheel units of kind c that reached the screen be-tween to and t1 are", 8, 74, 651, 58, lines: 2, lineHeight: 25, keptToday: false),
            Row("Uc(to, t1)", 98, 164, 100, 32, lines: 1, lineHeight: 32, keptToday: true),
            Row("(12)", 614, 166, 42, 26, lines: 1, lineHeight: 26, keptToday: true),
            Row("k: Ck =C", 252, 204, 72, 17, lines: 1, lineHeight: 17, keptToday: true),
            Row("and the content movement expected between them, in points, is", 9, 245, 646, 67, lines: 2, lineHeight: 33, keptToday: false),
            Row("A(to, t1) = ppUp(to, t1) + PIUL(to, t1).", 66, 337, 490, 32, lines: 1, lineHeight: 32, keptToday: true),
            Row("(13)", 614, 337, 42, 28, lines: 1, lineHeight: 28, keptToday: true),
            Row("The ratios pe are points per wheel unit. pp starts at 1; pL is unknown, and contributes 0, until a frame has", 8, 397, 647, 60, lines: 2, lineHeight: 27, keptToday: false),
        ]),
        Window(name: "D2", what: "method paper p6 left column, eq (10)", rows: [
            Row("the text has descenders. The translation is then set at the largest size that fits the room. With measure(s)", 12, 22, 646, 94, lines: 3, lineHeight: 26, keptToday: false),
            Row("s* = max { s € [Smin› Smax] : measure(s) ≤ box },", 41, 142, 587, 33, lines: 1, lineHeight: 33, keptToday: true),
            Row("(10)", 617, 174, 42, 28, lines: 1, lineHeight: 28, keptToday: true),
            Row("which is found by bisection to a resolution of 0.5 pt (TextFitter. fitFontSize); when nothing fits, Smin is", 10, 208, 652, 90, lines: 3, lineHeight: 26, keptToday: false),
            Row("As a last resort a translation that does not fit at the smallest size is cut at a word boundary and ends in", 11, 303, 651, 154, lines: 5, lineHeight: 26, keptToday: false),
        ]),
        Window(name: "S2", what: "method paper p2 right column, eq (1)", rows: [
            Row("3.1", 10, 0, 41, 24, lines: 1, lineHeight: 24, keptToday: true),
            Row("Rules over one block", 91, 0, 323, 24, lines: 1, lineHeight: 24, keptToday: false),
            Row("Let x be the text of a recognised line or block. The text is kept as written when", 9, 52, 646, 56, lines: 2, lineHeight: 25, keptToday: false),
            Row("literal(x) = P(x) V F(x) V I(x) V H(x),", 85, 142, 494, 30, lines: 1, lineHeight: 30, keptToday: true),
            Row("(1)", 628, 142, 29, 30, lines: 1, lineHeight: 30, keptToday: true),
            Row("where P matches a fixed list of patterns (a shell prompt followed by a command, a time or date stamp, a URL", 8, 206, 651, 156, lines: 5, lineHeight: 28, keptToday: false),
            Row("MatMul, YouTube) and H is the mathematics-heavy test (isMathHeavy). Table 2 lists the features and thresholds.", 7, 365, 652, 60, lines: 2, lineHeight: 28, keptToday: false),
        ]),
        Window(name: "P", what: "method paper p3 left column, eq (2)", rows: [
            Row("F(x) = [=1] V [W ≤214(x) \\ 2(x)], (2)", 69, 34, 591, 32, lines: 1, lineHeight: 32, keptToday: true),
            Row("1 = (W=0) V (W=1ЛеЛl,≥ 2lw)", 106, 126, 440, 28, lines: 1, lineHeight: 28, keptToday: true),
            Row("Here e says that the line holds a relation sign, c that it holds a call, and u that the two prose words are", 12, 228, 649, 220, lines: 7, lineHeight: 28, keptToday: false),
        ]),
        Window(name: "J", what: "method paper p7 right column, eq (16)", rows: [
            Row("is from the text it translates. The self-test measures it.", 9, 20, 650, 24, lines: 1, lineHeight: 24, keptToday: false),
            Row("For each block it records, when the block is first seen, its position on the page: the on-screen position", 9, 50, 649, 160, lines: 5, lineHeight: 28, keptToday: false),
            Row("Df = max pb(f) - pь(0)||2'", 160, 233, 343, 36, lines: 1, lineHeight: 36, keptToday: true),
            Row("(16)", 614, 235, 42, 26, lines: 1, lineHeight: 26, keptToday: true),
            Row("and prints Df per frame and, at the end, the mean of Df, the maximum, and the number of frames with Df > 2", 9, 308, 650, 91, lines: 3, lineHeight: 30, keptToday: false),
            Row("With exact prediction every block stays on its text and", 7, 403, 648, 28, lines: 1, lineHeight: 28, keptToday: false),
            Row("Df = 0 (Proposition 1); without it, Df is the distance", 9, 435, 646, 30, lines: 1, lineHeight: 30, keptToday: false),
        ]),
        Window(name: "C", what: "method paper p6 right column, eq (11), a cases bracket between two paragraphs", rows: [
            Row("k that is on screen at time t is, with s = t - tk - 1,", 9, 26, 589, 30, lines: 1, lineHeight: 30, keptToday: false),
            Row("S≤0", 460, 90, 59, 28, lines: 1, lineHeight: 28, keptToday: true),
            Row("Фк(t)", 36, 124, 57, 28, lines: 1, lineHeight: 28, keptToday: true),
            Row("S > 0, CK = P,", 460, 124, 164, 33, lines: 1, lineHeight: 33, keptToday: true),
            Row("- (1 - min(1, s/T))3", 191, 154, 239, 43, lines: 1, lineHeight: 43, keptToday: true),
            Row("S > 0, CK = L.", 460, 166, 164, 28, lines: 1, lineHeight: 28, keptToday: true),
            Row("(11)", 614, 197, 42, 28, lines: 1, lineHeight: 28, keptToday: true),
            Row("A precise delta is a step: the content has moved all at once. A line step eases out, as in a smooth-scroll", 8, 229, 647, 64, lines: 2, lineHeight: 29, keptToday: false),
            Row("animation: it starts at speed 3/T = 20 s-1 of its to-", 9, 283, 650, 40, lines: 1, lineHeight: 40, keptToday: false),
            Row("tal and slows to zero at I, so that half of it is on", 9, 327, 646, 30, lines: 1, lineHeight: 30, keptToday: false),
        ]),
    ]

    /// The four rows of the method paper that 258e76a translated and redrew: the text rules read each as prose.
    static let equationRows: Set<String> = [
        "ô = 1.4826 medianpering| l(p) - l|,", "V prompt V S≥2 ^ D(R),", "ô = 1.4826 medianpEring|l(p) - l],", "≥0.30 A［hsigt",
    ]

    private let page = RGBA(255, 255, 255)

    private func reasons(_ w: Window) -> [CodeRegion.Reason?] { CodeRegion.keep(blocks: w.rows.map(\.block), frameBackground: page) }

    /// What the app does with a block: the text rules (`TranslationFilter.isLiteral`; a block with no letter is literal before them), then the region.
    private func kept(_ row: Row, _ reason: CodeRegion.Reason?) -> Bool {
        !row.text.contains(where: \.isLetter) || TranslationFilter.isLiteral(row.text) || reason != nil
    }

    // MARK: the rows

    @Test func theCauseIsTheTextRulesReadingEachRowAsProse() {
        for w in Self.windows {
            for row in w.rows where Self.equationRows.contains(row.text) {
                #expect(!TranslationFilter.isLiteral(row.text), "\(w.name): \(row.text)")
                let shape = TranslationFilter.shape(of: row.text)
                #expect(shape.proseWords == 1 && shape.signs >= 1, "\(w.name): \(row.text) words \(shape.proseWords) signs \(shape.signs)")
            }
        }
    }

    @Test func aDisplayRowWithOneWordOrBracketIsKept() {
        var found = 0
        for w in Self.windows {
            let r = reasons(w)
            for (i, row) in w.rows.enumerated() where Self.equationRows.contains(row.text) {
                found += 1
                #expect(r[i]?.rawValue == "equation", "\(w.name): \(row.text)")
                #expect(kept(row, r[i]), "\(w.name): \(row.text)")
            }
        }
        #expect(found == 4)
    }

    @Test func everyOtherBlockOfTheWindowsKeepsItsVerdict() {
        // The equations that were kept stay kept, the prose (paragraphs with inline mathematics, the lines of a sentence cut by the window, the
        // lead-in "where ...") stays translated: the verdict of every block but the four rows is the one the text rules gave.
        for w in Self.windows {
            let r = reasons(w)
            for (i, row) in w.rows.enumerated() where !Self.equationRows.contains(row.text) {
                #expect(kept(row, r[i]) == row.keptToday, "\(w.name): \(row.text) kept \(kept(row, r[i])) today \(row.keptToday)")
            }
        }
    }

    // MARK: the place says what the text cannot

    /// Body text of one column, 36 px a line, from x = 10 to x = 660, and `middle` between two paragraphs.
    private func column(_ middle: [CodeRegion.Block], at y: Double = 200) -> [CodeRegion.Block] {
        func paragraph(_ y: Double) -> CodeRegion.Block {
            let words = "The ring is the background sample and the noise of the background is the robust spread of the ring".split(separator: " ").map(String.init)
            let ls = (0..<2).map { i in CodeRegion.Line(text: words.dropFirst(i * 10).prefix(10).joined(separator: " "), rect: CGRect(x: 10, y: y + Double(i) * 36, width: 650, height: 30)) }
            return CodeRegion.Block(text: words.joined(separator: " "), rect: CGRect(x: 10, y: y, width: 650, height: 66), lines: ls, background: page)
        }
        return [paragraph(y - 120)] + middle + [paragraph(y + 100)]
    }

    private func row(_ text: String, x: Double, width: Double, y: Double = 200) -> CodeRegion.Block {
        CodeRegion.Block(text: text, rect: CGRect(x: x, y: y, width: width, height: 30), lines: [.init(text: text, rect: CGRect(x: x, y: y, width: width, height: 30))], background: page)
    }

    private func verdict(_ blocks: [CodeRegion.Block], at i: Int) -> String? {
        CodeRegion.keep(blocks: blocks, frameBackground: page)[i]?.rawValue
    }

    @Test func theSameTextAtTheMarginOfTheBodyIsAProseLine() {
        // "where ... holds" at the margin is a line of the paragraph above it, whatever it holds; set off, it is a row.
        #expect(verdict(column([row("V prompt V S≥2 ^ D(R),", x: 10, width: 360)]), at: 1) == nil)
        #expect(verdict(column([row("V prompt V S≥2 ^ D(R),", x: 130, width: 360)]), at: 1) == "equation")
    }

    @Test func aRowSetOffOnOneSideOnlyIsNotADisplay() {
        // Flush with the right margin and a long way from the left: the tail of a sentence cut at a formula, not a centred row.
        #expect(verdict(column([row("V prompt V S≥2 ^ D(R),", x: 300, width: 360)]), at: 1) == nil)
    }

    @Test func aCaptionOrHeadingSetOffIsTranslatedForWantOfAnySignOfMathematics() {
        #expect(verdict(column([row("IV. Resilience of time reversal", x: 130, width: 360)]), at: 1) == nil)
        #expect(verdict(column([row("Abstract", x: 250, width: 120)]), at: 1) == nil)
    }

    @Test func aSetOffSentenceWithAFormulaInItIsTranslated() {
        // More than one word of prose: the second word makes it a sentence ("Figure 3: speed s = 2 over time").
        #expect(verdict(column([row("Figure 3: speed s = 2 over time", x: 130, width: 360)]), at: 1) == nil)
        #expect(verdict(column([row("V prompt V fast S≥2 ^ D(R),", x: 130, width: 360)]), at: 1) == nil)
    }

    @Test func aSentenceCutBeforeItsReferenceIsTranslated() {
        // "setting N = 1 in Eq. (A2)": the recognizer cut the line before "(A2)". The line stands at the margin of its column.
        let sentence = row("setting N = 1 in Eq.", x: 10, width: 220, y: 200)
        let reference = row("(A2)", x: 240, width: 48, y: 204)
        #expect(verdict(column([sentence, reference]), at: 1) == nil)
    }

    @Test func aRowOfATableWithoutBodyTextAroundItIsNotMeasured() {
        // No body text over its middle, no margin to stand off: the rule says nothing.
        let alone = [row("Score = 12", x: 130, width: 200)]
        #expect(CodeRegion.keep(blocks: alone, frameBackground: page) == [nil])
    }

    @Test func aRowOfOtherScriptsIsLeftToTheTextRules() {
        // The scan stops at the first letter that is not Latin, Greek or Cyrillic, before it counts the signs: the row has none.
        #expect(TranslationFilter.shape(of: "x = 12 × 총합").signs == 0)
        #expect(verdict(column([row("x = 12 × 총합", x: 130, width: 360)]), at: 1) == nil)
    }

    @Test func aBlockThatHoldsTheRowIsNoMarginOfTheBodyText() {
        // Two columns read as one paragraph: its box spans both, and holds the row of the right column. The margin is the right column's.
        func paragraph(_ y: Double) -> CodeRegion.Block {
            CodeRegion.Block(text: "The ring is the background sample and the noise of the background is the robust spread of the ring",
                             rect: CGRect(x: 841, y: y, width: 665, height: 66), lines: [.init(text: "The ring is the background sample and the noise of the background is the robust spread of the ring",
                                                                                           rect: CGRect(x: 841, y: y, width: 665, height: 30))], background: page)
        }
        let merged = CodeRegion.Block(text: "In the appendix it is shown that the Fisher information above coincides with the one of the Fock states",
                                      rect: CGRect(x: 140, y: 100, width: 1366, height: 1800),
                                      lines: [.init(text: "In the appendix it is shown that the Fisher information above coincides with the one of the Fock states",
                                                    rect: CGRect(x: 140, y: 100, width: 1366, height: 30))], background: page)
        let blocks = [merged, paragraph(300), row("V prompt V S≥2 ^ D(R),", x: 845, width: 220, y: 400), paragraph(500)]
        #expect(verdict(blocks, at: 2) == nil)
    }

    @Test func aShortLabelIsNoMarginOfTheBodyText() {
        // Blocks of fewer than four words (a label, a number, another row) say nothing about where the text of a column stands.
        let labels = [row("Save changes", x: 10, width: 700, y: 100), row("V prompt V S≥2 ^ D(R),", x: 130, width: 360, y: 200), row("Done now", x: 10, width: 700, y: 300)]
        #expect(verdict(labels, at: 1) == nil)
    }
}
