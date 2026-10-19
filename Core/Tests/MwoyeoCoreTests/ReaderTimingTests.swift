import Foundation
import Testing
@testable import MwoyeoCore

/// g2-fast-host-gates (2026-10-19): the durations of the reader host are one injectable struct whose defaults are what always shipped.
@Suite struct ReaderTimingTests {
    @Test func theShippedNumbersAreTheOnesTheHostAlwaysRanOn() {
        // New pins (not a re-pin): the values of ReadVia.patience, WorkerHealth's limits, Backoff.Use and OCRHealth.coldWait as of
        // 7f8d1af, before the host's durations became parameters. A change here changes the product.
        let t = ReaderTiming.standard
        #expect(t.patience == [.doc: 2, .rev3: 3, .rev2: 3, .fast: 1])
        #expect(t.stuckAfter == 240 && t.warmingBound == 400 && t.idleExitAfter == 600)
        #expect(t.code13Span == 60 && t.recycleWindow == 1800 && t.crashWindow == 600)
        #expect(t.restart.schedule(7) == [1, 2, 4, 8, 16, 30, 30] && t.restart.healthyWindow == 600)
        #expect(t.rung.schedule(7) == [1, 2, 4, 8, 16, 30, 30] && t.docsRest.schedule(7) == [1, 2, 4, 8, 16, 30, 30])
        #expect(t.coldWait == 180 && t.warmPoll == 0.2 && t.docsWaitPoll == 0.1)
        #expect(!t.waitsForDocs, "the mutation of the silence gates is never the default")
    }

    @Test func theDiskNumbersAreTheOnesTheDesignDerived() {
        // New pins, 2026-10-20 (ane-disk). One failed preallocation was 2,407,530,496 bytes (2.41 GB, /tmp/ane-root/nospace.log), so a
        // volume under 3 GiB cannot take the next one: [provisional — backlog] until a Mac with a full disk has reported.
        let t = ReaderTiming.standard
        #expect(t.lowDisk == 3 << 30 && t.lowDisk > 2_407_530_496)
        #expect(t.compileRung.schedule(7) == [60, 120, 240, 480, 600, 600, 600] && t.compileRung.healthyWindow == nil)
        #expect(t.compileWindow == 300 && t.diskSampleEvery == 30)
    }

    @Test func aHealthTakesItsLimitsFromTheTiming() {
        var t = ReaderTiming.standard
        t.patience[.doc] = 0.2
        t.stuckAfter = 5
        var h = WorkerHealth(role: .docs, timing: t)
        h.dispatch(WorkerJob(via: .doc, key: "en"), now: 0)
        #expect(h.nextDeadline(now: 0) == 0.2)
        #expect(h.tick(now: 0.2).contains { if case .suspected = $0 { true } else { false } })
        #expect(h.nextDeadline(now: 0.2) == 5, "stuck at stuckAfter from the start of the request")
        var shipped = WorkerHealth(role: .docs)
        shipped.dispatch(WorkerJob(via: .doc, key: "en"), now: 0)
        #expect(shipped.nextDeadline(now: 0) == 2, "S(doc) = 2 s unless a gate says otherwise")
    }

    @Test func aRestartAndARungTakeTheirBackoffFromTheTiming() {
        var t = ReaderTiming.standard
        t.restart = Backoff(base: 0.1, cap: 0.4)
        var h = WorkerHealth(role: .lines, timing: t)
        h.dispatch(WorkerJob(via: .rev3, key: "en"), now: 0)
        h.interrupted(now: 1)
        #expect(h.state == .restarting(until: 1.1))
        var rest = DocsRest(timing: ReaderTiming.standard.applying("docsrest=0.5/2").timing)
        rest.slowAnswer(now: 0)
        #expect(rest.slowAnswer(now: 10) == 0.5, "the first rest of the second consecutive slow answer")
    }

    @Test func theSpecOverridesWhatItNamesAndReportsWhatItDoesNot() {
        let (t, unknown) = ReaderTiming.standard.applying("doc=0.5, rev3=1 ,stuck=30,restart=0.2/2,rung=0.1/0.8,poll=0.05,docs-wait=1")
        #expect(unknown.isEmpty)
        #expect(t.patience(.doc) == 0.5 && t.patience(.rev3) == 1 && t.patience(.rev2) == 3 && t.patience(.fast) == 1)
        #expect(t.stuckAfter == 30 && t.warmingBound == 400)
        #expect(t.restart.schedule(4) == [0.2, 0.4, 0.8, 1.6] && t.restart.healthyWindow == 600, "doubling and the healthy window stay")
        #expect(t.rung.schedule(5) == [0.1, 0.2, 0.4, 0.8, 0.8])
        #expect(t.warmPoll == 0.05 && t.waitsForDocs)

        let nothing = ReaderTiming.standard.applying(nil)
        #expect(nothing.timing == .standard && nothing.unrecognized.isEmpty)

        // A typo changes nothing, and is said.
        let bad = ReaderTiming.standard.applying("dco=1,doc=0,doc=abc,restart=2,restart=2/1,rung=-1/5,stuck,idle=inf")
        #expect(bad.timing == .standard)
        #expect(bad.unrecognized == ["dco=1", "doc=0", "doc=abc", "restart=2", "restart=2/1", "rung=-1/5", "stuck", "idle=inf"])
    }
}
