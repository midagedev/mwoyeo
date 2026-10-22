import XCTest
@testable import MwoyeoCore

/// The stack of lines that left the lens (design games-and-video §2), fed by the transcript recorder's own events.
final class RecentLinesTests: XCTestCase {
    private struct Feed {
        var recorder = TranscriptRecorder()
        var recent: RecentLines
        var time = 0.0
        /// `hold` 0 shows a line the look after it left (the rule is what these tests are about); the tests of the wait give their own.
        init(capacity: Int = 3, hold: TimeInterval = 0) { recent = RecentLines(capacity: capacity, hold: hold) }
        /// One observation: the lines in the lens now, each with its translation (nil: not translated yet).
        mutating func show(_ lines: [(String, String?)]) {
            time += 1
            let observed = lines.map { TranscriptRecorder.Observed(source: $0.0, translation: $0.1, inLens: true) }
            recent.observe(recorder.observe(time: time, lines: observed), lines: observed)
        }
        var sources: [String] { recent.stack.map(\.source) }
        func sources(at t: TimeInterval) -> [String] { recent.stack(at: t).map(\.source) }
        /// Every source the stack showed at any look (at the time of that look).
        var seen: Set<String> = []
        /// One observation with the places of the blocks (points from the lens's corner), the regions the lens ignores, and its time (60 ms
        /// after the last one when not given).
        mutating func look(_ lines: [(String, CGRect)], translated: Bool = true, ignored: [CGRect] = [], at when: TimeInterval? = nil) {
            time = when ?? time + 0.06
            let observed = lines.map { TranscriptRecorder.Observed(source: $0.0, translation: translated ? "t:" + $0.0 : nil, inLens: true, frame: $0.1) }
            recent.observe(recorder.observe(time: time, lines: observed), lines: observed, ignored: ignored, at: time)
            seen.formUnion(sources(at: time))
        }
    }

    // A visual novel's lens (768 x 225 points): the speaker's name on the box's top edge, the text in the box under it.
    private let box = CGRect(x: 20, y: 70, width: 700, height: 70)
    private func name(_ n: String = "シュザンヌ") -> (String, CGRect) { (n, CGRect(x: 10, y: 30, width: 80, height: 28)) }
    private let first = "はい、シュザンヌ様。足元にお気をつけください"
    private let second = "エルヴェ、大丈夫よ。ゆっくり行きましょう"
    private let third = "九十九、ここが月影の祠よ。間違いないわ"

    /// A game types its line out: the lens reads a longer part of it every 60 ms (the first characters, then more).
    private func typeOut(_ f: inout Feed, _ line: String, by speaker: String, step: Int = 3) {
        var n = step
        while n < line.count {
            f.look([name(speaker), (String(line.prefix(n)), box)])
            n += step
        }
        f.look([name(speaker), (line, box)])
    }

    func testTheLinesThatLeftStayNewestFirst() {
        var f = Feed()
        for n in ["A", "B", "C", "D"] { f.show([(n, "t\(n)")]) }
        XCTAssertEqual(f.sources, ["C", "B", "A"], "the line on screen is not in the stack")
        XCTAssertEqual(f.recent.stack.first?.translation, "tC")
    }

    func testTheStackHoldsAtMostItsCapacity() {
        var f = Feed(capacity: 2)
        for n in ["A", "B", "C", "D", "E"] { f.show([(n, "t\(n)")]) }
        XCTAssertEqual(f.sources, ["D", "C"])
        f.recent.setCapacity(99)
        XCTAssertEqual(f.recent.capacity, RecentLines.range.upperBound)
        f.recent.setCapacity(0)
        XCTAssertEqual(f.recent.capacity, RecentLines.range.lowerBound)
    }

    func testALineThatReturnsLeavesTheStack() {
        var f = Feed()
        for n in ["A", "B", "C"] { f.show([(n, "t\(n)")]) }
        XCTAssertEqual(f.sources, ["B", "A"])
        f.show([("A", "tA")])
        XCTAssertEqual(f.sources, ["C", "B"])
    }

    func testALineNotTranslatedYetIsNeverKept() {
        var f = Feed()
        f.show([("A", "tA")])
        f.show([("B", nil)])
        f.show([("C", "tC")])
        XCTAssertEqual(f.sources, ["A"])
    }

