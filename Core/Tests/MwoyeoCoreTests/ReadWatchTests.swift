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
        var sim = Sim(previous: scene(phase: 0, line: 0))
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

    func testAnInjectedHoldIsHowLongATileMustBeStill() {
        for (hold, restsAt) in [(ReadWatch.standardHold, 0.45), (0.05, 0.08)] {
            var sim = Sim(watch: ReadWatch(hold: hold), previous: scene(phase: nil, line: 0))
            _ = sim.step(scene(phase: nil, line: 0, extra: PixelRect(x: 224, y: 96, width: 64, height: 16)), boxes: [box])
            XCTAssertEqual(sim.watch.hold, hold)
            XCTAssertEqual(sim.watch.takeRested(at: sim.time + hold / 2), [], "hold \(hold): read before it had been still")
            XCTAssertFalse(sim.watch.takeRested(at: sim.time + restsAt).isEmpty, "hold \(hold): not read once it had been still for \(restsAt) s")
        }
    }
}
