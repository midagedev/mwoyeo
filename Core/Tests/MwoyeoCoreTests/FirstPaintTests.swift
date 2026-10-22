import Foundation
import Testing
@testable import MwoyeoCore

/// fast117 (docs/design/first-lens.md §13): the quick first paint of a lens's first batch and the high-fidelity text that replaces it. No test waits on a
/// clock: the runners are held by gates the test opens, and the book is given its time.
@Suite struct FirstPaintTests {
    // MARK: Plan

    @Test func planIsProvisionalOnlyWhenEveryConditionHolds() {
        for flag in [false, true] {
            for asked in [false, true] {
                for hf in [false, true] {
                    for quick in [false, true] {
                        let plan = FirstPaintPlan.decide(flag: flag, asked: asked, finalIsHighFidelity: hf, quickInstalled: quick)
                        let all = flag && asked && hf && quick
                        #expect(plan == (all ? .provisionalThenFinal : .finalOnly), "flag \(flag) asked \(asked) hf \(hf) quick \(quick)")
                    }
                }
            }
        }
    }

    @Test func aGroupAsksTheSystemForThePackOnlyWhenTheRestHolds() {
        for flag in [false, true] {
            for asked in [false, true] {
                for hf in [false, true] {
                    #expect(FirstPaintPlan.wants(flag: flag, asked: asked, finalIsHighFidelity: hf) == (flag && asked && hf))
                }
            }
        }
    }

    // MARK: Book

    @Test func aQuickTextIsShownUntilTheFinalOneLands() {
        var book = FirstPaintBook()
        #expect(book.shown(for: "Hello") == nil)
        #expect(book.offer("안녕", for: "Hello", at: 0.5) == "안녕")
        #expect(book.shown(for: "Hello") == "안녕")
        #expect(book.settle("안녕하세요", for: "Hello", at: 8) == .repaint)
        #expect(book.shown(for: "Hello") == nil)
        #expect(book.lines["Hello"]?.shownFor == 7.5)
    }

    @Test func aFinalTextEqualToTheShownOneIsNotRepainted() {
        var book = FirstPaintBook()
        _ = book.offer("안녕", for: "Hello", at: 1)
        #expect(book.settle("안녕", for: "Hello", at: 3) == .keep)
        #expect(book.stats.kept == 1 && book.stats.repainted == 0 && book.stats.charsChanged == 0)
    }

    @Test func aQuickTextThatLandsAfterTheFinalOneIsDropped() {
        var book = FirstPaintBook()
        #expect(book.settle("안녕하세요", for: "Hello", at: 2) == .repaint)
        #expect(book.offer("안녕", for: "Hello", at: 2.1) == nil)
        #expect(book.shown(for: "Hello") == nil)
        #expect(book.stats.painted == 0)
    }

    @Test func aQuickTextThatSaysNothingIsNotPainted() {
        var book = FirstPaintBook()
        #expect(book.offer("", for: "Hello", at: 0) == nil)
        #expect(book.offer("Hello", for: "Hello", at: 0) == nil)
        #expect(book.shown(for: "Hello") == nil)
        #expect(book.offer("안녕", for: "Hello", at: 0) == "안녕")
        #expect(book.offer("안녕", for: "Hello", at: 0.1) == nil)
        // The same source is painted once: its time is the first paint's.
        #expect(book.offer("안녕!", for: "Hello", at: 0.2) == "안녕!")
        #expect(book.lines["Hello"]?.paintedAt == 0)
    }

    @Test func theStatsCountWhatWasPaintedChangedAndKept() {
        var book = FirstPaintBook()
        _ = book.offer("안녕", for: "a", at: 0)
        _ = book.offer("좋은 아침", for: "b", at: 0)
        _ = book.offer("또 만나요", for: "c", at: 0)
        _ = book.settle("안녕하세요", for: "a", at: 5)       // 3 characters added
        _ = book.settle("좋은 아침", for: "b", at: 6)
        let s = book.stats
        #expect(s.painted == 3 && s.repainted == 1 && s.kept == 1 && s.open == 1)
        #expect(s.charsChanged == 3 && s.charsFinal == 5)
        #expect(s.shownFor == [5, 6] || s.shownFor == [6, 5])
    }

