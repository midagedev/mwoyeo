import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

/// 2026-10-18 lens-robust (footprint audit F1): a lens whose capture stopped (a wake, a display change, a stream error) stayed dead
/// with no signal. What each event makes a lens do, given the lens and the displays.
@Suite struct CaptureRecoveryTests {
    /// A laptop (1512 × 982, a 38 pt menu bar) with an external display to its right.
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let usable = CGRect(x: 0, y: 38, width: 1512, height: 944)
    private let external = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
    private var docked: DisplayLayout { DisplayLayout(frames: [laptop, external], primary: usable) }
    private var undocked: DisplayLayout { DisplayLayout(frames: [laptop], primary: usable) }
    /// A lens on the external display, and one on the laptop.
    private let far = CGRect(x: 2000, y: 300, width: 749, height: 410)
    private let near = CGRect(x: 200, y: 300, width: 749, height: 410)

    /// Where `far` goes without the external display (`.null` when the rule says it stays: the expectations then fail).
    private var farMoved: CGRect { LensPlacement.resolve(far, in: undocked) ?? .null }

    private func decide(_ event: CaptureEvent, lens: CGRect, follows: Bool = false, stream: CGRect?, layout: DisplayLayout,
                        failures: Int = 0) -> CaptureAction {
        CaptureRecovery.decide(event, lens: lens, followsWindow: follows, streamDisplay: stream, layout: layout, failures: failures)
    }

    // MARK: where a lens goes

    @Test func aLensOnADisplayStays() {
        #expect(LensPlacement.resolve(far, in: docked) == nil)
        #expect(LensPlacement.resolve(near, in: undocked) == nil)
    }

    @Test func aLensWhoseDisplayIsGoneMovesToTheNearestPlaceOnThePrimary() {
        let moved = LensPlacement.resolve(far, in: undocked)
        #expect(moved == CGRect(x: 1512 - 749, y: 300, width: 749, height: 410))
        // Above the usable area (under the menu bar) is clamped down.
        let above = LensPlacement.resolve(CGRect(x: 2000, y: -150, width: 300, height: 200), in: undocked)
        #expect(above == CGRect(x: 1512 - 300, y: 38, width: 300, height: 200))
    }

    @Test func aLensThatDoesNotFitShrinksToTheDisplay() {
        let huge = CGRect(x: 2000, y: 0, width: 3000, height: 1200)
        #expect(LensPlacement.resolve(huge, in: undocked) == usable)
    }

    @Test func aSmallerResolutionLeavesALensOffScreen() {
        let smaller = DisplayLayout(frames: [laptop, CGRect(x: 1512, y: 0, width: 1920, height: 1080)], primary: usable)
        let corner = CGRect(x: 3300, y: 900, width: 300, height: 200)
        #expect(LensPlacement.resolve(corner, in: docked) == nil)
        #expect(LensPlacement.resolve(corner, in: smaller) == CGRect(x: 1512 - 300, y: 782, width: 300, height: 200))
    }

    @Test func noDisplayMeansNoPlace() {
        #expect(LensPlacement.resolve(far, in: DisplayLayout(frames: [], primary: .null)) == nil)
    }

    @Test func aDisplayIsTheOneShowingMostOfTheRect() {
        let across = CGRect(x: 1400, y: 300, width: 400, height: 200)   // 112 pt on the laptop, 288 on the external
        #expect(docked.display(showing: across) == external)
        #expect(docked.display(showing: CGRect(x: 6000, y: 0, width: 10, height: 10)) == nil)
    }

    // MARK: events

    @Test func aSavedLensOnAGoneDisplayMovesAtLaunch() {
        #expect(decide(.launch, lens: far, stream: nil, layout: undocked) == .move(to: farMoved))
        #expect(decide(.launch, lens: far, stream: nil, layout: docked) == .nothing)
        #expect(decide(.launch, lens: near, stream: nil, layout: undocked) == .nothing)
    }

    @Test func wakeStartsTheCaptureAgainEvenIfNothingSaysItStopped() {
        // No frame comes for content that did not change, so a stream that died quietly cannot be told from a still screen.
        #expect(decide(.wake, lens: far, stream: external, layout: docked) == .restart(after: 0))
        #expect(decide(.wake, lens: near, stream: nil, layout: docked) == .restart(after: 0))
    }

