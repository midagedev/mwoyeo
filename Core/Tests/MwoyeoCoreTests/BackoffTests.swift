import Foundation
import Testing
@testable import MwoyeoCore

/// R2 reader-core (2026-10-18, design §4.8, F5): one backoff type, one policy table, no fixed waits.
@Suite struct BackoffTests {
    /// Today's rule (`ReadBackoff.failure(transient: true)`, `RetryBackoff.swift:104-107` at feb7a12) waited a fixed 1 s: with a
    /// lens on a stalled rev3 that is one Code-13 error every ~1.01 s, 56 a minute for 32 minutes (flow-contention, RC). Doubling
    /// 1 → 30 s gives attempts at 0, 1, 3, 7, 15, 31 s: six in the first minute (`testRungBoundsCodeThirteenToSixAMinute`).
    @Test func testTransientWaitsDouble() {
        var read = ReadBackoff()
        let readWaits = (0..<7).map { _ in read.failure(now: 0, transient: true) }
        #expect(readWaits == [1, 2, 4, 8, 16, 30, 30])

        var rung = Backoff.rev3Rung
        let rungWaits = (0..<7).map { _ in rung.failure(now: 0) }
        #expect(rungWaits == [1, 2, 4, 8, 16, 30, 30])
    }

    @Test func testRungBoundsCodeThirteenToSixAMinute() {
        // A Code-13 request fails in 12 ms (design §4.9), so a lens with nothing else to do asks again as soon as the rung allows.
        func errorsInFirstMinute(wait: (inout Backoff) -> TimeInterval) -> Int {
            var b = Backoff.rev3Rung
            var t: TimeInterval = 0
            var errors = 0
            while t < 60 {
                errors += 1
                t += wait(&b) + 0.012
            }
            return errors
        }
        let doubling = errorsInFirstMinute { (b: inout Backoff) in b.failure(now: 0) }
        // The fixed 1 s of the old transient path, for the record: the 56 a minute of the RC were this (with the pass around it).
        let fixed = errorsInFirstMinute { (_: inout Backoff) in 1 }
        #expect(doubling == 6)
        #expect(fixed >= 59)
    }

    /// A transient streak and a hard streak do not feed each other, and a success or a reset ends both.
    @Test func transientAndHardStreaksAreIndependent() {
        var r = ReadBackoff()
        let wait = r.failure(now: 0)
        #expect(wait == 1)
        let wait2 = r.failure(now: 0, transient: true)
        #expect(wait2 == 1)
        let wait3 = r.failure(now: 0)
        #expect(wait3 == 2)
        let wait4 = r.failure(now: 0, transient: true)
        #expect(wait4 == 2)
        #expect(r.failures == 4)
        r.success()
        #expect(r.failures == 0 && !r.isWaiting(now: 0))
        let wait5 = r.failure(now: 0, transient: true)
        #expect(wait5 == 1)
    }

    @Test func hardReadErrorsStayCappedAtFive() {
        var b = Backoff.lensRead
        let waits = (0..<6).map { _ in b.failure(now: 0) }
        #expect(waits == [1, 2, 4, 5, 5, 5])
        #expect(b.isWaiting(now: 4.9) && !b.isWaiting(now: 5))
    }

    /// The policy table: every number in one place. A change here is a change of the design (§4.8): re-pin with a derivation.
    @Test func testPolicyTable() {
        let rows = Backoff.table
        let want: [Backoff.Use: [TimeInterval]] = [
            .translationQueue: [2, 4, 8, 16, 30, 30, 30],
            .engineCooldown: [2, 4, 8, 16, 30, 30, 30],
            .lensRead: [1, 2, 4, 5, 5, 5, 5],
            .rev3Rung: [1, 2, 4, 8, 16, 30, 30],
            .workerRestart: [1, 2, 4, 8, 16, 30, 30],
            .captureRestart: [1, 2, 5, 15, 30, 30, 30],
        ]
        #expect(rows.count == want.count)
        for (use, waits) in rows { #expect(waits == want[use], "\(use)") }
        #expect(Backoff.engineCooldown.healthyWindow == 60)
        #expect(Backoff.workerRestart.healthyWindow == 600)
        #expect(Backoff.captureRestart.healthyWindow == 30)
        #expect(Backoff.translationQueue.healthyWindow == nil && Backoff.lensRead.healthyWindow == nil && Backoff.rev3Rung.healthyWindow == nil)
    }

    /// The capture restart keeps `CaptureRecoveryPolicy.standard`'s values (`CaptureRecovery.swift`, not ours to edit): drift between
    /// the two would split the policy table in two again.
    @Test func captureRestartRowIsTheCapturePolicy() {
        let policy = CaptureRecoveryPolicy.standard
        let row = Backoff.captureRestart
        #expect(row.steps == policy.backoff)
        #expect(row.healthyWindow == policy.healthy)
    }

    @Test func explicitStepsRunOutAndRepeatTheLast() {
        var b = Backoff.captureRestart
        #expect(!b.exhausted)
        let waits = (0..<7).map { _ in b.failure(now: 0) }
        #expect(waits == [1, 2, 5, 15, 30, 30, 30])
        #expect(b.exhausted)
        b.reset()
        #expect(!b.exhausted && b.failures == 0)
    }

    /// The wrappers the pipeline and the translation service still call keep their old numbers (R3 removes them).
    @Test func wrappersKeepTheirRows() {
        var q = RetryBackoff()
        let waits = (0..<6).map { _ in q.failure(now: 100) }
        #expect(waits == [2, 4, 8, 16, 30, 30])
        #expect(RetryBackoff.base == 2 && RetryBackoff.cap == 30)
        #expect(q.isPaused(now: 129.9) && !q.isPaused(now: 130))
        #expect(q.pausedUntil == 130)
        q.success()
        #expect(q.failures == 0 && q.pausedUntil == nil)
        #expect(HealthyBackoff.window == 60)
        #expect(ReadBackoff.base == 1 && ReadBackoff.cap == 5)
    }

    // MARK: the window

    @Test func aWindowKeepsDoublingUntilAHealthyStretch() {
        var b = Backoff(base: 2, cap: 30, healthyWindow: 60)
        _ = b.failure(now: 0)
        _ = b.failure(now: 10)
        b.success(now: 20)                       // the stretch starts
        b.success(now: 79)                       // 59 s: not yet
        let wait = b.failure(now: 100)
        #expect(wait == 8)
        b.success(now: 200)
        b.success(now: 260)                      // 60 s
        #expect(b.failures == 0)
        let wait2 = b.failure(now: 300)
        #expect(wait2 == 2)
    }

    /// A worker that answers for ten minutes after a crash starts its next restart at 1 s again; one that crashes inside the
    /// ten minutes goes on doubling.
    @Test func workerRestartResetsAfterTenMinutesWithoutACrash() {
        var b = Backoff.workerRestart
        let wait = b.failure(now: 0)
        #expect(wait == 1)
        b.success(now: 5)
        let wait2 = b.failure(now: 100)
        #expect(wait2 == 2)        // a crash inside the stretch
        b.success(now: 105)
        b.success(now: 105 + 599)
        #expect(b.failures == 2)
        b.success(now: 105 + 600)
        let wait3 = b.failure(now: 1000)
        #expect(wait3 == 1)
    }

    @Test func aSuccessWithoutAWindowEndsTheStreakAtOnce() {
        var b = Backoff.rev3Rung
        _ = b.failure(now: 0)
        _ = b.failure(now: 1)
        b.success(now: 2)
        #expect(b.failures == 0)
        let wait = b.failure(now: 3)
        #expect(wait == 1)
    }
}
