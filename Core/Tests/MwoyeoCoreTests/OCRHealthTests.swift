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
}
