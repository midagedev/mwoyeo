import Foundation
import Testing
@testable import MwoyeoCore

@Suite struct PaceStatsTests {
    private let engine = UUID()
    private func slot(_ pair: String, engine: UUID? = nil) -> PaceStats.Slot {
        PaceStats.Slot(key: "\(pair)|\(engine == nil ? "apple:auto" : "ext:x")", engine: engine)
    }

    @Test func expectedSecondsFollowsTheNamespaceInUseAndIsNilUntilItsFirstLine() {
        let p = PaceStats()
        let en = slot("en>ko"), ja = slot("ja>ko")
        p.use(en)
        #expect(p.expectedSeconds(lines: 3) == nil)
        p.record(1.5, isFirst: true, slot: en)
        p.record(0, isFirst: false, slot: en)
        #expect(p.expectedSeconds(lines: 3) == 1.5)
        // Another pair knows nothing yet.
        p.use(ja)
        #expect(p.expectedSeconds(lines: 3) == nil)
        p.use(en)
        #expect(p.expectedSeconds(lines: 3) == 1.5)
    }

    @Test func aFallbackLendsItsPaceUntilItEndsOrTheNamespaceChanges() {
        let p = PaceStats()
        let added = slot("en>ko", engine: engine), apple = slot("en>ko")
        p.use(added)
        p.record(2, isFirst: true, slot: added)
        p.record(0.2, isFirst: true, slot: apple)
        p.useFallback(apple, until: ProcessInfo.processInfo.systemUptime + 60)
        #expect(p.expectedSeconds(lines: 1) == 0.2)
        p.clearFallback()
        #expect(p.expectedSeconds(lines: 1) == 2)
        p.useFallback(apple, until: ProcessInfo.processInfo.systemUptime - 1)
        #expect(p.expectedSeconds(lines: 1) == 2)
        p.useFallback(apple, until: ProcessInfo.processInfo.systemUptime + 60)
        p.use(slot("ja>ko", engine: engine))
        #expect(p.expectedSeconds(lines: 1) == nil)
    }

    @Test func anEnginesSpeedSummaryAddsUpItsPairsAndLeavesOtherEnginesOut() {
        let p = PaceStats()
        let a = slot("en>ko", engine: engine), b = slot("ja>ko", engine: engine), apple = slot("en>ko")
        for s in [1.0, 2.0, 3.0] { p.finish(slot: a, total: s, ok: true, cancelled: false) }
        for s in [4.0, 5.0] { p.finish(slot: b, total: s, ok: true, cancelled: false) }
        p.finish(slot: apple, total: 0.1, ok: true, cancelled: false)
        // Failed and cancelled batches are no latency (cancelled ones are counted).
        p.finish(slot: a, total: 9, ok: false, cancelled: false)
        p.finish(slot: a, total: 9, ok: false, cancelled: true)
        p.recordBatch(6, slot: b)
        #expect(p.summary(for: engine, minBatches: 7) == nil)
        #expect(p.summary(for: engine, minBatches: 6) != nil)
        #expect(p.medianSeconds(for: engine) == 4)
        p.use(a)
        p.recordLookup(hit: true)
        p.recordLookup(hit: false)
        p.use(b)
        p.recordLookup(hit: true)
        p.recordLookup(hit: true)
        #expect(p.summary(for: engine, minBatches: 6)?.fromMemory == 0.75)
        #expect(p.medianSeconds(for: UUID()) == nil)
        let stats = p.stats()
        #expect(stats.map(\.key) == stats.map(\.key).sorted() && stats.count == 3)
        #expect(stats.first { $0.key == a.key }?.cancelled == 1)
        #expect(stats.first { $0.key == a.key }?.batches == 3)
    }

    @Test func lineCountsAndEstimatesArePerNamespace() {
        let p = PaceStats()
        let a = slot("en>ko", engine: engine), apple = slot("en>ko")
        p.record(1, isFirst: true, slot: a)
        p.record(0, isFirst: false, slot: a)
        p.record(0, isFirst: false, slot: a)
        p.record(0.3, isFirst: true, slot: apple)
        let s = p.stats()
        #expect(s.first { $0.key == a.key }?.translatedLines == 3)
        #expect(s.first { $0.key == a.key }?.first == 1)
        #expect(s.first { $0.key == apple.key }?.first == 0.3)
    }
}
