import XCTest
@testable import MwoyeoCore

/// A moving scene beside the text (design games-and-video §3), on synthetic frames and a clock the test moves: 320×192 gray pixels, 16-pixel
/// tiles. The "game": a dialogue box at the bottom (`box`), a band of moving stripes above it (`band`), and room elsewhere.
final class ReadWatchTests: XCTestCase {
    private let width = 320, height = 192
    private let box = PixelRect(x: 48, y: 144, width: 224, height: 32)
    private let band = PixelRect(x: 0, y: 16, width: 320, height: 64)

    /// A frame: the band's stripes at `phase` (moving 6 px per phase, in the band only), the box's text as line `line`, and, when `extra` is
    /// set, one more patch of text there.
    private func scene(phase: Int?, line: Int, extra: PixelRect? = nil) -> GrayImage {
        var g = GrayImage(width: width, height: height, fill: 100)
        if let phase {
            for y in band.y ..< band.y + band.height {
                for x in band.x ..< band.x + band.width { g[x, y] = (x + 6 * phase) % 24 < 12 ? 220 : 60 }
            }
        }
        // Text: short vertical strokes, 6 px apart, shifted by 2 px per line (a new line changes every stroke).
        for y in box.y + 6 ..< box.y + 26 {
            for x in stride(from: box.x + 8 + 2 * line, to: box.x + box.width - 8, by: 6) { g[x, y] = 230; g[x + 1, y] = 230 }
        }
        if let e = extra {
            for y in e.y ..< e.y + e.height { for x in stride(from: e.x, to: e.x + e.width, by: 5) { g[x, y] = 240; g[x + 1, y] = 240 } }
        }
        return g
    }

    /// What the pipeline's `ingest` does with a frame: the change against the previous frame, `learns` for a small one, and the watch.
    private struct Sim {
        var watch = ReadWatch()
        var previous: GrayImage
        var time = 0.0
        mutating func step(_ frame: GrayImage, boxes: [PixelRect]?, dt: Double = 0.1) -> ReadWatch.Noted {
            time += dt
            let raw = FrameDiff.changeMap(from: previous, to: frame)
            previous = frame
            return watch.frame(raw, boxes: boxes, at: time, learns: raw.ratio <= 0.2)
        }
    }

    func testMovingBandAboveTheBoxCountsNothing() {
        var sim = Sim(previous: scene(phase: 0, line: 0))
        var counted = 0
        for i in 1...30 where !sim.step(scene(phase: i, line: 0), boxes: [box]).counted.isUnchanged { counted += 1 }
        XCTAssertEqual(counted, 0, "frames whose band motion counted as a change: \(counted) of 30")
    }

    func testTheTextChangingCountsAtOnceAndOnlyItsOwnTiles() {
        var sim = Sim(previous: scene(phase: 0, line: 0))
        for i in 1...10 { _ = sim.step(scene(phase: i, line: 0), boxes: [box]) }
        // The line changes in the same frame the band moves on.
        let noted = sim.step(scene(phase: 11, line: 1), boxes: [box])
        guard let dirty = noted.counted.dirtyRect else { return XCTFail("a changed line did not count at the frame it changed") }
        let reach = PixelRect(x: box.x - 16, y: box.y - 16, width: box.width + 32, height: box.height + 32)
        XCTAssertTrue(dirty.y >= reach.y && dirty.x >= reach.x && dirty.x + dirty.width <= reach.x + reach.width,
                      "the box's change was counted with the band's: dirty \(dirty.x),\(dirty.y) \(dirty.width)×\(dirty.height), box reaches \(reach.x),\(reach.y)")
    }

    func testNewTextAwayFromTheBoxesWaitsUntilItIsStill() {
        var sim = Sim(previous: scene(phase: nil, line: 0))
        let extra = PixelRect(x: 224, y: 96, width: 64, height: 16)
        let noted = sim.step(scene(phase: nil, line: 0, extra: extra), boxes: [box])
        XCTAssertTrue(noted.counted.isUnchanged, "a change away from the text counted at once")
        XCTAssertGreaterThan(noted.held, 0)
        XCTAssertEqual(sim.watch.takeRested(at: sim.time + 0.3), [], "read before it had been still")
        XCTAssertEqual(sim.watch.restsIn(at: sim.time + 0.3).map { ($0 * 100).rounded() / 100 }, 0.1)
        let rested = sim.watch.takeRested(at: sim.time + 0.5)
        XCTAssertFalse(rested.isEmpty, "never read once it was still")
        XCTAssertTrue(rested.contains { $0.x <= extra.x && $0.x + $0.width >= extra.x + extra.width && $0.y <= extra.y && $0.y + $0.height >= extra.y + extra.height },
                      "the area handed back does not cover the new text: \(rested)")
        XCTAssertEqual(sim.watch.takeRested(at: sim.time + 5), [], "the same area handed back twice")
    }

