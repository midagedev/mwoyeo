import Foundation
import Testing
@testable import MwoyeoCore

/// g2-fast-host-gates (2026-10-19): the gates of the reader host that were shell runs of minutes (tools/ocr-probe/host-gates.sh g1-g4:
/// a service that really slept 40 s, a rung that really rested 61 s) as unit tests on a fake clock. Same fakes, same spec strings
/// (`MWOYEO_FAKE_READER`), same shipped durations (`ReaderTiming.standard`); the clock jumps, so each test runs in milliseconds.
/// What stays in the shell: a real service that dies and is started again (`host-gates.sh`, scaled-down durations).
@Suite struct ReaderHostTests {
    private let english: [ReadVia] = [.rev3, .rev2, .fast]

    /// A world whose services are warm for `key`: warm-up runs to its end (Lines, then Docs), `fakes` applied to the warm-up too.
    private func warmWorld(fakes: String, key: String = "en", timing: ReaderTiming = .standard) -> HostWorld {
        let world = HostWorld(timing: timing, fakes: fakes)
        world.warmUp(key: key)
        world.settle()
        return world
    }

    private func layoutLens(_ world: HostWorld, key: String = "en") -> HostWorld.Lens {
        world.addLens(plan: ReadPlan(want: .layout, layoutWanted: true, key: key, ladder: english))
    }

    // MARK: g1: patience S, then a reroute; the slow request runs on

    /// The seconds a lens that wants the document layout is silent when Docs takes 40 s for every job (`docs-slow:40000`), on a
    /// Docs that is warm for the key. The instrument of g1 and of its FAIL-first.
    private func silenceOnSlowDocs(timing: ReaderTiming) -> (silence: TimeInterval, world: HostWorld, lens: HostWorld.Lens) {
        let world = warmWorld(fakes: "docs-slow:40000", timing: timing)
        #expect(world.core.isReady(now: world.now), "the warm-up ended: both workers warm for the key and idle")
        let lens = layoutLens(world)
        world.ask(lens)
        world.advance(by: 41)       // Docs' slow answer comes at 40.4 s; its re-read has not turned suspect (2 s) yet
        return (lens.passes[0].silence ?? .infinity, world, lens)
    }

    @Test func aSlowDocsIsWaitedForSecondsThenTheReadGoesToLines() {
        // Paper: Docs warm, so the layout read is sent to Docs at t0. WorkerHealth turns it suspect at S(doc) = 2 s, the pass is
        // routed again without it (Lines is warm for rev3: dispatch) and Lines answers in its warm 0.3 s: the lens has lines at
        // 2 + 0.3 = 2.3 s. Docs answers at 40.4 s (40 s fake + 0.4 s warm read) and is a late result.
        let (silence, world, lens) = silenceOnSlowDocs(timing: .standard)
        #expect(abs(silence - 2.3) < 0.05, "silence \(silence) s, expected 2.3")
        #expect(silence <= 8, "the lens is never silent for more than N = 8 s (host-gates g1: longest <= 8000 ms)")
        #expect(lens.passes[0].verdict == .answer(via: .rev3), "the stand-in is Lines + the grouper")
        #expect(world.counted["reader.reroute.docs.lines"] == 1, "reader.reroute.docs.lines")
        // The slow request is never cancelled or killed: it ends in an answer, never a failure, a stuck recycle or a crash.
        // The late answer started the re-read of the lens that stood in: Docs is busy with it (idle if nobody asked again).
        let docs = world.core.health[.docs]!
        #expect(["idle", "busy"].contains(world.state(.docs).name), "docs state=\(world.state(.docs).name)")
        #expect(docs.stats.failed.values.reduce(0, +) == 0 && docs.stats.stuck == 0 && docs.stats.crashes == 0)
        #expect(docs.stats.answered[.doc, default: 0] >= 2, "the warm-up and the slow read both answered")
        #expect(docs.stats.suspects == 1 && world.core.counts.late == 1, "the slow answer came, and was a late result")
        #expect(world.waits(containing: "reader answered role=docs via=doc ms=40400").count >= 1, "the Docs request ran its 40.4 s")
        #expect(world.core.counts.rereads == 1, "the lens that stood in reads again once Docs answered")
    }

