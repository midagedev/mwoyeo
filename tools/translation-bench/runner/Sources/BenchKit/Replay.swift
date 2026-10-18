import Foundation

/// One request of a replay: the lines to translate and what the screen shows around them.
public struct Batch: Sendable, Equatable {
    public var number: Int
    public var screen: Int
    public var items: [BenchLine]
    /// Lines of the same screen above the first item and below the last (the lens's "nearby" lines, in reading order).
    public var above: [BenchLine]
    public var below: [BenchLine]
}

public enum Replay {
    /// The batches in the order the lens asks for them: screen by screen, the lines a screen adds in reading order,
    /// at most `batchSize` at a time (`RegionPipeline.nextBatch` takes `prefix(3)` of what is pending).
    public static func plan(_ seq: BenchSequence, batchSize: Int = 3) -> [Batch] {
        let byID = Dictionary(uniqueKeysWithValues: seq.lines.map { ($0.id, $0) })
        var done = Set<Int>()
        var out: [Batch] = []
        for (si, screen) in seq.screens.enumerated() {
            var pending = screen.filter { !done.contains($0) }
            while !pending.isEmpty {
                let ids = Array(pending.prefix(batchSize))
                pending.removeFirst(ids.count)
                let first = ids.first!, last = ids.last!
                out.append(Batch(number: out.count + 1, screen: si + 1,
                                 items: ids.compactMap { byID[$0] },
                                 above: screen.filter { $0 < first }.compactMap { byID[$0] },
                                 below: screen.filter { $0 > last }.compactMap { byID[$0] }))
                done.formUnion(ids)
            }
        }
        return out
    }
}
