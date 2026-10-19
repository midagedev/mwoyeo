import Foundation
import Testing
@testable import MwoyeoCore

/// ane-disk (2026-10-20): a Mac short of disk space never gets text recognition ready. Every compile preallocates 2.4 GB of temp
/// space, fails 35-55 s later with `e5rtError("e5rt_e5_compiler_compile call failed", 11)` and caches nothing, so the next request
/// compiles again, for ever, and the lens said "Preparing text recognition" for ever (the client log of 2026-10-19 23:51-23:54: three
/// of these in 3.5 minutes, each answered to the app as an error reply, each read there as Code 13).
///
/// The fakes are the real `MWOYEO_FAKE_READER` grammar (`lines-nospace:<n>`: the first n jobs of the newest model fail after the
/// compile time); the clock is fake; the free space is a value the test sets (`HostWorld.disk`), asked through
/// `ReaderHostCore.freeSpace` like the app does. Shipped numbers (`ReaderTiming.standard`).
@Suite struct ReaderDiskTests {
    private let japanese: [ReadVia] = [.rev3, .rev2]   // no `.fast`: Japanese has nothing that reads without a compile but rev2
    private let gib: UInt64 = 1 << 30

    private func world(_ fakes: String, free: UInt64?, timing: ReaderTiming = .standard) -> (world: HostWorld, lens: HostWorld.Lens) {
        let world = HostWorld(timing: timing, fakes: fakes)
        world.disk.bytes = free
        world.warmUp(key: "ja")
        let lens = world.addLens(plan: ReadPlan(want: .lines, key: "ja", ladder: japanese))
        return (world, lens)
    }

    /// One pass a second, like a pill that keeps asking, up to `end` seconds. What the lens's wait said after each pass.
    @discardableResult
    private func pass(_ world: HostWorld, _ lens: HostWorld.Lens, to end: TimeInterval) -> [(at: TimeInterval, hint: RecognitionWait?)] {
        var said: [(TimeInterval, RecognitionWait?)] = []
        while world.now < end {
            world.advance(by: 1)
            world.ask(lens)
            said.append((world.now, lens.hint))
        }
        return said.map { (at: $0.0, hint: $0.1) }
    }

    private func line(_ hint: RecognitionWait?) -> LensHint? { LensSignals(recognition: hint).hint() }

    // MARK: (a) a full disk: hint, backoff, rev2 meanwhile

    @Test func twoCompileFailuresOnAFullDiskRaiseTheHintAndRestTheRung() {
        // Paper: lines-nospace:40 fails the first 40 newest-model jobs after a 35 s compile. The warm-up asks when the rung's rest ends
        // (95 s, 250 s): failures at 35, 130 and 285 s (the last is past coldWait, so the warm-up step ends failed). With 1 GiB free
        // (< 3 GiB) each rests the rung on Backoff.compileRung: 60, 120, 240 s; the second one raises the hint. Before it the lens only
        // prepares; while a compile runs and nothing else can read (Docs is warmed after Lines), it says the disk.
        let (world, lens) = world("lines-nospace:40", free: gib)
        let said = pass(world, lens, to: 300)
        func hint(at t: TimeInterval) -> RecognitionWait? { said.first { $0.at >= t }?.hint }
        #expect(hint(at: 20) == .preparing, "first compile in flight: the disk is not blamed yet (\(String(describing: hint(at: 20))))")
        #expect(hint(at: 100) == .preparing, "second compile in flight, one failure is no verdict (\(String(describing: hint(at: 100))))")
        #expect(hint(at: 260) == .needsDiskSpace, "third compile in flight after two failures on a full disk (\(String(describing: hint(at: 260))))")
        #expect(line(hint(at: 260)) == .recognitionNeedsDiskSpace)
        #expect(Array(world.rungWaits.prefix(3)) == [60, 120, 240], "rests \(world.rungWaits)")
        #expect(world.waits(containing: "why=nospace").count == 2, "the log names it from the second failure: \(world.waits(containing: "why=nospace").map(\.at))")
        #expect(world.waits(containing: "reader failed role=lines via=rev3 why=compileFailed").count == 1, "only the first is not yet a verdict")
        // While the rung rests, rev2 reads, and the lens has no hint.
        let after = pass(world, lens, to: 500)
        let reads = world.sent.filter { !$0.warm && $0.at > 286 && $0.at < 500 }
        #expect(!reads.isEmpty && reads.allSatisfy { $0.via == .rev2 }, "rev2 reads while the rung rests: \(reads.prefix(6).map { "\($0.via.rawValue)@\(Int($0.at))" })")
        #expect(after.allSatisfy { $0.hint == nil }, "and the lens has no hint while it is read")
        #expect(world.core.health[.lines]!.lacksDiskSpace && (world.core.health[.lines]!.restUntil ?? 0) > 500)
    }