    @Test func waitingForDocsHoweverLongFailsTheSilenceAssertion() {
        // FAIL-first of the test above (host-gates g1m, MWOYEO_DOCS_WAIT=1): the same instrument sees 40.4 s when the pass waits for
        // Docs as the in-process path did. A silence assertion that this does not break measures nothing.
        var mutated = ReaderTiming.standard
        mutated.waitsForDocs = true
        let (silence, world, _) = silenceOnSlowDocs(timing: mutated)
        #expect(silence >= 38, "silence \(silence) s under docs-wait=1")
        #expect(world.counted["reader.reroute.docs.lines"] == nil, "no reroute under the mutation")
    }

    @Test func theDurationsAreInjected() {
        // The same scenario with S(doc) = 0.2 s: the reroute comes at 0.2 + 0.3, not 2 + 0.3.
        let timing = ReaderTiming.standard.applying("doc=0.2").timing
        let (silence, _, _) = silenceOnSlowDocs(timing: timing)
        #expect(abs(silence - 0.5) < 0.05, "silence \(silence) s, expected 0.5")
    }

    @Test func aDocsThatKeepsAnsweringLateRestsBeforeEachNextRequest() {
        // Docs answers every request at 40.4 s. The first slow answer is one episode: the lens reads again at once; each consecutive
        // slow answer rests Docs 1, 2, 4 ... s (`DocsRest`) before the lens reads again, so Docs is not asked by every re-read.
        let world = warmWorld(fakes: "docs-slow:40000")
        let lens = layoutLens(world)
        world.ask(lens)
        world.advance(by: 40.4 * 4)
        let docsReads = world.sent.filter { $0.role == .docs && $0.via == .doc && !$0.warm }
        #expect(docsReads.count >= 4)
        let gaps = zip(docsReads.dropFirst(), docsReads).map { ($0.at - $1.at).rounded() }
        // 40.4 s of Docs' answer, then the rest (0, 1, 2 s) after it: the lens reads again 40.4, 41.4, 42.4 after the previous.
        #expect(Array(gaps.prefix(3)) == [40, 41, 42], "gaps between Docs requests: \(gaps)")
    }

    // MARK: g2: a reader that is warming says so at S, and nothing reads again by itself

    @Test func aLinesThatTakes40sForJapaneseSaysPreparingAtSAndReadsAgainOnlyWhenReady() {
        // Paper: ja has no `.fast`, Docs is cold, so Lines (cold, rev3's home) takes the read at t = 0. It is suspect at S(rev3) =
        // 3 s: the router has no other reader, the pass gets `.unavailable(.preparing)` at 3.0 s and the hint is up. Nothing reads
        // again on a timer: one read in 37 s. Lines answers at 40.3 s: readerReady, and the lens reads exactly once more.
        let world = HostWorld(fakes: "lines-slow:40000")
        let lens = world.addLens(plan: ReadPlan(want: .lines, layoutWanted: true, key: "ja", ladder: [.rev3, .rev2]))
        world.ask(lens)
        world.advance(to: 2.9)
        #expect(lens.hint == nil && lens.passes[0].verdict == nil, "within S the lens is reading")
        world.advance(to: 3.1)
        #expect(lens.hint == .preparing, "hint: preparingRecognition")
        #expect(abs((lens.passes[0].silence ?? .infinity) - 3.0) < 0.05 && (lens.passes[0].silence ?? .infinity) <= 3.5)
        #expect(lens.passes[0].verdict == .unavailable(.preparing))
        world.advance(to: 39.9)
        #expect(world.core.counts.reads == 1 && lens.passes.count == 1, "no read on a timer while the reader prepares")
        #expect(world.sent.count == 1 && world.counted["reader.unavailable.preparing"] == 1)
        #expect(world.waits(containing: "timeout").isEmpty && world.waits(containing: "Timeout").isEmpty)
        world.advance(to: 40.5)
        #expect(lens.passes.count == 2, "readerReady: the lens reads again, once")
        #expect(world.core.counts.rereads == 1)
        #expect(abs(lens.passes[1].started - 40.3) < 0.05, "at the answer of the slow request, \(lens.passes[1].started)")
    }

