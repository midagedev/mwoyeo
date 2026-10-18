import Foundation
import Testing
@testable import MwoyeoCore

/// R2 reader-core (2026-10-18, design §4.4 and §10): the worker health state machine. Times are seconds of a simulated clock.
@Suite struct ReaderHealthTests {
    typealias H = WorkerHealth
    private func lens(_ via: ReadVia, _ key: String) -> WorkerJob { WorkerJob(via: via, key: key, purpose: .lens) }

    /// An idle worker that has answered `via` for `key` (a warm-up ran).
    private func warmed(_ role: WorkerRole, _ via: ReadVia, _ key: String = "en", at t: TimeInterval = 0) -> H {
        var h = H(role: role)
        let sent = h.dispatch(WorkerJob(via: via, key: key, purpose: .warmup), now: t)
        #expect(sent)
        h.reply(.answered, now: t + 1)
        return h
    }

    // MARK: S, suspect, recovery

    @Test func testSlowDocReadIsNotFailure() {
        // Today (G7, `SwiftVisionGate.missed`, `SwiftVisionGate.swift:132-137` at feb7a12): the second document read that misses its
        // deadline makes the key `.failed` until relaunch, and the first one made the step due again (a second compile). Here a read
        // is slow when it is slow, and nothing else: two late answers leave the worker as usable as before.
        var h = warmed(.docs, .doc)
        var events: [H.Event] = []
        for round in 0..<2 {
            let t0 = TimeInterval(10 + round * 100)
            let sent = h.dispatch(lens(.doc, "en"), now: t0)
            #expect(sent)
            events += h.tick(now: t0 + 2)
            #expect(h.state.name == "suspect")
            events += h.reply(.answered, now: t0 + 34.3)       // doc p13 on a cold network: 34.3 s
            #expect(h.state == .idle)
        }
        #expect(h.readiness(for: .doc, key: "en", now: 300) == .ready)
        #expect(h.state != .disabled(.crashLoop) && h.state != .disabled(.stuckTwice))
        #expect(events.filter { if case .suspected = $0 { true } else { false } }.count == 2)
        #expect(events.filter { if case .recovered = $0 { true } else { false } }.count == 2)
        #expect(h.stats.suspects == 2)
        #expect(abs(h.stats.maxSuspectSeconds - 34.3) < 1e-9)
    }

    @Test func busyTurnsSuspectAtSOfItsKind() {
        for (via, s) in [(ReadVia.doc, 2.0), (.rev3, 3), (.rev2, 3), (.fast, 1)] {
            var h = warmed(.lines, via)
            #expect(via.patience == s)
            h.dispatch(lens(via, "en"), now: 100)
            let quiet = h.tick(now: 100 + s - 0.001).isEmpty
            #expect(quiet, "\(via)")
            #expect(h.state.name == "busy")
            let events = h.tick(now: 100 + s)
            #expect(events == [.suspected(lens(via, "en"), after: s)], "\(via)")
            #expect(h.state.name == "suspect")
        }
    }

    @Test func oneRequestInFlightPerWorker() {
        var h = warmed(.lines, .rev3)
        let sent = h.dispatch(lens(.rev3, "en"), now: 10)
        #expect(sent)
        let sent2 = h.dispatch(lens(.fast, "en"), now: 10.1)
        #expect(!sent2)
        #expect(!h.canDispatch)
        h.tick(now: 14)
        let sent3 = h.dispatch(lens(.fast, "en"), now: 14)
        #expect(!sent3)      // suspect: no stacking on it either
        h.reply(.answered, now: 15)
        #expect(h.canDispatch)
    }

    @Test func aReplyEndsSuspectWarmsTheKeyAndBroadcastsReady() {
        var h = H(role: .lines)
        h.dispatch(lens(.rev3, "ja"), now: 0)                  // the lens's own read is the compile (cold for "ja", Lines is home)
        h.tick(now: 3)
        let events = h.reply(.answered, now: 40)
        #expect(events == [.recovered(lens(.rev3, "ja"), after: 40), .readerReady])
        #expect(h.isWarm(.rev3, key: "ja") && !h.isWarm(.rev3, key: "en"))
        #expect(h.state == .idle)
    }

