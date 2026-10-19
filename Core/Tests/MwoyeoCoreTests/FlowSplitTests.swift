import Foundation
import Testing
@testable import MwoyeoCore

/// One translation, painted in the pieces of a paragraph that goes on in the next column (docs/design/recognition.md section 11).
@Suite struct FlowSplitTests {
    private static let korean = "블록의 줄은 해당자가 선택한 엔진에 의해 번역됩니다: 언어 팩이 포함된 apple의 번역 프레임워크[5] 또는 설정에 추가된 엔진. 라인은 읽기 순서대로 최대 세 개의 새로운 라인으로 배치됩니다. 기본적으로 화면의 어떤 것도 기계에서 나가지 않으며, 텍스트는 사람이 엔진을 추가할 경우에만 네트워크 엔진으로 전송됩니다."

    @Test func theTranslationOfTwoPiecesIsCutByTheCharactersOfTheirSource() {
        // p2: three source lines of 166 characters, then four of 177 (recorded); the real translation of the paragraph.
        let parts = FlowSplit.slices(Self.korean, weights: [166, 177])
        #expect(parts.count == 2)
        #expect(parts.joined(separator: " ") == Self.korean)
        #expect(parts[0].hasSuffix("순서대로") && parts[1].hasPrefix("최대 세 개의"), "cut at a space near the middle: \(parts)")
    }

    @Test func oneWeightIsOnePieceAndNothingIsLost() {
        #expect(FlowSplit.slices("a b c", weights: [10]) == ["a b c"])
        #expect(FlowSplit.slices("", weights: [3, 4]) == ["", ""])
        for n in 1...6 {
            let w = Array(repeating: 7, count: n)
            #expect(FlowSplit.slices(Self.korean, weights: w).joined(separator: " ") == Self.korean)
        }
    }

    @Test func textWithoutSpacesIsNeverCutBeforeAClosingMark() {
        let jp = "この段落は二つの列にまたがっていて、翻訳は一つの文として扱われます。したがって、切れ目は句読点の前には置かれません。"
        for k in 3...40 {
            let parts = FlowSplit.slices(jp, weights: [k, 60 - k])
            #expect(parts.joined() == jp)
            #expect(!(parts[1].first.map { FlowSplit.closing.contains($0) } ?? false), "k=\(k): \(parts)")
        }
    }

    @Test func moreWeightsThanWordsStillGivesEveryPieceItsShare() {
        let parts = FlowSplit.slices("one two", weights: [1, 1, 1, 1])
        #expect(parts.count == 4)
        #expect(parts.joined(separator: " ").split(separator: " ").joined(separator: " ") == "one two")
    }

    @Test func eachPieceDrawsItsOwnShare() {
        let weights = [166, 177]
        let first = FlowPart(group: 7, index: 0, count: 2, weights: weights), second = FlowPart(group: 7, index: 1, count: 2, weights: weights)
        #expect(FlowSplit.share(of: Self.korean, part: first) + " " + FlowSplit.share(of: Self.korean, part: second) == Self.korean)
        // a part that does not fit its weights draws the whole text rather than nothing
        #expect(FlowSplit.share(of: "x y", part: FlowPart(group: 1, index: 3, count: 4, weights: [1, 1])) == "x y")
    }

    // MARK: A paragraph is whole or it is not

    private func part(_ group: Int, _ index: Int, of count: Int) -> FlowPart { FlowPart(group: group, index: index, count: count) }

    @Test func piecesThatCameThroughTheChainWholeShareTheirWeights() {
        let parts: [FlowPart?] = [nil, part(4, 0, of: 2), nil, part(4, 1, of: 2)]
        let resolved = FlowSplit.resolve(parts, characters: [30, 166, 12, 177])
        #expect(resolved[0] == nil && resolved[2] == nil)
        #expect(resolved[1] == FlowPart(group: 4, index: 0, count: 2, weights: [166, 177]))
        #expect(resolved[3] == FlowPart(group: 4, index: 1, count: 2, weights: [166, 177]))
    }

    @Test func aPieceThatWasMergedOrTakenForALabelLeavesTheOthersAParagraphOfTheirOwn() {
        // one of three pieces is gone (merged into a neighbour, a label): the two left would skip a part of the sentence
        let resolved = FlowSplit.resolve([part(1, 0, of: 3), part(1, 2, of: 3), part(2, 0, of: 2), part(2, 1, of: 2)], characters: [10, 10, 20, 30])
        #expect(resolved[0] == nil && resolved[1] == nil)
        #expect(resolved[2]?.weights == [20, 30] && resolved[3]?.weights == [20, 30])
        // pieces out of their reading order are not whole either
        #expect(FlowSplit.resolve([part(1, 1, of: 2), part(1, 0, of: 2)], characters: [5, 5]).allSatisfy { $0 == nil })
        // a piece with no characters still weighs one, so the slices never divide by zero
        #expect(FlowSplit.resolve([part(1, 0, of: 2), part(1, 1, of: 2)], characters: [0, 0])[0]?.weights == [1, 1])
    }
}
