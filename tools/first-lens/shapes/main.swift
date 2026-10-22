// shapes117: the one-click lens's shapes measured on the picker's own reads (ocrdump's vn read, tofix.py -> scenes.txt). Built by
// build.sh with LensShape.swift and the column owner (LensTarget) with the seam of docs/design/lens-shapes.md section 6 (seam/): what the
// picker would do, the column target first and `LensShape.choose` where it has none. --plain measures the bare `column ?? shape` chain
// instead (the seam without its hold), --alone LensShape without the column owner, --column the column owner as it is today.
//
//   shapes measure <scenes.txt> [--plain] [--alone] [--column] [--why] [--mutant nohold]
//                                                                 per scene: claims, kinds, cuts, reversals, cost; --why prints each reversal
//   shapes sweep <scenes.txt> <scene> <path.json> [--plain]       per frame of the planned pointer path: kind and rect (30 fps)
//   shapes grid <scenes.txt> <scene> <step> [--plain]             every grid position's kind and rect (contact sheets)
//   shapes at <scenes.txt> <scene> <x> <y> [<x> <y> ...] [--plain]   the choice at each point in turn, the held choice carried along
import CoreGraphics
import Foundation

struct Scene { var name: String; var useCase: String; var size: CGSize; var blocks: [LensShape.Block] }

func load(_ path: String) -> [Scene] {
    var out: [Scene] = []
    for line in (try! String(contentsOfFile: path, encoding: .utf8)).split(separator: "\n") {
        let f = line.split(separator: " ", omittingEmptySubsequences: false)
        if f.first == "scene" {
            out.append(Scene(name: String(f[1]), useCase: String(f[2]), size: CGSize(width: Double(f[3])!, height: Double(f[4])!), blocks: []))
        } else if f.count >= 5, let x = Double(f[0]), let y = Double(f[1]), let w = Double(f[2]), let h = Double(f[3]), let n = Int(f[4]) {
            out[out.count - 1].blocks.append(LensShape.Block(core: CGRect(x: x, y: y, width: w, height: h), lines: n))
        }
    }
    return out
}

struct Pick { var kind: String; var rect: CGRect; var held: LensTarget.Target }

let args = CommandLine.arguments
let plain = args.contains("--plain")
let alone = args.contains("--alone")
let columnOnly = args.contains("--column")
let why = args.contains("--why")
let mutant = args.firstIndex(of: "--mutant").map { args[$0 + 1] }

struct Maps {
    var column: LensTarget.Map
    var shape: LensShape.Map
    init(_ s: Scene) {
        column = LensTarget.Map(blocks: s.blocks.map { ColumnFit.Block(core: $0.core, lines: $0.lines) })
        shape = LensShape.Map(blocks: s.blocks)
    }
}

func cutsAny(_ r: CGRect, _ blocks: [LensShape.Block]) -> Bool { blocks.contains { LensShape.cuts(r, $0.core) } }

func ghost(_ p: CGPoint, _ b: CGRect) -> CGRect {
    let w = min(560, b.width), h = min(320, b.height)
    return CGRect(x: min(max(p.x - w / 2, b.minX), b.maxX - w), y: min(max(p.y - h / 2, b.minY), b.maxY - h), width: w, height: h)
}

func pick(_ m: Maps, _ blocks: [LensShape.Block], _ p: CGPoint, _ held: LensTarget.Target?, _ bounds: CGRect) -> Pick? {
    let h = mutant == "nohold" ? nil : held
    func shape(_ q: CGPoint, _ hs: LensShape.Shape?) -> LensShape.Shape? { LensShape.choose(m.shape, pointer: q, bounds: bounds, held: hs) }
    let t: LensTarget.Target?
    if columnOnly {
        t = LensTarget.choose(m.column, pointer: p, held: h, bounds: bounds)
    } else if alone {
        t = shape(p, h?.shape).map(LensTarget.Target.init(shape:))
    } else if plain {
        t = LensTarget.choose(m.column, pointer: p, held: h?.shape == nil ? h : nil, bounds: bounds) ?? shape(p, h?.shape).map(LensTarget.Target.init(shape:))
    } else {
        t = LensTarget.choose(m.column, pointer: p, held: h, bounds: bounds, fallback: shape)
    }
    return t.map { Pick(kind: $0.shape?.kind.rawValue ?? "column", rect: $0.rect, held: $0) }
}

func near(_ blocks: [LensShape.Block], _ p: CGPoint) -> Bool {
    blocks.contains { b in
        let dx = max(b.core.minX - p.x, 0, p.x - b.core.maxX), dy = max(b.core.minY - p.y, 0, p.y - b.core.maxY)
        return dx * dx + dy * dy <= LensShape.reach * LensShape.reach
    }
}

func r1(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }
func rs(_ r: CGRect) -> String { "\(r1(r.minX)) \(r1(r.minY)) \(r1(r.maxX)) \(r1(r.maxY))" }

