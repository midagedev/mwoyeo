import CoreGraphics
import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct TranslationSchedulingTests {
    private typealias S = TranslationScheduling

    @Test func preemptsWhenEverythingUnfinishedLeft() {
        #expect(S.preemption(unfinished: [.gone, .gone], lensWaiting: false, afterLensPreemption: false) == .allGone)
        #expect(S.preemption(unfinished: [.gone], lensWaiting: true, afterLensPreemption: false) == .allGone)
    }

    @Test func preemptsWhenNothingIsInLensOrLeadingAndLensTextWaits() {
        #expect(S.preemption(unfinished: [.other, .gone, .other], lensWaiting: true, afterLensPreemption: false) == .lensWaiting)
    }

    @Test func doesNotPreemptWhileOneUnfinishedSourceIsInTheLensOrLeading() {
        #expect(S.preemption(unfinished: [.other, .lens], lensWaiting: true, afterLensPreemption: false) == nil)
        #expect(S.preemption(unfinished: [.other, .leading], lensWaiting: true, afterLensPreemption: false) == nil)
        // Nothing waits in the lens: finishing the overscan is fine.
        #expect(S.preemption(unfinished: [.other], lensWaiting: false, afterLensPreemption: false) == nil)
        #expect(S.preemption(unfinished: [], lensWaiting: true, afterLensPreemption: false) == nil)
    }

    @Test func lensRuleStaysQuietAfterALensPreemptionButGoneRuleDoesNot() {
        #expect(S.preemption(unfinished: [.other], lensWaiting: true, afterLensPreemption: true) == nil)
        #expect(S.preemption(unfinished: [.gone], lensWaiting: true, afterLensPreemption: true) == .allGone)
    }

    private let lens = CGRect(x: 0, y: 1000, width: 600, height: 300)

    @Test func trailingOnlyBeyondOneLensExtentAndOnlyWhileMoving() {
        let lead = CGVector(dx: 0, dy: 1) // content arrives from below; above is behind
        let near = CGRect(x: 0, y: 800, width: 600, height: 150)        // gap 50 < 300
        let far = CGRect(x: 0, y: 500, width: 600, height: 150)         // gap 350 > 300
        let ahead = CGRect(x: 0, y: 2000, width: 600, height: 150)
        #expect(!S.isTrailing(near, lens: lens, lead: lead))
        #expect(S.isTrailing(far, lens: lens, lead: lead))
        #expect(!S.isTrailing(ahead, lens: lens, lead: lead))
        #expect(!S.isTrailing(far, lens: lens, lead: .zero))
        // A rect that straddles the one-extent line is not wholly beyond it.
        #expect(!S.isTrailing(CGRect(x: 0, y: 600, width: 600, height: 150), lens: lens, lead: lead))
        // Reversed motion: below is behind.
        #expect(S.isTrailing(CGRect(x: 0, y: 1700, width: 600, height: 100), lens: lens, lead: CGVector(dx: 0, dy: -1)))
        // Never the lens itself.
        #expect(!S.isTrailing(lens, lens: lens, lead: lead))
    }

    @Test func standingFollowsLensAndLead() {
        let lead = CGVector(dx: 0, dy: 1)
        #expect(S.standing(of: CGRect(x: 0, y: 1100, width: 100, height: 20), lens: lens, lead: lead) == .lens)
        #expect(S.standing(of: CGRect(x: 0, y: 1400, width: 100, height: 20), lens: lens, lead: lead) == .leading)
        #expect(S.standing(of: CGRect(x: 0, y: 400, width: 100, height: 20), lens: lens, lead: lead) == .other)
        #expect(S.standing(of: CGRect(x: 0, y: 1400, width: 100, height: 20), lens: lens, lead: .zero) == .other)
    }

    @Test func aCancelledCallerOfWithDeadlineReturnsAtOnceAsCancelledNotTimedOut() async {
        let task = Task { await withDeadline(.seconds(30)) { try await Task.sleep(for: .seconds(60)); return 1 } }
        try? await Task.sleep(for: .milliseconds(50))
        let cancelled = ContinuousClock.now
        task.cancel()
        let r = await task.value
        // Re-pinned 2026-10-17: the bound included the 50 ms lead-in and failed at 163 ms with the machine at load 160.
        // The failure this guards is waiting for the deadline (30 s) or the work (60 s); 1 s from the cancel still
        // separates those by 30x and a broken cancel path fails it.
        #expect(ContinuousClock.now - cancelled < .seconds(1))
        guard case let .failed(e) = r else { Issue.record("expected .failed, got \(r)"); return }
        #expect(e is CancellationError)
    }
}