    func testSeveralLinesOfAChatKeepTheirOrder() {
        var f = Feed(capacity: 4)
        f.show([("one", "1"), ("two", "2")])
        f.show([("three", "3"), ("four", "4")])
        XCTAssertEqual(f.sources, ["two", "one"])
    }

    func testAFragmentFoldsIntoTheFullerReading() {
        var f = Feed()
        f.show([("Patch 1.4 finally fixed the double jump bug. What else are you hoping", "frag")])
        f.show([("Patch 1.4 finally fixed the double jump bug. What else are you hoping they fix next?", "whole")])
        f.show([("Z", "tZ")])
        XCTAssertEqual(f.recent.stack.map(\.translation), ["whole"], "one line, the fuller reading")
    }

    func testAChangedTranslationReplacesTheOneKept() {
        var f = Feed()
        f.show([("A", "old")])
        f.show([("B", "tB")])
        f.show([("A", "new")])
        f.show([("C", "tC")])
        XCTAssertEqual(f.recent.stack.first { $0.source == "A" }?.translation, "new")
    }

    func testALineTypedOutIsOneLineInTheStack() {
        // Recent117 (film 4 F21): every part of a typed-out line was translated alone and kept beside the line.
        var f = Feed()
        typeOut(&f, first, by: "シュザンヌ")
        typeOut(&f, second, by: "エルヴェ")
        typeOut(&f, third, by: "九十九")
        XCTAssertEqual(f.sources, [second, first], "the whole lines only, the one in the lens left out")
        XCTAssertEqual(f.recent.stack.map(\.translation), ["t:" + second, "t:" + first])
    }

    func testPartsReadApartFromTheLineAreTheLine() {
        // The stage's first characters are read as blocks of their own, in the middle of the box, not in front of the line.
        var f = Feed()
        f.look([name(), ("ュザ", CGRect(x: 240, y: 72, width: 50, height: 60))])
        f.look([name(), ("はい、シュザンヌ様。足元にお気をつけ", box), ("い", CGRect(x: 300, y: 100, width: 25, height: 36))])
        f.look([name(), (first, box)])
        f.look([name("エルヴェ"), (second, box)])
        XCTAssertEqual(f.sources, [first])
    }

    func testAPartIsTheLineEvenWhenTheLineIsNotTranslatedYet() {
        var f = Feed()
        f.look([("ヴ", CGRect(x: 240, y: 72, width: 30, height: 40))])
        f.look([(second, box)], translated: false)
        f.look([("ok", CGRect(x: 10, y: 10, width: 40, height: 20))])
        XCTAssertEqual(f.sources, [], "the part is the line that is still being read; the line is on screen or not translated")
    }

    func testAReadingInAnIgnoredRegionIsNeverAKeptLine() {
        // Recent117 (film 4 F21): the HUD was read before Ignore Region took effect and stayed in the stack.
        let hud = CGRect(x: 250, y: 10, width: 500, height: 40)
        var f = Feed()
        f.look([("所持金 1,280 G", CGRect(x: 520, y: 14, width: 200, height: 32)), (first, box)])
        f.look([(first, box)], ignored: [hud])
        f.look([(second, box)], ignored: [hud])
        XCTAssertEqual(f.sources, [first], "the HUD read before the region was ignored is not a line")
        // The same reads without the region are the control: the HUD is a line then.
        var control = Feed()
        control.look([("所持金 1,280 G", CGRect(x: 520, y: 14, width: 200, height: 32)), (first, box)])
        control.look([(first, box)])
        control.look([(second, box)])
        XCTAssertEqual(control.sources, [first, "所持金 1,280 G"])
    }

    func testAReadingStillInTheLensWhileItsRegionIsIgnoredNeverEnters() {
        // A pass that was already running when the region was marked still reads the HUD once.
        let hud = CGRect(x: 250, y: 10, width: 500, height: 40)
        var f = Feed()
        f.look([("金 1,280 G", CGRect(x: 520, y: 14, width: 120, height: 32)), (first, box)], ignored: [hud])
        f.look([(second, box)], ignored: [hud])
        f.look([(third, box)], ignored: [hud])
        XCTAssertEqual(f.sources, [second, first])
    }

    func testANameOverItsBoxIsNotALine() {
        var f = Feed()
        f.look([name("九十九"), (first, box)])
        f.look([name("エルヴェ"), (second, box)])
        f.look([name("シュザンヌ"), (third, box)])
        XCTAssertEqual(f.sources, [second, first], "the names left the lens too, and none of them is kept")
        XCTAssertEqual(f.recent.reading(of: RecentLines.Line(source: "九十九", translation: "", time: 0)), .label)
    }