/// A deterministic jitter source (no Foundation randomness: the numbers are a gate's).
struct LCG { var s: UInt64; mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(s >> 11) / CGFloat(1 << 53) } }

func measure(_ scenes: [Scene]) {
    print("scene                      category  blocks near  claim%  column  table thread dialog  subs  group  cut%  changes rev(h) rev(no h)  us/choose  build_us(shape,column)")
    var all = (near: 0, claim: 0, cut: 0, rev: 0)
    for s in scenes {
        let m = Maps(s), bounds = CGRect(origin: .zero, size: s.size)
        // The map's cost: the shapes' map and the column owner's, built 200 times each (once per picker open, in the read's shadow).
        var buildShape = 0.0, buildColumn = 0.0
        for _ in 0..<200 {
            let t0 = DispatchTime.now().uptimeNanoseconds
            _ = LensShape.Map(blocks: s.blocks)
            let t1 = DispatchTime.now().uptimeNanoseconds
            _ = LensTarget.Map(blocks: s.blocks.map { ColumnFit.Block(core: $0.core, lines: $0.lines) })
            buildShape += Double(t1 - t0); buildColumn += Double(DispatchTime.now().uptimeNanoseconds - t1)
        }
        var nNear = 0, nClaim = 0, nCut = 0
        var kinds: [String: Int] = [:]
        var t = 0.0, calls = 0
        var y: CGFloat = 5
        while y < s.size.height {
            var x: CGFloat = 5
            while x < s.size.width {
                let p = CGPoint(x: x, y: y)
                if near(s.blocks, p) {
                    nNear += 1
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    let r = pick(m, s.blocks, p, nil, bounds)
                    t += Double(DispatchTime.now().uptimeNanoseconds - t0); calls += 1
                    if let r {
                        nClaim += 1; kinds[r.kind, default: 0] += 1
                        if cutsAny(r.rect, s.blocks) { nCut += 1 }
                    }
                }
                x += 10
            }
            y += 10
        }
        // Stability: walk the pointer along every 10 pt row and column at 1 pt with the held choice; at every change, 200 jittered
        // positions within 2 pt, held, counted for reversals (A -> B -> A); the same without the hold (the mutant's measure).
        var changes = 0, revH = 0, revN = 0, revSeam = 0, revEdge = 0
        var rng = LCG(s: 1)
        func key(_ p: Pick?) -> String { p.map { "\($0.kind) \(rs($0.rect))" } ?? "ghost" }
        for vertical in [false, true] {
            var line: CGFloat = 5
            while line < (vertical ? s.size.width : s.size.height) {
                var held: LensTarget.Target? = nil, last = "ghost", along: CGFloat = 0
                while along < (vertical ? s.size.height : s.size.width) {
                    let p = vertical ? CGPoint(x: line, y: along) : CGPoint(x: along, y: line)
                    let r = pick(m, s.blocks, p, held, bounds)
                    let k = key(r)
                    if k != last {
                        changes += 1
                        for hold in [true, false] {
                            var h: LensTarget.Target? = held, seq: [String] = [], qs: [CGPoint] = []
                            for _ in 0..<200 {
                                let q = CGPoint(x: p.x + (rng.next() * 4 - 2), y: p.y + (rng.next() * 4 - 2))
                                let rr = pick(m, s.blocks, q, hold ? h : nil, bounds)
                                seq.append(key(rr)); qs.append(q); h = rr?.held
                            }
                            let rev = (2..<seq.count).filter { seq[$0] == seq[$0 - 2] && seq[$0] != seq[$0 - 1] }
                            if why, hold, let i = rev.first {
                                print("  rev \(s.name) at \(r1(p.x)),\(r1(p.y)) [\(vertical ? "down" : "across") from \(last)]: \(seq[i - 1]) <-> \(seq[i]) x\(rev.count)"
                                      + " q=" + (i - 2...i).map { "\(r1(qs[$0].x)),\(r1(qs[$0].y))" }.joined(separator: " "))
                            }
                            if hold {
                                revH += rev.count
                                revSeam += rev.filter { seq[$0].hasPrefix("column") != seq[$0 - 1].hasPrefix("column") && seq[$0] != "ghost" && seq[$0 - 1] != "ghost" }.count
                                revEdge += rev.filter { seq[$0] == "ghost" || seq[$0 - 1] == "ghost" }.count
                            } else { revN += rev.count }
                        }
                    }
                    held = r?.held; last = k
                    along += 1
                }
                line += 10
            }
        }
        func pc(_ k: String) -> String { String(format: "%5.0f%%", 100 * Double(kinds[k, default: 0]) / Double(max(nNear, 1))) }
        print(s.name.padding(toLength: 27, withPad: " ", startingAt: 0) + s.useCase.padding(toLength: 9, withPad: " ", startingAt: 0)
              + String(format: " %6d %5d %6.0f%% ", s.blocks.count, nNear, 100 * Double(nClaim) / Double(max(nNear, 1)))
              + pc("column") + " " + pc("table") + " " + pc("thread") + " " + pc("dialog") + " " + pc("subtitles") + " " + pc("group")
              + String(format: " %5.1f%% %7d %6d %9d %10.2f  seam=%d edge=%d", 100 * Double(nCut) / Double(max(nClaim, 1)), changes, revH, revN, t / Double(max(calls, 1)) / 1000, revSeam, revEdge)
              + String(format: "  build=%.0f,%.0f", buildShape / 200 / 1000, buildColumn / 200 / 1000))
        all.near += nNear; all.claim += nClaim; all.cut += nCut; all.rev += revH
    }
    print(String(format: "ALL near=%d claim=%.1f%% cut=%.2f%% reversals(h)=%d", all.near, 100 * Double(all.claim) / Double(max(all.near, 1)),
                 100 * Double(all.cut) / Double(max(all.claim, 1)), all.rev))
}