    func testAMovingAreaIsReadOnceWhenItStops() {
        // The hold's rule alone: the cap (`heldReadInterval`, 1.5 s) would hand the band back at 1.6 s, while it moves until 2.0 s. Its own
        // tests are the ones below (untrans117, 2026-10-23: the cap was out of this one's way, no assertion of it was changed).
        var sim = Sim(watch: ReadWatch(heldReadInterval: .infinity), previous: scene(phase: 0, line: 0))
        for i in 1...20 {
            _ = sim.step(scene(phase: i, line: 0), boxes: [box])
            XCTAssertEqual(sim.watch.takeRested(at: sim.time), [], "the band was handed back to be read while it still moved (frame \(i))")
        }
        let stopped = sim.time
        XCTAssertEqual(sim.watch.takeRested(at: stopped + 0.3), [])
        let rested = sim.watch.takeRested(at: stopped + 0.45)
        XCTAssertFalse(rested.isEmpty, "the band was not read once it stopped")
        XCTAssertTrue(rested.allSatisfy { $0.y >= band.y - 16 && $0.y + $0.height <= band.y + band.height + 16 }, "areas: \(rested)")
        XCTAssertEqual(sim.watch.takeRested(at: stopped + 5), [])
    }

    func testWithNoTextKnownEveryChangeCountsAsBefore() {
        for boxes in [nil, [PixelRect]()] as [[PixelRect]?] {
            var sim = Sim(previous: scene(phase: 0, line: 0))
            let noted = sim.step(scene(phase: 1, line: 0), boxes: boxes)
            let raw = FrameDiff.changeMap(from: scene(phase: 0, line: 0), to: scene(phase: 1, line: 0))
            XCTAssertEqual(noted.counted, raw, "boxes \(String(describing: boxes)): a change was left out")
            XCTAssertEqual(noted.held, 0)
        }
    }

    func testTilesHeldAreLeftOutOfTheDifferenceToTheRead() {
        var sim = Sim(previous: scene(phase: nil, line: 0))
        let base = scene(phase: nil, line: 0)
        let now = scene(phase: 3, line: 1)
        _ = sim.step(now, boxes: [box])
        let diff = FrameDiff.changeMap(from: base, to: now)
        let counted = sim.watch.stale(diff, boxes: [box], at: sim.time)
        XCTAssertTrue(counted.changedCount > 0 && counted.changedCount < diff.changedCount, "counted \(counted.changedCount) of \(diff.changedCount)")
        guard let d = counted.dirtyRect else { return XCTFail("the box's change was left out") }
        XCTAssertGreaterThanOrEqual(d.y, box.y - 16, "the band's tiles stayed in the difference: \(d)")
    }

    func testAChangeNeverSeenAwayStillCountsInTheDifference() {
        // A difference the watch was not told about (a pass that ended on a frame that moved on) has no history: it counts, as it did.
        let watch = ReadWatch()
        let diff = FrameDiff.changeMap(from: scene(phase: nil, line: 0), to: scene(phase: 2, line: 0))
        XCTAssertEqual(watch.stale(diff, boxes: [box], at: 1), diff)
    }

    func testDidReadReleasesTheTilesInsideTheArea() {
        var sim = Sim(previous: scene(phase: nil, line: 0))
        _ = sim.step(scene(phase: 1, line: 0), boxes: [box])
        XCTAssertNotNil(sim.watch.restsIn(at: sim.time))
        sim.watch.didRead(band, frameTime: sim.time)
        XCTAssertNil(sim.watch.restsIn(at: sim.time), "tiles inside what was read stayed held")
        _ = sim.step(scene(phase: 2, line: 0), boxes: [box])
        sim.watch.didRead(nil, frameTime: sim.time)
        XCTAssertNil(sim.watch.wake(at: sim.time))
    }

