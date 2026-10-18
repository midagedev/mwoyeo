import Foundation
import Testing
@testable import MwoyeoCore

/// 2026-10-18 (r3-docs-xpc): the rules by which a read that wants the document layout meets the Docs worker in 1.1.2. The lens is
/// never silent and never waits for Docs: anything but an idle, warm Docs reads with the grouper at once, and a slow answer is
/// never a failure. Each rule has a variant that breaks it (FAIL-first, recorded in the round's report).
@Suite struct DocsRouteTests {
    private func warm(_ key: String = "en", at now: TimeInterval = 0) -> WorkerHealth {
        var h = WorkerHealth(role: .docs)
        h.dispatch(WorkerJob(via: .doc, key: key, purpose: .warmup), now: now)
        h.reply(.answered, now: now + 1)
        return h
    }

    private func lensJob(_ key: String = "en") -> WorkerJob { WorkerJob(via: .doc, key: key, purpose: .lens) }

    @Test func aKeyDocsHasNeverAnsweredReadsWithTheGrouper() {
        let h = WorkerHealth(role: .docs)
        #expect(DocsRoute.route(docs: h, key: "en", now: 0) == .fallback(.cold))
        // A first document read of a key compiles for tens of seconds: only a warm key is asked.
        let w = warm("en")
        #expect(DocsRoute.route(docs: w, key: "en", now: 2) == .doc)
        #expect(DocsRoute.route(docs: w, key: "ja", now: 2) == .fallback(.cold))
    }

    @Test func aWarmUpInFlightIsAFallbackNotAWait() {
        var h = WorkerHealth(role: .docs)
        h.dispatch(WorkerJob(via: .doc, key: "en", purpose: .warmup), now: 0)
        #expect(DocsRoute.route(docs: h, key: "en", now: 30) == .fallback(.warming))
        h.reply(.answered, now: 40)
        #expect(DocsRoute.route(docs: h, key: "en", now: 40) == .doc)
    }

    @Test func aBusyDocsIsNotQueuedBehindAndNeitherIsASuspectOne() {
        var h = warm()
        h.dispatch(lensJob(), now: 10)
        #expect(DocsRoute.route(docs: h, key: "en", now: 10.5) == .fallback(.busy))
        // S = 2 s (`ReadVia.doc.patience`); the route reads the state at `now`, with no tick in between.
        #expect(DocsRoute.route(docs: h, key: "en", now: 12) == .fallback(.suspect))
        #expect(DocsRoute.route(docs: h, key: "en", now: 70) == .fallback(.suspect))
    }

    @Test func aSlowAnswerIsNeverAFailureAndDocsIsUsedAgain() {
        // The old gate took a key back after a second missed deadline, until relaunch. Three episodes of 60-130 s: still usable.
        var h = warm()
        var t: TimeInterval = 10
        for seconds in [61.0, 130.0, 90.0] {
            h.dispatch(lensJob(), now: t)
            let suspected = h.tick(now: t + 2)
            #expect(suspected.contains { if case .suspected = $0 { true } else { false } })
            #expect(DocsRoute.route(docs: h, key: "en", now: t + 2) == .fallback(.suspect))
            let events = h.reply(.answered, now: t + seconds)
            #expect(events.contains(.readerReady))
            #expect(DocsRoute.route(docs: h, key: "en", now: t + seconds) == .doc)
            t += seconds + 5
        }
        #expect(h.stats.suspects == 3)
        #expect(h.state == .idle)
    }

    @Test func aStuckRequestStillComesBackWhenItAnswers() {
        var h = warm()
        h.dispatch(lensJob(), now: 0)
        _ = h.tick(now: 240)
        #expect(DocsRoute.route(docs: h, key: "en", now: 240) == .fallback(.stuck))
        // Nothing here recycles it (R3-lite never cancels): the answer, whenever it comes, ends the episode.
        _ = h.reply(.answered, now: 300)
        #expect(DocsRoute.route(docs: h, key: "en", now: 300) == .doc)
    }

    @Test func aCrashClearsWhatWasWarmAndTheKeyWarmsAgain() {
        var h = warm()
        h.dispatch(lensJob(), now: 10)
        let events = h.interrupted(now: 11)
        #expect(events == [.crashed(count: 1)])
        #expect(DocsRoute.route(docs: h, key: "en", now: 11.5) == .fallback(.restarting))
        // The restart waits `Backoff.workerRestart` (1 s). The service comes back cold for the key: the warm-up job asks again.
        let restarted = h.tick(now: 12.1)
        #expect(restarted == [.usableAgain])
        #expect(DocsRoute.route(docs: h, key: "en", now: 12.1) == .fallback(.cold))
        h.dispatch(WorkerJob(via: .doc, key: "en", purpose: .warmup), now: 12.2)
        h.reply(.answered, now: 13)
        #expect(DocsRoute.route(docs: h, key: "en", now: 13) == .doc)
    }