func grid(_ s: Scene, step: CGFloat) {
    let m = Maps(s), bounds = CGRect(origin: .zero, size: s.size)
    var y = step / 2
    while y < s.size.height {
        var x = step / 2
        while x < s.size.width {
            let p = CGPoint(x: x, y: y)
            if let r = pick(m, s.blocks, p, nil, bounds) { print("\(r1(x)) \(r1(y)) \(r.kind) \(rs(r.rect)) \(cutsAny(r.rect, s.blocks) ? 1 : 0)") }
            else if near(s.blocks, p) { print("\(r1(x)) \(r1(y)) ghost") }
            x += step
        }
        y += step
    }
}

/// path.json: {"fps": 30, "points": [{"x", "y", "dwell", "move"}...]}: the pointer rests `dwell` s at each point and takes `move` s
/// (smoothstep) to the next.
func sweep(_ s: Scene, path: String) {
    let json = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
    let fps = (json["fps"] as? Double) ?? 30
    let pts = (json["points"] as! [[String: Any]]).map { (CGPoint(x: $0["x"] as! Double, y: $0["y"] as! Double), $0["dwell"] as? Double ?? 0.4, $0["move"] as? Double ?? 0.5, $0["label"] as? String ?? "") }
    var frames: [(CGPoint, String)] = []
    for (i, (p, dwell, move, label)) in pts.enumerated() {
        for _ in 0..<Int((dwell * fps).rounded()) { frames.append((p, label)) }
        guard i + 1 < pts.count else { break }
        let q = pts[i + 1].0, n = Int((move * fps).rounded())
        for k in 1...max(n, 1) {
            let u = CGFloat(k) / CGFloat(max(n, 1)), e = u * u * (3 - 2 * u)
            frames.append((CGPoint(x: p.x + (q.x - p.x) * e, y: p.y + (q.y - p.y) * e), "->"))
        }
    }
    let m = Maps(s), bounds = CGRect(origin: .zero, size: s.size)
    var held: LensTarget.Target? = nil
    print("# frame t x y kind x0 y0 x1 y1 cut planned")
    for (f, (p, label)) in frames.enumerated() {
        let r = pick(m, s.blocks, p, held, bounds)
        held = r?.held
        let rect = r?.rect ?? ghost(p, bounds)
        print("\(f) \(String(format: "%.3f", Double(f) / fps)) \(r1(p.x)) \(r1(p.y)) \(r?.kind ?? "ghost") \(rs(rect)) \(r.map { cutsAny($0.rect, s.blocks) ? 1 : 0 } ?? 0) \(label)")
    }
}

/// The choice at each given point in turn, the held choice carried from one to the next (a debugger for a reversal: no debugger attach).
func at(_ s: Scene, _ coords: [Double]) {
    let m = Maps(s), bounds = CGRect(origin: .zero, size: s.size)
    var held: LensTarget.Target? = nil
    for i in stride(from: 0, to: coords.count - 1, by: 2) {
        let p = CGPoint(x: coords[i], y: coords[i + 1])
        let r = pick(m, s.blocks, p, held, bounds)
        print("\(r1(p.x)),\(r1(p.y)) held=\(held.map { $0.shape.map { "shape:\($0.kind.rawValue)#\($0.anchor)" } ?? "column\($0.column)#\($0.anchor)" } ?? "-") -> \(r?.kind ?? "ghost") \(r.map { rs($0.rect) } ?? "")")
        held = r?.held
    }
}

let scenes = load(args[2])
switch args[1] {
case "measure": measure(scenes)
case "grid": grid(scenes.first { $0.name == args[3] }!, step: CGFloat(Double(args[4])!))
case "sweep": sweep(scenes.first { $0.name == args[3] }!, path: args[4])
case "at": at(scenes.first { $0.name == args[3] }!, args[4...].compactMap { Double($0) })
default: print("usage: shapes measure|grid|sweep <scenes.txt> ...")
}