    @Test func aWarmupEndBroadcastsReadyAndAWarmupIsNeverSuspect() {
        var h = H(role: .docs)
        let job = WorkerJob(via: .doc, key: "auto", purpose: .warmup)
        h.dispatch(job, now: 0)
        #expect(h.state == .warming(job, since: 0))
        let quiet = h.tick(now: 3).isEmpty
        let quiet2 = h.tick(now: 100).isEmpty
        #expect(quiet && quiet2)
        #expect(h.readiness(for: .fast, key: "auto", now: 50) == .unusable)     // a compiling process answers nothing
        let events = h.reply(.answered, now: 131)
        #expect(events == [.warmed(job, after: 131), .readerReady])
        #expect(h.isWarm(.doc, key: "auto"))
    }

    @Test func aReplyWithNothingInFlightChangesNothing() {
        var h = warmed(.lines, .rev3)
        let quiet = h.reply(.answered, now: 50).isEmpty
        #expect(quiet)
        #expect(h.state == .idle)
    }

    @Test func anErrorReplyFreesTheWorkerWithoutWarmingTheKey() {
        var h = H(role: .docs)
        h.dispatch(lens(.doc, "en"), now: 0)
        h.tick(now: 2)
        let events = h.reply(.failed, now: 9)
        #expect(events == [.usableAgain])
        #expect(!h.isWarm(.doc, key: "en") && h.state == .idle)
        #expect(h.stats.failed[.doc] == 1)
    }

    // MARK: stuck

    /// Today (`OCRHealth.giveUpAfter` = 180, `OCRHealth.swift:14`) every stall is judged at 180 s whatever it waits for: the
    /// longest cold compile seen is 138 s under contention, and §10.3 moves a lens job to 240 s.
    @Test func aLensJobIsStuckAt240NotBefore() {
        var h = H(role: .lines)
        h.dispatch(lens(.rev3, "en"), now: 0)
        h.tick(now: 3)
        let quiet = h.tick(now: 180).isEmpty
        #expect(quiet)
        let quiet2 = h.tick(now: 239.9).isEmpty
        #expect(quiet2)
        #expect(h.state.name == "suspect")
        let events = h.tick(now: 240)
        #expect(events == [.stuck(lens(.rev3, "en"), after: 240), .recycle(.stuck)])
        #expect(h.state == .stuck(lens(.rev3, "en"), since: 0))
        #expect(h.stats.stuck == 1)
    }

    @Test func testStuckTwiceStopsRecycling() {
        // Today (design §3.3, `OCRHealth.probeEvery`): a stalled model is probed every 120 s for ever and nothing ever restarts the
        // process that holds the request. Here the first stuck recycles once; if the successor's first job is stuck too, another
        // exit would only repeat it: no recycle, `disabled`, and the router says "not responding".
        var h = H(role: .lines)
        h.dispatch(lens(.rev3, "en"), now: 0)
        let first = h.tick(now: 240)
        #expect(first.contains(.recycle(.stuck)))
        let quiet = h.interrupted(now: 241).isEmpty
        #expect(quiet)               // the exit we asked for is not a crash
        #expect(h.state == .restarting(until: 242))
        #expect(h.stats.crashes == 0)
        let ticked = h.tick(now: 242)
        #expect(ticked == [.usableAgain] && h.state == .cold)

        h.dispatch(lens(.rev3, "en"), now: 245)                // the successor's first job
        let second = h.tick(now: 245 + 240)
        #expect(!second.contains(.recycle(.stuck)))
        #expect(second.contains(.disabled(.stuckTwice)))
        #expect(h.state == .disabled(.stuckTwice))
        #expect(h.readiness(for: .rev3, key: "en", now: 500) == .unusable)
        #expect(h.stats.recycles == 1)                         // the first stuck asked for one exit, the second did not
    }