    @Test func theVerdictStaysWhileTheDiskStaysFullAndTheRungIsAskedAgainWhenItsRestEnds() {
        // 285 + 240 = 525 s: the rest ends and the lens asks rev3 again (35 s, failing at 560 s; rest 480 s), and again at 1040 (fails at
        // 1075; rest 600 s, the cap). The failures at 560 and 1075 are 515 s apart, more than the 5-minute window, and the verdict stays:
        // it is the disk's until the disk or an answer ends it. (Docs, warm by now, reads for the lens meanwhile.)
        let (world, lens) = world("lines-nospace:40", free: gib)
        pass(world, lens, to: 1100)
        let again = world.sent.filter { !$0.warm && $0.via == .rev3 }.map(\.at)
        #expect(again.count == 2 && again[0] >= 525 && again[0] < 527 && again[1] >= 1040 && again[1] < 1042, "rev3 asked as each rest ends: \(again)")
        #expect(world.core.health[.lines]!.lacksDiskSpace, "still the disk's after \(world.core.health[.lines]!.lastCompileFailure ?? -1) s")
        #expect(Array(world.rungWaits.prefix(5)) == [60, 120, 240, 480, 600], "the cap is reached: \(world.rungWaits)")
    }

    @Test func theWarmUpWaitsOutTheRungsRestOnAFullDisk() {
        // Paper: lines-nospace:40, 1 GiB free. The warm-up's first Lines step asks at 0 and fails at 35 s; the rung rests 60 s (until 95).
        // The warm-up used to ask again after its own 1 s (36 s), 2 s ... for coldWait: a 2.4 GB preallocation that fails each 35 s. Now
        // it asks when the rest ends: 95 s, fails at 130, rests 120 s, asks at 250, fails at 285 (past coldWait, 180 s from its start):
        // three compiles, not five, and the step ends failed.
        let (world, _) = world("lines-nospace:40", free: gib)
        world.settle()
        let asks = world.sent.filter { $0.warm && $0.role == .lines }.map(\.at)
        #expect(asks.count == 3, "warm-up asks: \(asks)")
        #expect(asks.count > 1 && asks[1] >= 35 + 60, "the second ask waits out the 60 s rest: \(asks)")
        #expect(asks.count > 2 && asks[2] >= asks[1] + 35 + 120, "and the third the 120 s rest: \(asks)")
        #expect(world.waits(containing: "reader warm-up role=lines key=ja failed").count == 1)
    }

    @Test func theWarmUpOfADiskWithRoomAsksAgainAfterItsOwnBackoffAsBefore() {
        // The default path: 20 GiB free. The rung's rest and the warm-up's own wait are the same 1, 2, 4 ... s, so the asks are at 0, 36, 73.
        let (world, _) = world("lines-nospace:40", free: 20 * gib)
        world.settle()
        let asks = world.sent.filter { $0.warm && $0.role == .lines }.map(\.at)
        #expect(asks.count >= 3 && abs(asks[1] - 36) < 0.01 && abs(asks[2] - 73) < 0.01, "warm-up asks: \(asks)")
    }

    // MARK: (b) room on the disk: ordinary backoff, no cause invented

    @Test func compileFailuresWithRoomOnTheDiskDoNotRaiseTheHint() {
        // Paper: the same two failures, 20 GiB free: Backoff.rev3Rung rests (1, 2, 4, 8, 16 s), no hint beyond "preparing".
        let (world, lens) = world("lines-nospace:40", free: 20 * gib)
        let said = pass(world, lens, to: 200)
        #expect(said.allSatisfy { $0.hint != .needsDiskSpace }, "the hint never rises")
        #expect(Array(world.rungWaits.prefix(5)) == [1, 2, 4, 8, 16], "ordinary rests \(world.rungWaits)")
        #expect(world.waits(containing: "nospace").isEmpty)
        #expect(!world.core.health[.lines]!.lacksDiskSpace)
    }

    @Test func aDiskThatCannotBeReadIsNotBlamed() {
        let (world, lens) = world("lines-nospace:40", free: nil)
        let said = pass(world, lens, to: 120)
        #expect(said.allSatisfy { $0.hint != .needsDiskSpace })
        #expect(Array(world.rungWaits.prefix(3)) == [1, 2, 4])
    }

    // MARK: (c) space comes back

