// shapestab: the stability probe of docs/design/lens-shapes.md section 13, on LensShape alone (nothing else is compiled in).
//   swiftc -O -o /tmp/stability tools/first-lens/shapes/stability/main.swift Core/Sources/MwoyeoCore/LensShape.swift
//   stability hero <hero.txt>                              the five stops of the film stage on each read: kind and rect
//   stability sweep <hero.txt> <read>                      the read moved (dy 0..7, dx 0..3, 1 and 0.888) and jittered by 0.5 .. 3 pt: wrong answers per stop
//   stability why <hero.txt> <read> <amount> <stop>        the jitters that flip a stop, each with LensShape.explain
//   stability flip <scenes.txt> <amount> <seeds>           per scene: the kind at each block's centre, unjittered against jittered
//   stability grid <scenes.txt> <step>                     every grid position's kind and rect (diff two builds)
//   stability cost <scenes.txt> <scene> <cut>              us per choose, all blocks inside against a window that leaves the left `cut` pt out
//   stability at <scenes.txt> <scene> <x> <y>              explain at a point
// hero.txt is `data/shapes/hero/hero.txt` (herofix.py): `scene <name> <w> <h> <dy> <zoom> <n>`, then `x y w h lines hx hy hw hh` (`-` for no head).
import CoreGraphics
import Foundation
// shapestab scratch harness: hero reads, sweeps, and the 53-scene grid.
typealias Block = LensShape.Block
struct Read { var name: String; var size: CGSize; var dy: CGFloat; var zoom: CGFloat; var blocks: [Block] }
func loadHero(_ path: String) -> [Read] {
    var out: [Read] = []
    for line in (try! String(contentsOfFile: path, encoding: .utf8)).split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        if f.first == "scene" { out.append(Read(name: f[1], size: CGSize(width: Double(f[2])!, height: Double(f[3])!), dy: CGFloat(Double(f[4])!), zoom: CGFloat(Double(f[5])!), blocks: [])); continue }
        guard f.count >= 9, let x = Double(f[0]) else { continue }
        let head = f[5] == "-" ? nil : CGRect(x: Double(f[5])!, y: Double(f[6])!, width: Double(f[7])!, height: Double(f[8])!)
        out[out.count - 1].blocks.append(Block(core: CGRect(x: x, y: Double(f[1])!, width: Double(f[2])!, height: Double(f[3])!), lines: Int(f[4])!, head: head))
    }
    return out
}
struct Scene { var name: String; var size: CGSize; var blocks: [Block] }
func loadScenes(_ path: String) -> [Scene] {
    var out: [Scene] = []
    for line in (try! String(contentsOfFile: path, encoding: .utf8)).split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: false)
        if f.first == "scene" { out.append(Scene(name: String(f[1]), size: CGSize(width: Double(f[3])!, height: Double(f[4])!), blocks: [])); continue }
        if f.count >= 5, let x = Double(f[0]), let y = Double(f[1]), let w = Double(f[2]), let h = Double(f[3]), let n = Int(f[4]) {
            out[out.count - 1].blocks.append(Block(core: CGRect(x: x, y: y, width: w, height: h), lines: n))
        }
    }
    return out
}
let bounds = CGRect(x: 0, y: 61, width: 1512, height: 839)
struct Stop { let name: String; let x: CGFloat; let y: CGFloat; let kind: LensShape.Kind }
func stops(_ zoom: CGFloat) -> [Stop] {
    [Stop(name: "heading", x: 240, y: 64, kind: .group), Stop(name: "thread", x: 770, y: 176, kind: .thread),
     Stop(name: "table", x: 1236, y: 140, kind: .table), Stop(name: "subtitles", x: 1240, y: 492, kind: .subtitles),
     Stop(name: "dialog", x: 1180, y: zoom == 1 ? 754 : 850, kind: .dialog)]
}
func pointer(_ s: Stop, _ zoom: CGFloat, _ dy: CGFloat = 0) -> CGPoint { CGPoint(x: s.x * zoom, y: s.y * zoom + 61 + dy) }
func desc(_ s: LensShape.Shape?) -> String { s.map { "\($0.kind.rawValue) \(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))" } ?? "ghost" }
func moved(_ blocks: [Block], dx: CGFloat = 0, dy: CGFloat = 0, zoom: CGFloat = 1) -> [Block] {
    func at(_ r: CGRect) -> CGRect { CGRect(x: r.minX * zoom + dx, y: (r.minY - 61) * zoom + 61 + dy, width: r.width * zoom, height: r.height * zoom) }
    return blocks.map { Block(core: at($0.core), lines: $0.lines, head: $0.head.map(at)) }
}
struct LCG { var s: UInt64; mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 11) / CGFloat(1 << 53) } }
func jittered(_ blocks: [Block], _ amount: CGFloat, _ seed: UInt64) -> [Block] {
    var rng = LCG(s: seed)
    func off() -> CGFloat { (rng.next() * 2 - 1) * amount }
    return blocks.map { b in
        let x = off(), y = off(), w = off(), h = off()
        return Block(core: CGRect(x: b.core.minX + x, y: b.core.minY + y, width: b.core.width + w, height: b.core.height + h), lines: b.lines,
                     head: b.head.map { CGRect(x: $0.minX + x, y: $0.minY + y, width: $0.width, height: $0.height) })
    }
}
func kind(_ blocks: [Block], _ p: CGPoint) -> String { LensShape.choose(blocks: blocks, pointer: p, bounds: bounds)?.kind.rawValue ?? "ghost" }