    @Test func theEditDistanceCountsInsertDeleteAndReplace() {
        #expect(FirstPaintBook.distance("", "") == 0)
        #expect(FirstPaintBook.distance("안녕", "") == 2)
        #expect(FirstPaintBook.distance("안녕", "안녕") == 0)
        #expect(FirstPaintBook.distance("안녕", "안녕하세요") == 3)
        #expect(FirstPaintBook.distance("kitten", "sitting") == 3)
    }

    // MARK: Run

    /// Gives the scheduler up to 20,000 turns to make `condition` true (a bounded wait on events, never on a clock): a broken run fails the test and does not hang it.
    private func until(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<20_000 {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    /// Lets a runner wait for the test.
    private actor Gate {
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if open { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func release() {
            open = true
            for w in waiting { w.resume() }
            waiting = []
        }
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [String] = []
        func add(_ s: String) { lock.withLock { all.append(s) } }
        var lines: [String] { lock.withLock { all } }
    }

    /// A clock the test moves.
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t: TimeInterval = 0
        var now: TimeInterval { lock.withLock { t } }
        func set(_ v: TimeInterval) { lock.withLock { t = v } }
    }

    /// A runner that answers `answers` when its gate opens, telling its sink one by one; it records its start and end in the log.
    private func runner(_ name: String, gate: Gate, answers: [String: String], log: Log) -> FirstPaint.Runner {
        { items, sink in
            log.add("\(name) start")
            await gate.wait()
            try Task.checkCancellation()
            var out: [String: String] = [:]
            for s in items {
                guard let t = answers[s] else { continue }
                out[s] = t
                sink(s, t)
            }
            log.add("\(name) end")
            return out
        }
    }

    @Test func theFinalTextsAreTheAnswerAndTheQuickOnesOnlyReachTheProvisionalSink() async throws {
        let log = Log(), gq = Gate(), gf = Gate()
        let items = ["Hello", "World"]
        let quick = runner("quick", gate: gq, answers: ["Hello": "안녕", "World": "세계"], log: log)
        let final = runner("final", gate: gf, answers: ["Hello": "안녕하세요", "World": "세계"], log: log)
        let clock = Clock()
        let painted = Log(), landed = Log()
        let book = BookBox()
        let run = Task {
            try await FirstPaint.run(items: items, quick: quick, final: final,
                                     provisional: { s, t in if let p = book.offer(t, for: s, at: clock.now) { painted.add("\(s)=\(p)") } },
                                     onFinal: { s, t in landed.add("\(s)=\(t)"); _ = book.settle(t, for: s, at: clock.now) })
        }
        clock.set(0.5)
        await gq.release()
        guard await until({ painted.lines.count == 2 }) else { Issue.record("the quick texts were not painted"); run.cancel(); return }
        clock.set(7.0)
        await gf.release()
        let answer = try await run.value
        #expect(answer == ["Hello": "안녕하세요", "World": "세계"])
        #expect(Set(painted.lines) == ["Hello=안녕", "World=세계"])
        #expect(landed.lines == ["Hello=안녕하세요", "World=세계"])
        // What anything keeps (cache, log, credit) is `answer` and the final sink: the quick texts are in neither.
        #expect(!answer.values.contains("안녕") && !landed.lines.contains { $0.hasSuffix("=안녕") })
        let stats = book.stats
        #expect(stats.painted == 2 && stats.repainted == 1 && stats.kept == 1 && stats.shownFor.sorted() == [6.5, 6.5])
        #expect(stats.charsChanged == 3)
    }

    /// Reference box for the book, shared by the sinks of one run.
    private final class BookBox: @unchecked Sendable {
        private let lock = NSLock()
        private var book = FirstPaintBook()
        func offer(_ text: String, for source: String, at now: TimeInterval) -> String? { lock.withLock { book.offer(text, for: source, at: now) } }
        func settle(_ text: String, for source: String, at now: TimeInterval) -> FirstPaintBook.Settled { lock.withLock { book.settle(text, for: source, at: now) } }
        var stats: FirstPaintBook.Stats { lock.withLock { book.stats } }
        func shown(for source: String) -> String? { lock.withLock { book.shown(for: source) } }
    }

    @Test func inParallelTheFinalModelStartsWithoutWaitingForTheQuickOne() async throws {
        let log = Log(), gq = Gate(), gf = Gate()
        let quick = runner("quick", gate: gq, answers: ["a": "A"], log: log)
        let final = runner("final", gate: gf, answers: ["a": "AA"], log: log)
        let run = Task { try await FirstPaint.run(items: ["a"], quick: quick, final: final, provisional: { _, _ in }, onFinal: { _, _ in }) }
        guard await until({ Set(log.lines) == ["quick start", "final start"] }) else { Issue.record("the final model did not start beside the quick one"); run.cancel(); return }
        await gf.release()
        await gq.release()
        #expect(try await run.value == ["a": "AA"])
    }

    @Test func aQuickFailureCostsTheFirstPaintOnly() async throws {
        struct Boom: Error {}
        let log = Log(), gf = Gate()
        await gf.release()
        let final = runner("final", gate: gf, answers: ["a": "AA"], log: log)
        let painted = Log()
        let answer = try await FirstPaint.run(items: ["a"], quick: { _, _ in throw Boom() }, final: final,
                                              provisional: { s, t in painted.add("\(s)=\(t)") }, onFinal: { _, _ in })
        #expect(answer == ["a": "AA"] && painted.lines.isEmpty)
    }

    @Test func aFinalFailureIsThrownAsItWouldBeAlone() async {
        struct Boom: Error, Equatable {}
        let log = Log(), gq = Gate()
        await gq.release()
        let quick = runner("quick", gate: gq, answers: ["a": "A"], log: log)
        let painted = Log()
        var thrown: Boom?
        do {
            _ = try await FirstPaint.run(items: ["a"], quick: quick, final: { _, _ in throw Boom() },
                                         provisional: { s, t in painted.add("\(s)=\(t)") }, onFinal: { _, _ in })
        } catch { thrown = error as? Boom }
        #expect(thrown == Boom())
    }

    @Test func theQuickModelIsCancelledWhenTheFinalOneIsDone() async throws {
        let ended = Log(), gf = Gate()
        await gf.release()
        let final = runner("final", gate: gf, answers: ["a": "AA"], log: Log())
        let started = Gate()
        let quick: FirstPaint.Runner = { _, _ in
            await started.release()
            // Held until the run cancels it: the sleep ends on cancellation, not on its time.
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(3600))
            } onCancel: { ended.add("cancelled") }
            return [:]
        }
        let run = Task { try await FirstPaint.run(items: ["a"], quick: quick, final: final, provisional: { _, _ in }, onFinal: { _, _ in }) }
        let cancelled = await until { ended.lines == ["cancelled"] }
        #expect(cancelled, "the quick model was still running when the final one was done")
        guard cancelled else { run.cancel(); return }
        #expect(try await run.value == ["a": "AA"])
    }

