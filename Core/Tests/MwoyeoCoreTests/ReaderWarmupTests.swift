import Foundation
import Testing
@testable import MwoyeoCore

/// R2 reader-core (2026-10-18, design §4.10 and §10.5, §10.7): the warm-up plan.
@Suite struct ReaderWarmupTests {
    typealias W = ReaderWarmup
    private let both: Set<WorkerRole> = [.lines, .docs]

    /// Runs every step that is due, one at a time, each taking `seconds`; returns the order they ran in.
    private func runAll(_ w: inout W, from now: TimeInterval = 0, each seconds: TimeInterval = 60) -> [W.Step] {
        var t = now
        var order: [W.Step] = []
        while let step = w.nextDue(idleSlots: both) {
            #expect(w.running == nil)
            w.started(step, now: t)
            #expect(w.nextDue(idleSlots: both) == nil, "a running step is never stacked on")
            t += seconds
            w.finished(failure: nil, now: t)
            order.append(step)
        }
        return order
    }

    @Test func testWarmupOrderLinesThenDocs() {
        // §10.7, load-bearing: the compile service is serial and system-wide, and Docs' `.fast` must stay free to read Latin while
        // Lines compiles rev3; the other way round, Lines is free while Docs compiles. Per key, Lines first, then Docs, and one
        // warm-up at a time across both workers, key by key. Today `TextRecognizer.warmUp` runs the text model, the document
        // model and the Swift text model in that order for one process; two workers need the order written down.
        var w = W()
        let auto = w.want("auto", lensOn: false), ja = w.want("ja", lensOn: false)
        #expect(auto && ja)
        let order = runAll(&w)
        #expect(order == [W.Step(.lines, "auto"), W.Step(.docs, "auto"), W.Step(.lines, "ja"), W.Step(.docs, "ja")])
        #expect(w.allDone && w.remaining == 0)
        // the request each step is: rev3 on the probe picture at Lines, the document networks at Docs; no Swift text model step
        #expect(order.map(\.via) == [.rev3, .doc, .rev3, .doc])
        #expect(order.map(\.job.purpose) == Array(repeating: .warmup, count: 4))
    }

    @Test func docsNeverStartsBeforeLinesIsDoneOrFailedForItsKey() {
        var w = W()
        w.want("auto", lensOn: false)
        // Docs has an idle slot and Lines does not: nothing runs (the order is not jumped), even though Docs could take it.
        #expect(w.nextDue(idleSlots: [.docs]) == nil)
        #expect(w.nextDue(idleSlots: [.lines]) == W.Step(.lines, "auto"))
        w.started(W.Step(.lines, "auto"), now: 0)
        #expect(w.nextDue(idleSlots: both) == nil)
        w.finished(failure: nil, now: 70)
        #expect(w.nextDue(idleSlots: [.lines]) == nil)           // Docs' turn, Docs is not idle
        #expect(w.nextDue(idleSlots: [.docs]) == W.Step(.docs, "auto"))
    }

    @Test func aFailedStepWaitsForRetryAndDocsDoesNotWaitForIt() {
        var w = W()
        w.want("auto", lensOn: false)
        w.started(W.Step(.lines, "auto"), now: 0)
        w.finished(failure: "no answer", now: 30)
        #expect(w.hasFailed && w.state(W.Step(.lines, "auto")) == .failed("no answer"))
        #expect(w.nextDue(idleSlots: both) == W.Step(.docs, "auto"))     // nothing compiles in Lines any more
        w.started(W.Step(.docs, "auto"), now: 31)
        w.finished(failure: nil, now: 100)
        #expect(w.nextDue(idleSlots: both) == nil && !w.allDone)
        w.retry()
        #expect(!w.hasFailed)
        #expect(w.nextDue(idleSlots: both) == W.Step(.lines, "auto"))
    }

    @Test func testNoWarmupForNewKeyWhileLensOn() {
        // §10.5: a key that appears while a lens is on is read by that lens, and that read is the compile (in Lines, the kind's
        // home); a warm-up job beside it would be a second compile of the same programs. Today `TextRecognizer.blocks` asks
        // the gate to `want` every key it reads, lens or not, and the gate then runs the whole step list for it.
        var w = W()
        w.want("auto", lensOn: false)
        let whileLensOn = w.want("ja", lensOn: true)
        #expect(!whileLensOn)
        #expect(w.isSkipped("ja") && !w.isWanted("ja"))
        let order = runAll(&w)
        #expect(order == [W.Step(.lines, "auto"), W.Step(.docs, "auto")])      // nothing for "ja"
        #expect(w.state(W.Step(.lines, "ja")) == nil)
        // a key already wanted stays wanted when a lens is on
        let again = w.want("auto", lensOn: true)
        #expect(!again && w.isWanted("auto"))
        // once no lens is on, the key may be wanted after all (a launch, a lens turned off)
        let later = w.want("ja", lensOn: false)
        let second = runAll(&w, from: 500)
        #expect(later)
        #expect(second == [W.Step(.lines, "ja"), W.Step(.docs, "ja")])
    }

