import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct ReadingOrderTests {
    private func order(_ rects: [CGRect]) -> [Int] {
        ReadingOrder.sorted(Array(rects.enumerated()), frame: { $0.element }).map(\.offset)
    }

    @Test func topToBottom() {
        let r = [CGRect(x: 0, y: 200, width: 100, height: 20), CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 0, y: 100, width: 100, height: 20)]
        #expect(order(r) == [1, 2, 0])
    }

    @Test func sideBySideReadsLeftToRightEvenWithSlightlyDifferentTops() {
        let r = [CGRect(x: 200, y: 0, width: 100, height: 20), CGRect(x: 0, y: 6, width: 100, height: 20), CGRect(x: 0, y: 60, width: 100, height: 20)]
        #expect(order(r) == [1, 0, 2])
    }

    @Test func aTallBlockDoesNotSwallowTheRowsBelowIt() {
        let r = [CGRect(x: 0, y: 0, width: 100, height: 200), CGRect(x: 120, y: 0, width: 100, height: 20), CGRect(x: 120, y: 40, width: 100, height: 20)]
        #expect(order(r) == [0, 1, 2])
    }
}