    @Test func anAnswerBetweenTwoStucksBreaksTheRow() {
        var h = H(role: .lines)
        h.dispatch(lens(.rev3, "en"), now: 0)
        h.tick(now: 240)
        h.interrupted(now: 241)
        h.tick(now: 242)
        h.dispatch(lens(.rev3, "en"), now: 243)
        h.reply(.answered, now: 244)                           // the successor answers: it was not stuck "twice in a row"
        h.dispatch(lens(.rev3, "en"), now: 1000)
        let events = h.tick(now: 1240)
        #expect(events.contains(.recycle(.stuck)) && !events.contains(.disabled(.stuckTwice)))
    }

    @Test func aLateAnswerFromAStuckWorkerReleasesIt() {
        var h = H(role: .docs)
        h.dispatch(lens(.doc, "en"), now: 0)
        h.tick(now: 240)
        #expect(h.state.name == "stuck")
        let events = h.reply(.answered, now: 241)              // it answered before our exit reached it
        #expect(events.contains(.readerReady) && h.state == .idle)
    }

    // MARK: warming

    @Test func testWarmingIsNeverRecycledBefore400s() {
        // Today the stall rule is `giveUpAfter` = 180 for every request, a warm-up (an expected 64-130 s compile, 138 s under
        // contention) included. §10.3: `warming` has its own bound of 400 s (≥ 2× the longest warm-up) and is never recycled before it.
        var h = H(role: .lines)
        let job = WorkerJob(via: .rev3, key: "ja", purpose: .warmup)
        h.dispatch(job, now: 0)
        var events: [H.Event] = []
        for t in [3.0, 60, 138, 180, 240, 300, 399.9] { events += h.tick(now: t) }
        #expect(events.isEmpty)
        #expect(h.state == .warming(job, since: 0))
        let bound = h.tick(now: 400)
        #expect(bound == [.stuck(job, after: 400), .recycle(.stuck)])
        #expect(h.nextDeadline(now: 400) == nil)               // stuck: only the exit report moves it on
    }

    // MARK: crash, restart, recycle

    @Test func aCrashRestartsOnBackoffAndTheFifthInTenMinutesDisables() {
        var h = warmed(.docs, .doc)
        var t: TimeInterval = 10
        var untils: [TimeInterval] = []
        for n in 1...4 {
            h.dispatch(lens(.doc, "en"), now: t)
            let events = h.interrupted(now: t + 0.5)
            #expect(events == [.crashed(count: n)])
            if case let .restarting(until) = h.state { untils.append(until - (t + 0.5)) }
            #expect(h.warm.isEmpty)                            // the warm set goes with the process
            t += 0.5 + untils.last!
            let ticked = h.tick(now: t)
            #expect(ticked == [.usableAgain] && h.state == .cold)
        }
        #expect(untils == [1, 2, 4, 8])
        h.dispatch(lens(.doc, "en"), now: t)
        let fifth = h.interrupted(now: t + 0.1)
        #expect(fifth == [.crashed(count: 5), .disabled(.crashLoop)])
        #expect(h.state == .disabled(.crashLoop))
        let quiet = h.tick(now: t + 9999).isEmpty
        #expect(quiet && h.state == .disabled(.crashLoop))
    }

    @Test func crashesTenMinutesApartNeverDisable() {
        var h = H(role: .lines)
        for n in 0..<8 {
            let t = TimeInterval(n * 700)
            h.dispatch(lens(.rev3, "en"), now: t)
            h.interrupted(now: t + 1)
            h.tick(now: t + 40)
        }
        #expect(h.state == .cold)
        #expect(h.stats.crashes == 8)
    }

    @Test func aNoticeOfOurOwnExitIsNotACrash() {
        var h = warmed(.lines, .rev3)
        h.tick(now: 1 + H.idleExitAfter)                       // idle exit → cold
        #expect(h.state == .cold)
        let quiet = h.interrupted(now: 1 + H.idleExitAfter + 0.1).isEmpty
        #expect(quiet)
        #expect(h.stats.crashes == 0 && h.state == .cold)
    }

