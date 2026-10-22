#if !MAS
import AppKit
import MwoyeoCore
import MwoyeoEngines

/// The first Korean of a lens is drawn when its own block's patch is filled, not when every block's is (round erase117, docs/design/first-lens.md
/// §14), run by `--capture-ui … check-logic` and alone by `erase-checks` (PASS/FAIL lines). FAILURE MODE IT BLOCKS: the erase pass run in one
/// piece on the pipeline's actor (fast117, design §13.8: a translation that landed 14.1 s after the click was drawn at 23.1 s, when the pass ended).
///
/// A real pipeline (`StillTranslation`, the lens's own mode) over the page of `ResizeHoldChecks`, a mock engine that answers after 120 ms, and a
/// gate on the pipeline's fills (`RegionPipeline.setFillGate`) that holds each fill back, as a slow fill would, until the check lets it go. What
/// is checked is the order of events, never how long anything took: the waits below only bound a run that would otherwise hang.
@MainActor
enum EraseChecks {
    /// The fills the pipeline has asked for, in order, and how many of them may go on. `pass` is called off the actor and blocks.
    final class Gate: @unchecked Sendable {
        private let lock = NSCondition()
        private var asked: [CGRect] = []
        private var allowed = 0
        private var open = false

        func pass(_ rect: CGRect) {
            lock.lock()
            asked.append(rect)
            let n = asked.count
            while !open, n > allowed { lock.wait() }
            lock.unlock()
        }

        /// The first `n` fills asked for may go on.
        func allow(_ n: Int) { lock.lock(); allowed = max(allowed, n); lock.broadcast(); lock.unlock() }
        /// Every fill goes on, from now on.
        func openAll() { lock.lock(); open = true; lock.broadcast(); lock.unlock() }
        var rects: [CGRect] { lock.lock(); defer { lock.unlock() }; return asked }
        /// Fills asked for and held back now.
        var held: Int { lock.lock(); defer { lock.unlock() }; return open ? 0 : max(0, asked.count - allowed) }
    }