    @Test func aCrashLoopDisablesDocsForTheRun() {
        // Five crashes inside ten minutes: no more attempts in this run (the grouper reads for good). Each cycle is a lens request
        // that dies with the service, the restart wait, and the warm-up job that asks again.
        var h = warm()
        var t: TimeInterval = 100
        for crash in 1...WorkerHealth.crashLimit {
            h.dispatch(lensJob(), now: t)
            let events = h.interrupted(now: t + 0.5)
            #expect(events.contains(.crashed(count: crash)))
            t += 40
            if crash < WorkerHealth.crashLimit {
                h.tick(now: t)
                h.dispatch(WorkerJob(via: .doc, key: "en", purpose: .warmup), now: t)
                h.reply(.answered, now: t + 0.5)
                #expect(DocsRoute.route(docs: h, key: "en", now: t + 0.5) == .doc)
            }
        }
        #expect(DocsRoute.route(docs: h, key: "en", now: t) == .fallback(.disabled))
        #expect(h.state == .disabled(.crashLoop))
    }

    @Test func aDocsThatKeepsAnsweringLateRestsBetweenRequests() {
        // 2026-10-18 (r3-docs-xpc): found with `docs-slow` and a recovery re-read per late answer: a request that always takes longer than
        // S was sent again by every re-read, for ever. The first slow answer is one episode (a cold compile): no rest, the lenses read
        // again at once. Each slow answer after it rests Docs 1, 2, 4 … 30 s.
        var h = warm()
        var rest = DocsRest()
        var t: TimeInterval = 10
        var starts: [TimeInterval] = []
        while t < 60 {
            let route = DocsRoute.route(docs: h, key: "en", now: t, restingUntil: rest.until)
            if route == .doc {
                starts.append(t)
                h.dispatch(lensJob(), now: t)
                h.tick(now: t + 2)
                t += 3                                    // it answers after 3 s: past S = 2 s
                h.reply(.answered, now: t)
                rest.slowAnswer(now: t)                   // what the host does on `recovered`
            } else {
                #expect(route == .fallback(.resting))
                t += 0.5
            }
        }
        // 3 s each: without a rest 17 requests in these 50 s. Rested: the 2nd goes at once, then after 1, 2, 4, 8, 16 s.
        #expect(starts == [10, 13, 17, 22, 29, 40, 59])
    }

    @Test func aRestStartsAtTheSecondSlowAnswerAndAnAnswerInTimeEndsTheStreak() {
        var rest = DocsRest()
        #expect(rest.slowAnswer(now: 100) == 0)
        #expect(!rest.isResting(now: 100) && rest.until == nil)
        #expect(rest.slowAnswer(now: 110) == 1)
        #expect(rest.isResting(now: 110.5) && !rest.isResting(now: 111))
        #expect(rest.slowAnswer(now: 120) == 2)
        #expect(rest.streak == 3)
        rest.answeredInTime()
        #expect(rest.streak == 0 && rest.until == nil)
        #expect(rest.slowAnswer(now: 200) == 0)
        for i in 0..<12 { rest.slowAnswer(now: 300 + TimeInterval(i)) }
        #expect(rest.slowAnswer(now: 400) == 30)
    }

    @Test func aRestIsOverAtItsEndAndBeatsNothingElse() {
        let h = warm()
        #expect(DocsRoute.route(docs: h, key: "en", now: 5, restingUntil: 6) == .fallback(.resting))
        #expect(DocsRoute.route(docs: h, key: "en", now: 6, restingUntil: 6) == .doc)
        #expect(DocsRoute.route(docs: h, key: "en", now: 5, restingUntil: nil) == .doc)
        // The state is told first: a busy Docs is busy, rested or not.
        var busy = warm()
        busy.dispatch(lensJob(), now: 5)
        #expect(DocsRoute.route(docs: busy, key: "en", now: 5.5, restingUntil: 9) == .fallback(.busy))
        #expect(DocsRoute.route(docs: h, key: "en", now: 5, path: .vn, restingUntil: 9) == .fallback(.vnOnly))
    }

    @Test func theBenchOverridesAreOnlyThoseTwo() {
        let cold = WorkerHealth(role: .docs)
        #expect(DocsRoute.route(docs: cold, key: "en", now: 0, path: .vn) == .fallback(.vnOnly))
        #expect(DocsRoute.route(docs: warm(), key: "en", now: 2, path: .vn) == .fallback(.vnOnly))
        // `swift` assumes the key warm, and that is all: a busy worker is still busy.
        #expect(DocsRoute.route(docs: cold, key: "en", now: 0, path: .swift) == .doc)
        var busy = warm()
        busy.dispatch(lensJob(), now: 5)
        #expect(DocsRoute.route(docs: busy, key: "en", now: 5.1, path: .swift) == .fallback(.busy))
    }

    // MARK: LayoutStandIns

    @Test func aClientThatFellBackReadsAgainOnceWhenDocsIsReady() {
        var s = LayoutStandIns()
        s.fellBack(3)
        s.fellBack(1)
        s.fellBack(3)
        #expect(s.contains(1) && s.contains(3))
        let first = s.ready()
        #expect(first == [1, 3])
        let second = s.ready()
        #expect(second.isEmpty)
    }

    @Test func aClientThatGotTheDocumentLayoutOrLeftIsNotReadAgain() {
        var s = LayoutStandIns()
        s.fellBack(1)
        s.fellBack(2)
        s.fellBack(3)
        s.served(1)
        s.forget(2)
        #expect(!s.contains(1) && !s.contains(2))
        let ready = s.ready()
        #expect(ready == [3])
    }
}