    /// Runs `n` rev3 requests that fail with Code 13, each when the rung allows it; returns every event.
    private func codeThirteenStreak(_ h: inout H, _ n: Int, from start: TimeInterval) -> (events: [H.Event], end: TimeInterval) {
        var t = start
        var all: [H.Event] = []
        for _ in 0..<n {
            let sent = h.dispatch(lens(.rev3, "en"), now: t)
            #expect(sent)
            let events = h.reply(.notReady, now: t + 0.012)
            all += events
            if events.contains(where: { if case .recycle = $0 { true } else { false } }) { return (all, t) }
            let wait = events.compactMap { e -> TimeInterval? in if case let .rungResting(_, w) = e { w } else { nil } }.first ?? 0
            t += 0.012 + wait
            all += h.tick(now: t)
        }
        return (all, t)
    }

    @Test func aCodeThirteenStreakRecyclesAnIdleWorkerOnce20() {
        // The 3 h case (13,361 errors in one process, cured only by a restart): rev3 had answered, then every request fails.
        var h = warmed(.lines, .rev3)
        let (events, _) = codeThirteenStreak(&h, 25, from: 10)
        let recycles = events.filter { $0 == .recycle(.code13) }
        #expect(recycles.count == 1)
        #expect(h.stats.recycles == 1)
        // Waits 1,2,4,8,16 and 30 s after: the 20th failure comes 451 s after the first, far past the 60 s clause.
        #expect(h.state.name == "restarting")
        #expect(h.warm.isEmpty)
    }

    @Test func theRungRestsBetweenCodeThirteenErrors() {
        var h = warmed(.lines, .rev3)
        h.dispatch(lens(.rev3, "en"), now: 10)
        let e1 = h.reply(.notReady, now: 10.012)
        #expect(e1 == [.rungResting(.rev3, for: 1)])
        #expect(h.readiness(for: .rev3, key: "en", now: 10.5) == .unusable)
        #expect(h.readiness(for: .rev2, key: "en", now: 10.5) == .ready)        // rev2 and .fast serve meanwhile
        #expect(h.readiness(for: .fast, key: "en", now: 10.5) == .ready)
        #expect(h.nextDeadline(now: 10.5) == 11.012)
        let ticked = h.tick(now: 11.012)
        #expect(ticked == [.usableAgain])
        #expect(h.readiness(for: .rev3, key: "en", now: 11.012) == .ready)
        h.dispatch(lens(.rev3, "en"), now: 11.1)
        let events = h.reply(.notReady, now: 11.11)
        #expect(events == [.rungResting(.rev3, for: 2)])
        h.tick(now: 14)
        h.dispatch(lens(.rev3, "en"), now: 14)
        let answered = h.reply(.answered, now: 14.3)                               // an answer ends the streak
        #expect(answered.isEmpty)
        #expect(h.stats.code13Streak == 0)
        h.dispatch(lens(.rev3, "en"), now: 15)
        let events2 = h.reply(.notReady, now: 15.01)
        #expect(events2 == [.rungResting(.rev3, for: 1)])
    }

    @Test func noCodeThirteenRecycleUnlessRev3HadAnswered() {
        var h = H(role: .lines)                                // a worker whose rev3 never answered: still compiling, not broken
        let (events, _) = codeThirteenStreak(&h, 30, from: 0)
        #expect(!events.contains(.recycle(.code13)))
        #expect(h.stats.code13Streak == 30)
    }

    @Test func atMostThreeRecyclesInThirtyMinutes() {
        var h = warmed(.lines, .rev3)
        var t: TimeInterval = 10
        var recycledAt: [TimeInterval] = []
        for _ in 0..<4 {
            // 22 failures: the 20th is the one that would recycle, the 21st and 22nd come before the first recycle is 30 minutes old.
            let (events, end) = codeThirteenStreak(&h, 22, from: t)
            if events.contains(.recycle(.code13)) { recycledAt.append(end) }
            // The successor starts and rev3 answers once, as it would; then the streak begins again.
            t = end + 60
            h.tick(now: t)
            h.dispatch(lens(.rev3, "en"), now: t)
            h.reply(.answered, now: t + 1)
            t += 2
        }
        #expect(recycledAt.count == 3)
        #expect(recycledAt.last! - recycledAt.first! < H.recycleWindow)
    }