    @Test func aLinesThatIsWarmingForJapaneseSaysPreparingAtOnceAndReadsAgainOnlyWhenReady() {
        // The shell g2 as it really ran (hint at 105 ms): the app warms Lines for the key at launch, and the warm-up job takes 40 s
        // (lines-slow:40000 + 0.6 s). A pass that meets the warming worker has no other reader for ja: `.unavailable(.preparing)` at
        // t = 0, no read on a timer in 40 s, and exactly one more read when the warm-up answers (readerReady, 40.6 s).
        let world = HostWorld(fakes: "lines-slow:40000")
        world.warmUp(key: "ja")
        let lens = world.addLens(plan: ReadPlan(want: .lines, layoutWanted: true, key: "ja", ladder: [.rev3, .rev2]))
        world.ask(lens)
        #expect(lens.hint == .preparing && lens.passes[0].verdict == .unavailable(.preparing), "hint: preparingRecognition")
        #expect((lens.passes[0].silence ?? .infinity) <= 3.5, "at \(lens.passes[0].silence ?? -1) s")
        world.advance(to: 40.5)
        #expect(world.core.counts.reads == 1 && lens.passes.count == 1, "no read on a timer while Lines prepares")
        #expect(world.waits(containing: "imeout").isEmpty)
        world.advance(to: 40.7)
        #expect(lens.passes.count == 2 && world.core.counts.rereads == 1, "the warm-up answered: the lens reads again, once")
        #expect(abs(lens.passes[1].started - 40.6) < 0.05, "at \(lens.passes[1].started)")
    }

    // MARK: g3: the rung rests 1, 2, 4, 8, 16, 30 s, and no minute sees more than 6 errors

    @Test func theRevThreeRungRestsOnTheBackoffAndTheLensIsFilledMeanwhile() {
        // Paper: lines-e5rt:40 fails the first 40 jobs of rev3 (warm-up included) with Code 13 in 12 ms. The warm-up asks again
        // after Backoff.rev3Rung (1, 2, 4, 8, 16, 30, 30 ... s, for at most 180 s), failing at 0, 1, 3, 7, 15, 31, 61 ... s; the
        // health's rung rests the same waits, so a lens read never meets rev3 before the rest ends and is served by `.fast` (Docs,
        // while the warm-up job is in flight) or rev2. At most 6 failures in the first minute, then one per 30 s.
        let world = HostWorld(fakes: "lines-e5rt:40")
        world.warmUp(key: "en")
        let lens = world.addLens(plan: ReadPlan(want: .lines, layoutWanted: true, key: "en", ladder: english))
        for _ in 0..<400 {
            world.ask(lens)
            world.advance(by: 1)
        }
        #expect(Array(world.rungWaits.prefix(6)) == [1, 2, 4, 8, 16, 30], "logged rung waits \(world.rungWaits.prefix(8))")
        #expect(world.worstCode13() <= 6, "worst 60 s window: \(world.worstCode13()) Code-13 errors (56 a minute before 1.1.2)")
        #expect(lens.passes.allSatisfy { if case .answer? = $0.verdict { true } else { false } }, "every pass was served")
        #expect(lens.passes.allSatisfy { ($0.silence ?? .infinity) < 1 }, "and quickly: rev2 or .fast filled the lens")
        #expect(world.core.health[.lines]!.stats.crashes == 0)
    }

    // MARK: g4: a service that dies is restarted after the backoff and usable again

    @Test func aServiceThatDiesOnItsFirstJobIsRestartedAfterTheBackoff() {
        // Paper: the Lines service exits on the lens's first read (t = 0). The connection is interrupted at 5 ms: Lines is
        // `restarting` until 5 ms + Backoff.workerRestart (1 s), the read goes to Docs `.fast` (0.1 s) and the lens has its blocks
        // at 0.105 s. At 1.005 s the restart ends: "reader usable again role=lines", one crash counted.
        let world = HostWorld(fakes: "crash")
        let lens = world.addLens(plan: ReadPlan(want: .lines, layoutWanted: true, key: "en", ladder: english))
        world.ask(lens)
        world.advance(to: 0.5)
        #expect(lens.passes[0].verdict == .answer(via: .fast), "the render completes with blocks > 0 (Docs' .fast reads meanwhile)")
        #expect((lens.passes[0].silence ?? .infinity) < 0.2)
        #expect(world.state(.lines).name == "restarting")
        world.advance(to: 3)
        #expect(world.core.health[.lines]!.stats.crashes == 1 && world.counted["reader.lines.crash"] == 1, "one crash is counted")
        let usable = world.waits(containing: "reader usable again role=lines")
        #expect(usable.count == 1 && abs((usable.first?.at ?? 0) - 1.005) < 0.01, "usable again at \(usable.first?.at ?? -1)")
        #expect(world.state(.lines).name == "cold", "ready for the next job; launchd starts the service with it")
    }