let a = CommandLine.arguments
switch a[1] {
case "hero":
    for r in loadHero(a[2]) {
        let m = LensShape.Map(blocks: r.blocks)
        print(r.name.padding(toLength: 5, withPad: " ", startingAt: 0), stops(r.zoom).map { "\($0.name)=" + desc(LensShape.choose(m, pointer: pointer($0, r.zoom, r.dy), bounds: bounds)) }.joined(separator: " ; "))
    }
case "sweep":  // sweep <hero.txt> <read> : shifts, zoom, jitter amounts
    let r = loadHero(a[2]).first { $0.name == a[3] }!
    var bad: [String: Int] = [:], total = 0
    for dy in 0...7 { for dx in 0...3 { for z in [CGFloat(1), 0.887831] {
        let bl = moved(r.blocks, dx: CGFloat(dx), dy: CGFloat(dy), zoom: z)
        for s in stops(1) { total += 1; let k = kind(bl, pointer(s, z)); if k != s.kind.rawValue { bad["shift \(s.name)->\(k)", default: 0] += 1 } }
    } } }
    print("shift: \(total) cases, bad:", bad.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))
    for amount in [CGFloat(0.5), 1, 1.5, 2, 3] {
        var bad: [String: Int] = [:]; total = 0
        for seed in 1...200 {
            let bl = jittered(r.blocks, amount, UInt64(seed))
            for s in stops(r.zoom) { total += 1; let k = kind(bl, pointer(s, r.zoom, r.dy)); if k != s.kind.rawValue { bad["\(s.name)->\(k)", default: 0] += 1 } }
        }
        print("jitter \(amount): \(total) cases, bad:", bad.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", "))
    }
case "grid":  // grid <scenes.txt> <step>
    let step = CGFloat(Double(a[3])!)
    for sc in loadScenes(a[2]) {
        let map = LensShape.Map(blocks: sc.blocks), b = CGRect(origin: .zero, size: sc.size)
        var y = step / 2
        while y < b.height { var x = step / 2; while x < b.width {
            let s = LensShape.choose(map, pointer: CGPoint(x: x, y: y), bounds: b)
            print(sc.name, Int(x), Int(y), s.map { "\($0.kind.rawValue) \($0.rect) a\($0.anchor)" } ?? "ghost")
            x += step }; y += step }
    }
