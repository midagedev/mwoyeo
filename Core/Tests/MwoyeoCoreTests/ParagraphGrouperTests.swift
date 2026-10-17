import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// Boxes measured on Vision's accurate revision 3 (macOS 27) over the app's test pictures, rounded: a box is as tall as the
/// glyphs of its line, so heights of one paragraph differ by up to 1.45 times.
@Suite struct ParagraphGrouperTests {
    private struct Line { var x, y, w, h: Double; var text: String }

    private func line(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ text: String) -> Line { Line(x: x, y: y, w: w, h: h, text: text) }

    /// The paragraphs as their lines joined with "|".
    private func paragraphs(_ lines: [Line]) -> [String] {
        ParagraphGrouper.groups(lines, rect: { CGRect(x: $0.x, y: $0.y, width: $0.w, height: $0.h) }, text: \.text)
            .map { $0.map(\.text).joined(separator: "|") }
    }

    // MARK: Chat

    @Test func oneMessagePerBubbleStaysApart() {
        // A bubble per message, 40-60 px between them; the second line is taller (a comma and an ascender).
        let p = paragraphs([
            line(376, 78, 554, 16, "Is anyone doing the co-op event tonight? I need two more people for the raid"),
            line(374, 176, 240, 16, "I'm in! what time are you thinking"),
            line(376, 236, 322, 21, "Around 9 my time, so like an hour from now?"),
        ])
        #expect(p.count == 3)
    }