    @Test func freeSpaceComingBackEndsTheRestAndAsksTheRungAtOnce() {
        // Paper: lines-nospace:3 is the warm-up's three failures (35, 130, 285 s); the next newest-model job compiles. At 285 s the rung
        // rests 240 s (until 525) and rev2 reads. The user frees space at 400 s: the next sample (every 30 s, at a pass: 420 s) sees
        // 20 GiB, the rest ends then, "usable again" is announced, and the lens's pass asks rev3, which answers. Nothing waits for 525.
        let (world, lens) = world("lines-nospace:3", free: gib)
        pass(world, lens, to: 400)
        #expect(world.core.health[.lines]!.lacksDiskSpace)
        #expect((world.core.health[.lines]!.restUntil ?? 0) > 500, "resting until about 525: \(String(describing: world.core.health[.lines]!.restUntil))")
        world.disk.bytes = 20 * gib
        let said = pass(world, lens, to: 450)
        let rev3 = world.sent.filter { !$0.warm && $0.via == .rev3 && $0.at > 400 }
        #expect(rev3.first.map { $0.at < 435 } ?? false, "rev3 asked again within a sample of the space coming back: \(rev3.map(\.at))")
        #expect(!world.core.health[.lines]!.lacksDiskSpace, "the verdict is gone")
        #expect(said.allSatisfy { $0.hint == nil }, "and the lens has no hint")
        #expect(world.core.health[.lines]!.isWarm(.rev3, key: "ja"), "rev3 answered, so the rest and the failures are forgotten")
        #expect(world.core.health[.lines]!.restUntil == nil && world.core.health[.lines]!.lastCompileFailure == nil)
    }

    // MARK: (d) a slow compile is not a full disk

    @Test func aSlowColdCompileNeverRaisesTheDiskHint() {
        // lines-slow:60000: the cold compile takes 60 s and then reads. 1 GiB free changes nothing: no error came back, so there is
        // no failure to blame (a slow compile returns nothing until it ends).
        let (world, lens) = world("lines-slow:60000", free: gib)
        let said = pass(world, lens, to: 90)
        #expect(said.contains { $0.at < 55 && $0.hint == .preparing }, "preparing while it compiles")
        #expect(said.allSatisfy { $0.hint != .needsDiskSpace })
        #expect(world.rungWaits.isEmpty && !world.core.health[.lines]!.lacksDiskSpace)
        #expect(world.core.health[.lines]!.isWarm(.rev3, key: "ja"))
    }

    // MARK: The sample

    @Test func theFreeSpaceIsAskedAtMostOncePerThirtySeconds() {
        // One pass a second for 100 s on a world that keeps replying: the asks are at the first decision (0 s) and then no sooner than
        // 30 s apart: at most 1 + 100 / 30 = 4.
        let (world, lens) = world("", free: 20 * gib)
        pass(world, lens, to: 100)
        #expect(world.disk.asks >= 3 && world.disk.asks <= 4, "asked \(world.disk.asks) times in 100 s")
    }

    // MARK: The health alone

    private func fail(_ h: inout WorkerHealth, _ via: ReadVia = .rev3, at t: TimeInterval, started: TimeInterval? = nil) -> [WorkerHealth.Event] {
        h.dispatch(WorkerJob(via: via, key: "ja"), now: started ?? t - 35)
        return h.reply(.compileFailed, now: t)
    }

    @Test func aCompileFailureRestsTheRungOnTheCompileBackoffOnlyWhileTheVolumeIsShort() {
        var full = WorkerHealth(role: .lines)
        full.sampledDisk(gib, now: 0)
        #expect(fail(&full, at: 35).contains(.rungResting(.rev3, for: 60)) && !full.lacksDiskSpace, "one failure: the rung rests, no verdict")
        #expect(fail(&full, at: 71).contains(.rungResting(.rev3, for: 120)) && full.lacksDiskSpace, "two within the window: the disk")
        var roomy = WorkerHealth(role: .lines)
        roomy.sampledDisk(20 * gib, now: 0)
        #expect(fail(&roomy, at: 35).contains(.rungResting(.rev3, for: 1)), "with room it is the ordinary rung")
        #expect(fail(&roomy, at: 71).contains(.rungResting(.rev3, for: 2)) && !roomy.lacksDiskSpace)
        var unknown = WorkerHealth(role: .lines)
        _ = fail(&unknown, at: 35)
        #expect(fail(&unknown, at: 71).contains(.rungResting(.rev3, for: 2)) && !unknown.lacksDiskSpace, "free space never read: no cause invented")
    }

