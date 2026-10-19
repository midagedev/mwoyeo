import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// Round I1 (2026-10-19), from D1's diagnosis of page 2 of our paper: one reader paragraph goes on from the foot of column 1 to the
/// top of column 2, its union is 71 % of the page, and `Territory.trim` cut the 32 other blocks against it (docs/design/recognition.md
/// section 11). The fixtures are the recorded blocks of that page, of the d03 magazine picture and of the rotated words of a figure of
/// arXiv 1706.03762.
@Suite struct ColumnBreakTests {
    private typealias P2 = ColumnBreakP2
    private typealias Recorded = ColumnBreakRecorded

    private var bigLines: [CGRect] { P2.bigLines.map(\.0) }

    /// What `RegionPipeline.layoutPlaces` does with the cores: `Territory.want`, then `Territory.trim`.
    private func territories(_ cores: [CGRect], _ heights: [Double]) -> [CGRect] {
        let bounds = CGRect(origin: .zero, size: P2.image)
        let wants = cores.indices.map { i -> CGRect in
            let ring = CGFloat(Territory.ring(lineHeight: CGFloat(heights[i])))
            return Territory.want(core: cores[i], lineHeight: CGFloat(heights[i]), ring: ring).intersection(bounds)
        }
        return Territory.trim(cores: cores, wants: wants)
    }

    private func union(_ r: [CGRect]) -> CGRect { r.dropFirst().reduce(r[0]) { $0.union($1) } }

    @Test func linesThatClimbStartANewColumn() {
        #expect(ColumnBreak.climbs(bigLines) == [3])
        #expect(ColumnBreak.climbs([CGRect(x: 0, y: 0, width: 600, height: 26), CGRect(x: 0, y: 30, width: 600, height: 26)]).isEmpty)
        // two pieces of one text row (a sum cut by the reader) stand side by side: not a climb
        #expect(ColumnBreak.climbs([CGRect(x: 0, y: 100, width: 300, height: 30), CGRect(x: 310, y: 104, width: 90, height: 26)]).isEmpty)
    }

    @Test func theParagraphThatGoesOnInTheNextColumnIsCutAtTheClimb() {
        // Page 2 of our paper: 33 blocks, one of them the 7 lines of reader paragraph 19.
        let page = P2.cores.indices.map { $0 == P2.bigIndex ? bigLines : [P2.cores[$0].0] }
        let cut = ColumnBreak.pieces(page)
        #expect(cut.indices.filter { cut[$0].count > 1 } == [P2.bigIndex], "the block with the two columns is the only one cut")
        #expect(cut[P2.bigIndex] == [[0, 1, 2], [3, 4, 5, 6]])
    }

    @Test func territoriesOfTheWholePageStayWhole() {
        // The gate: no block of the page may lose more than 3 % of its source rect to the others' territories, and none may be left
        // with a patch under two pixels. On main (no cut) this page has 0 whole blocks, 16 squeezed and 17 dropped (RESULTS-own-2026-10-19).
        var cores = P2.cores.map(\.0), heights = P2.cores.map(\.1)
        let big = P2.bigIndex
        let runs = ColumnBreak.pieces(P2.cores.indices.map { $0 == big ? bigLines : [P2.cores[$0].0] })[big]
        cores.replaceSubrange(big...big, with: runs.map { union($0.map { bigLines[$0] }) })
        heights.replaceSubrange(big...big, with: runs.map { _ in 29.0 })
        let terr = territories(cores, heights)
        var whole = 0, squeezed = 0, dropped = 0
        for i in cores.indices {
            let t = terr[i], c = cores[i]
            if t.height <= 1.5 || t.width <= 1.5 { dropped += 1; continue }
            let i = c.intersection(t)
            (i.isNull ? 0 : i.width * i.height) >= 0.97 * c.width * c.height ? (whole += 1) : (squeezed += 1)
        }
        #expect(whole == cores.count, "whole=\(whole) squeezed=\(squeezed) dropped=\(dropped) of \(cores.count)")
    }

    @Test func theStatCountsTheTerritoriesUnderHalfOfTheirCore() {
        // `layout.squeezed`: on the uncut page (the code as it was) 30 of 33 territories were under half of their core, none after the
        // cut. 30 = 17 patches of 0-1 px (the 16 dropped and the one cut to an ellipsis, RESULTS-own-2026-10-19) + 12 cut in width at
        // the middle of their overlap with the big block + the big block's own patch (x 470-1167 of its 1349 px, 35 % of its core).
        let uncut = P2.cores.map(\.0), heights = P2.cores.map(\.1)
        let before = territories(uncut, heights)
        #expect(uncut.indices.filter { Territory.squeezed(core: uncut[$0], territory: before[$0]) }.count == 30)
        var cores = uncut, h = heights
        let runs = ColumnBreak.pieces(P2.cores.indices.map { $0 == P2.bigIndex ? bigLines : [P2.cores[$0].0] })[P2.bigIndex]
        cores.replaceSubrange(P2.bigIndex...P2.bigIndex, with: runs.map { union($0.map { bigLines[$0] }) })
        h.replaceSubrange(P2.bigIndex...P2.bigIndex, with: runs.map { _ in 29.0 })
        let after = territories(cores, h)
        #expect(cores.indices.filter { Territory.squeezed(core: cores[$0], territory: after[$0]) }.isEmpty)
        // A territory cut to nothing, or to a hairline, is squeezed; one that keeps its core is not.
        let core = CGRect(x: 100, y: 100, width: 400, height: 30)
        #expect(Territory.squeezed(core: core, territory: CGRect(x: 100, y: 100, width: 400, height: 1)))
        #expect(Territory.squeezed(core: core, territory: CGRect(x: 100, y: 100, width: 150, height: 30)))
        #expect(!Territory.squeezed(core: core, territory: CGRect(x: 96, y: 96, width: 408, height: 40)))
        #expect(Territory.squeezed(core: core, territory: CGRect(x: 600, y: 600, width: 10, height: 10)))
    }

