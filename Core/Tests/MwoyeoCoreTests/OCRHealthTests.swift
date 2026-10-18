import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct OCRHealthTests {
    private typealias H = OCRHealth

    /// A request that started at `at` and missed its deadline.
    private func stall(_ h: inout H, at: TimeInterval = 0, now: TimeInterval = 8) -> Int {
        let id = h.begin(now: at)
        h.missed(id, now: now)
        return id
    }

    @Test func aColdModelWaitsLongOnlyWhenNothingElseCouldRead() {
        let h = H()
        #expect(h.plan(canFallBack: true, now: 0) == .run(seconds: 8))
        #expect(h.plan(canFallBack: false, now: 0) == .run(seconds: 180))
    }

    @Test func aWarmModelGetsTheShortWaitEitherWay() {
        var h = H()
        let id = h.begin(now: 0)
        h.answered(id)
        #expect(h.plan(canFallBack: false, now: 10) == .run(seconds: 8))
        #expect(h.plan(canFallBack: true, now: 10) == .run(seconds: 8))
    }

    @Test func aMissStallsAndReadsMoveToTheOtherRecognizersOrAreRefused() {
        var h = H()
        let id = h.begin(now: 0)
        do { let r = h.missed(id, now: 8); #expect(r) }
        #expect(h.plan(canFallBack: true, now: 9) == .fallback)
        #expect(h.plan(canFallBack: false, now: 9) == .refuse)
        // A second miss is the same stall.
        do { let r = h.missed(id, now: 9); #expect(!r) }
    }

    @Test func aLoadRunningPastEightSecondsSendsNewReadsElsewhere() {
        var h = H()
        _ = h.begin(now: 100)
        #expect(h.plan(canFallBack: true, now: 105) == .run(seconds: 8))
        #expect(h.plan(canFallBack: true, now: 109) == .fallback)
        // Not stalled yet and nothing else reads Japanese: it waits like the first read does.
        #expect(h.plan(canFallBack: false, now: 109) == .run(seconds: 180))
        #expect(!h.stalled)
    }

    @Test func anAnswerEndsTheStall() {
        var h = H()
        let slow = stall(&h)
        do { let r = h.answered(slow); #expect(r) }
        #expect(!h.stalled)
        #expect(h.stalledFor(now: 50) == nil)
        #expect(h.plan(canFallBack: true, now: 20) == .run(seconds: 8))
        // An answer while healthy ends nothing.
        let next = h.begin(now: 21)
        do { let r = h.answered(next); #expect(!r) }
    }

    @Test func aHungRequestOlderThanAnAnswerNoLongerCountsAsLate() {
        var h = H()
        _ = stall(&h)                   // hung for good
        let probe = h.begin(now: 120)
        do { let r = h.answered(probe); #expect(r) }
        #expect(h.plan(canFallBack: true, now: 300) == .run(seconds: 8))
    }

    @Test func aFailedRequestLeavesHealthAlone() {
        var h = H()
        let id = h.begin(now: 0)
        h.failed(id)
        #expect(!h.stalled)
        #expect(h.plan(canFallBack: true, now: 50) == .run(seconds: 8))
        _ = stall(&h, at: 1)
        let other = h.begin(now: 2)
        h.failed(other)
        #expect(h.stalled)
    }

    @Test func theStallDatesFromTheRequestThatMissed() {
        var h = H()
        #expect(h.stalledFor(now: 10) == nil)
        _ = stall(&h, at: 100, now: 280)        // a cold read that waited the full 180 s
        #expect(h.stalledFor(now: 280) == 180)
        #expect(h.stalledFor(now: 300) == 200)
        // A later miss does not move it.
        let later = h.begin(now: 290)
        h.missed(later, now: 298)
        #expect(h.stalledFor(now: 300) == 200)
        // A warm read gives up after 8 s: well short of "not responding".
        var w = H()
        w.answered(w.begin(now: 0))
        _ = stall(&w, at: 50, now: 58)
        #expect(w.stalledFor(now: 58)! < H.giveUpAfter)
    }

    @Test func aProbeNeverStacksOnARequestThatIsStillLoading() {
        var h = H()
        #expect(!h.probeDue(now: 500))      // healthy: nothing to probe
        let loading = stall(&h)
        #expect(!h.probeDue(now: 100))      // the load has run under two minutes: it is the probe
        #expect(h.probeDue(now: 120))
        _ = h.begin(now: 120)               // the probe
        #expect(!h.probeDue(now: 200))
        do { let r = h.answered(loading); #expect(r) }
        #expect(!h.probeDue(now: 300))
    }

    @Test func oneProberAtATimeAndItStopsOnlyWhenHealthy() {
        var h = H()
        do { let r = h.startProbing(); #expect(!r) }      // nothing stalled
        let id = stall(&h)
        do { let r = h.startProbing(); #expect(r) }
        do { let r = h.startProbing(); #expect(!r) }      // someone has the role
        do { let r = h.stopProbing(); #expect(!r) }       // still stalled: keeps probing
        h.answered(id)
        do { let r = h.stopProbing(); #expect(r) }
        // A later stall can start a prober again.
        _ = stall(&h, at: 500, now: 508)
        do { let r = h.startProbing(); #expect(r) }
    }

    // MARK: programs not ready (vision-setup, 2026-10-18)

    /// The line the user's Mac logged on every revision 3 read for about 90 s after a long cold compile.
    private let logged = "e5rtError(\"e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed\", 13)"

    private struct Logged: Error, CustomStringConvertible { let description: String }

    @Test func theLoggedE5rtErrorIsProgramsNotReady() {
        #expect(H.programsNotReady(description: logged))
        #expect(H.programsNotReady(Logged(description: logged)))
        #expect(!H.programsNotReady(Logged(description: "Error Domain=com.apple.vis Code=9 \"timeout\"")))
        #expect(!H.programsNotReady(CancellationError()))
    }

    /// Logged 2026-10-18 by the RC on a saturated Neural Engine ("document OCR failed: nilError"): the read returned no result
    /// and no error. Like "programs not ready", the next read answers once the system catches up.
    @Test func aPassFailureIsTransientForNotReadyAndNilResults() {
        #expect(H.passFailureIsTransient(Logged(description: logged)))
        #expect(H.passFailureIsTransient(Logged(description: "nilError")))
        #expect(!H.passFailureIsTransient(Logged(description: "Error Domain=com.apple.vis Code=9 \"timeout\"")))
        #expect(!H.passFailureIsTransient(CancellationError()))
    }

    @Test func notReadySendsReadsDownTheLadderForFiveSecondsThenAsksAgain() {
        var h = H()
        let id = h.begin(now: 100)
        h.notReady(id, now: 101)
        #expect(h.isNotReady)
        #expect(h.plan(canFallBack: true, now: 102) == .fallback)
        #expect(h.plan(canFallBack: true, now: 105.9) == .fallback)
        #expect(h.plan(canFallBack: true, now: 106) == .run(seconds: 8))
        // Nothing older to read: it is asked at once, as before (the error then reaches the caller).
        #expect(h.plan(canFallBack: false, now: 102) == .run(seconds: 180))
        // Not a stall: no probe, no refusal.
        #expect(!h.stalled && !h.probeDue(now: 500))
    }

    @Test func anAnswerEndsNotReadyAndAFailingRetryStartsTheFiveSecondsAgain() {
        var h = H()
        h.notReady(h.begin(now: 0), now: 1)
        h.notReady(h.begin(now: 6), now: 7)
        #expect(h.plan(canFallBack: true, now: 8) == .fallback)
        h.answered(h.begin(now: 12))
        #expect(!h.isNotReady)
        #expect(h.plan(canFallBack: true, now: 13) == .run(seconds: 8))
    }

    @Test func notReadyDoesNotMakeALoadLookLate() {
        var h = H()
        let id = h.begin(now: 0)
        h.notReady(id, now: 1)
        #expect(h.plan(canFallBack: true, now: 20) == .run(seconds: 8))
    }
}
