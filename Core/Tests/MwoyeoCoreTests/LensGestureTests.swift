import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// The ring's double-click and the lens's spring (round fit117): a fake clock, no event loop.
@Suite struct LensGestureTests {
    private let interval = 0.5

    @Test func twoTapsWithinTheIntervalAndTheSlopAreADoubleClickAndAThirdStartsAgain() {
        var taps = DoubleTap()
        let first = taps.tap(at: CGPoint(x: 100, y: 100), time: 10, interval: interval)
        let second = taps.tap(at: CGPoint(x: 102, y: 101), time: 10.4, interval: interval)
        let third = taps.tap(at: CGPoint(x: 102, y: 101), time: 10.5, interval: interval)      // the second was used up: this one is a first
        let fourth = taps.tap(at: CGPoint(x: 102, y: 101), time: 10.6, interval: interval)
        #expect(!first && second && !third && fourth)
    }

    @Test func aSlowSecondTapOrAFarOneIsAFirstTap() {
        var taps = DoubleTap()
        let first = taps.tap(at: CGPoint(x: 100, y: 100), time: 10, interval: interval)
        let slow = taps.tap(at: CGPoint(x: 100, y: 100), time: 10.6, interval: interval)       // 0.6 s later: too slow, becomes the first
        let far = taps.tap(at: CGPoint(x: 110, y: 100), time: 10.7, interval: interval)        // 10 pt away: too far, becomes the first
        let near = taps.tap(at: CGPoint(x: 112, y: 100), time: 10.8, interval: interval)
        #expect(!first && !slow && !far && near)
    }

    @Test func aDragBetweenForgetsTheFirstTap() {
        var taps = DoubleTap()
        let first = taps.tap(at: CGPoint(x: 100, y: 100), time: 10, interval: interval)
        taps.reset()
        let second = taps.tap(at: CGPoint(x: 100, y: 100), time: 10.2, interval: interval)
        #expect(!first && !second)
    }

    @Test func theSpringRisesFromZeroToTheTargetWithoutOvershootWithinItsDuration() {
        for duration in [LensMotion.fit, LensMotion.autoFit, LensMotion.settle] {
            #expect(FitMotion.progress(0, duration: duration) == 0)
            var last: CGFloat = 0
            for i in 1...100 {
                let p = FitMotion.progress(duration * Double(i) / 100, duration: duration)
                #expect(p >= last && p <= 1, "at \(i) % of \(duration) s: \(p)")
                last = p
            }
            #expect(last >= 0.995)                                                        // at the end it stands within 0.5 % of the target
            #expect(FitMotion.progress(duration / 2, duration: duration) > 0.9)           // and is most of the way at the half: a spring, not a ramp
        }
        #expect(LensMotion.fit <= 0.4 && LensMotion.autoFit <= 0.25 && LensMotion.settle <= 0.25)
    }

    @Test func aFrameInBetweenKeepsTheLensesRowsAndInterpolatesTheColumns() {
        let from = CGRect(x: 150, y: 300, width: 200, height: 150), to = CGRect(x: 66, y: 300, width: 338, height: 150)
        #expect(FitMotion.frame(from: from, to: to, progress: 0) == from && FitMotion.frame(from: from, to: to, progress: 1) == to)
        let mid = FitMotion.frame(from: from, to: to, progress: 0.5)
        #expect(mid == CGRect(x: 108, y: 300, width: 269, height: 150))
    }
}
