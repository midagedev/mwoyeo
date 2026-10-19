#if !MAS
import CoreGraphics
import Foundation

/// The checks of `DriftMeter`, the drift of `--pan`, run by `--capture-ui … check-logic` and alone by `drift-checks` (PASS/FAIL lines). On frames
/// built by hand, no clock: a page scrolled 50 pt a frame, and a text at page y 400 that is on screen at 400 minus the offset.
enum DriftChecks {
    static func run() -> Int {
        var failed = 0
        func check(_ what: String, _ got: CGFloat, _ want: CGFloat) {
            let ok = abs(got - want) < 0.01
            print("check-logic: \(ok ? "PASS" : "FAIL") drift: \(what)" + (ok ? "" : " [got \(got), want \(want)]"))
            if !ok { failed += 1 }
        }
        let size = CGSize(width: 200, height: 20)
        /// The block's place in the frame captured at `frame` (time = frame number), as the pipeline's snapshot gives it.
        func at(_ frame: Int) -> CGRect { CGRect(x: 100, y: 400 - 50 * CGFloat(frame), width: size.width, height: size.height) }
        func offset(_ frame: Int) -> CGVector { CGVector(dx: 0, dy: 50 * CGFloat(frame)) }
        func meter(frames: Int) -> DriftMeter {
            var m = DriftMeter()
            for f in 0...frames { m.fed(at: TimeInterval(f), offset: offset(f)) }
            return m
        }

        // A block that was translated late: first drawn at frame 5 from the snapshot of frame 4 (a step old, no prediction), so it sits 50 pt
        // behind its text; the next shot has the snapshot of frame 5, and the text and the translation are together. Measured from where it
        // was first drawn, the first shot read 0 and the second 50.
        do {
            var m = meter(frames: 5)
            let id = UUID()
            check("late block, first drawn a step behind: the gap is the step", m.gap(id: id, size: size, followed: at(4), shown: at(4), time: 4, now: offset(5), scrolls: true), 50)
            check("late block, then placed right: no gap", m.gap(id: id, size: size, followed: at(5), shown: at(5), time: 5, now: offset(5), scrolls: true), 0)
        }
        // The same block drawn with the prediction (moved on by the step) is on its text at once.
        do {
            var m = meter(frames: 5)
            let id = UUID()
            check("late block drawn with the prediction: no gap", m.gap(id: id, size: size, followed: at(4), shown: at(5), time: 4, now: offset(5), scrolls: true), 0)
        }
        // A block drawn at rest, then scrolled with the page by a frame that is one step old at every shot: the gap is that step, every time.
        do {
            var m = meter(frames: 6)
            let id = UUID()
            check("block drawn at rest: no gap", m.gap(id: id, size: size, followed: at(0), shown: at(0), time: 0, now: offset(0), scrolls: true), 0)
            for f in 2...6 {
                check("block one frame behind at frame \(f)", m.gap(id: id, size: size, followed: at(f - 1), shown: at(f - 1), time: TimeInterval(f - 1), now: offset(f), scrolls: true), 50)
            }
        }
        // A block the pipeline moved wrongly (3 pt off) reads 3 pt, however late it was first drawn.
        do {
            var m = meter(frames: 5)
            let id = UUID()
            _ = m.gap(id: id, size: size, followed: at(4), shown: at(5), time: 4, now: offset(5), scrolls: true)
            check("a block shifted 3 pt wrong", m.gap(id: id, size: size, followed: at(5).offsetBy(dx: 0, dy: 3), shown: at(5).offsetBy(dx: 0, dy: 3), time: 5, now: offset(5), scrolls: true), 3)
        }
        // A block outside the scrolling area does not move with the offset: still, it has no gap; a block laid out again is anchored again.
        do {
            var m = meter(frames: 5)
            let fixed = UUID(), relaid = UUID(), still = CGRect(x: 10, y: 10, width: 50, height: 20)
            check("a fixed block", m.gap(id: fixed, size: still.size, followed: still, shown: still, time: 4, now: offset(5), scrolls: false), 0)
            check("a fixed block, later", m.gap(id: fixed, size: still.size, followed: still, shown: still, time: 5, now: offset(5), scrolls: false), 0)
            _ = m.gap(id: relaid, size: size, followed: at(2), shown: at(2), time: 2, now: offset(2), scrolls: true)
            let taller = CGSize(width: 200, height: 40)
            let moved = CGRect(origin: at(3).origin, size: taller).offsetBy(dx: 0, dy: 10)   // the new layout puts it 10 pt lower
            check("a block laid out again is measured from there", m.gap(id: relaid, size: taller, followed: moved, shown: moved, time: 3, now: offset(3), scrolls: true), 0)
        }
        return failed
    }
}
#endif