    func testAShortLineAloneInTheBoxIsALine() {
        // 'はい' is a word of two kana like a name, but nothing longer stands under it: it is what was said.
        var f = Feed()
        f.look([("はい", box)])
        f.look([(second, box)])
        f.look([(third, box)])
        XCTAssertEqual(f.sources, [second, "はい"])
    }

    func testALineThatContainsAnEarlierOneIsNotItsPartWhenItIsElsewhere() {
        // A chat: 'ok' was a message of its own; the longer one came later at the bottom, where the first no longer is.
        var f = Feed()
        f.look([("ok", CGRect(x: 10, y: 150, width: 40, height: 20))])
        f.look([("ok", CGRect(x: 10, y: 120, width: 40, height: 20)), ("ok, see you at eight", CGRect(x: 10, y: 150, width: 200, height: 20))])
        f.look([("later", CGRect(x: 10, y: 150, width: 100, height: 20))])
        XCTAssertEqual(f.sources, ["ok, see you at eight", "ok"])
    }

    func testALineSaidAfterALongerOneItIsPartOfStaysALine() {
        // Parts come before the whole. 'はい' after 'はい、そうですね' in the same box is a new line.
        var f = Feed()
        f.look([("はい、そうですね", box)])
        f.look([("はい", box)])
        f.look([(second, box)])
        XCTAssertEqual(f.sources, ["はい", "はい、そうですね"])
    }

    func testLinesThatScrollByInOneLookEachAreAllKept() {
        // Not a dwell rule: a one-row lens over a fast chat shows each line for one look, and those are the lines the stack is for.
        var f = Feed(capacity: 4)
        for n in ["alpha one", "bravo two", "charlie three", "delta four", "echo five"] { f.look([(n, CGRect(x: 10, y: 10, width: 200, height: 20))]) }
        XCTAssertEqual(f.sources, ["delta four", "charlie three", "bravo two", "alpha one"])
    }

    func testAPartIsTheLineOnlyWhileTheLineFollowsItClosely() {
        // `reach` changes of what the lens shows after the part was last seen; a look that repeats the one before is not a change.
        func run(between n: Int) -> [String] {
            var f = Feed(capacity: 8)
            f.look([("ュザ", CGRect(x: 240, y: 72, width: 50, height: 60))])
            for k in 0..<n { f.look([("x\(k) other", CGRect(x: 10, y: 150, width: 100, height: 20))]) }
            for _ in 0..<5 { f.look([("x\(n) other", CGRect(x: 10, y: 150, width: 100, height: 20))]) }
            f.look([(first, box)])
            f.look([("last", CGRect(x: 10, y: 150, width: 100, height: 20))])
            return f.sources.filter { $0 == "ュザ" }
        }
        // n other reads and one more, shown five times over, then the line: the line is the (n + 2)th change after the part.
        XCTAssertEqual(run(between: RecentLines.reach - 2), [], "the line showed within reach: the part is the line")
        XCTAssertEqual(run(between: RecentLines.reach - 1), ["ュザ"], "the line showed one change too late: the part was a line of its own")
    }

    func testTheFinalLineReadAgainWithAnotherTranslationIsOneLineWithTheNewerOne() {
        var f = Feed()
        typeOut(&f, first, by: "シュザンヌ")
        f.look([name(), (first, box)])
        let better = TranscriptRecorder.Observed(source: first, translation: "better", inLens: true, frame: box)
        f.recent.observe(f.recorder.observe(time: f.time + 1, lines: [better]), lines: [better])
        typeOut(&f, second, by: "エルヴェ")
        f.look([name("九十九"), (third, box)])
        XCTAssertEqual(f.sources, [second, first])
        XCTAssertEqual(f.recent.stack.last?.translation, "better")
    }

