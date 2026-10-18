import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct SwiftVisionGateTests {
    private typealias G = SwiftVisionGate

    /// Runs every due step, each taking `seconds`, starting at `now`; returns the time after the last.
    private func runAll(_ g: inout G, from now: TimeInterval, each seconds: TimeInterval) -> TimeInterval {
        var t = now
        while let due = g.nextDue() {
            g.started(due, now: t)
            t += seconds
            g.finished(failure: nil, now: t)
        }
        return t
    }

    private func runOne(_ g: inout G, at now: TimeInterval, seconds: TimeInterval) -> TimeInterval {
        guard let due = g.nextDue() else { return now }
        g.started(due, now: now)
        g.finished(failure: nil, now: now + seconds)
        return now + seconds
    }

    @Test func nothingIsReadyOrDueUntilAKeyIsWanted() {
        let g = G()
        #expect(!g.isReady("ja"))
        #expect(g.nextDue() == nil)
        #expect(g.allReady)
        #expect(!g.shouldShowProgress(now: 100))
        #expect(g.steps.values.allSatisfy { $0 == .pending })
    }

    @Test func stepsRunInOrderOneAtATimeNeverStackedOn() {
        var g = G()
        g.want("ja")
        #expect(g.nextDue() == G.Due(key: "ja", step: .textModel))
        g.started(G.Due(key: "ja", step: .textModel), now: 0)
        #expect(g.nextDue() == nil)
        g.finished(failure: nil, now: 1)
        #expect(g.nextDue() == G.Due(key: "ja", step: .documentModel))
        g.started(G.Due(key: "ja", step: .documentModel), now: 1)
        #expect(g.nextDue() == nil)
        #expect(!g.isReady("ja"))
        g.finished(failure: nil, now: 90)
        #expect(g.isReady("ja"))
        // 2026-10-18 (r3-docs-xpc): there is no third step. `RecognizeTextRequest` was never read and cost a ~30 s serial compile.
        #expect(g.nextDue() == nil)
        #expect(G.Step.allCases == [.textModel, .documentModel])
    }

    @Test func keysGoInTheOrderTheyWereAskedFor() {
        var g = G()
        g.want("fr")
        g.want("ja")
        g.want("fr")
        #expect(g.nextDue()?.key == "fr")
        _ = runAll(&g, from: 0, each: 1)
        #expect(g.isReady("fr") && g.isReady("ja"))
        #expect(g.readyKeys == ["fr", "ja"])
    }

    @Test func aFailedStepStopsItsKeyAndNeverRunsAgainByItself() {
        var g = G()
        g.want("ja")
        g.want("fr")
        g.started(G.Due(key: "ja", step: .textModel), now: 0)
        g.finished(failure: "boom", now: 5)
        // The next key goes on; the failed key waits, however long.
        #expect(g.nextDue() == G.Due(key: "fr", step: .textModel))
        _ = runAll(&g, from: 6, each: 1)
        #expect(g.nextDue() == nil)
        #expect(g.isReady("fr") && !g.isReady("ja"))
        #expect(g.steps[.textModel] == .failed("boom"))
    }

    @Test func retryMakesFailedStepsDueAgainAndKeepsTheDoneOnes() {
        var g = G()
        g.want("ja")
        g.started(G.Due(key: "ja", step: .textModel), now: 0)
        g.finished(failure: nil, now: 1)
        g.started(G.Due(key: "ja", step: .documentModel), now: 1)
        g.finished(failure: "x", now: 2)
        #expect(g.nextDue() == nil)
        g.retry()
        #expect(g.nextDue() == G.Due(key: "ja", step: .documentModel))
        #expect(g.steps[.textModel] == .done(seconds: 1))
    }

    @Test func aSlowDocumentStepIsDoneNotFailedAndTheKeyStaysReady() {
        // 2026-10-18 (r3-docs-xpc): a document answer that is slow is not a failure (the old rule took the key back after a second
        // miss until relaunch). The step takes as long as the Docs service takes, and once done the key stays ready for the run.
        var g = G()
        g.want("ja")
        _ = runAll(&g, from: 0, each: 130)
        #expect(g.isReady("ja"))
        #expect(g.steps[.documentModel] == .done(seconds: 130))
        #expect(g.nextDue() == nil)
        #expect(g.readyKeys == ["ja"])
    }

    @Test func stepsAcrossKeysReportRunningThenDoneSum() {
        var g = G()
        g.want("a")
        g.want("b")
        g.started(G.Due(key: "a", step: .textModel), now: 10)
        #expect(g.steps[.textModel] == .running(since: 10))
        g.finished(failure: nil, now: 12)
        #expect(g.steps[.textModel] == .pending)
        // Keys go one after the other, each in step order: a's textModel took 2 s, b's takes 3 s.
        _ = runAll(&g, from: 12, each: 3)
        #expect(g.steps[.textModel] == .done(seconds: 5))
    }

    // MARK: progress visibility

    @Test func progressShowsOnlyAfterAStepRanOverTwoSeconds() {
        var g = G()
        g.want("ja")
        g.started(G.Due(key: "ja", step: .textModel), now: 0)
        #expect(!g.shouldShowProgress(now: 2))
        #expect(g.shouldShowProgress(now: 2.5))
    }

    @Test func aFastWarmLaunchNeverShowsProgress() {
        var g = G()
        g.want("ja")
        var t: TimeInterval = 0
        for _ in 0..<3 {
            #expect(!g.shouldShowProgress(now: t))
            t = runOne(&g, at: t, seconds: 0.4)
        }
        #expect(!g.shouldShowProgress(now: t))
        #expect(!g.shouldShowProgress(now: t + 10))
    }

    @Test func progressStaysTwoSecondsAfterAllDoneThenGoes() {
        var g = G()
        g.want("ja")
        let t = runAll(&g, from: 0, each: 30)
        #expect(g.shouldShowProgress(now: t))
        #expect(g.shouldShowProgress(now: t + 1.9))
        #expect(!g.shouldShowProgress(now: t + 2))
    }

    @Test func aFailureKeepsProgressUpUntilRetried() {
        var g = G()
        g.want("ja")
        g.started(G.Due(key: "ja", step: .textModel), now: 0)
        g.finished(failure: "no answer", now: 1)
        #expect(g.shouldShowProgress(now: 1))
        #expect(g.shouldShowProgress(now: 10_000))
        g.retry()
        #expect(!g.shouldShowProgress(now: 10_001))
    }
}