    @Test func theTwoFailuresMustComeWithinTheWindow() {
        let window = ReaderTiming.standard.compileWindow
        var near = WorkerHealth(role: .lines), far = WorkerHealth(role: .lines)
        near.sampledDisk(gib, now: 0)
        far.sampledDisk(gib, now: 0)
        _ = fail(&near, at: 100); _ = fail(&near, at: 100 + window - 1)
        _ = fail(&far, at: 100); _ = fail(&far, at: 100 + window)
        #expect(near.lacksDiskSpace, "\(window - 1) s apart")
        #expect(!far.lacksDiskSpace, "\(window) s apart is not within the window")
        #expect(near.compileFailuresInWindow == 2 && far.compileFailuresInWindow == 1 && far.lastCompileFailure == 100 + window)
    }

    @Test func aDocsCompileFailureRestsNothing() {
        // Only the newest Lines model has a rung; a failed document read already goes on as lines + grouper.
        var docs = WorkerHealth(role: .docs)
        docs.sampledDisk(gib, now: 0)
        let events = fail(&docs, .doc, at: 35)
        #expect(!events.contains { if case .rungResting = $0 { true } else { false } } && docs.restUntil == nil)
        #expect(docs.stats.failed[.doc] == 1 && docs.lastCompileFailure == 35)
    }

    @Test func freeSpaceBackEndsTheRestAndTheVerdictAtOnce() {
        var h = WorkerHealth(role: .lines)
        h.sampledDisk(gib, now: 0)
        _ = fail(&h, at: 35); _ = fail(&h, at: 71)
        #expect(h.isResting(.rev3, now: 100) && h.lacksDiskSpace)
        h.sampledDisk(nil, now: 100)
        #expect(h.isResting(.rev3, now: 100) && h.lacksDiskSpace && h.freeBytes == gib, "a sample that cannot be read changes nothing")
        h.sampledDisk(20 * gib, now: 100)
        #expect(!h.isResting(.rev3, now: 100) && !h.lacksDiskSpace && h.freeBytes == 20 * gib)
        #expect(h.tick(now: 100).contains(.usableAgain), "the lenses that waited are told, as at the end of any rest")
        #expect(h.compileFailuresInWindow == 0)
        // The backoff starts over: the next failure with a full disk again is a first one.
        h.sampledDisk(gib, now: 120)
        #expect(fail(&h, at: 200).contains(.rungResting(.rev3, for: 60)) && !h.lacksDiskSpace)
    }

    @Test func aNewestModelAnswerOrANewProcessEndsTheVerdict() {
        var answered = WorkerHealth(role: .lines), restarted = WorkerHealth(role: .lines)
        for index in 0..<2 {
            var h = index == 0 ? answered : restarted
            h.sampledDisk(gib, now: 0)
            _ = fail(&h, at: 35); _ = fail(&h, at: 71)
            #expect(h.lacksDiskSpace)
            if index == 0 {
                h.dispatch(WorkerJob(via: .rev3, key: "ja"), now: 80)
                h.reply(.answered, now: 81)
                answered = h
            } else {
                h.dispatch(WorkerJob(via: .rev3, key: "ja"), now: 80)
                h.interrupted(now: 81)
                restarted = h
            }
        }
        #expect(!answered.lacksDiskSpace && answered.restUntil == nil && answered.lastCompileFailure == nil, "a rev3 answer")
        #expect(!restarted.lacksDiskSpace && restarted.restUntil == nil, "a process that starts from nothing")
    }

    // MARK: Which wait the lens is told

    @Test func theDiskIsNamedAheadOfStuckAndPreparing() {
        func health(compileFailures: Bool) -> WorkerHealth {
            var h = WorkerHealth(role: .lines)
            h.sampledDisk(gib, now: 0)
            if compileFailures { _ = fail(&h, at: 35); _ = fail(&h, at: 71) }
            h.dispatch(WorkerJob(via: .rev3, key: "ja"), now: 80)
            return h
        }
        let blamed = health(compileFailures: true), plain = health(compileFailures: false)
        #expect(ReadRouter.unavailableReason(lines: blamed, now: 90) == .needsDiskSpace, "a compile in flight, suspect")
        #expect(ReadRouter.unavailableReason(lines: plain, now: 90) == .preparing)
        #expect(blamed.effectiveState(now: 400).name == "stuck" && plain.effectiveState(now: 400).name == "stuck")
        #expect(ReadRouter.unavailableReason(lines: blamed, now: 400) == .needsDiskSpace, "stuck, and the disk is its cause")
        #expect(ReadRouter.unavailableReason(lines: plain, now: 400) == .notResponding)
    }
}