    @Test func aWarmUpThatLostItsServiceAsksAgainAfterTheRestart() {
        // crash:lines on the warm-up's first job: the warm-up sees the service lost, polls the restart (0.2 s) and sends the job
        // again once the worker is usable (1.005 s; the poll finds it at 1.006). launchd starts the service again in 10 s, so Lines
        // answers at 11.6 and Docs follows. The restart queued the plan again, but both workers are warm by then: no more jobs.
        let world = HostWorld(fakes: "crash:lines")
        world.warmUp(key: "en")
        world.settle()
        let warms = world.sent.filter(\.warm).map { "\($0.role.rawValue)@\(Int($0.at))" }
        #expect(warms == ["lines@0", "lines@1", "docs@11"], "warm-up jobs: \(warms)")
        #expect(world.core.isReady(now: world.now), "Lines and Docs warm for the key and idle again")
        #expect(world.core.health[.lines]!.stats.crashes == 1)
        let again = world.sent.filter { $0.warm && $0.role == .lines }
        #expect(again.count == 2 && again[1].at >= 1.0 && again[1].at < 1.3, "the second Lines job went at \(again.count > 1 ? again[1].at : -1)")
        let planned = world.effects.filter { if case .setup(.started) = $0.effect { true } else { false } }.count
        #expect(planned == 4, "the plan ran again for the key (Lines and Docs steps, twice): \(planned)")
    }

    @Test func aServiceThatDiesIdleLosesWhatWasWarmAndWarmsItAgainAfterItsBackoff() {
        // Both workers are warm at 12.2 s. Lines dies idle at T: its warm set is gone, the restart ends at T + 1 s, and the plan runs
        // again for the key: Lines is asked to warm (launchd starts it in 10 s, the job takes 0.6 s), Docs kept what it had.
        let world = warmWorld(fakes: "")
        let before = world.sent.filter(\.warm).count
        let died = world.now
        world.kill(.lines)
        world.advance(by: 0.5)
        #expect(!world.core.health[.lines]!.isWarm(.rev3, key: "en") && world.state(.lines).name == "restarting")
        #expect(!world.core.isReady(now: world.now))
        world.advance(by: 30)
        let usable = world.waits(containing: "reader usable again role=lines")
        #expect(usable.count == 1 && abs((usable[0].at - died) - 1.0) < 0.01, "usable again after Backoff.workerRestart")
        let jobs = world.sent.filter(\.warm).dropFirst(before)
        #expect(jobs.map(\.role) == [.lines], "only what was lost is warmed again: \(jobs.map(\.role))")
        #expect(abs((jobs.first?.at ?? 0) - (died + 1.0)) < 0.01)
        #expect(world.core.isReady(now: world.now) && world.core.health[.lines]!.isWarm(.rev3, key: "en"))
        #expect(world.core.health[.lines]!.stats.crashes == 1)
    }

    // MARK: A read that no worker can take waits, whoever asks

    @Test func aLensPassesWithDocsWaitUnsetNeverPollsForDocs() {
        // The mutation (`waitsForDocs`) is the only thing that makes a pass wait for Docs; shipped, it never does.
        var shipped = ReaderHostCore()
        let layout = ReadPlan(want: .layout, layoutWanted: true, key: "en", ladder: english)
        let shippedWaits = shipped.mustWaitForDocs(layout, now: 0)
        #expect(!shippedWaits)
        var mutated = ReaderTiming.standard
        mutated.waitsForDocs = true
        var core = ReaderHostCore(timing: mutated)
        let coldDocsWaits = core.mustWaitForDocs(layout, now: 0)
        let linesWaits = core.mustWaitForDocs(ReadPlan(want: .lines, key: "en", ladder: [.rev3]), now: 0)
        #expect(coldDocsWaits, "Docs is cold for the key: the mutated pass waits")
        #expect(!linesWaits, "only a layout read waits")
    }

    // MARK: What the stats and the ring show of the reads

    @Test func lowConfidenceLinesAreCountedAndTheRingSaysSo() {
        let world = warmWorld(fakes: "")
        world.lowConfidence = 3
        world.ask(layoutLens(world))
        world.settle()
        #expect(world.core.counts.lowConfidence == 3, "the answer's count is the host's")
        #expect(world.core.ring.contains { $0.contains(" ok ") && $0.hasSuffix(" low=3") }, "\(world.core.ring)")
        world.lowConfidence = 0
        world.ask(layoutLens(world))
        world.settle()
        #expect(world.core.counts.lowConfidence == 3, "an answer with none adds none")
    }
}