    @Test func wakeAfterAnUndockMovesTheLens() {
        #expect(decide(.wake, lens: far, stream: external, layout: undocked) == .move(to: farMoved))
    }

    @Test func screensChangedLeavesAStreamOnTheSameDisplayAlone() {
        #expect(decide(.screensChanged, lens: far, stream: external, layout: docked) == .nothing)
        #expect(decide(.screensChanged, lens: near, stream: laptop, layout: docked) == .nothing)
    }

    @Test func screensChangedRestartsAStreamWhoseDisplayChanged() {
        let other = DisplayLayout(frames: [laptop, CGRect(x: 1512, y: -200, width: 1920, height: 1080)], primary: usable)
        #expect(decide(.screensChanged, lens: far, stream: external, layout: other) == .restart(after: 0))   // another resolution
        let moved = DisplayLayout(frames: [laptop, external.offsetBy(dx: 0, dy: 300)], primary: usable)
        #expect(decide(.screensChanged, lens: far, stream: external, layout: moved) == .restart(after: 0))   // rearranged
        #expect(decide(.screensChanged, lens: near, stream: nil, layout: docked) == .restart(after: 0))      // no stream at all
    }

    @Test func screensChangedMovesALensWhoseDisplayWasUnplugged() {
        #expect(decide(.screensChanged, lens: far, stream: external, layout: undocked) == .move(to: farMoved))
    }

    @Test func aLensThatFollowsAWindowIsNeverMovedForADisplay() {
        #expect(decide(.screensChanged, lens: far, follows: true, stream: external, layout: undocked) == .restart(after: 0))
        #expect(decide(.streamStopped(.other), lens: far, follows: true, stream: nil, layout: undocked) == .restart(after: 1))
        #expect(decide(.launch, lens: far, follows: true, stream: nil, layout: undocked) == .nothing)
    }

    @Test func aStoppedStreamIsStartedAgainWithBackoff() {
        let delays = (0..<CaptureRecoveryPolicy.standard.backoff.count).map {
            decide(.streamStopped(.other), lens: near, stream: nil, layout: docked, failures: $0)
        }
        #expect(delays == [.restart(after: 1), .restart(after: 2), .restart(after: 5), .restart(after: 15), .restart(after: 30)])
    }

    @Test func theBackoffEndsAndTheLensWaitsForTheNextEvent() {
        let n = CaptureRecoveryPolicy.standard.backoff.count
        #expect(decide(.streamStopped(.other), lens: near, stream: nil, layout: docked, failures: n) == .nothing)
        #expect(decide(.streamStopped(.other), lens: near, stream: nil, layout: docked, failures: n + 7) == .nothing)
        let policy = CaptureRecoveryPolicy.standard
        #expect(policy.backoff == policy.backoff.sorted() && (policy.backoff.last ?? 0) <= 30 && policy.backoff.reduce(0, +) < 120)
    }

    @Test func aStopForTheGrantOrByThePersonIsNotUndone() {
        for stop in [CaptureStop.permission, .userStopped] {
            #expect(decide(.streamStopped(stop), lens: near, stream: nil, layout: docked) == .nothing)
            // Not even moved: the stream would be started there.
            #expect(decide(.streamStopped(stop), lens: far, stream: nil, layout: undocked) == .nothing)
        }
    }

    @Test func aStreamThatStoppedBecauseItsDisplayWentMovesTheLens() {
        #expect(decide(.streamStopped(.other), lens: far, stream: nil, layout: undocked) == .move(to: farMoved))
    }

    @Test func stopReasonsAreTold() {
        let d = CaptureFailure.screenCaptureKitDomain
        #expect(CaptureStop.classify(domain: d, code: -3801) == .permission)
        #expect(CaptureStop.classify(domain: d, code: -3817) == .userStopped)
        #expect(CaptureStop.classify(domain: d, code: -3821) == .other)    // stopped by the system (sleep, a display change)
        #expect(CaptureStop.classify(domain: d, code: -3814) == .other)    // no display list
        #expect(CaptureStop.classify(domain: "NSCocoaErrorDomain", code: -3817) == .other)
    }
}
