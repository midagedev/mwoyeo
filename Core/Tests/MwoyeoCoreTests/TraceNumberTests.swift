import CoreGraphics
import Testing
@testable import MwoyeoCore

@Suite struct TraceNumberTests {
    @Test func aRectThatIsNullOrInfiniteIsZeroNotATrap() {
        // 2026-10-18 (r3-docs-xpc): `Int(CGRect.null.minX)` traps ("Double value cannot be converted to Int because it is infinite").
        #expect(TraceNumber.px(CGRect.null.minX) == 0)
        // `CGRect.infinite` is the largest finite size, not infinity: cut, not zero.
        #expect(TraceNumber.px(CGRect.infinite.width) == 1_000_000_000)
        #expect(TraceNumber.px(.nan) == 0)
        #expect(TraceNumber.px(-.infinity) == 0)
    }

    @Test func aFiniteValueIsItsWholePart() {
        #expect(TraceNumber.px(12.9) == 12)
        #expect(TraceNumber.px(-3.7) == -3)
        #expect(TraceNumber.px(0) == 0)
        #expect(TraceNumber.px(1e300) == 1_000_000_000)
        #expect(TraceNumber.px(-1e300) == -1_000_000_000)
    }
}
