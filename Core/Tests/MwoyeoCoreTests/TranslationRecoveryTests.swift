import Foundation
import Synchronization
import Testing
@testable import MwoyeoCore

@Suite struct TranslationRecoveryTests {
    @Test func deadlineTimesOutEvenWhenTheWorkIgnoresCancellation() async {
        // Parked on a continuation that nothing cancels; the test resumes it at the end.
        let parked = Mutex<CheckedContinuation<Void, Never>?>(nil)
        let start = ContinuousClock.now
        let r = await withDeadline(.milliseconds(200)) {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in parked.withLock { $0 = c } }
            return 1
        }
        let elapsed = ContinuousClock.now - start
        guard case .timedOut = r else { Issue.record("expected .timedOut, got \(r)"); return }
        #expect(elapsed < .milliseconds(500))
        #expect(elapsed >= .milliseconds(150))
        parked.withLock { $0 }?.resume()
    }

    @Test func deadlineReturnsTheValueWhenTheWorkIsFaster() async {
        let r = await withDeadline(.seconds(5)) { try await Task.sleep(for: .milliseconds(20)); return 42 }
        guard case let .value(v) = r else { Issue.record("expected .value, got \(r)"); return }
        #expect(v == 42)
    }

    @Test func deadlineReportsThrownErrors() async {
        struct Boom: Error {}
        let r = await withDeadline(.seconds(5)) { () async throws -> Int in throw Boom() }
        guard case let .failed(e) = r else { Issue.record("expected .failed, got \(r)"); return }
        #expect(e is Boom)
    }

    @Test func deadlineCancelsTheWorkOnTimeout() async {
        let cancelled = Mutex(false)
        let r = await withDeadline(.milliseconds(50)) {
            do { try await Task.sleep(for: .seconds(10)) } catch { cancelled.withLock { $0 = true }; throw error }
            return 0
        }
        guard case .timedOut = r else { Issue.record("expected .timedOut, got \(r)"); return }
        for _ in 0..<50 where !cancelled.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(cancelled.withLock { $0 })
    }

    @Test func backoffPausesDoubleToTheCapAndResetOnSuccess() {
        var b = RetryBackoff()
        var pauses: [TimeInterval] = []
        for _ in 0..<6 { pauses.append(b.failure(now: 100)) }
        #expect(pauses == [2, 4, 8, 16, 30, 30])
        #expect(b.isPaused(now: 129.9))
        #expect(!b.isPaused(now: 130))
        b.success()
        let afterSuccess = b.failure(now: 0)
        #expect(afterSuccess == 2)
        b.reset()
        #expect(b.failures == 0 && b.pausedUntil == nil)
    }

    @Test func strikesParkAtThreeAndClearOnSuccess() {
        var s = SourceStrikes()
        let first = [s.strike("a"), s.strike("a")]
        #expect(first == [false, false])
        s.clear("a")
        let again = [s.strike("a"), s.strike("a"), s.strike("a")]
        #expect(again == [false, false, true])
        #expect(s.isParked("a") && s.parkedCount == 1 && !s.isParked("b"))
        s.reset()
        #expect(!s.isParked("a") && s.parkedCount == 0)
    }
}