    @Test func aBlockThatClimbsAndHoldsNothingIsLeftAlone() {
        // The words of a figure turned on their side (1706.03762 p14): their lines climb, their rects hold no other block.
        let cut = ColumnBreak.pieces(Recorded.rotated1706)
        #expect(cut.allSatisfy { $0.count == 1 })
        #expect(Recorded.rotated1706.contains { !ColumnBreak.climbs($0).isEmpty }, "the fixture does climb, or the test says nothing")
    }

    @Test func theMagazineParagraphThatGoesOnInTheNextColumnIsCutToo() {
        let cut = ColumnBreak.pieces(Recorded.magazine.map { $0.map(\.0) })
        #expect(cut[3] == [[0, 1, 2], [3]])
        #expect(cut.enumerated().allSatisfy { $0.offset == 3 || $0.element.count == 1 })
    }

    @Test func aPieceGoesOnWithTheSentenceOrIsAParagraphOfItsOwn() {
        // p2: "... in the settings. Lines" / "are sent in batches ..."; d03: "row, according to the la" / "in the country."
        #expect(ColumnBreak.continues(previousLast: P2.bigLines[2].1, nextFirst: P2.bigLines[3].1))
        #expect(ColumnBreak.continues(previousLast: "row, according to the la", nextFirst: "in the country."))
        // p12-s1 (side crop): a prose line, then a shell command of the next column's listing: two paragraphs
        #expect(!ColumnBreak.continues(previousLast: "ch becomes pL (Eq. 14, f", nextFirst: "$ cd../paper-bench && ./"))
        // the sentence ended, or the next one starts with a capital: a paragraph of its own
        #expect(!ColumnBreak.continues(previousLast: "It ends here.", nextFirst: "are sent"))
        #expect(!ColumnBreak.continues(previousLast: "and then", nextFirst: "The next one"))
        // a closing quotation mark or bracket after the full stop does not hide the end of the sentence
        #expect(!ColumnBreak.continues(previousLast: "He said \"it is done.\"", nextFirst: "and left"))
        #expect(!ColumnBreak.continues(previousLast: "(see the appendix.)", nextFirst: "and left"))
        #expect(ColumnBreak.continues(previousLast: "he said \"go\"", nextFirst: "and left"))
        // no case in Han / hangul / kana: a letter that starts the line goes on
        #expect(ColumnBreak.continues(previousLast: "これは文の途中で", nextFirst: "次の段に続く"))
        #expect(!ColumnBreak.continues(previousLast: "これは文の終わり。", nextFirst: "次の段に続く"))
        #expect(!ColumnBreak.continues(previousLast: "", nextFirst: "x"))
    }

    @Test func piecesThatGoOnShareAChainAndTheOthersStandAlone() {
        // p2: two pieces of one sentence.
        #expect(ColumnBreak.chains([(first: P2.bigLines[0].1, last: P2.bigLines[2].1), (first: P2.bigLines[3].1, last: P2.bigLines[6].1)]) == [0, 0])
        // p12-s1: a prose line, then a shell command.
        #expect(ColumnBreak.chains([(first: "ch becomes pL (Eq. 14, f", last: "ch becomes pL (Eq. 14, f"), (first: "$ cd../paper-bench", last: "$ ls")]) == [0, 1])
        // three pieces: the sentence goes on from the first to the second, the third is a heading.
        #expect(ColumnBreak.chains([(first: "one two", last: "three four"), (first: "five six.", last: "seven."), (first: "Next", last: "end.")]) == [0, 0, 1])
    }

    @Test func aBlockSpanningTwoColumnsIsCountedAsHoldingTheBlocksBetween() {
        // `LayoutCheck.holds` = the `score.py` cross_col pairs: on the page as it was, the big block holds 32 others.
        func drawn(_ core: CGRect) -> DrawnBlock { DrawnBlock(source: "x", core: core, patch: core, text: core) }
        let before = LayoutCheck.check(P2.cores.map { drawn($0.0) })
        #expect(before.holds.count == 32, "holds=\(before.holds.count)")
        var cores = P2.cores.map(\.0)
        let runs = ColumnBreak.pieces(P2.cores.indices.map { $0 == P2.bigIndex ? bigLines : [P2.cores[$0].0] })[P2.bigIndex]
        cores.replaceSubrange(P2.bigIndex...P2.bigIndex, with: runs.map { union($0.map { bigLines[$0] }) })
        let after = LayoutCheck.check(cores.map(drawn))
        #expect(after.holds.isEmpty, "holds=\(after.holds.count)")
        #expect(after.summary == "layout: blocks=34 overlaps=0 spill=0 cut=0 clipped=0 holds=0")
    }

    @Test func theRingIsTheEraseMargin() {
        #expect(Territory.ring(lineHeight: 26) == 4 && Territory.ring(lineHeight: 10) == 3 && Territory.ring(lineHeight: 100) == 18)
    }
}