    func testAChangeAfterTheFrameThatWasReadStaysHeld() {
        // The read ended while the band moved on: the frames that came in during it changed the band again, and the read did not see that.
        var sim = Sim(previous: scene(phase: nil, line: 0))
        _ = sim.step(scene(phase: 1, line: 0), boxes: [box])
        let readFrame = sim.time
        for i in 2...4 { _ = sim.step(scene(phase: i, line: 0), boxes: [box]) }
        sim.watch.didRead(nil, frameTime: readFrame)
        XCTAssertNotNil(sim.watch.restsIn(at: sim.time), "a tile that changed after the frame read was let go")
        // And the newest frame still differs from what the read described only where the band is, which is held, so nothing is stale.
        let stale = sim.watch.stale(FrameDiff.changeMap(from: scene(phase: 1, line: 0), to: scene(phase: 4, line: 0)), boxes: [box], at: sim.time)
        XCTAssertTrue(stale.isUnchanged, "the band's motion since the read counted as a change: \(stale.changedCount) tiles")
    }

    func testTheLookAgainIsDueWhenTheFirstHeldTileRests() {
        var sim = Sim(previous: scene(phase: nil, line: 0))
        XCTAssertNil(sim.watch.wake(at: 0))
        _ = sim.step(scene(phase: 1, line: 0), boxes: [box])
        let due = sim.watch.wake(at: sim.time + 0.1)
        XCTAssertEqual(due.map { ($0 * 100).rounded() / 100 }, 0.3)
    }

    func testAnimatedTilesNearTheTextStillGoOutAsBefore() {
        // A caret blinking beside the line: three changes within the window make its tiles animated, weighed or not.
        var sim = Sim(previous: scene(phase: nil, line: 0))
        var counts: [Int] = []
        for i in 0..<5 {
            var f = scene(phase: nil, line: 0)
            if i % 2 == 0 { for y in box.y + 8 ..< box.y + 24 { f[box.x + box.width + 2, y] = 255; f[box.x + box.width + 3, y] = 255 } }
            counts.append(sim.step(f, boxes: [box]).counted.changedCount)
        }
        XCTAssertEqual(counts.last, 0, "a blinking caret kept counting: \(counts)")
    }

    func testTheInboxSeesUpToTheOldestFrameNotCounted() {
        var inbox = ReadWatch.Inbox()
        XCTAssertEqual(inbox.seen(at: 5), 5, "nothing waiting: the frames counted show the scene up to now")
        inbox.delivered(1)
        inbox.delivered(2)
        XCTAssertEqual(inbox.seen(at: 5), 1)
        XCTAssertEqual(inbox.count, 2)
        inbox.counted(1)
        XCTAssertEqual(inbox.seen(at: 5), 2)
        inbox.counted(2)
        inbox.counted(3)   // a frame never handed in changes nothing
        XCTAssertEqual(inbox.seen(at: 5), 5)
        inbox.delivered(7)
        XCTAssertEqual(inbox.seen(at: 5), 5, "a frame stamped after now does not run the clock ahead of now")
    }

