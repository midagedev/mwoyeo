// fit117 latency probe: the column estimator (columns.py) and the per-frame drag lookup, in Swift, timed. Not product code.
// swiftc -O ColumnFitProbe.swift -o /tmp/r117/fit117/probe/swift/colprobe && colprobe
import Foundation
import CoreGraphics

struct Col { var left, right, top, bottom: CGFloat; var blocks, lines: Int }
struct Blk { var r: CGRect; var lines: Int }

func columns(_ blocks: [Blk], tol: CGFloat = 6, split: CGFloat = 24, minLines: Int = 2, minSupport: Int = 4) -> [Col] {
    let p = blocks.filter { $0.lines >= minLines }.sorted { $0.r.minX < $1.r.minX }
    var stacks: [[Blk]] = [], cur: [Blk] = []
    for b in p {
        if let l = cur.last, b.r.minX - l.r.minX > tol { stacks.append(cur); cur = [] }
        cur.append(b)
    }
    if !cur.isEmpty { stacks.append(cur) }
    var out: [Col] = []
    for s in stacks {
        let s = s.sorted { $0.r.maxX < $1.r.maxX }
        var subs: [[Blk]] = [], c: [Blk] = []
        for b in s {
            if let l = c.last, b.r.maxX - l.r.maxX > split { subs.append(c); c = [] }
            c.append(b)
        }
        if !c.isEmpty { subs.append(c) }
        for sub in subs {
            let lines = sub.reduce(0) { $0 + $1.lines }
            guard lines >= minSupport else { continue }
            let lefts = sub.map(\.r.minX).sorted()
            out.append(Col(left: lefts[lefts.count / 2], right: sub.map(\.r.maxX).max()!, top: sub.map(\.r.minY).min()!, bottom: sub.map(\.r.maxY).max()!, blocks: sub.count, lines: lines))
        }
    }
    return out.sorted { ($0.left, $0.right) < ($1.left, $1.right) }
}

/// the drag's per-frame work: the nearest target to the lens's two vertical edges, within `reach`
func nearest(_ lens: CGRect, targetsLeft: [CGFloat], targetsRight: [CGFloat], reach: CGFloat = 8) -> CGFloat? {
    var best: CGFloat?
    for t in targetsLeft where abs(t - lens.minX) <= reach && abs(t - lens.minX) < abs(best ?? 99) { best = t - lens.minX }
    for t in targetsRight where abs(t - lens.maxX) <= reach && abs(t - lens.maxX) < abs(best ?? 99) { best = t - lens.maxX }
    return best
}

func synthetic(_ n: Int) -> [Blk] {
    var g = SystemRandomNumberGenerator(), out: [Blk] = []
    for i in 0..<n {
        let col = i % 2, x = CGFloat(72 + col * 348) + CGFloat.random(in: -1...1, using: &g)
        let lines = Int.random(in: 1...9, using: &g)
        out.append(Blk(r: CGRect(x: x, y: CGFloat(i / 2) * 120, width: 325 + CGFloat.random(in: -1...1, using: &g), height: CGFloat(lines) * 14), lines: lines))
    }
    return out
}

func time(_ label: String, _ runs: Int, _ body: () -> Void) {
    for _ in 0..<(runs / 10) { body() }
    let t0 = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<runs { body() }
    let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(runs)
    print(String(format: "%-46s %9.2f us", (label as NSString).utf8String!, dt / 1000))
}

var sink = 0
for n in [12, 60, 200, 1000] {
    let b = synthetic(n)
    time("columns(blocks) n=\(n)", n >= 1000 ? 2000 : 20000) { sink &+= columns(b).count }
}
let cols = columns(synthetic(60))
let tl = cols.map(\.left), tr = cols.map(\.right)
var x: CGFloat = 0
time("nearest(lens) per drag frame, \(cols.count) columns", 2_000_000) { x += 0.37; sink &+= nearest(CGRect(x: 60 + x.truncatingRemainder(dividingBy: 700), y: 0, width: 300, height: 250), targetsLeft: tl, targetsRight: tr) == nil ? 0 : 1 }
print("sink", sink)
