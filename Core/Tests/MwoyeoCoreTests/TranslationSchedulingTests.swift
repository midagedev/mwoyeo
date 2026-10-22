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

    /// The queue's own rule, moved here from `RegionPipeline` unchanged (erase117): the erase order shares it.
    @Test func priorityIsTheLensInReadingOrderThenTheOverscanNearestFirst() {
        let a = CGRect(x: 0, y: 1100, width: 100, height: 20), b = CGRect(x: 0, y: 1150, width: 100, height: 20)
        #expect(S.priority(of: a, lens: lens, lead: .zero) == (0, 1100))
        #expect(S.priority(of: b, lens: lens, lead: .zero) == (0, 1150))
        // 200 px below the lens's bottom edge (1300); the side things are heading to counts half as far.
        let below = CGRect(x: 0, y: 1500, width: 100, height: 20)
        #expect(S.priority(of: below, lens: lens, lead: .zero) == (1, 200))
        #expect(S.priority(of: below, lens: lens, lead: CGVector(dx: 0, dy: 1)) == (1, 100))
        #expect(S.priority(of: below, lens: lens, lead: CGVector(dx: 0, dy: -1)) == (1, 200))
    }

    // MARK: Prediction

    @Test func dwellIsTheTimeUntilTheFarEdgePassesTheLensExit() {
        let r = CGRect(x: 100, y: 1100, width: 50, height: 20)
        // Moving down (+y): leaves past maxY (1300) when r.minY does: 200 px at 100 px/s.
        #expect(S.dwell(of: r, lens: lens, velocity: CGVector(dx: 0, dy: 100)) == 2)
        // Moving up (-y): leaves past minY (1000) when r.maxY does: 120 px.
        #expect(abs(S.dwell(of: r, lens: lens, velocity: CGVector(dx: 0, dy: -100))! - 1.2) < 1e-9)
        // Sideways, both directions (lens x 0…600, r x 100…150).
        #expect(S.dwell(of: r, lens: lens, velocity: CGVector(dx: 50, dy: 0)) == 10)
        #expect(S.dwell(of: r, lens: lens, velocity: CGVector(dx: -50, dy: 0)) == 3)
        // Two axes: the first to leave decides.
        #expect(S.dwell(of: r, lens: lens, velocity: CGVector(dx: 50, dy: 100)) == 2)
        // Text above the lens still has to cross it before it is useless.
        #expect(S.dwell(of: CGRect(x: 0, y: 500, width: 50, height: 20), lens: lens, velocity: CGVector(dx: 0, dy: 100)) == 8)
    }

    @Test func dwellIsZeroOncePastTheExitAndNilWhenNotMoving() {
        let past = CGRect(x: 100, y: 1400, width: 50, height: 20)
        #expect(S.dwell(of: past, lens: lens, velocity: CGVector(dx: 0, dy: 100)) == 0)
        #expect(S.dwell(of: CGRect(x: 100, y: 800, width: 50, height: 20), lens: lens, velocity: CGVector(dx: 0, dy: -100)) == 0)
        #expect(S.dwell(of: past, lens: lens, velocity: .zero) == nil)
    }

    @Test func entryIsTheTimeUntilTheRectTouchesTheLens() {
        let below = CGRect(x: 100, y: 1500, width: 50, height: 20)
        #expect(S.entry(of: below, lens: lens, velocity: CGVector(dx: 0, dy: -100)) == 2)
        #expect(S.entry(of: below, lens: lens, velocity: CGVector(dx: 0, dy: 100)) == nil)
        #expect(abs(S.entry(of: CGRect(x: 100, y: 500, width: 50, height: 20), lens: lens, velocity: CGVector(dx: 0, dy: 100))! - 4.8) < 1e-9)
        #expect(S.entry(of: CGRect(x: 100, y: 1100, width: 50, height: 20), lens: lens, velocity: CGVector(dx: 0, dy: 100)) == 0)
        // Outside the lens along an axis it does not move on: never.
        #expect(S.entry(of: CGRect(x: 700, y: 1500, width: 50, height: 20), lens: lens, velocity: CGVector(dx: 0, dy: -100)) == nil)
        #expect(S.entry(of: below, lens: lens, velocity: .zero) == nil)
    }

    private func sources(_ list: [(String, CGFloat)], x: CGFloat = 100) -> [S.Candidate] {
        list.map { S.Candidate(source: $0.0, rect: CGRect(x: x, y: $0.1, width: 50, height: 20)) }
    }

    @Test func movingBatchSkipsTextThatWillHaveLeftAndRanksLensThenEntry() {
        let up = CGVector(dx: 0, dy: -100)  // dwell = (r.maxY - 1000) / 100 for text in or above the lens
        // A (y 1050): dwell 0.7, gone before 1 s + margin. B (1250): 2.7. C, D below: enter in 2 s and 3 s, dwell 5.2 / 6.2.
        let c = sources([("D", 1600), ("A", 1050), ("C", 1500), ("B", 1250)])
        let out = S.batch(from: c, lens: lens, velocity: up, limit: 3, expectedSeconds: { Double($0) })
        #expect(out == ["B", "C", "D"])
        // The k-th line must outlast expectedSeconds(k) + margin: with 2 s a line, B alone (2.7 ≥ 2.5) qualifies.
        #expect(S.batch(from: c, lens: lens, velocity: up, limit: 3, expectedSeconds: { 2 * Double($0) }) == ["B", "C"])
        #expect(S.batch(from: c, lens: lens, velocity: up, limit: 3, expectedSeconds: { _ in 10 }).isEmpty)
        #expect(S.batch(from: c, lens: lens, velocity: up, limit: 1, expectedSeconds: { Double($0) }) == ["B"])
    }

    /// Fixed text (a header, an input box) outside the scrolling region does not move: no dwell limit, never too late.
    @Test(arguments: [100.0, 1500.0]) func textOutsideTheScrollRegionIsAdmittedAndNeverCut(speed: Double) {
        let up = CGVector(dx: 0, dy: -speed)
        let region = CGRect(x: 0, y: 1100, width: 600, height: 200)          // the message log under a fixed header
        let header = S.Candidate(source: "header", rect: CGRect(x: 100, y: 1010, width: 50, height: 20))  // dwell would be 0.03 s at 1 k px/s or less
        let line = S.Candidate(source: "line", rect: CGRect(x: 100, y: 1250, width: 50, height: 20))
        // Without the region rule the header's predicted dwell is far below the 0.5 s margin: it is held back.
        #expect(!S.batch(from: [header], lens: lens, velocity: up, limit: 3, expectedSeconds: { _ in 1 }).contains("header"))
        let out = S.batch(from: [header, line], lens: lens, velocity: up, scrollRegion: region, limit: 3, expectedSeconds: { _ in 1 })
        #expect(out.contains("header"))
        // Inside the region the old prediction stays: the line (dwell 2.7 s at 100 px/s, 0.18 s at 1500) qualifies only when it outlasts.
        #expect(out.contains("line") == (speed == 100))
        // In flight: the header's dwell is unlimited, so the batch is not too late.
        let v = S.velocity(of: header.rect, up, scrollRegion: region)
        #expect(v == .zero)
        #expect(S.dwell(of: header.rect, lens: lens, velocity: v) == nil)
        #expect(!S.tooLate(dwells: [S.dwell(of: header.rect, lens: lens, velocity: v) ?? .infinity], remaining: 5))
        #expect(S.velocity(of: line.rect, up, scrollRegion: region) == up)
        #expect(S.velocity(of: header.rect, up, scrollRegion: nil) == up)
    }

    @Test func movingBatchKeepsReadingOrderInTheLensAndDropsTextThatNeverArrives() {
        let up = CGVector(dx: 0, dy: -10)
        let c = sources([("low", 1200), ("high", 1050)]) + sources([("aside", 1500)], x: 700)
        #expect(S.batch(from: c, lens: lens, velocity: up, limit: 3, expectedSeconds: { _ in 1 }) == ["high", "low"])
        // A source in two blocks counts at its best one.
        let twice = sources([("dup", 1050)]) + sources([("dup", 1250)])
        #expect(S.batch(from: twice, lens: lens, velocity: CGVector(dx: 0, dy: -100), limit: 3, expectedSeconds: { _ in 1 }) == ["dup"])
    }

    @Test func tooLateOnlyWhenEveryUnfinishedSourceLeavesBeforeTheBatchEnds() {
        #expect(S.tooLate(dwells: [0.4, 0.9], remaining: 1.0))
        #expect(!S.tooLate(dwells: [0.4, 1.5], remaining: 1.0))
        #expect(!S.tooLate(dwells: [1.0], remaining: 1.0))
        #expect(!S.tooLate(dwells: [], remaining: 1.0))
    }

    @Test func lensRuleHasNoLivelockGuardOnceContentStopped() {
        // Moving: after a lens cut the rule stays quiet. Stopped: nothing moves, so the lens batch it triggers cannot be cut again.
        #expect(S.preemption(unfinished: [.other], lensWaiting: true, afterLensPreemption: true, moving: true) == nil)
        #expect(S.preemption(unfinished: [.other], lensWaiting: true, afterLensPreemption: true, moving: false) == .lensWaiting)
        #expect(S.preemption(unfinished: [.lens, .other], lensWaiting: true, afterLensPreemption: true, moving: false) == nil)
    }

    @Test func paceIsUnknownUntilTheFirstLineThenALineCostsAsMuchAsTheFirstUntilMeasured() {
        var p = TranslationPace()
        #expect(p.expectedSeconds(lines: 3) == nil)
        p.record(seconds: 1.5, isFirst: true)
        #expect(p.expectedSeconds(lines: 1) == 1.5)
        #expect(p.expectedSeconds(lines: 3) == 4.5)
        #expect(p.expectedSeconds(lines: 0) == 0)
        p.record(seconds: 0, isFirst: false)
        #expect(p.expectedSeconds(lines: 3) == 1.5)
    }

    @Test func aRunningCallOwesOnlyWhatIsLeftOfItsFixedCostThenItsLaterLines() {
        var p = TranslationPace()
        #expect(p.remainingSeconds(lines: 3, delivered: 0, elapsed: 0) == nil)
        p.record(seconds: 1.5, isFirst: true)
        p.record(seconds: 0.5, isFirst: false)
        // Nothing back yet: the unspent part of the first line's cost, then two more lines.
        #expect(p.remainingSeconds(lines: 3, delivered: 0, elapsed: 0) == 2.5)
        #expect(p.remainingSeconds(lines: 3, delivered: 0, elapsed: 1.0) == 1.5)
        // Past its expected first result: only the later lines are owed (the first may land at any moment).
        #expect(p.remainingSeconds(lines: 3, delivered: 0, elapsed: 2.0) == 1.0)
        #expect(p.remainingSeconds(lines: 3, delivered: 1, elapsed: 2.0) == 1.0)
        #expect(p.remainingSeconds(lines: 3, delivered: 3, elapsed: 2.0) == 0)
    }

    @Test func paceIsARunningMeanForFiveSamplesThenAnEWMA() {
        var p = TranslationPace()
        for s in [1.0, 2.0, 3.0, 4.0, 5.0] { p.record(seconds: s, isFirst: true) }
        #expect(abs(p.first! - 3) < 1e-9)
        p.record(seconds: 6, isFirst: true)
        #expect(abs(p.first! - (3 + TranslationPace.weight * 3)) < 1e-9)
        #expect(p.firstSamples == 6 && p.nextSamples == 0)
        // Absurd samples are clamped (a call that sat on a stalled machine).
        p.record(seconds: 1000, isFirst: false)
        #expect(p.next == 60)
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