    @Test func aTwoLineBubbleIsOneBlockAndTheNextBubbleAnother() {
        let p = paragraphs([
            line(60, 100, 330, 16, "Someone said you can catch a golden carp"),
            line(60, 120, 250, 22, "behind the lighthouse at night"),
            line(60, 170, 300, 16, "that thread was wild, half the comments"),
            line(60, 190, 180, 16, "were saying it's fake"),
        ])
        #expect(p == ["Someone said you can catch a golden carp|behind the lighthouse at night",
                      "that thread was wild, half the comments|were saying it's fake"])
    }

    @Test func bubblesOfBothSidesDoNotJoinWhenTheyAreClose() {
        // Theirs on the left, mine on the right, a tight 8 px apart: the left edges are far apart and so are the centres.
        let p = paragraphs([
            line(60, 100, 250, 16, "are you coming tonight?"),
            line(620, 124, 180, 16, "yes, see you at nine"),
            line(60, 148, 160, 16, "great, bring snacks"),
        ])
        #expect(p.count == 3)
    }

    @Test func aHeaderRowIsNotJoinedAndTheMessageUnderItIsItsOwnBlock() {
        // A header row: name, badge and time on one row, then the message under the name.
        let p = paragraphs([
            line(376, 56, 40, 14, "rinrin"),
            line(426, 58, 40, 10, "EVENT"),
            line(468, 58, 100, 12, "Today at 8:16 PM"),
            line(376, 100, 554, 16, "Is anyone doing the co-op event tonight?"),
        ])
        // The message is 30 px under the name: its own block, and the row's three pieces stay three.
        #expect(p == ["rinrin", "EVENT", "Today at 8:16 PM", "Is anyone doing the co-op event tonight?"])
    }

    // MARK: Article

    @Test func justifiedParagraphsAreSplitAtTheirGap() {
        // Two justified paragraphs: full-width lines (heights 24, 22, 26 by the glyphs), a short last line, 12 px between the
        // lines of a paragraph and 40 px between paragraphs.
        let p = paragraphs([
            line(70, 686, 708, 24, "First paragraph, line one of a justified column of text"),
            line(70, 722, 708, 22, "line two reaches the same right edge as the first one"),
            line(70, 756, 392, 26, "and the last line is short."),
            line(70, 822, 708, 24, "Second paragraph starts after a gap of forty pixels"),
            line(70, 858, 708, 20, "and runs on for a second full line before it ends"),
            line(70, 886, 120, 14, "game"),
        ])
        #expect(p == ["First paragraph, line one of a justified column of text|line two reaches the same right edge as the first one|and the last line is short.",
                      "Second paragraph starts after a gap of forty pixels|and runs on for a second full line before it ends|game"])
    }

    @Test func aShortLastLineStaysWithItsParagraph() {
        // Measured: "…the most beautiful thing in this" is 20 px tall, its last line "game" 14 px (a ratio of 1.43).
        let p = paragraphs([
            line(258, 536, 572, 20, "The sunset behind the lighthouse is the most beautiful thing in this"),
            line(260, 564, 50, 14, "game"),
        ])
        #expect(p == ["The sunset behind the lighthouse is the most beautiful thing in this|game"])
    }

    @Test func aHeadingIsNotJoinedToTheTextUnderIt() {
        // A 50 px title two lines long, then a date line 16 px tall, 22 px lower; and a heading tight over its text.
        let p = paragraphs([
            line(70, 155, 690, 50, "A title that wraps onto"),
            line(72, 206, 80, 42, "a second line"),
            line(70, 270, 318, 16, "2026-10-15 by A. Writer"),
            line(70, 400, 200, 30, "Heading"),
            line(70, 436, 600, 16, "The text right under the heading, six pixels lower."),
        ])
        #expect(p == ["A title that wraps onto|a second line", "2026-10-15 by A. Writer", "Heading",
                      "The text right under the heading, six pixels lower."])
    }

    @Test func twoColumnsAreTwoParagraphsNotInterleavedLines() {
        let p = paragraphs([
            line(70, 100, 500, 20, "left one"), line(700, 100, 400, 20, "right one"),
            line(70, 124, 500, 20, "left two"), line(700, 124, 400, 20, "right two"),
            line(70, 148, 300, 20, "left three"), line(700, 148, 300, 20, "right three"),
        ])
        #expect(p == ["left one|left two|left three", "right one|right two|right three"])
    }

    @Test func groupsComeInReadingOrderWhateverTheInputOrder() {
        let p = paragraphs([
            line(70, 300, 200, 20, "third"), line(70, 100, 200, 20, "first"), line(70, 200, 200, 20, "second"),
        ])
        #expect(p == ["first", "second", "third"])
    }

    // MARK: Subtitles

    @Test func twoCenteredSubtitleLinesAreOneBlock() {
        // Japanese subtitle: 52 and 50 px tall, centres equal, left edges 26 px apart.
        let p = paragraphs([
            line(372, 558, 536, 52, "今日はとても楽しかったね"),
            line(398, 620, 484, 50, "また明日も一緒に遊ぼう"),
        ])
        #expect(p == ["今日はとても楽しかったね|また明日も一緒に遊ぼう"])
    }

    @Test func centeredLinesOfVeryDifferentLengthJoinByTheirCentre() {
        // Left edges 170 px apart (four heights): only the centres, 640 and 640, say it is one subtitle.
        let p = paragraphs([
            line(300, 600, 680, 40, "A long first line of the subtitle goes here"),
            line(470, 646, 340, 40, "and a short one"),
        ])
        #expect(p.count == 1)
    }

    @Test func leftAlignedLinesOfDifferentLengthAreNotCenteredByAccident() {
        // Left edges 170 apart and centres 170 apart: neither the column nor the centre matches.
        let p = paragraphs([
            line(300, 600, 340, 40, "Left aligned and short"),
            line(470, 646, 340, 40, "Pushed to the right"),
        ])
        #expect(p.count == 2)
    }

    @Test func twoSubtitlesFarApartAreTwo() {
        let p = paragraphs([
            line(372, 558, 536, 52, "今日はとても楽しかったね"),
            line(398, 680, 484, 50, "また明日も一緒に遊ぼう"),
        ])
        #expect(p.count == 2)
    }

    // MARK: Lists

    @Test func listItemsAreEachABlockEvenWhenClose() {
        // Measured on the Japanese side list: 6 px between the lines, a 20 px hanging indent on the wrapped lines.
        let p = paragraphs([
            line(888, 178, 220, 22, "1.新しいノートパソコンは何が"),
            line(908, 206, 92, 19, "変わったのか"),
            line(888, 232, 216, 18, "2.電池を長持ちさせる七つの設"),
            line(908, 256, 22, 16, "定"),
            line(888, 280, 216, 18, "3.初心者でもわかる画像生成の"),
            line(908, 304, 48, 18, "仕組み"),
        ])
        #expect(p == ["1.新しいノートパソコンは何が|変わったのか", "2.電池を長持ちさせる七つの設|定", "3.初心者でもわかる画像生成の|仕組み"])
    }

    @Test func bulletsOpenBlocksAndTheirWrappedLinesStay() {
        let p = paragraphs([
            line(100, 100, 400, 18, "• Turn the lens on"),
            line(120, 122, 300, 18, "from the menu bar"),
            line(100, 144, 400, 18, "• Drag it over the text"),
            line(100, 166, 400, 18, "- and let go"),
        ])
        #expect(p == ["• Turn the lens on|from the menu bar", "• Drag it over the text", "- and let go"])
    }

    @Test func listMarkers() {
        for text in ["1. one", "12) twelve", "3．三", "2、二", "1.新しい", "(3) three", "（4）四", "① one", "⑳ twenty", "• dot", "・中点", "● ball", "※ note",
                     "- item", "– item", "* item", "+ item", "  7. indented", "-"] {
            #expect(ParagraphGrouper.startsListItem(text), "\(text)")
        }
        for text in ["", "3.14 million people", "2026年10月15日", "10月15日", "1, 2, 3", "-1 degrees", "*args", "—and then", "(see above)", "(1234) is long",
                     "Hello", "今日は", "1234. year", "A. Smith"] {
            #expect(!ParagraphGrouper.startsListItem(text), "\(text)")
        }
    }

    @Test func aDecimalAtTheStartOfAWrappedLineStaysInItsParagraph() {
        let p = paragraphs([
            line(100, 100, 600, 18, "The population grew by about"),
            line(100, 122, 300, 18, "3.14 million between the two counts."),
        ])
        #expect(p.count == 1)
    }

    // MARK: Degenerate input

    @Test func emptyAndSingleInput() {
        #expect(paragraphs([]) == [])
        #expect(paragraphs([line(0, 0, 10, 10, "x")]) == ["x"])
    }

    @Test func aBoxWithoutHeightJoinsNothing() {
        let p = paragraphs([line(0, 0, 100, 0, "flat"), line(0, 2, 100, 16, "real")])
        #expect(p.count == 2)
    }

    @Test func lineBoxesThatOverlapALittleStillJoin() {
        // "you" and "Online": the boxes overlap by 2 px.
        let p = paragraphs([line(120, 764, 28, 14, "you"), line(119, 776, 39, 14, "Online")])
        #expect(p == ["you|Online"])
    }

    @Test func aLineBesideAnotherIsNeverItsContinuation() {
        // Same row, same left edge (a stacked glyph artefact): the boxes overlap by a whole height.
        let p = paragraphs([line(100, 100, 200, 20, "first"), line(100, 102, 200, 20, "second")])
        #expect(p.count == 2)
    }
}
