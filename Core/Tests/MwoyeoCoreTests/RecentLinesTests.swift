import XCTest
@testable import MwoyeoCore

/// The stack of lines that left the lens (design games-and-video §2), fed by the transcript recorder's own events.
final class RecentLinesTests: XCTestCase {
    private struct Feed {
        var recorder = TranscriptRecorder()
        var recent: RecentLines
        var time = 0.0
        init(capacity: Int = 3) { recent = RecentLines(capacity: capacity) }
        /// One observation: the lines in the lens now, each with its translation (nil: not translated yet).
        mutating func show(_ lines: [(String, String?)]) {
            time += 1
            let observed = lines.map { TranscriptRecorder.Observed(source: $0.0, translation: $0.1, inLens: true) }
            recent.observe(recorder.observe(time: time, lines: observed), lines: observed)
        }
        var sources: [String] { recent.stack.map(\.source) }
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
