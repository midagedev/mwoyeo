#if !MAS
import CoreGraphics
import Foundation
import MwoyeoCore

/// A probe, not a check (round game117, 2026-10-22): how long the lens takes to read a line of text that changes in a game's text box while a
/// scene moves in the band above it, run as `--capture-ui <dir> band-probe` (`MWOYEO_READ_SCOPE=off` runs it as the lens did before the watch
/// weighed a change by its distance from the text). The frames are fed as a capture feeds them: 8 a second on the real clock, each in a task of
/// its own that does not wait for the pipeline (a pass that takes longer than a frame leaves frames behind it), rendered ahead by other threads
/// as a game renders itself. Every 3 s the line changes; the latency is the time from the frame that shows a new line to the snapshot that holds
/// it as read text. The engine is not there: translation is the same either way, and Apple Translation would need the main queue.
@MainActor
enum BandProbe {
    private nonisolated static let lines = ["Alpha gate opens when the lights turn green", "Bravo team holds the bridge until dawn",
                                "Charlie finds a silver key under the old table", "Delta signal is lost behind the mountain",
                                "Echo bell rings twice before the storm", "Foxtrot road leads down to the quiet harbor",
                                "Golf cart waits outside the empty station", "Hotel lobby smells of rain and old paper",
                                "India ink spills across the captain's letter", "Juliet window looks over the frozen lake"]
    /// Frames before the first change, and between changes (at 8 a second: 1 s and 3 s), and after the last.
    private nonisolated static let lead = 8, between = 24, tail = 24

    private final class Latencies: @unchecked Sendable {
        private let lock = NSLock()
        private var wanted: (key: String, since: TimeInterval)?
        private var done: [Double] = []
        func expect(_ key: String, since: TimeInterval) { lock.withLock { wanted = (key, since) } }
        func snapshot(_ s: OverlaySnapshot) {
            let now = ProcessInfo.processInfo.systemUptime
            lock.withLock {
                guard let w = wanted, s.texts.contains(where: { $0.source.lowercased().contains(w.key) }) else { return }
                done.append(now - w.since)
                wanted = nil
            }
        }
        var values: [Double] { lock.withLock { done } }
    }

    /// The frames of a run, rendered ahead of the clock by worker threads (never more than `ahead` frames in front of the feeder).
    private final class Supply: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [Int: CapturedFrame] = [:]
        private var claimed = 0, fed = 0
        private let total: Int, ahead = 24
        init(total: Int, workers: Int) {
            self.total = total
            for _ in 0..<workers { Thread.detachNewThread { [self] in work() } }
        }
        private func work() {
            while true {
                let k: Int? = lock.withLock {
                    // A worker pool that cannot keep up works on what is due, not on what has passed (the run reports the frames it missed).
                    claimed = max(claimed, fed)
                    guard claimed < total else { return -1 }
                    guard claimed - fed < ahead else { return nil }
                    defer { claimed += 1 }
                    return claimed
                }
                guard let k else { Thread.sleep(forTimeInterval: 0.01); continue }
                if k < 0 { return }
                let f = BandProbe.frame(line: BandProbe.lineIndex(of: k), band: k + 1)
                lock.withLock { made[k] = f }
            }
        }
        /// Frame `k`, stamped now, or nil when it is not made yet.
        func take(_ k: Int) -> CapturedFrame? {
            lock.withLock {
                fed = max(fed, k)
                guard let f = made.removeValue(forKey: k) else { return nil }
                return CapturedFrame(image: f.image, gray: f.gray, grayStep: f.grayStep, scale: f.scale, rect: f.rect, time: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    nonisolated static func frame(line: Int, band: Int) -> CapturedFrame {
        GameChecks.frame(GameChecks.picture([(lines[line], 250)], band: band), at: 0)!
    }

    /// The line the frame `k` of a run shows.
    nonisolated static func lineIndex(of k: Int) -> Int { k < lead ? 0 : min(lines.count - 1, 1 + (k - lead) / between) }

    static func run(runs: Int = 3) async {
        let scope = ProcessInfo.processInfo.environment["MWOYEO_READ_SCOPE"] == "off" ? "off" : "on"
        let total = lead + between * (lines.count - 1) + tail
        var medians: [Double] = []
        for run in 1...runs {
            let reads = GameChecks.ReadCounter(), latency = Latencies()
            let p = await GameChecks.pipeline(reads, mode: .adaptive, onSnapshot: { latency.snapshot($0) })
            // The first line is read before the clock starts (a cold reader takes long).
            await p.ingest(GameChecks.stamped(frame(line: 0, band: 0)))
            _ = await reads.wait(beyond: 0)
            await p.idle()
            // The rewrite in place that follows the first read once the lens is still, and the translation that fails, are over before the clock starts.
            try? await Task.sleep(for: .seconds(1.5))
            await p.idle()
            let readsAtStart = reads.count
            let supply = Supply(total: total, workers: 4)
            try? await Task.sleep(for: .seconds(0.5))
            let began = ProcessInfo.processInfo.systemUptime
            var late = 0
            for k in 0..<total {
                let due = began + Double(k) * 0.125, now = ProcessInfo.processInfo.systemUptime
                if due > now { try? await Task.sleep(for: .milliseconds(max(1, Int((due - now) * 1000)))) }
                guard let f = supply.take(k) else { late += 1; continue }
                if k > 0, lineIndex(of: k) != lineIndex(of: k - 1) {
                    latency.expect(String(lines[lineIndex(of: k)].split(separator: " ")[0]).lowercased(), since: f.time)
                }
                Task { await p.ingest(f) }
            }
            try? await Task.sleep(for: .seconds(1))
            await p.idle()
            let inOrder = latency.values.map { $0 * 1000 }
            let ms = inOrder.sorted()
            let median = ms.isEmpty ? Double.nan : ms[ms.count / 2]
            if !median.isNaN { medians.append(median) }
            print(String(format: "band-probe: scope=%@ run %d: lines read %d of %d, read latency ms[p50=%.0f p90=%.0f max=%.0f], passes %d over %d frames (%d not made in time)",
                         scope, run, ms.count, lines.count - 1, median, ms.isEmpty ? 0 : ms[min(ms.count - 1, ms.count * 9 / 10)], ms.last ?? 0,
                         reads.count - readsAtStart, total, late) + " each " + inOrder.map { String(Int($0)) }.joined(separator: " "))
        }
        let m = medians.sorted()
        print(String(format: "band-probe: scope=%@ median of the %d runs' p50 = %.0f ms", scope, m.count, m.isEmpty ? Double.nan : m[m.count / 2]))
    }
}
#endif