    @Test func aFootprintOverTwiceItsBaselineRecyclesWhenIdle() {
        var h = H(role: .docs)
        h.dispatch(WorkerJob(via: .doc, key: "en", purpose: .warmup), now: 0)
        let has = h.reply(.answered, now: 100, footprintMB: 60).contains(.readerReady)
        #expect(has)     // the baseline: 60 MB after the warm-up
        h.dispatch(lens(.doc, "en"), now: 101)
        let quiet = h.reply(.answered, now: 101.4, footprintMB: 118).isEmpty
        #expect(quiet)                 // 1.97×: fine
        h.dispatch(lens(.doc, "en"), now: 102)
        let events3 = h.reply(.answered, now: 102.4, footprintMB: 121)
        #expect(events3 == [.recycle(.footprint)])
        #expect(h.state.name == "restarting")
    }

    // MARK: idle exit

    @Test func anIdleWorkerExitsAfterTenMinutesWithNoClient() {
        var h = warmed(.lines, .rev3)                          // idle since t = 1
        #expect(h.nextDeadline(now: 2) == 1 + H.idleExitAfter)
        let quiet = h.tick(now: 600.9).isEmpty
        #expect(quiet)
        // A lens that wants this worker keeps it.
        let quiet2 = h.tick(now: 601, wanted: true).isEmpty
        #expect(quiet2)
        let quiet3 = h.tick(now: 1200, wanted: true).isEmpty
        #expect(quiet3)
        let quiet4 = h.tick(now: 1200 + H.idleExitAfter - 0.1).isEmpty
        #expect(quiet4)                  // the clock restarted at the last "wanted"
        let ticked5 = h.tick(now: 1200 + H.idleExitAfter)
        #expect(ticked5 == [.idleExit])
        #expect(h.state == .cold)
        #expect(h.isWarm(.rev3, key: "en"))                    // the cache is on disk: the next job relaunches in ~0.6 s
        #expect(h.readiness(for: .rev3, key: "en", now: 1300) == .ready)
    }

    // MARK: readiness (rules 6 and the down states)

    @Test func readinessByStateAndKind() {
        // cold: usable for its home kinds (the first job starts it), and for `.fast` anywhere; a doc read needs a warm key.
        let lines = H(role: .lines), docs = H(role: .docs)
        #expect(lines.readiness(for: .rev3, key: "ja", now: 0) == .ready)
        #expect(lines.readiness(for: .rev2, key: "ja", now: 0) == .ready)
        #expect(docs.readiness(for: .fast, key: "en", now: 0) == .ready)
        #expect(docs.readiness(for: .doc, key: "en", now: 0) == .unusable)
        #expect(docs.readiness(for: .doc, key: "en", now: 0, assumeWarm: true) == .ready)
        // never a kind to the worker that is not its home and has not answered it
        #expect(docs.readiness(for: .rev3, key: "en", now: 0) == .unusable)
        #expect(docs.readiness(for: .rev2, key: "en", now: 0) == .unusable)
        #expect(lines.readiness(for: .doc, key: "en", now: 0) == .unusable)
        // busy within S: behind the request in flight; past S: down
        var busy = warmed(.docs, .doc)
        busy.dispatch(lens(.doc, "en"), now: 10)
        #expect(busy.readiness(for: .doc, key: "en", now: 11) == .queueBehind)
        #expect(busy.readiness(for: .doc, key: "en", now: 12) == .unusable)         // age 2 = S, though no tick has run
        #expect(busy.readiness(for: .fast, key: "en", now: 12) == .unusable)        // one compile blocks the whole process
        // warming, restarting, disabled
        var warming = H(role: .docs)
        warming.dispatch(WorkerJob(via: .doc, key: "en", purpose: .warmup), now: 0)
        #expect(warming.readiness(for: .fast, key: "en", now: 10) == .unusable)
        var restarting = warmed(.lines, .rev3)
        restarting.dispatch(lens(.rev3, "en"), now: 5)
        restarting.interrupted(now: 6)
        #expect(restarting.readiness(for: .rev3, key: "en", now: 6.5) == .unusable)
        #expect(restarting.readiness(for: .rev3, key: "en", now: 7) == .ready)       // the restart wait is over: cold, home kind
    }
}