case "why":  // why <hero.txt> <read> <amount> <stop>: the seeds where the stop flips, with LensShape.explain of the first six
    let r = loadHero(a[2]).first { $0.name == a[3] }!
    let amount = CGFloat(Double(a[4])!)
    let s = stops(r.zoom).first { $0.name == a[5] }!
    var shown = 0
    for seed in 1...200 {
        let bl = jittered(r.blocks, amount, UInt64(seed))
        let p = pointer(s, r.zoom, r.dy)
        let sh = LensShape.choose(blocks: bl, pointer: p, bounds: bounds)
        if sh?.kind != s.kind && shown < 6 {
            shown += 1
            print("seed", seed, desc(sh))
            for l in LensShape.explain(LensShape.Map(blocks: bl), pointer: p, bounds: bounds) { print("   ", l) }
        }
    }
case "flip":  // flip <scenes.txt> <amount> <seeds>: kind at each block's centre, unjittered vs jittered
    let amount = CGFloat(Double(a[3])!), seeds = Int(a[4])!
    var all = 0, allFlip = 0
    for sc in loadScenes(a[2]) {
        let b = CGRect(origin: .zero, size: sc.size)
        let base = LensShape.Map(blocks: sc.blocks)
        var n = 0, flips = 0, kinds: [String: Int] = [:]
        for blk in sc.blocks {
            let p = CGPoint(x: blk.core.midX, y: blk.core.midY)
            let k0 = LensShape.choose(base, pointer: p, bounds: b)?.kind.rawValue ?? "ghost"
            for seed in 1...seeds {
                let k1 = LensShape.choose(blocks: jittered(sc.blocks, amount, UInt64(seed)), pointer: p, bounds: b)?.kind.rawValue ?? "ghost"
                n += 1
                if k1 != k0 { flips += 1; kinds["\(k0)>\(k1)", default: 0] += 1 }
            }
        }
        all += n; allFlip += flips
        if flips > 0 { print(sc.name.padding(toLength: 28, withPad: " ", startingAt: 0), "flips", flips, "of", n, kinds.sorted { $0.key < $1.key }.map { "\($0.key) x\($0.value)" }.joined(separator: ", ")) }
    }
    print("TOTAL flips", allFlip, "of", all)
case "cost":  // cost <scenes.txt> <scene> <left cut pt>: us per choose, all blocks inside vs a window that leaves some outside
    let sc = loadScenes(a[2]).first { $0.name == a[3] }!
    let cut = CGFloat(Double(a[4])!)
    let map = LensShape.Map(blocks: sc.blocks)
    func run(_ b: CGRect) -> Double {
        var pts: [CGPoint] = []
        var y: CGFloat = 5; while y < b.height { var x: CGFloat = b.minX + 5; while x < b.maxX { pts.append(CGPoint(x: x, y: y)); x += 23 }; y += 17 }
        let t0 = DispatchTime.now().uptimeNanoseconds
        var n = 0
        for _ in 0..<5 { for p in pts { if LensShape.choose(map, pointer: p, bounds: b) != nil { n += 1 } } }
        let dt = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1000
        return dt / Double(5 * pts.count)
    }
    let full = CGRect(origin: .zero, size: sc.size)
    print(String(format: "all inside: %.1f us/choose   window with blocks outside (left %g pt cut): %.1f us/choose; blocks outside: %d of %d", run(full), cut, run(CGRect(x: cut, y: 0, width: sc.size.width - cut, height: sc.size.height)),
                 map.blocks.filter { $0.core.maxX <= cut }.count, map.blocks.count))
case "at":  // at <scenes.txt> <scene> <x> <y>: explain, then the blocks
    let sc = loadScenes(a[2]).first { $0.name == a[3] }!
    let map = LensShape.Map(blocks: sc.blocks), b = CGRect(origin: .zero, size: sc.size)
    for l in LensShape.explain(map, pointer: CGPoint(x: Double(a[4])!, y: Double(a[5])!), bounds: b) { print(l) }
    for (i, bl) in map.blocks.enumerated() { print(i, bl.core, bl.lines) }
default: break
}