    @Test func aWarmupGoesOnlyToAnIdleWorkerWithAnEmptyQueue() {
        var lines = makeHealth(.lines, .idle, warm: [WarmKey(.rev3, "en")]), docs = makeHealth(.docs, .cold)
        var sched = ReadScheduler()
        #expect(W.idleSlots(lines: lines, docs: docs, scheduler: sched) == both)
        // a lens job queued at Lines: not idle for a warm-up, though nothing is in flight
        let target = ReadTarget(role: .lines, via: .rev3)
        _ = sched.submit(client: 1, purpose: .lens, frame: 1, key: "en", target: target, now: 0)
        #expect(W.idleSlots(lines: lines, docs: docs, scheduler: sched) == [.docs])
        // in flight at Docs: not idle either
        let job = sched.next(.lines)!
        lines.dispatch(job.workerJob, now: 0)
        docs.dispatch(WorkerJob(via: .fast, key: "en"), now: 0)
        #expect(W.idleSlots(lines: lines, docs: docs, scheduler: sched).isEmpty)
        // a suspect worker is down for warm-up too
        docs.tick(now: 5)
        lines.reply(.answered, now: 5)
        _ = sched.complete(.lines, id: job.id)
        #expect(W.idleSlots(lines: lines, docs: docs, scheduler: sched) == [.lines])
    }

    @Test func aStepIsNotStartedWhenNothingIsDue() {
        var w = W()
        #expect(w.nextDue(idleSlots: both) == nil && !w.allDone && w.remaining == 0)
        w.started(W.Step(.lines, "auto"), now: 0)                  // not wanted: ignored
        #expect(w.running == nil)
        w.finished(failure: nil, now: 1)
        #expect(w.remaining == 0)
    }

    /// R3a (2026-10-19): the order as `RecognitionHost` runs it, with the real health and scheduler: each step is dispatched as a
    /// warm-up job to its worker, which is down (`warming`) while it runs. Lines compiles first for every key, Docs after, and no
    /// two warm-ups overlap; a lens read that takes a worker keeps its step waiting; a restart replays the plan from the start.
    @Test func theHostRunsLinesThenDocsPerKeyOnTheRealHealth() {
        var lines = WorkerHealth(role: .lines), docs = WorkerHealth(role: .docs)
        var sched = ReadScheduler()
        var w = W()
        _ = w.want("auto", lensOn: false)
        _ = w.want("ja", lensOn: false)
        var dispatched: [String] = []
        var t: TimeInterval = 0

        /// What the host's loop does: start the step that is due on its worker, let it run `seconds`, report it.
        func runDue(seconds: TimeInterval) -> Bool {
            guard let step = w.nextDue(idleSlots: W.idleSlots(lines: lines, docs: docs, scheduler: sched)) else { return false }
            w.started(step, now: t)
            let job = sched.beginWarmup(client: 0, role: step.role, via: step.via, key: step.key, now: t)!
            if step.role == .lines { lines.dispatch(job.workerJob, now: t) } else { docs.dispatch(job.workerJob, now: t) }
            dispatched.append("\(step.role.rawValue):\(step.key)")
            // while it runs, the other worker may not take a second warm-up, and a step is not stacked on a running one
            #expect(w.nextDue(idleSlots: W.idleSlots(lines: lines, docs: docs, scheduler: sched)) == nil)
            t += seconds
            if step.role == .lines { lines.reply(.answered, now: t) } else { docs.reply(.answered, now: t) }
            _ = sched.complete(step.role, id: job.id)
            w.finished(failure: nil, now: t)
            return true
        }

        // a lens read holds Lines: the first step waits for it
        let busy = sched.submit(client: 1, purpose: .lens, frame: 1, key: "auto", target: ReadTarget(role: .lines, via: .rev3), now: 0).job
        #expect(!runDue(seconds: 1))
        #expect(sched.next(.lines)?.id == busy.id)
        lines.dispatch(busy.workerJob, now: 0)
        #expect(!runDue(seconds: 1))
        lines.reply(.answered, now: 1)
        _ = sched.complete(.lines, id: busy.id)
        while runDue(seconds: 30) {}
        #expect(dispatched == ["lines:auto", "docs:auto", "lines:ja", "docs:ja"])
        #expect(w.allDone)

        // Lines crashes: its warm set is gone, and the host plans again from the start (a fresh plan over the same keys)
        lines.dispatch(WorkerJob(via: .rev3, key: "ja"), now: t)
        _ = lines.interrupted(now: t)
        #expect(lines.warm.isEmpty)
        _ = sched.lost(.lines)
        w = W()
        _ = w.want("auto", lensOn: false)
        _ = w.want("ja", lensOn: false)
        t += 60
        _ = lines.tick(now: t)
        dispatched = []
        while runDue(seconds: 1) {}
        #expect(dispatched == ["lines:auto", "docs:auto", "lines:ja", "docs:ja"])
    }
}
