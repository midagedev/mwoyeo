import Foundation
import CoreText
import Testing
@testable import MwoyeoCore

/// Defects from the use-case audit (papers, subtitles, games, chat, documents), 2026-10-18.
@Suite struct UseCaseFixTests {
    // MARK: literal text stays as it is

    @Test func shellCommandsTimestampsAndURLsAreLeftAlone() {
        for t in ["$ npm run build", "% make test", "root@box:/# apt update", "user@host:~$ ls -la", "10:42 AM", "10:42", "오후 2:11", "午後3:20",
                  "2026-10-14", "14/10/2026 10:42", "https://example.com/a", "www.example.com", "github.com/foo/bar"] {
            #expect(!TranslationFilter.needsTranslation(t, cjkSource: false), "\(t)")
            #expect(!TranslationFilter.needsTranslation(t, cjkSource: true), "\(t)")
        }
    }

    @Test func ordinaryTextIsStillTranslated() {
        for t in ["Today at 10 we meet", "Run the build", "# general", "# 일반", "The price is $5", "It costs # 3 more", "Posted October 14, 2026 by Dana Cole",
                  "C# is great", "F# for beginners", "50% off everything", "» Read more", "C:/Users path explained"] {
            #expect(TranslationFilter.needsTranslation(t, cjkSource: false), "\(t)")
        }
        #expect(TranslationFilter.needsTranslation("오후에 만나요", cjkSource: true))
    }

    // MARK: a bold CJK glyph is text, not an icon

    @Test func aSolidCJKGlyphIsNotAnIcon() {
        let solid = InkCluster(minX: 10, maxX: 40, color: RGBA(255, 255, 255), ink: 900, solid: true)
        let glyph = StyleRuns.token(text: "君", minX: 8, maxX: 42, clusters: [solid], lineHeight: 34)
        #expect(!glyph.solid)
        #expect(glyph.color == RGBA(255, 255, 255))
        #expect(StyleRuns.runs([glyph, StyleRuns.Token(text: "は", minX: 44, maxX: 70, color: RGBA(255, 255, 255), solid: false)], lineHeight: 34) == [0..<2])
        // A filled shape that is not a letter still is one.
        #expect(StyleRuns.token(text: "😊", minX: 8, maxX: 42, clusters: [solid], lineHeight: 34).solid)
    }

    // MARK: names above bubbles

    private func item(_ text: String, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 20, _ c: RGBA, lines: Int = 1) -> LabelRule.Item {
        .init(rect: CGRect(x: x, y: y, width: w, height: h * CGFloat(lines)), text: text, color: c, lineHeight: h)
    }

    @Test func aCJKNameAboveAMessageIsALabel() {
        let grey = RGBA(120, 120, 120), black = RGBA(20, 20, 20)
        let items = [item("민지", x: 60, y: 100, w: 36, grey), item("야 오늘 저녁에 뭐 해?", x: 70, y: 128, w: 200, black),
                     item("약속 없는데 왜?", x: 70, y: 200, w: 150, black)]
        #expect(LabelRule.labels(items) == [0])
    }

    @Test func aHeadingOverBodyTextIsNotAName() {
        let blue = RGBA(20, 60, 200), black = RGBA(20, 20, 20)
        // Larger than the body, so a heading; and a Latin word is left to the engine.
        #expect(LabelRule.labels([item("개요", x: 10, y: 10, w: 60, h: 34, blue), item("본문은 여기에서 시작합니다", x: 10, y: 54, w: 300, black)]).isEmpty)
        #expect(LabelRule.labels([item("Trending", x: 10, y: 10, w: 80, blue), item("Ten tips for faster Wi-Fi", x: 10, y: 38, w: 200, black)]).isEmpty)
        // The same colour as the text below: not a name tag.
        #expect(LabelRule.labels([item("개요", x: 10, y: 10, w: 60, black), item("본문은 여기에서 시작합니다", x: 10, y: 38, w: 300, black)]).isEmpty)
        // A sentence is never a name.
        #expect(LabelRule.labels([item("안녕하세요.", x: 10, y: 10, w: 60, blue), item("본문은 여기에서 시작합니다", x: 10, y: 38, w: 300, black)]).isEmpty)
    }

