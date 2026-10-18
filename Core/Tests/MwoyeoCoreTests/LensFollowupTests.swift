import Foundation
import Testing
@testable import MwoyeoCore

/// 2026-10-18 lens follow-ups: a flapping engine keeps its backoff, an all-untranslated batch strikes, failed reads back off.
@Suite struct LensFollowupTests {
    // 1. A success resets the backoff only after the engine stayed healthy for the window.
    @Test func flappingEngineKeepsDoubling() {
        var b = HealthyBackoff()
        var pauses: [TimeInterval] = []
        var t: TimeInterval = 100
        for _ in 0..<5 {
            pauses.append(b.failure(now: t))
            t += 10
            b.success(now: t)   // answers once, then fails again 10 s later: inside the window
            t += 10
        }
        #expect(pauses == [2, 4, 8, 16, 30])
    }

    @Test func backoffResetsAfterTheHealthyWindow() {
        var b = HealthyBackoff()
        _ = b.failure(now: 0)
        _ = b.failure(now: 10)
        b.success(now: 20)
        b.success(now: 20 + HealthyBackoff.window - 1)
        #expect(b.failure(now: 100) == 8)   // not yet reset
        b.success(now: 200)
        b.success(now: 200 + HealthyBackoff.window)
        #expect(b.failure(now: 400) == 2)   // healthy for the whole window: reset
    }

    // 2. Every line returned unchanged (nothing came back, no error) is a strike for each; an error is not.
    @Test func allUntranslatedBatchStrikes() {
        let items = ["a", "b", "c"]
        #expect(StrikeRule.struck(items: items, translated: [:], groupFailed: false) == Set(items))
        #expect(StrikeRule.struck(items: items, translated: ["a": "A"], groupFailed: false) == ["b", "c"])
        #expect(StrikeRule.struck(items: items, translated: [:], groupFailed: true).isEmpty)
        #expect(StrikeRule.struck(items: items, translated: ["a": "A"], groupFailed: true) == ["b", "c"])
        #expect(StrikeRule.struck(items: items, translated: Dictionary(uniqueKeysWithValues: items.map { ($0, $0) }), groupFailed: false).isEmpty)
    }

    // 3. Failed reads back off 1 s doubling to 30 s; a success or a geometry change ends it.
    @Test func readBackoffDoublesAndResets() {
        var r = ReadBackoff()
        var waits: [TimeInterval] = []
        for _ in 0..<5 { waits.append(r.failure(now: 50)) }
        // Capped at 5 s: once recognition works again, a lens is idle 5 s at most (it was 30, 2026-10-18).
        #expect(waits == [1, 2, 4, 5, 5])
        #expect(r.isWaiting(now: 54.9) && !r.isWaiting(now: 55))
        #expect(abs((r.remaining(now: 52) ?? 0) - 3) < 1e-9)
        r.success()
        #expect(!r.isWaiting(now: 50) && r.remaining(now: 50) == nil)
        #expect(r.failure(now: 0) == 1)
        r.reset()
        #expect(r.failures == 0 && !r.isWaiting(now: 0))
    }

    /// A transient error (programs not ready after a compile, a timeout) is retried in 1 s and never builds up the wait:
    /// otherwise the minute of e5rt errors after an update would leave the lens idle long after recognition is back.
    @Test func transientReadFailuresDoNotBuildUp() {
        var r = ReadBackoff()
        for _ in 0..<20 { #expect(r.failure(now: 0, transient: true) == 1) }
        #expect(r.failures == 0)
        #expect(r.failure(now: 0) == 1)
        #expect(r.failure(now: 0, transient: true) == 1)
        #expect(r.failure(now: 0) == 2)
    }
}
