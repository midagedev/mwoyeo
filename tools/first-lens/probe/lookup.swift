// first117: what one mouseMoved costs. The target choice of hover.py, in Swift with the data layout the Core owner would have:
// a Map built once per read (columns, each with its member blocks sorted by top), and `choose` per pointer position: pick the column by x,
// binary-search the anchor by y (signed distance, with the held anchor's hysteresis), extend down over the members until the height budget.
// Timed with swiftc -O on this Mac, 2,000,000 random pointer positions per size; the map build is timed on its own (median of 200).
import CoreGraphics
import Foundation

struct Blk { var r: CGRect; var lines: Int }
struct Col { var left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat; var members: [Blk] }
struct Map {
    var cols: [Col]
    init(_ blocks: [Blk]) {
        // evidence + stacks as ColumnFit.columns (tol 6, support 4, split 24), then every block inside a column's x range is a member
        let ev = blocks.filter { $0.lines >= 2 }.sorted { $0.r.minX < $1.r.minX }
        var stacks: [[Blk]] = [], cur: [Blk] = []
        for b in ev { if let l = cur.last, b.r.minX - l.r.minX > 6 { stacks.append(cur); cur = [] }; cur.append(b) }
        if !cur.isEmpty { stacks.append(cur) }
        var out: [Col] = []
        for s in stacks where s.reduce(0, { $0 + $1.lines }) >= 4 {
            let left = s.map { $0.r.minX }.sorted()[s.count / 2], right = s.map { $0.r.maxX }.max()!
            let mem = blocks.filter { $0.r.minX >= left - 8 && $0.r.maxX <= right + 8 }.sorted { $0.r.minY < $1.r.minY }
            out.append(Col(left: left, right: right, top: mem.first!.r.minY, bottom: mem.map { $0.r.maxY }.max()!, members: mem))
        }
        cols = out.sorted { $0.left < $1.left }
    }
    static let pad: CGFloat = 6, slack: CGFloat = 12, gap: CGFloat = 40, switchBy: CGFloat = 8, brk: CGFloat = 44
    func choose(_ p: CGPoint, held: Int?, area: CGFloat = 560 * 320) -> (CGRect, Int)? {
        var ci = -1; var best = CGFloat.infinity
        for (i, c) in cols.enumerated() {
            let lo = c.left - Self.pad - Self.slack, hi = c.right + Self.pad + Self.slack
            guard p.x >= lo && p.x <= hi else { continue }
            let d = max(0, max(c.left - Self.pad - p.x, p.x - (c.right + Self.pad)))
            if d < best { best = d; ci = i }
        }
        guard ci >= 0 else { return nil }
        let c = cols[ci], m = c.members
        func score(_ b: Blk) -> CGFloat { p.y >= b.r.minY && p.y <= b.r.maxY ? min(p.y - b.r.minY, b.r.maxY - p.y) : -min(abs(p.y - b.r.minY), abs(p.y - b.r.maxY)) }
        // the member whose top is the last one above the pointer, and its neighbours: the best score is one of the three
        var lo = 0, hi = m.count
        while lo < hi { let mid = (lo + hi) / 2; if m[mid].r.minY <= p.y { lo = mid + 1 } else { hi = mid } }
        var a = -1; var s = -CGFloat.infinity
        for i in max(0, lo - 2)...min(m.count - 1, lo + 1) { let v = score(m[i]); if v > s { s = v; a = i } }
        if let h = held, h >= 0, h < m.count, h != a, score(m[h]) >= -Self.gap, s - score(m[h]) < Self.switchBy { a = h; s = score(m[h]) }
        guard a >= 0, s >= -Self.gap else { return nil }
        let w = c.right - c.left + 2 * Self.pad, H = max(160, min(560, area / w))
        let top = m[a].r.minY; var bottom = m[a].r.maxY, j = a
        while j + 1 < m.count, bottom - top < H, m[j + 1].r.minY - bottom <= Self.brk {
            let n = m[j + 1]
            if n.r.maxY - top > H && (H - (bottom - top)) < n.r.height / 2 { break }
            bottom = n.r.maxY; j += 1
        }
        return (CGRect(x: c.left - Self.pad, y: top, width: w, height: bottom - top), a)
    }
}

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
var seed: UInt64 = 88172645463325252
func rnd() -> CGFloat { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return CGFloat(seed % 100000) / 100000 }

// two columns of n paragraph blocks (3 lines each, 14 pt lines, 10 pt gaps) and a few one-line headings and sidebar items
func page(_ n: Int) -> [Blk] {
    var b: [Blk] = []
    for col in 0..<2 {
        var y: CGFloat = 80
        for i in 0..<n {
            if i % 5 == 0 { b.append(Blk(r: CGRect(x: 72 + CGFloat(col) * 348, y: y, width: 200, height: 14), lines: 1)); y += 24 }
            b.append(Blk(r: CGRect(x: 72 + CGFloat(col) * 348, y: y, width: 325, height: 45), lines: 3)); y += 55
        }
    }
    return b
}
print("blocks  map build (us, median of 200)   choose (ns/call, held anchor, random pointer)")
for n in [6, 30, 100, 400] {
    let blocks = page(n)
    var ts: [Double] = []
    for _ in 0..<200 { let t = now(); let m = Map(blocks); ts.append(Double(now() - t) / 1000); if m.cols.isEmpty { print("no cols") } }
    ts.sort()
    let map = Map(blocks)
    let H = (map.cols.map { $0.bottom }.max() ?? 800)
    var held: Int? = nil, hits = 0
    let N = 2_000_000
    let t = now()
    for _ in 0..<N {
        let p = CGPoint(x: rnd() * 800, y: rnd() * H)
        if let r = map.choose(p, held: held) { held = r.1; hits += 1 } else { held = nil }
    }
    let ns = Double(now() - t) / Double(N)
    print("\(blocks.count)\t\(String(format: "%.1f", ts[100]))\t\t\t\(String(format: "%.0f", ns))\t(\(hits * 100 / N) % of positions have a target)")
}