    @Test func aNameInTheInkOfItsBoxIsANameTagByPlaceAlone() {
        // Recent117: a game's name has the ink of its box, so `labels` keeps it for the engine; the stack of recent lines asks only where it stands.
        let black = RGBA(20, 20, 20)
        let tag = item("九十九", x: 10, y: 10, w: 60, black), box = item("はい、シュザンヌ様。足元にお気をつけください", x: 10, y: 38, w: 300, black)
        #expect(LabelRule.labels([tag, box]).isEmpty)
        #expect(LabelRule.nameTags([tag, box]) == [0])
        #expect(LabelRule.nameTags([item("はい", x: 10, y: 10, w: 60, black)]).isEmpty, "nothing under it: a word that was said")
        #expect(LabelRule.nameTags([item("安心して。", x: 10, y: 10, w: 60, black), box]).isEmpty, "a sentence is never a name")
        #expect(LabelRule.nameTags([tag, item("はい、シュザンヌ様。足元にお気をつけください", x: 10, y: 200, w: 300, black)]).isEmpty, "far under it: not its box")
    }

    // MARK: a HUD's labels are translated (untrans117, 2026-10-23)

    @Test func aWordBesideAFigureIsNotALabel() {
        let white = RGBA(255, 255, 255), yellow = RGBA(255, 220, 60), red = RGBA(230, 60, 60)
        // The three HUD fixtures of the audit: a label and its value in another colour were both left as written.
        #expect(LabelRule.labels([item("Gold", x: 20, y: 20, w: 60, h: 24, white), item("540", x: 90, y: 20, w: 50, h: 24, yellow)]).isEmpty)
        #expect(LabelRule.labels([item("体力", x: 20, y: 20, w: 50, h: 24, white), item("120", x: 80, y: 20, w: 50, h: 24, red)]).isEmpty)
        // A price, a ratio, a time, a percentage, a count with its unit mark.
        for value in ["1,280 G", "120/300", "00:45", "35%", "x12", "480円", "¥1,200", "3.5"] {
            #expect(LabelRule.labels([item("Gold", x: 20, y: 20, w: 60, h: 24, white), item(value, x: 90, y: 20, w: 90, h: 24, yellow)]).isEmpty, "\(value)")
        }
        // What is not only a figure still makes the word a label: a phrase, a relative time, a clock with its marker, a name's handle and its age.
        for value in ["Find the lost key", "5時間前", "8:12 PM", "3 replies", "12 hours ago"] {
            #expect(LabelRule.labels([item("Quest", x: 20, y: 20, w: 70, h: 24, white), item(value, x: 100, y: 20, w: 120, h: 24, yellow)]) == [0], "\(value)")
        }
    }

    @Test func aHeadingOverAListIsNotALabel() {
        let white = RGBA(255, 255, 255), yellow = RGBA(255, 220, 60)
        let heading = item("アイテム", x: 20, y: 20, w: 100, h: 24, yellow)
        func rows(_ n: Int, _ texts: [String] = ["ポーションを使う", "ハイポーションを使う", "毒消しを使う", "エーテルを使う"]) -> [LabelRule.Item] {
            (0..<n).map { item(texts[$0], x: 20, y: 52 + CGFloat($0) * 32, w: 200, h: 24, white) }
        }
        #expect(LabelRule.labels([heading] + rows(3)).isEmpty, "a yellow heading over a white list of three")
        #expect(LabelRule.labels([heading] + rows(4)).isEmpty, "of four")
        // Rows with a sparse pitch (a menu's), and a list that goes on past the heading's reach.
        let sparse = (0..<4).map { item(["ポーション", "ハイポーション", "毒消し", "エーテル"][$0], x: 20, y: 70 + CGFloat($0) * 46, w: 160, h: 24, white) }
        #expect(LabelRule.labels([heading] + sparse).isEmpty)
        // A name over one line of speech, over two, or over three sentences is a name tag as before.
        let speech = ["야 오늘 저녁에 뭐 해?", "약속 없는데 왜?", "새로 생긴 라멘집 가보자!"]
        let name = item("민지", x: 20, y: 20, w: 40, h: 24, yellow)
        for n in 1...3 {
            let lines = (0..<n).map { item(speech[$0], x: 20, y: 52 + CGFloat($0) * 32, w: 200, h: 24, white) }
            #expect(LabelRule.labels([name] + lines) == [0], "a name over \(n) lines of speech")
        }
        // A heading over one line, or over two, is not told from a name by its place: kept, as before.
        #expect(LabelRule.labels([heading] + rows(1)) == [0])
        #expect(LabelRule.labels([heading] + rows(2)) == [0])
        // The list in the heading's own colour was never a label.
        #expect(LabelRule.labels([item("アイテム", x: 20, y: 20, w: 100, h: 24, white)] + rows(3)).isEmpty)
    }