    /// The check's case (`GameChecks.movingBandDuringAPass`) on a clock the test moves, in milliseconds: the band moves a phase every 10 ms, a
    /// pass holds the pipeline from 100 to 900 (hold 0.6 s), and after it the frames that waited are counted one every 8 ms while more come
    /// in. A look is asked for by the frame counted after the last look ran, and runs once the frames handed in before it are counted (the
    /// pipeline's actor takes its jobs in order). The band never stops until 2000: no look may find it at rest before then, and once the
    /// frames are all counted it rests `hold` after its last frame, not later.
    func testAPassThatOutlastsTheHoldDoesNotMakeAMovingBandRest() {
        let hold = 0.6
        // The hold's rule alone: the band moves for 2 s, longer than the cap's interval (untrans117, 2026-10-23: out of this one's way, no
        // assertion changed).
        var watch = ReadWatch(hold: hold, heldReadInterval: .infinity), inbox = ReadWatch.Inbox()
        // The stripes repeat every 4 phases: four pictures, and the change between any two of them, made once.
        let frames = (0..<4).map { scene(phase: $0, line: 0) }
        let changes = frames.map { a in frames.map { b in FrameDiff.changeMap(from: a, to: b) } }
        var previous = 0
        var waiting: [Int] = []   // the phases handed in and not counted, in order; phase k is captured at 10 k ms
        var ahead: Int?           // frames still before the look asked for
        var looks = 0, restedOnTheWall = 0, restedSeen: [Int] = []
        func countNext() {
            let phase = waiting.removeFirst(), t = Double(phase) / 100
            inbox.counted(t)
            let raw = changes[previous][phase % 4]
            _ = watch.frame(raw, boxes: [box], at: t, learns: raw.ratio <= 0.2)
            previous = phase % 4
        }
        var nextJob = 900
        for ms in 1...2700 {
            let now = Double(ms) / 1000
            if ms % 10 == 0, ms <= 2000 { waiting.append(ms / 10); inbox.delivered(Double(ms) / 1000) }
            if ms < 100 { while !waiting.isEmpty { countNext() }; continue }
            guard ms >= 900, ms >= nextJob else { continue }
            if ahead == 0 {
                // The look: what the pipeline's `noteRested` judges when a run starts.
                looks += 1
                var wall = watch
                if !wall.takeRested(at: now).isEmpty { restedOnTheWall += 1 }
                if !watch.takeRested(at: inbox.seen(at: now)).isEmpty { restedSeen.append(ms) }
                ahead = nil
                nextJob = ms + 1
            } else if !waiting.isEmpty {
                countNext()
                ahead = ahead.map { $0 - 1 } ?? waiting.count
                nextJob = ms + 8
            } else if ms % 10 == 5 {
                // Nothing waits: the timer's look, as `run`'s wake asks for one.
                ahead = 0
            }
        }
        XCTAssertGreaterThan(restedOnTheWall, 0, "the case is not the one the check fails on: no look rested the band on the wall clock")
        XCTAssertGreaterThan(looks, 20)
        XCTAssertTrue(restedSeen.first.map { $0 >= 2600 } ?? false,
                      "the band rested while it moved, or never once it stopped: rested at \(restedSeen) ms (it stopped at 2000, hold \(Int(hold * 1000)) ms)")
        XCTAssertTrue(restedSeen.first.map { $0 <= 2610 } ?? false, "the band rested later than its hold after it stopped: \(restedSeen) ms")
    }

    func testAnInjectedHoldIsHowLongATileMustBeStill() {
        for (hold, restsAt) in [(ReadWatch.standardHold, 0.45), (0.05, 0.08)] {
            var sim = Sim(watch: ReadWatch(hold: hold), previous: scene(phase: nil, line: 0))
            _ = sim.step(scene(phase: nil, line: 0, extra: PixelRect(x: 224, y: 96, width: 64, height: 16)), boxes: [box])
            XCTAssertEqual(sim.watch.hold, hold)
            XCTAssertEqual(sim.watch.takeRested(at: sim.time + hold / 2), [], "hold \(hold): read before it had been still")
            XCTAssertFalse(sim.watch.takeRested(at: sim.time + restsAt).isEmpty, "hold \(hold): not read once it had been still for \(restsAt) s")
        }
    }

    // MARK: A scene that never stops (untrans117, 2026-10-23)

    /// The pipeline's reads on the watch: a take is a read of what was handed back, as the pass `noteRested` starts is, and the frame it read
    /// is the one just counted (`didRead`).
    private func readsInANeverStillScene(frames: Int, dt: Double, appearing: [(frame: Int, at: PixelRect)] = [],
                                         watch: ReadWatch = ReadWatch()) -> (reads: [(time: Double, areas: [PixelRect])], sim: Sim) {
        var sim = Sim(watch: watch, previous: scene(phase: 0, line: 0))
        var reads: [(time: Double, areas: [PixelRect])] = []
        for i in 1...frames {
            // Text that appears in the band at a frame stays; the band's cells move on under it.
            let extra = appearing.last { $0.frame <= i }?.at
            _ = sim.step(scene(phase: i, line: 0, extra: extra), boxes: [box], dt: dt)
            let areas = sim.watch.takeRested(at: sim.time)
            if !areas.isEmpty {
                reads.append((sim.time, areas))
                sim.watch.didRead(nil, frameTime: sim.time)
            }
        }
        return (reads, sim)
    }

