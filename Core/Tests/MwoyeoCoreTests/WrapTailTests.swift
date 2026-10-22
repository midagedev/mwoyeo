import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// The last line of a wrapped message that is a few characters long (round read117, item 2: "イだわ" under "マジでここが今までで一番いいコミュニテ"
/// was a block of its own in a chat render and was translated alone). The boxes are the document reader's, read from a 840 x 1736 chat
/// picture at three type sizes (`/tmp/r117/item2`, a Discord-like page in Japanese): the message wraps at the container's width, so its
/// full lines end at x = 734 +- 3.
@Suite struct WrapTailTests {
    private func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }

    private typealias Page = (lines: [[CGRect]], texts: [[String]])

    /// Blocks 5, 9, 13, 20, 23, 24 and 27 of the picture (as the reader returned them), and a short message below.
    private func chat(head: CGRect = CGRect(x: 125, y: 1154, width: 609, height: 35), headText: String = "マジでここが今までで一番いいコミュニテ",
                      tail: CGRect = CGRect(x: 128, y: 1199, width: 95, height: 34), tailText: String = "イだわ") -> Page {
        (lines: [[r(125, 174, 609, 38), r(125, 220, 318, 34)], [r(125, 346, 612, 38), r(125, 391, 161, 35)],
                 [r(122, 580, 612, 35), r(125, 626, 256, 40)], [r(129, 1021, 602, 38)],
                 [head], [tail], [r(125, 1389, 416, 31)]],
         texts: [["あのスレやばかったよね、コメントの半分", "はガセだって言ってた"], ["昨日釣れたよ！！40分くらいかかったけど", "本当にいる"],
                 ["運営が次のアプデで隠しスポットもっと増", "やすって言ってた"], ["よし決まり、レイド終わったら釣り行こう"],
                 [headText], [tailText], ["急にしんみりするのやめてw"]])
    }

    private func pairs(_ page: Page) -> [WrapTail.Pair] { WrapTail.pairs(lines: page.lines, texts: page.texts) }

    private static let found = [WrapTail.Pair(head: 4, tail: 5)]

    // MARK: The tail of a wrapped message

    @Test func theTailOfAWrappedMessageIsFoundAndJoins() {
        let page = chat()
        #expect(pairs(page) == Self.found)
        #expect(BlockMerge.groups(page.lines, tails: pairs(page)) == [[0], [1], [2], [3], [4, 5], [6]])
        #expect(BlockMerge.groups(page.lines) == [[0], [1], [2], [3], [4], [5], [6]], "without the rule the blocks stay apart")
    }

    @Test func theThreeSizesOfThePicture() {
        // 14, 15 and 16 px type: the head ends at 734, 734 and 733; the tail is 95 wide and 45 to 46 px below.
        for (x, w, y, hy) in [(131.0, 600.0, 1281.0, 1326.0), (125.0, 609.0, 1154.0, 1199.0), (129.0, 602.0, 916.0, 962.0)] {
            let page = chat(head: r(x, y, w, 35), tail: r(128, hy, 95, 36))
            #expect(pairs(page) == Self.found, "head at \(y)")
        }
    }

    @Test func aTailInLatinIsOneToo() {
        let page = chat(headText: "I think this is the best community we have had so far, and I", tailText: "it.")
        #expect(pairs(page) == Self.found)
    }

    // MARK: A message of its own

    @Test func aMessageThatEndsShortIsFollowedByAMessage() {
        // The line above stops 4 heights before the container's edge: it did not wrap.
        #expect(pairs(chat(head: r(125, 1154, 480, 35))).isEmpty)
    }

    @Test func aFullStopEndsTheParagraph() {
        for end in ["。", "！", "？", ".", "…"] {
            #expect(pairs(chat(headText: "マジでここが今までで一番いいコミュニテ" + end)).isEmpty, "ends with \(end)")
        }
    }

    @Test func aLongerOrNumericLineIsNoTail() {
        for text in ["イだわね", "20:21", "12", "①", "G＜6", "→", "+1", "", "   ", "。", "!!", "…", "）"] {
            #expect(pairs(chat(tailText: text)).isEmpty, "'\(text)'")
        }
        #expect(WrapTail.isTail("ね"))
        #expect(WrapTail.isTail("だわ。"))
        #expect(WrapTail.isTail("it."))
        #expect(WrapTail.isTail(" ね "))
    }

    @Test func aTailThatIsNotWhereTheNextLineWouldBeIsNoTail() {
        #expect(pairs(chat(tail: r(128, 1154 + 35 + 25, 95, 34))).isEmpty, "0.7 heights below: a message of its own")
        #expect(pairs(chat(tail: r(128 + 80, 1199, 95, 34))).isEmpty, "indented by 2.3 heights")
        #expect(pairs(chat(tail: r(128, 1199, 95, 80))).isEmpty, "a heading, not a line of text: 2.3 times as tall")
        #expect(pairs(chat(tail: r(128, 1100, 95, 34))).isEmpty, "above the line")
        #expect(pairs(chat(tail: r(128, 1199, 700, 34))).isEmpty, "a tail is not wider than the line above it")
    }

    @Test func aLineThatIsAloneInItsColumnHasNoEdge() {
        // Nothing else of the column is as wide: the longest line of a list is not wrapped.
        let log = (lines: [[r(100, 100, 240, 30)], [r(100, 140, 180, 30)], [r(100, 180, 600, 30)], [r(100, 220, 40, 30)]],
                   texts: [["connecting to the host"], ["retrying"], ["the connection was closed by peer"], ["ok"]])
        #expect(pairs(log).isEmpty)
    }

    @Test func aLineOfAnotherColumnIsNoEdge() {
        // A wider column beside it does not move the edge of this one: `sameColumn`.
        let page = (lines: [[r(100, 100, 400, 30)], [r(100, 140, 380, 30)], [r(100, 180, 400, 30)], [r(100, 220, 40, 30)],
                            [r(700, 100, 500, 30)], [r(700, 140, 490, 30)]],
                    texts: [["a wrapped line that goes on"], ["and on"], ["and another that is full"], ["ly"],
                            ["a line in the wider column"], ["that goes on"]])
        #expect(pairs(page) == [WrapTail.Pair(head: 2, tail: 3)], "the tail of a full line in a column of full lines")
        // The only full lines of the page are in the other column: this column has no edge to be full to.
        let beside = (lines: [[r(100, 180, 400, 30)], [r(100, 220, 40, 30)], [r(700, 100, 400, 30)], [r(700, 140, 390, 30)]],
                      texts: [["a line that is full"], ["ly"], ["a line in the next column"], ["that is full too"]])
        #expect(pairs(beside).isEmpty)
    }

    @Test func aBlockTakesOneTail() {
        var page = chat()
        page.lines.append([r(128, 1199, 95, 34)])
        page.texts.append(["イだわ"])
        let found = pairs(page)
        #expect(found.count == 1 && found[0].head == 4, "\(found)")
    }

    @Test func aTailThatContinuesAListItemIsNone() {
        #expect(pairs(chat(tailText: "・ね")).isEmpty)
        #expect(pairs(chat(tailText: "- a")).isEmpty)
    }
}