    // MARK: Korean wraps at spaces

    @Test func koreanWrapsAtSpacesNotInsideWords() {
        let text = "노스필드 마을의 대장장이에게 이야기를 걸어 보세요"
        let font = CTFontCreateWithName("Apple SD Gothic Neo" as CFString, 20, nil)
        func lines(_ t: String, width: CGFloat) -> [String] {
            let s = NSAttributedString(string: t, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(s), CFRange(), CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 1000), transform: nil), nil)
            return (CTFrameGetLines(frame) as! [CTLine]).map { l in
                let r = CTLineGetStringRange(l)
                return (s.string as NSString).substring(with: NSRange(location: r.location, length: r.length)).replacingOccurrences(of: "\u{2060}", with: "")
            }
        }
        for width in stride(from: 90.0, through: 260.0, by: 10.0) {
            let words = Set(text.split(separator: " ").map(String.init))
            for l in lines(TextFitter.keepingWordsTogether(text), width: width) {
                // Every line is whole words (the longest word is 6 syllables, 120 pt, so widths from 130 pt keep them intact).
                if width >= 130 { #expect(l.split(separator: " ").allSatisfy { words.contains(String($0)) }, "width \(width): \(l)") }
            }
        }
        #expect(TextFitter.keepingWordsTogether("가나 다") == "가\u{2060}나 다")
        #expect(TextFitter.keepingWordsTogether("Hello 世界") == "Hello 世界")
    }

    // MARK: line size

    @Test func twoLinesOfOneParagraphStayTogetherWhateverTheirAscenders() {
        // d06: the same 12.6 px per character, boxes 50 and 37 px tall.
        let a = LineSize.Line(height: 50, width: 1210, text: String(repeating: "a new processor ", count: 6).prefix(96).description)
        let b = LineSize.Line(height: 37, width: 590, text: "price, according to the company that makes it.")
        #expect(!LineSize.differ(a, b))
        #expect(!LineSize.differ(b, a))
    }

    @Test func aHeadingOverBodyTextStillSplits() {
        let heading = LineSize.Line(height: 50, width: 26 * 22, text: "Battery life doubles, say")
        let body = LineSize.Line(height: 37, width: 13 * 60, text: String(repeating: "x", count: 60))
        #expect(LineSize.differ(heading, body))
        #expect(LineSize.differ(LineSize.Line(height: 60, width: 300, text: "概要の見出しです"), LineSize.Line(height: 36, width: 36 * 20, text: String(repeating: "あ", count: 20))))
        #expect(!LineSize.differ(LineSize.Line(height: 36, width: 36 * 12, text: String(repeating: "あ", count: 12)), LineSize.Line(height: 37, width: 37 * 20, text: String(repeating: "あ", count: 20))))
    }

    // MARK: vertical text

    @Test func tallNarrowColumnsAreVerticalText() {
        let columns = (0..<5).map { CGRect(x: 40 + CGFloat($0) * 60, y: 20, width: 44, height: 900) }
        #expect(VerticalText.isVertical(columns))
        let lines = (0..<6).map { CGRect(x: 40, y: 20 + CGFloat($0) * 50, width: 900, height: 36) }
        #expect(!VerticalText.isVertical(lines))
        // A lone tall mark, or two among many horizontal lines, does not make a page vertical.
        #expect(!VerticalText.isVertical(lines + [CGRect(x: 0, y: 0, width: 10, height: 40)]))
        #expect(!VerticalText.isVertical(lines + columns.prefix(2)))
    }

    @Test func noteAndListMarkersStartAParagraph() {
        for t in ["3 Corresponding author.", "[4] K. He, X. Zhang", "• First point", "† Equal contribution"] { #expect(ParagraphMarker.startsItem(t), "\(t)") }
        for t in ["price, according to the company", "2 million users signed up", "10:42 AM", "and then 3 Corresponding", "The [4] is not first"] { #expect(!ParagraphMarker.startsItem(t), "\(t)") }
    }
}