    /// The reads of the film's game take (film 4, take t4-game, `render` lines of app.err with the patches and the times they gave, the patches in
    /// the capture's pixels), as the looks they came in: the name tag, the first characters of a line read as blocks of their own, the line, a
    /// HUD read after its region was ignored. Looks are on the take's clock in seconds from the first read of advance 1; the stack is the one the
    /// panel would show `hold` after the last look of each advance, and at no look did anything but a whole line show.
    func testTheFilmStageReadsKeepOnlyTheLines() {
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x, y: y, width: w, height: h) }
        let tag = "九十九", tagE = "エルヴェ", tagS = "シュザンヌ"
        let l2 = "九十九、ここが月影のよ。間違いないわ", l3 = "はい、シュザンヌ様。足元にお気をつけください"
        let l4a = "シュザンヌ様、お急ぎになりませぬよう。", l4b = "年寄りの足には堪えますので"
        let l5 = "エルヴェ、大丈夫よ。ゆっくり行きましょう", l6 = "エルヴェさん、肩をお貸ししますよ"
        let wholes: Set = [l2, l3, l4a, l4b, l5, l6]
        let hud = r(1500, 150, 400, 150)
        var f = Feed(capacity: 8, hold: RecentLines.hold)
        func settled(_ t: TimeInterval) -> [String] { f.sources(at: t + RecentLines.hold) }
        // The line on screen at the start, with the HUD read before the region was ignored.
        f.look([(tagS, r(561, 256, 216, 78)), (l2, r(530, 371, 1229, 106)), ("金 1,280 G", r(1588, 193, 167, 72))], ignored: [hud], at: -5.0)
        f.look([(tagS, r(561, 256, 216, 78)), (l2, r(530, 371, 1229, 106))], ignored: [hud], at: -4.6)
        XCTAssertEqual(settled(-4.6), [], "the HUD left the lens and is not a line; the line on screen is not in the stack")
        // Advance 1: 'ュザ' (a part of 'シュザンヌ' in the line), then the line's first part and 'い', then the line.
        f.look([(tag, r(559, 262, 139, 68)), ("ュザ", r(782, 368, 250, 111))], ignored: [hud], at: 0.000)
        f.look([(tag, r(559, 261, 139, 70)), ("はい、シュザンヌ様。足元にお気をつけ", r(535, 367, 1117, 99)), ("い", r(721, 465, 118, 82))], ignored: [hud], at: 0.494)
        f.look([(tag, r(559, 261, 139, 70)), (l3, r(535, 371, 1415, 178))], ignored: [hud], at: 0.895)
        f.look([(tag, r(559, 264, 139, 68)), (l3, r(534, 370, 1117, 199))], ignored: [hud], at: 1.349)
        XCTAssertEqual(settled(1.349), [l2], "the line that left, and neither the name nor 'ュザ'")
        // Advance 2: a line of two sentences, each its own block.
        f.look([(tagE, r(716, 507, 173, 73)), (l4a, r(689, 606, 1149, 104))], ignored: [hud], at: 3.551)
        f.look([(tagE, r(560, 264, 173, 68)), (l4a, r(535, 371, 1145, 95)), (l4b, r(531, 465, 1149, 100))], ignored: [hud], at: 6.923)
        XCTAssertEqual(settled(6.923), [l3, l2], "the whole of line 3 now, the name left too and is not kept")
        // Advance 3: the name is read while it fades in (a misread), then as it is, then the line.
        f.look([("シュサンヌ", r(563, 265, 212, 64))], ignored: [hud], at: 8.943)
        f.look([(tagS, r(561, 256, 216, 78))], ignored: [hud], at: 9.142)
        f.look([(tagS, r(561, 256, 216, 78)), (l5, r(532, 371, 1236, 106))], ignored: [hud], at: 9.196)
        XCTAssertEqual(settled(9.196), [l4b, l4a, l3, l2], "both sentences of line 4, the later one first (newest nearest the lens)")
        // Advance 4: 'ヴ' and '肩を', each read on its own, then the line.
        f.look([(tag, r(561, 263, 126, 64)), ("ヴ", r(662, 371, 118, 81))], ignored: [hud], at: 14.038)
        f.look([(tag, r(559, 261, 139, 71)), ("肩を", r(961, 368, 252, 102))], ignored: [hud], at: 14.328)
        f.look([(tag, r(559, 264, 139, 68)), (l6, r(532, 371, 986, 106))], ignored: [hud], at: 15.002)
        XCTAssertEqual(settled(15.002), [l5, l4b, l4a, l3, l2], "the lines, and not one of the parts")
        XCTAssertTrue(f.seen.isSubset(of: wholes), "at no look did a part, a name or the HUD show: \(f.seen.subtracting(wholes))")
    }

    func testAPartThatLeavesBeforeItsLineShowsNothingUntilTheLine() {
        // Film 4, advance 4: 'ヴ' left at the look of '肩を', 0.67 s before the line that holds it was read. The stack showed it for those 0.67 s.
        var f = Feed(hold: RecentLines.hold)
        let tag = name("九十九")
        f.look([tag, ("ヴ", CGRect(x: 662, y: 371, width: 118, height: 81))], at: 0)
        f.look([tag, ("肩を", CGRect(x: 961, y: 368, width: 252, height: 102))], at: 0.29)
        XCTAssertEqual(f.sources(at: 0.29), [], "'ヴ' left, and no line holds it yet: nothing shows")
        XCTAssertEqual(f.sources(at: 0.96), [], "still waiting, 0.67 s on")
        f.look([tag, ("エルヴェさん、肩をお貸ししますよ", CGRect(x: 532, y: 371, width: 986, height: 106))], at: 0.96)
        XCTAssertEqual(f.sources(at: 5), [], "the parts are the line, which is on screen")
    }

    func testALineThatLeftShowsAfterTheHoldAndNextLiftSaysWhen() {
        var f = Feed(hold: 1)
        f.look([("alpha one", CGRect(x: 10, y: 10, width: 200, height: 20))], at: 0)
        f.look([("bravo two", CGRect(x: 10, y: 10, width: 200, height: 20))], at: 5)
        XCTAssertEqual(f.sources(at: 5.9), [], "it left 0.9 s ago")
        XCTAssertEqual(try XCTUnwrap(f.recent.nextLift(at: 5.9)), 0.1, accuracy: 1e-9)
        XCTAssertEqual(f.sources(at: 6.0), ["alpha one"])
        XCTAssertNil(f.recent.nextLift(at: 6.0), "nothing waits any more")
        XCTAssertEqual(f.sources, [], "as of the last look, at 5, it still waited")
    }

    func testALineIsHeldFromTheLookThatLacksItNotFromTheOneBefore() {
        // A scene that does not change makes no look: the line stood there for as long as it stood.
        var f = Feed(hold: 1)
        f.look([("alpha one", CGRect(x: 10, y: 10, width: 200, height: 20))], at: 0)
        f.look([("alpha one", CGRect(x: 10, y: 10, width: 200, height: 20))], at: 30)
        f.look([("bravo two", CGRect(x: 10, y: 10, width: 200, height: 20))], at: 31)
        XCTAssertEqual(f.sources(at: 31.5), [])
        XCTAssertEqual(f.sources(at: 32), ["alpha one"])
    }

    func testALineWithNoPlaceOrNoClockIsNeverHeld() {
        var plain = Feed(hold: 1)
        for n in ["A", "B", "C"] { plain.show([(n, "t\(n)")]) }
        XCTAssertEqual(plain.sources, ["B", "A"], "no place to fold it by, and no clock: the look after it left shows it")
        var placed = RecentLines(capacity: 3, hold: 1)
        let a = TranscriptRecorder.Observed(source: "A", translation: "tA", inLens: true, frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        var recorder = TranscriptRecorder()
        placed.observe(recorder.observe(time: 1, lines: [a]), lines: [a])
        let b = TranscriptRecorder.Observed(source: "B", translation: "tB", inLens: true, frame: CGRect(x: 0, y: 0, width: 50, height: 20))
        placed.observe(recorder.observe(time: 2, lines: [b]), lines: [b])
        XCTAssertEqual(placed.stack.map(\.source), ["A"], "a caller with no clock waits for nothing")
    }

    func testClearForgetsEverything() {
        var f = Feed()
        for n in ["A", "B", "C"] { f.show([(n, "t\(n)")]) }
        f.recent.clear()
        XCTAssertEqual(f.sources, [])
    }

    func testFadingByAge() {
        XCTAssertEqual(RecentLines.opacity(rank: 0, of: 3), 1.0, accuracy: 1e-9)
        // 2026-10-22 (game117 vision): re-pinned from 0.45, which measured about 2.2:1 on the light material; 0.6 is the floor that read
        // (about 2.9:1 light, 5.4:1 dark). FAIL-first: the 0.45 build fails this line.
        XCTAssertEqual(RecentLines.opacity(rank: 2, of: 3), 0.6, accuracy: 1e-9)
        XCTAssertEqual(RecentLines.opacity(rank: 0, of: 1), 1.0, accuracy: 1e-9)
        let o = (0..<5).map { RecentLines.opacity(rank: $0, of: 5) }
        XCTAssertEqual(o, o.sorted(by: >), "older never brighter")
    }
}