    func testNewTextInASceneThatNeverStopsIsReadWithinTheInterval() {
        let text = PixelRect(x: 96, y: 32, width: 96, height: 16)
        // The text appears at 0.5 s, at 1.65 s (just after the first read of the band) and at 2.3 s.
        for frame in [5, 16, 23] {
            let appeared = Double(frame) / 10
            let run = readsInANeverStillScene(frames: 60, dt: 0.1, appearing: [(frame, text)])
            let covering = run.reads.first { r in r.time >= appeared && r.areas.contains { $0.x <= text.x && $0.x + $0.width >= text.x + text.width && $0.y <= text.y && $0.y + $0.height >= text.y + text.height } }
            XCTAssertNotNil(covering, "text that appeared at \(appeared) s in a scene that never stops was never read: reads at \(run.reads.map(\.time))")
            if let covering {
                XCTAssertLessThanOrEqual(covering.time - appeared, ReadWatch.standardHeldReadInterval + 0.1 + 1e-9, "text that appeared at \(appeared) s was read at \(covering.time) s")
            }
        }
    }

    func testASceneThatNeverStopsIsReadOncePerIntervalNotEveryFrame() {
        // The game117 probe's case: 31 s of a band that moves in every frame, 8 frames a second.
        let run = readsInANeverStillScene(frames: 248, dt: 0.125)
        print("readwatch-note: a band that never stops, 31 s at 8 frames a second: \(run.reads.count) reads, first at \(run.reads.first?.time ?? -1) s")
        XCTAssertGreaterThan(run.reads.count, 15, "reads of the band in 31 s: \(run.reads.count)")
        XCTAssertLessThanOrEqual(run.reads.count, Int(31 / ReadWatch.standardHeldReadInterval) + 1, "reads of the band in 31 s: \(run.reads.count)")
        for (a, b) in zip(run.reads, run.reads.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.time - a.time, ReadWatch.standardHeldReadInterval - 1e-9, "two reads of the band \(b.time - a.time) s apart")
        }
    }

    func testAToastInAStillAreaIsStillReadAtTheHoldWhileTheSceneNeverStops() {
        // The band moves in every frame; a toast appears below it at 0.2 s and stays: it rests at 0.2 + 0.4 s, long before the band is read.
        let toast = PixelRect(x: 224, y: 96, width: 64, height: 16)
        let run = readsInANeverStillScene(frames: 8, dt: 0.1, appearing: [(2, toast)])
        guard let first = run.reads.first else { return XCTFail("the toast was never read") }
        XCTAssertEqual(first.time, 0.6, accuracy: 0.101, "the toast was read at \(first.time) s")
        XCTAssertTrue(first.areas.allSatisfy { $0.y >= 80 }, "the band was read with it: \(first.areas)")
        XCTAssertTrue(first.areas.contains { $0.x <= toast.x && $0.x + $0.width >= toast.x + toast.width && $0.y <= toast.y && $0.y + $0.height >= toast.y + toast.height }, "areas \(first.areas)")
    }

    func testTheLookAgainIsDueWhenAMovingSceneHasBeenHeldForTheInterval() {
        // The band moves in every frame: the tiles never rest, so the look is due when the oldest has been held for the interval (1.6 s, the first
        // frame being at 0.1 s), not 0.4 s after the last frame.
        var sim = Sim(previous: scene(phase: 0, line: 0))
        for i in 1...15 { _ = sim.step(scene(phase: i, line: 0), boxes: [box]) }
        XCTAssertEqual(sim.time, 1.5, accuracy: 1e-9)
        XCTAssertEqual(sim.watch.restsIn(at: sim.time) ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(sim.watch.wake(at: sim.time) ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(sim.watch.takeRested(at: sim.time), [], "handed back before the interval was up")
        XCTAssertFalse(sim.watch.takeRested(at: sim.time + 0.1).isEmpty, "not handed back when the interval was up")
    }

    func testAnInjectedIntervalIsHowLongAMovingSceneGoesUnread() {
        for interval in [0.5, 3.0] {
            let run = readsInANeverStillScene(frames: 100, dt: 0.1, watch: ReadWatch(heldReadInterval: interval))
            XCTAssertEqual(run.sim.watch.heldReadInterval, interval)
            XCTAssertEqual(run.reads.first?.time ?? -1, interval + 0.1, accuracy: 0.101, "interval \(interval): first read of the band at \(run.reads.map(\.time))")
            XCTAssertLessThanOrEqual(run.reads.count, Int(10 / interval) + 1, "interval \(interval): reads \(run.reads.map(\.time))")
            for (a, b) in zip(run.reads, run.reads.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b.time - a.time, interval - 1e-9, "interval \(interval): two reads \(b.time - a.time) s apart")
            }
        }
    }
}