    @Test func aQuickTextThatLandsAfterTheFinalOneNeverReplacesIt() async throws {
        // The two tasks that carry the texts to the screen may run in either order: whatever order the sinks hear them, the book ends on the final.
        let book = BookBox()
        let clock = Clock()
        let gq = Gate(), gf = Gate()
        await gf.release()
        let final = runner("final", gate: gf, answers: ["a": "AA"], log: Log())
        let painted = Log(), landed = Log()
        // A quick model that does not stop when it is cancelled and tells its sink late, as a carried-over task would.
        let quick: FirstPaint.Runner = { _, sink in
            await gq.wait()
            sink("a", "A")
            return ["a": "A"]
        }
        let run = Task {
            try await FirstPaint.run(items: ["a"], quick: quick, final: final,
                                     provisional: { s, t in if let p = book.offer(t, for: s, at: clock.now) { painted.add(p) } },
                                     onFinal: { s, t in landed.add(t); _ = book.settle(t, for: s, at: clock.now) })
        }
        guard await until({ !landed.lines.isEmpty }) else { Issue.record("the final text did not land"); run.cancel(); return }
        await gq.release()
        let answer = try await run.value
        #expect(answer == ["a": "AA"] && painted.lines.isEmpty && book.shown(for: "a") == nil)
    }
}
