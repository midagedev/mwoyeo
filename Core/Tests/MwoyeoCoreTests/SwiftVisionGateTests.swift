import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct SwiftVisionGateTests {
    private typealias G = SwiftVisionGate

    @Test func nothingIsReadyOrDueUntilAKeyIsWanted() {
        let g = G()
        #expect(!g.isReady("ja"))
        #expect(g.nextDue(now: 0) == nil)
        #expect(g.allReady)
        #expect(g.waiting("ja", now: 5) == nil)
    }

    @Test func aWantedKeyIsDueAtOnce() {
        var g = G()
        g.want("ja")
        #expect(g.nextDue(now: 0) == "ja")
        #expect(!g.allReady)
    }

    @Test func aRunningChildIsNeverStackedOnHoweverLongItTakes() {
        var g = G()
        g.want("ja")
        g.want("fr")
        g.started("ja", now: 0)
        #expect(g.running == "ja")
        #expect(g.nextDue(now: 1) == nil)
        #expect(g.nextDue(now: G.retryEvery) == nil)
        #expect(g.nextDue(now: 10_000) == nil)
    }

    @Test func keysGoInTheOrderTheyWereAskedFor() {
        var g = G()
        g.want("fr")
        g.want("ja")
        g.want("fr")
        #expect(g.nextDue(now: 0) == "fr")
        g.started("fr", now: 0)
        let made = g.ended(success: true)
        #expect(made == "fr")
        #expect(g.nextDue(now: 1) == "ja")
    }

    @Test func aKeyThatEndedWithoutSuccessIsStartedAgainAfterTwoMinutesAndOthersGoMeanwhile() {
        var g = G()
        g.want("ja")
        g.want("fr")
        g.started("ja", now: 0)
        let made = g.ended(success: false)
        #expect(made == nil)
        #expect(!g.isReady("ja"))
        // fr is not starved by the key that failed.
        #expect(g.nextDue(now: 1) == "fr")
        g.started("fr", now: 1)
        g.ended(success: true)
        #expect(g.nextDue(now: 60) == nil)
        #expect(g.nextDue(now: G.retryEvery - 1) == nil)
        #expect(g.nextDue(now: G.retryEvery) == "ja")
    }

    @Test func theRetrySpacingCountsFromTheLastStartNotTheLastEnd() {
        var g = G()
        g.want("ja")
        g.started("ja", now: 0)
        g.ended(success: false)
        g.started("ja", now: 120)
        // Ended after a long run: the next start is due 120 s after the start at 120, not after the end.
        g.ended(success: false)
        #expect(g.nextDue(now: 239) == nil)
        #expect(g.nextDue(now: 240) == "ja")
    }

    @Test func aSuccessfulChildMakesOnlyItsKeyReadyForGood() {
        var g = G()
        g.want("ja")
        g.want("fr")
        g.started("ja", now: 0)
        let first = g.ended(success: true)
        #expect(first == "ja")
        #expect(g.isReady("ja"))
        #expect(!g.isReady("fr"))
        #expect(g.running == nil)
        #expect(g.nextDue(now: 10_000) == "fr")
        // A report with nothing running changes nothing.
        let second = g.ended(success: true)
        #expect(second == nil)
        #expect(g.isReady("ja"))
    }

    @Test func aFailedChildOfAReadyKeyDoesNotUndoIt() {
        var g = G()
        g.want("ja")
        g.started("ja", now: 0)
        g.ended(success: true)
        g.started("ja", now: 500)   // started again by mistake, or by a caller that did not check
        g.ended(success: false)
        #expect(g.isReady("ja"))
    }

    @Test func assumingReadyMakesEveryKeyReadyAndStartsNothing() {
        var g = G()
        g.assumeReady()
        g.want("ja")
        #expect(g.isReady("ja"))
        #expect(g.isReady("anything"))
        #expect(g.nextDue(now: 0) == nil)
        #expect(g.waiting("ja", now: 100) == nil)
    }

    @Test func waitingCountsFromTheKeysFirstStartUntilItIsReady() {
        var g = G()
        g.want("ja")
        g.started("ja", now: 10)
        g.ended(success: false)
        g.started("ja", now: 130)
        #expect(g.waiting("ja", now: 200) == 190)
        #expect(g.waiting("fr", now: 200) == nil)
        g.ended(success: true)
        #expect(g.waiting("ja", now: 200) == nil)
    }

    @Test func aChildThatCouldNotStartCountsAsAnAttempt() {
        var g = G()
        g.want("ja")
        g.started("ja", now: 0)
        g.ended(success: false)   // the process failed to run
        #expect(g.running == nil)
        #expect(g.nextDue(now: 1) == nil)
        #expect(g.nextDue(now: G.retryEvery) == "ja")
    }

    @Test func readyKeysListWhatWasLoaded() {
        var g = G()
        #expect(g.readyKeys.isEmpty)
        g.want("ja")
        g.want("auto")
        g.started("ja", now: 0)
        g.ended(success: true)
        #expect(g.readyKeys == ["ja"])
        g.assumeReady()
        #expect(g.readyKeys == ["*"])
    }

    @Test func allReadyWhenEveryWantedKeyIs() {
        var g = G()
        g.want("auto")
        g.want("ja")
        g.started("auto", now: 0)
        g.ended(success: true)
        #expect(!g.allReady)
        g.started("ja", now: 1)
        g.ended(success: true)
        #expect(g.allReady)
    }
}