    final class Snapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [OverlaySnapshot] = []
        func put(_ s: OverlaySnapshot) { lock.withLock { all.append(s) } }
        var last: OverlaySnapshot? { lock.withLock { all.last } }
    }

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") erase: \(what)" + (ok ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
        guard let mock = ContextChecks.Mock(mode: "slow:120"), let page = ResizeHoldChecks.renderPage(), let rgba = RGBAImage(cgImage: page) else {
            check("the mock server starts and the page is drawn", false)
            return failed
        }
        defer { mock.stop() }
        let engine = EngineConfig(id: UUID(), name: "Erase", kind: .openAICompatible(baseURL: mock.base.appendingPathComponent("v1"), model: "m1", thinking: .off, extraHeaders: [:]),
                                  context: nil)
        var settings = ContextChecks.settings(nil)
        settings.engines = [engine]
        settings.customEngineID = engine.id
        settings.renderMode = .adaptive
        let gate = Gate(), seen = Snapshots()
        let still = StillTranslation(.init(image: page, rgba: rgba, scale: ResizeHoldChecks.scale), settings: settings, translator: ContextChecks.service(settings),
                                     inpainter: nil, onSnapshot: { seen.put($0) })
        let pipeline = still.pipeline
        await pipeline.setFillGate { gate.pass($0) }
        _ = Trace.takeCounts()
        let s = ResizeHoldChecks.scale
        func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
            let end = ProcessInfo.processInfo.systemUptime + seconds
            while !done() {
                guard ProcessInfo.processInfo.systemUptime < end else { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }
        /// The blocks a snapshot reads, image pixels (a block's rect is its patch's).
        func patches(_ snapshot: OverlaySnapshot?) -> [CGRect] {
            (snapshot?.texts ?? []).map { CGRect(x: $0.frame.minX * s, y: $0.frame.minY * s, width: $0.frame.width * s, height: $0.frame.height * s) }
        }
        func same(_ a: CGRect, _ b: CGRect) -> Bool { abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1 && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1 }

        // The lens's first read (nothing on the screen yet): its blocks go up at once and their text to the translator, every fill held back.
        await still.ingest()
        let top = { patches(seen.last).min { $0.minY < $1.minY } }
        let landed = await until(60) {
            guard let t = top(), let last = seen.last else { return false }
            return last.texts.contains { same(CGRect(x: $0.frame.minX * s, y: $0.frame.minY * s, width: $0.frame.width * s, height: $0.frame.height * s), t) && $0.translation != nil }
        }
        let read = seen.last
        check("the first read's text goes to the translator before its patches are filled: the top block's translation lands with every fill held back (\(gate.rects.count) asked)",
              landed && gate.held == gate.rects.count, "landed \(landed), held \(gate.held) of \(gate.rects.count), texts \(read?.texts.count ?? 0)")
        check("and nothing is drawn before its own patch is in (\(read?.blocks.count ?? -1) blocks drawn)", landed && read?.blocks.isEmpty == true)
        let first = gate.rects.first
        check("the patches are filled one at a time, the top of the lens first", gate.rects.count == 1 && first.map { f in top().map { same($0, f) } ?? false } == true,
              "asked \(gate.rects.count), first \(first.map { "\($0)" } ?? "none"), top \(top().map { "\($0)" } ?? "none")")

        // One fill goes on: its block is drawn, and the next fill is asked for and held.
        gate.allow(1)
        let drawn = await until(60) { seen.last?.blocks.isEmpty == false && gate.rects.count >= 2 }
        let one = seen.last
        let drawnFirst = one?.blocks.first.map { b in first.map { same(CGRect(x: b.frame.minX * s, y: b.frame.minY * s, width: b.frame.width * s, height: b.frame.height * s), $0) } ?? false } ?? false
        check("the first Korean is drawn when its own block's patch is in, while the next patch is still held (\(one?.blocks.count ?? 0) drawn, \(gate.held) held)",
              drawn && one?.blocks.count == 1 && drawnFirst && gate.held >= 1, "drawn \(drawn) first \(drawnFirst) held \(gate.held)")

        // The rest of the first read goes on; the settled read that follows takes the place of blocks on the screen: its fills are held, and the
        // pipeline still draws on the blocks that are up (a change of the font redraws them), and none of them goes away.
        let firstRead = read?.texts.count ?? 0
        gate.allow(firstRead)
        let upAll = await until(60) { (seen.last?.blocks.count ?? 0) >= firstRead && gate.rects.count > firstRead }
        let before = seen.last
        let heldSecond = gate.held
        var styled = settings
        styled.fontStyle = settings.fontStyle == .serif ? .system : .serif
        let redraw = Task { await still.update(settings: styled) }
        let redrawn = await until(30) { (seen.last?.version ?? 0) > (before?.version ?? 0) }
        let during = seen.last
        check("a read over blocks on the screen fills its patches off the actor: a redraw of the blocks that are up is drawn while its fill is held (\(heldSecond) held)",
              upAll && heldSecond >= 1 && redrawn && gate.held >= 1, "all up \(upAll), held \(heldSecond), redrawn \(redrawn)")
        check("and the blocks that are up stay up meanwhile (\(before?.blocks.count ?? 0) → \(during?.blocks.count ?? 0))",
              (during?.blocks.count ?? 0) >= (before?.blocks.count ?? 1) && (before?.blocks.count ?? 0) > 0)

        gate.openAll()
        _ = await redraw.value
        try? await still.settle(from: Date(), maxWait: 120)
        let end = seen.last
        let counts = Trace.takeCounts()
        check("the lens ends with every block drawn and translated (\(end?.blocks.count ?? 0) of \(end?.texts.count ?? 0))",
              end.map { !$0.texts.isEmpty && $0.texts.allSatisfy { $0.translation != nil } && $0.blocks.count == $0.texts.count } ?? false)
        check("every erase planned is filled once (\(counts["erase", default: 0]) planned, \(gate.rects.count) filled)",
              counts["erase", default: 0] == gate.rects.count && gate.rects.count > firstRead)
        await pipeline.setFillGate(nil)
        await pipeline.halt()
        return failed
    }
}
#endif
