import CoreGraphics
import XCTest
@testable import MwoyeoCore

/// The membrane's gates (motion contract §9.7.2, §10). The prototype's organic scenes (`proto.html`, `measure.py`, `organic.py` of round motion117)
/// are ported to a fake clock at 240 Hz: the same pointer keys, the same targets, the rigid frame on its own spring. What is measured is the drawn
/// path itself (sampled, against a rigid rounded rect built by CoreGraphics), not the skin's own numbers, which are only cross-checked.
final class LensSkinTests: XCTestCase {
    // MARK: - The scenes (page px, y down, 2 px = 1 pt, as the prototype; `rect` turns them into pt, y up)

    private static let pt = 2.0, dt = 1.0 / 240
    private static let quick = 2 * Double.pi / 30, fit = 0.30, calm = 0.50   // LensMotion's springs (round fit117impl owns them; response, s)

    private static func rect(_ r: [Double]) -> CGRect {
        CGRect(x: r[0] / pt, y: -r[3] / pt, width: (r[2] - r[0]) / pt, height: (r[3] - r[1]) / pt)
    }

    /// The pointer on a minimum-jerk path between keys [t, x, y].
    private static func pointer(_ keys: [[Double]], _ t: Double) -> (x: Double, y: Double) {
        if t <= keys[0][0] { return (keys[0][1], keys[0][2]) }
        for i in 1..<keys.count where t <= keys[i][0] {
            let u = (t - keys[i - 1][0]) / (keys[i][0] - keys[i - 1][0]), s = u * u * u * (10 - 15 * u + 6 * u * u)
            return (keys[i - 1][1] + (keys[i][1] - keys[i - 1][1]) * s, keys[i - 1][2] + (keys[i][2] - keys[i - 1][2]) * s)
        }
        return (keys[keys.count - 1][1], keys[keys.count - 1][2])
    }

    private enum Event {
        case begin(LensSkin.Moment)
        case commit(target: CGRect, click: CGPoint)
    }
    private enum FrameModel {
        case target                                   // the hand's frame: the window is where the pointer put it
        case spring(Double)                           // critically damped on the target, additive (a new target keeps the velocity)
        case springUntil(Double, at: Double, then: CGRect)
        case custom((Double) -> CGRect)
    }
    private struct Scene {
        var dur: Double
        var target: (Double) -> CGRect
        var frame: FrameModel
        var hand: (Double) -> LensSkin.Hand = { _ in .none }
        var events: [(i: Int, what: Event)] = []
        var cursor: ((Double) -> CGPoint)?
    }

    /// 1. The bottom-right corner dragged across the column's right edge and back; the edge is the hand's and the snap pulls it (8 pt in, 12 pt out).
    private static func resize() -> Scene {
        let l0 = [250.0, 1128, 640, 1400], target = 805.0, off = 8.0, down = 0.75, up = 3.95
        let keys: [[Double]] = [[0, 560, 1480], [0.5, 632, 1392], [0.75, 632, 1392], [1.65, 788, 1396], [2.2, 792, 1397], [2.75, 834, 1398],
                                [3.15, 834, 1398], [3.7, 804, 1398], [3.95, 804, 1398], [4.6, 720, 1500], [5.6, 720, 1500]]
        var snaps: [(t: Double, on: Bool)] = []
        var on = false
        for i in 0...Int(up / dt) {
            let t = Double(i) * dt, d = abs(pointer(keys, t).x + off - target)
            if !on && d <= 8 * pt { on = true; if t >= down { snaps.append((t, true)) } } else if on && d > 12 * pt { on = false; if t >= down { snaps.append((t, false)) } }
        }
        func snapped(_ t: Double) -> Bool { snaps.last { t >= $0.t }?.on ?? false }
        func g(_ t: Double) -> CGRect {
            if t < down { return rect(l0) }
            let p = pointer(keys, min(t, up))
            return rect([l0[0], l0[1], snapped(t) ? target : p.x + off, p.y + off])
        }
        return Scene(dur: 5.6, target: g, frame: .target, hand: { $0 >= down && $0 < up ? .corner : .none })
    }

    /// 2. The lens carried by its top edge and dropped 7 pt, then 2.5 pt, off the column's left edge; a drop in reach settles onto it on `quick`.
    private static func settle() -> Scene {
        let l0 = [300.0, 1128, 700, 1400], target = 133.0, w = 400.0, h = 272.0
        let keys: [[Double]] = [[0, 560, 1300], [0.45, 470, 1126], [0.65, 470, 1126], [1.45, 310, 1134], [1.95, 317, 1136], [2.05, 317, 1136],
                                [3.0, 317, 1136], [3.6, 420, 1138], [4.3, 312, 1138], [4.45, 312, 1138], [5.0, 420, 1300], [5.8, 420, 1300]]
        let drags = [(down: 0.65, up: 2.05), (down: 3.0, up: 4.45)]
        var samples: [(Double, Double)] = [], settles: [(t: Double, from: Double, until: Double)] = []
        var x0 = l0[0], y0 = l0[1], grab: (d: Int, dx: Double, dy: Double, done: Bool)?, on = false
        for i in 0...Int(5.8 / dt + 1) {
            let t = Double(i) * dt, p = pointer(keys, t)
            if let d = drags.firstIndex(where: { t >= $0.down && t < $0.up }) {
                if grab?.d != d { grab = (d, p.x - x0, p.y - y0, false) }
                x0 = p.x - grab!.dx; y0 = p.y - grab!.dy
                let dist = abs(x0 - target)
                if !on && dist <= 8 * pt { on = true } else if on && dist > 12 * pt { on = false }
            } else if grab != nil && !grab!.done {
                grab!.done = true
                if on { settles.append((t, x0, drags.first { $0.down > t }?.down ?? 1e9)); x0 = target }
            }
            samples.append((x0, y0))
        }
        func at(_ t: Double) -> (x: Double, y: Double, settling: Bool) {
            var k = max(0, min(samples.count - 1, Int((t / dt).rounded())))
            if settles.contains(where: { t < $0.t && k >= Int(($0.t / dt).rounded()) }) { k -= 1 }
            let (x, y) = samples[k]
            if let s = settles.first(where: { t >= $0.t && t < $0.until }) {
                let w = 2 * Double.pi / quick, p = 1 - (1 + w * (t - s.t)) * exp(-w * (t - s.t))
                return (s.from + (target - s.from) * p, y, true)
            }
            return (x, y, false)
        }
        func frame(_ t: Double) -> CGRect { let p = at(t); return rect([p.x, p.y, p.x + w, p.y + h]) }
        func goal(_ t: Double) -> CGRect { let p = at(t); return rect([p.settling ? target : p.x, p.y, (p.settling ? target : p.x) + w, p.y + h]) }
        return Scene(dur: 5.8, target: goal, frame: .custom(frame),
                     hand: { t in drags.contains { t >= $0.down && t < $0.up } && !settles.contains { t >= $0.t && t < $0.until } ? .move : .none },
                     events: settles.map { (Int(($0.t / dt).rounded()), .begin(.drop)) },
                     cursor: { t in let p = pointer(keys, t); return CGPoint(x: p.x / pt, y: -p.y / pt) })
    }

    /// 3. A double-click on the ring fits the lens to the column (1.06 s); Undo Fit takes it back (3.90 s).
    private static func fitScene() -> Scene {
        let l0 = [300.0, 1128, 650, 1400], l1 = [133.0, 1128, 805, 1400]
        return Scene(dur: 6.0, target: { t in rect(t < 1.06 ? l0 : t < 3.9 ? l1 : l0) }, frame: .spring(fit),
                     events: [(Int((1.06 / dt).rounded(.up)), .begin(.fit)), (Int((3.9 / dt).rounded(.up)), .begin(.undoFit))])
    }

    /// 4. Auto Fit (1.4 s): not started by the person, on `calm`, bows at 0.6.
    private static func autoScene() -> Scene {
        let l0 = [133.0, 1128, 560, 1400], l1 = [133.0, 1128, 805, 1400]
        return Scene(dur: 4.6, target: { t in rect(t < 1.4 ? l0 : l1) }, frame: .spring(calm), events: [(Int((1.4 / dt).rounded(.up)), .begin(.autoFit))])
    }

    /// 5. One-click placement: the spotlight hops between targets (the hover), then the click commits the lens at the last of them.
    private static func placeScene() -> Scene {
        let col = [133.0, 756, 805, 1028], para = [133.0, 1126, 805, 1526], head = [829.0, 1127, 1502, 1337], column = [133.0, 756, 805, 1526]
        let hops: [(i: Int, r: [Double])] = [(292, para), (565, head), (792, para), (844, column), (991, para)]
        let release = 4.85, press = Int((release / dt).rounded())
        func goal(_ t: Double) -> CGRect { rect(hops.last { Double($0.i) * dt <= t + 1e-9 }?.r ?? col) }
        let keys: [[Double]] = [[4.0, 100, 1300], [4.5, 520, 1330], [5.9, 520, 1330]]
        let click = pointer(keys, release)
        return Scene(dur: 7.2, target: { t in t >= release ? rect(para) : goal(t) }, frame: .springUntil(quick, at: release, then: rect(para)),
                     events: hops.map { ($0.i, .begin(.pickerHop)) } + [(press, .commit(target: rect(para), click: CGPoint(x: click.x / pt, y: -click.y / pt)))])
    }

    // MARK: - The runner and its instrument

    private struct Sample {
        let t: Double, out: CGFloat, inward: CGFloat, bows: [CGFloat], elements: Int, hand: LensSkin.Hand, frame: CGRect, target: CGRect
        let handGap: CGFloat?, topGap: CGFloat?, metered: (peak: CGFloat, rest: Int, text: String), atRest: Bool
        var deviation: CGFloat { max(out, inward) }
    }

    private static func polyline(_ path: CGPath, steps: Int = 24) -> [CGPoint] {
        var pts: [CGPoint] = [], cur = CGPoint.zero
        path.applyWithBlock { e in
            let p = e.pointee.points
            switch e.pointee.type {
            case .moveToPoint, .addLineToPoint: cur = p[0]; pts.append(cur)
            case .addCurveToPoint:
                let a = cur, b = p[0], c = p[1], d = p[2]
                for k in 1...steps {
                    let s = CGFloat(k) / CGFloat(steps), u = 1 - s
                    pts.append(CGPoint(x: u * u * u * a.x + 3 * u * u * s * b.x + 3 * u * s * s * c.x + s * s * s * d.x,
                                       y: u * u * u * a.y + 3 * u * u * s * b.y + 3 * u * s * s * c.y + s * s * s * d.y))
                }
                cur = d
            default: break
            }
        }
        return pts
    }

    private static func elements(_ path: CGPath) -> [(type: CGPathElementType, points: [CGPoint])] {
        var out: [(CGPathElementType, [CGPoint])] = []
        path.applyWithBlock { e in
            let n = switch e.pointee.type { case .moveToPoint, .addLineToPoint: 1; case .addQuadCurveToPoint: 2; case .addCurveToPoint: 3; default: 0 }
            out.append((e.pointee.type, (0..<n).map { e.pointee.points[$0] }))
        }
        return out
    }

    /// The signed distance of `p` outside (+) or inside (−) a rounded rect.
    private static func sdf(_ p: CGPoint, _ r: CGRect, _ rad: CGFloat) -> CGFloat {
        let qx = abs(p.x - r.midX) - (r.width / 2 - rad), qy = abs(p.y - r.midY) - (r.height / 2 - rad)
        return hypot(max(qx, 0), max(qy, 0)) + min(max(qx, qy), 0) - rad
    }
    private static func distance(_ pts: [CGPoint], _ p: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count], dx = b.x - a.x, dy = b.y - a.y, l = dx * dx + dy * dy
            let u = l > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l)) : 0
            best = min(best, hypot(a.x + u * dx - p.x, a.y + u * dy - p.y))
        }
        return best
    }
    /// The highest point of the outline on the vertical through x.
    private static func top(_ pts: [CGPoint], at x: CGFloat) -> CGFloat {
        var y = -CGFloat.infinity
        for i in pts.indices {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            if (a.x - x) * (b.x - x) > 0 || a.x == b.x { continue }
            y = max(y, a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x))
        }
        return y
    }

    /// Drives the skin through a scene at `hz`, and measures the path it draws at every frame.
    private func run(_ scene: Scene, hz: Double = 240, moveBows: Bool = false, reduceMotion: Bool = false) -> [Sample] {
        let step = 1 / hz, ring: CGFloat = 1
        var skin = LensSkin(frame: scene.target(0), moveBows: moveBows)
        skin.reduceMotion = reduceMotion
        var f = LensSkin.edges(of: scene.target(0)), fv: [CGFloat] = [0, 0, 0, 0]
        var out: [Sample] = [], pending = scene.events.sorted { $0.i < $1.i }[...]
        for i in 0...Int(scene.dur / step) {
            let t = Double(i) * step
            while let event = pending.first, Double(event.i) * Self.dt <= t + 1e-9 {   // an event lands on the first frame at or after its time
                pending.removeFirst()
                switch event.what {
                case .begin(let moment): skin.begin(moment)
                case .commit(let target, let click): skin.commit(target: target, click: click)
                }
            }
            let g = scene.target(t), hand = scene.hand(t)
            skin.step(step, target: g, hand: hand)
            let frame: CGRect
            switch scene.frame {
            case .target: frame = g
            case .custom(let fn): frame = fn(t)
            case .spring(let r), .springUntil(let r, _, _):
                let goal = LensSkin.edges(of: g)
                for j in 0..<4 { (f[j], fv[j]) = LensSkin.advance(f[j], fv[j], to: goal[j], response: r, dt: CGFloat(step)) }
                frame = CGRect(x: f[0], y: f[3], width: f[2] - f[0], height: f[1] - f[3])
            }
            let shown: CGRect
            if case .springUntil(_, let at, let then) = scene.frame, t >= at { shown = then } else { shown = frame }
            let outline = skin.outline(around: shown)
            skin.record(outline)
            let path = outline.path(outset: ring), pts = Self.polyline(path)
            let rf = shown.insetBy(dx: -ring, dy: -ring), rigid = Self.polyline(CGPath(roundedRect: rf, cornerWidth: 13, cornerHeight: 13, transform: nil))
            let sd = pts.map { Self.sdf($0, rf, 13) }
            var gap: CGFloat?, topGap: CGFloat?
            if hand == .corner { let hc = CGPoint(x: rf.maxX, y: rf.minY); gap = Self.distance(pts, hc) - Self.distance(rigid, hc) }
            if hand == .move, let c = scene.cursor?(t) { topGap = abs(Self.top(pts, at: c.x) - rf.maxY) }
            out.append(Sample(t: t, out: max(0, sd.max() ?? 0), inward: max(0, -(sd.min() ?? 0)), bows: outline.bows, elements: Self.elements(path).count, hand: hand,
                              frame: shown, target: g, handGap: gap, topGap: topGap,
                              metered: (skin.meter.peak, Int((skin.meter.restAt * 1000).rounded()), skin.meter.summary), atRest: skin.isAtRest))
        }
        return out
    }

    /// What `organic.py` reads in a window: the farthest the outline got off the rigid ring, when, and when it was on it for good.
    private struct Reading { let out: CGFloat, inward: CGFloat, peak: CGFloat, peakMs: Double, restMs: Double }
    private func read(_ s: [Sample], _ a: Double, _ b: Double) -> Reading {
        let w = s.filter { $0.t >= a - 1e-9 && $0.t < b - 1e-9 }
        let k = w.indices.max { w[$0].deviation < w[$1].deviation }!
        let late = w.last { $0.deviation >= LensSkin.restBand }
        return Reading(out: w.map(\.out).max()!, inward: w.map(\.inward).max()!, peak: w[k].deviation, peakMs: (w[k].t - a) * 1000,
                       restMs: late.map { ($0.t - a + Self.dt) * 1000 } ?? 0)
    }

    /// The rows of §9.6, in the order of `LensSkin.choreography`, read from their scenes.
    private func readings() -> [(row: LensSkin.Row, got: Reading)] {
        let settle = run(Self.settle()), fit = run(Self.fitScene()), auto = run(Self.autoScene()), place = run(Self.placeScene()), resize = run(Self.resize())
        let stop = resize[(1..<resize.count).last { resize[$0].t < 3.95 && resize[$0].target != resize[$0 - 1].target }!].t
        let windows: [(Double, Double, [Sample])] = [(0.75, 3.95, resize), (2.05, 2.8, settle), (4.45, 5.2, settle), (1.06, 1.9, fit), (3.9, 4.6, fit),
                                                     (1.4, 2.4, auto), (292 / 240, 2.35, place), (565 / 240, 3.3, place), (844 / 240, 4.12, place), (4.85, 5.6, place)]
        return zip(LensSkin.choreography, windows).map { row, w in
            var got = read(w.2, w.0, w.1)
            if row.moment == .cornerDrag {   // the contract's rest is "after the hand stops": the last frame off the ring after the pointer's last move
                let late = resize.last { $0.t < 3.95 && $0.deviation >= LensSkin.restBand }
                got = Reading(out: got.out, inward: got.inward, peak: max(got.out, got.inward), peakMs: got.peakMs, restMs: max(0, (late?.t ?? stop) - stop + Self.dt) * 1000)
            }
            return (row, got)
        }
    }

    // MARK: - The skin

    /// §9.6 against what the ported scenes measure (±10 % and one frame). Prints one line per row; the report quotes them.
    func testChoreographyMatchesTable() {
        for (row, got) in readings() {
            let slack = Self.dt * 1000
            let line = String(format: "skin-table: %@ | %@ | peak %.2f (table %.2f) at %.0f ms (table %@) | rest %.0f ms (table %@%d)", row.moment.rawValue, row.label,
                              Double(got.peak), Double(row.peak), got.peakMs, row.peakMs.map(String.init) ?? "-", got.restMs, row.restIsBound ? "<= " : "", row.restMs)
            print(line)
            XCTAssertEqual(Double(got.peak), Double(row.peak), accuracy: 0.10 * Double(row.peak) + 0.05, line)
            // near its soft cap the peak is a flat top, so its time is only roughly placed: 30 ms
            if let ms = row.peakMs { XCTAssertEqual(got.peakMs, Double(ms), accuracy: max(0.10 * Double(ms), 30) + slack, line) }
            if row.restIsBound { XCTAssertLessThanOrEqual(got.restMs, Double(row.restMs), line) }
            else { XCTAssertEqual(got.restMs, Double(row.restMs), accuracy: 0.10 * Double(row.restMs) + slack, line) }
        }
    }

    func testCornerUnderTheHandIsExact() {
        let s = run(Self.resize()).compactMap(\.handGap)
        XCTAssertGreaterThan(s.count, 700)
        XCTAssertLessThanOrEqual(s.max()!, 0.5, "the ring at the hand's corner is no farther than the rigid ring's")
    }

    func testHeldTopEdgeIsExactUnderMove() {
        let gaps = run(Self.settle(), moveBows: true).compactMap(\.topGap)
        XCTAssertGreaterThan(gaps.count, 600)
        XCTAssertLessThanOrEqual(gaps.max()!, 0.25, "the held top edge is under the pointer")
        // and the other three do bow while carried, as the grid shows (out 3.75 / in 3.03 in the prototype)
        let carried = run(Self.settle(), moveBows: true).filter { $0.t >= 0.65 && $0.t < 2.05 }
        XCTAssertGreaterThan(carried.map(\.deviation).max()!, 2, "move bows on: the lens deforms while carried")
    }

    func testMoveBowsAreOffByDefault() {
        XCTAssertFalse(LensSkin.moveBows)
        let carried = run(Self.settle()).filter { $0.hand == .move }
        XCTAssertGreaterThan(carried.count, 300)
        XCTAssertLessThan(carried.map(\.deviation).max()!, 0.01, "carried, the outline is the frame")
        XCTAssertTrue(carried.allSatisfy { $0.bows.allSatisfy { $0 == 0 } })
    }

    func testCapsHoldInEveryScene() {
        for (name, scene, moveBows) in [("resize", Self.resize(), false), ("settle", Self.settle(), true), ("fit", Self.fitScene(), false),
                                        ("auto", Self.autoScene(), false), ("place", Self.placeScene(), false)] {
            let s = run(scene, moveBows: moveBows)
            let hand = s.filter { $0.hand != .none }.map(\.deviation).max() ?? 0
            let out = s.map(\.out).max()!, inward = s.map(\.inward).max()!
            print(String(format: "skin-caps: %@ | under the hand %.2f (<= 4) | out %.2f (<= 4) | in %.2f (<= 8)", name, Double(hand), Double(out), Double(inward)))
            XCTAssertLessThanOrEqual(hand, 4 + 0.01, "\(name): 4 pt under the hand")
            XCTAssertLessThanOrEqual(out, 4 + 0.01, "\(name): 4 pt out (the pill sits 6 pt above)")
            XCTAssertLessThanOrEqual(inward, 8 + 0.01, "\(name): 8 pt in")
        }
    }

    /// Every scripted change (a new target, the hand letting go, the commit) that is left alone for 0.5 s is back on the rigid ring (< 0.5 pt) by
    /// then. Auto Fit is the one change the person did not start: its frame takes 0.64 s to arrive and its row of §9.6 says 562 ms (checked there).
    func testBackOnTheRigidRingWithinHalfASecond() {
        for (name, scene, moveBows) in [("resize", Self.resize(), false), ("settle", Self.settle(), true), ("fit", Self.fitScene(), false),
                                        ("place", Self.placeScene(), false)] {
            let s = run(scene, moveBows: moveBows)
            let eventFrames = Set(scene.events.map { e in s.firstIndex { $0.t >= Double(e.i) * Self.dt - 1e-9 }! })
            let changes = (1..<s.count).filter {
                s[$0].target != s[$0 - 1].target || (s[$0 - 1].hand != .none && s[$0].hand == .none) || eventFrames.contains($0)
            }
            var worst = 0.0, counted = 0
            for (n, k) in changes.enumerated() {
                let next = n + 1 < changes.count ? changes[n + 1] : s.count
                if Double(next - k) * Self.dt < 0.5 + 1e-9 { continue }
                counted += 1
                let late = (k..<next).last { s[$0].deviation >= LensSkin.restBand }
                worst = max(worst, late.map { Double($0 + 1 - k) * Self.dt } ?? 0)
            }
            print(String(format: "skin-rest: %@ | worst %.3f s over %d changes with 0.5 s to spare (<= 0.5)", name, worst, counted))
            XCTAssertGreaterThan(counted, 0, name)
            XCTAssertLessThanOrEqual(worst, 0.5 + 1e-9, "\(name): back on the rigid ring within 0.5 s of the last change")
        }
        let reel = run(Self.settle()), carriedAndDropped = reel.filter { $0.t >= 2.05 && $0.t < 2.8 }
        XCTAssertLessThanOrEqual(carriedAndDropped.last { $0.deviation >= LensSkin.restBand }!.t - 2.05, 0.3)
    }

    func testPathHasAFixedElementCountAndStaysClosed() {
        for scene in [Self.resize(), Self.fitScene(), Self.placeScene(), Self.settle()] {
            XCTAssertTrue(run(scene, hz: 60).allSatisfy { $0.elements == 10 }, "a move, 8 cubics (4 arcs, 4 edges) and a close")
        }
        let rigid = LensOutline(frame: CGRect(x: 0, y: 0, width: 300, height: 200), bows: [0, 0, 0, 0], radius: 12, deviation: 0)
        XCTAssertEqual(Self.elements(rigid.path(outset: 1)).count, 10)
    }

    func testRestPathIsTodaysRoundedRect() {
        for frame in [CGRect(x: 10, y: 20, width: 300, height: 200), CGRect(x: -50, y: 5, width: 61, height: 80)] {
            for outset in [CGFloat(0), 1, 1.5] {
                let mine = Self.polyline(LensOutline(frame: frame, bows: [0, 0, 0, 0], radius: 12, deviation: 0).path(outset: outset, radiusOutset: 0), steps: 48)
                let r = frame.insetBy(dx: -outset, dy: -outset)
                let theirs = Self.polyline(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil), steps: 48)
                let worst = max(mine.map { Self.distance(theirs, $0) }.max()!, theirs.map { Self.distance(mine, $0) }.max()!)
                XCTAssertLessThan(worst, 0.02, "outset \(outset): the rest path is CGPath(roundedRect:)")
            }
        }
        let grown = Self.polyline(LensOutline(frame: CGRect(x: 0, y: 0, width: 300, height: 200), bows: [0, 0, 0, 0], radius: 12, deviation: 0).path(outset: 1))
        XCTAssertLessThan(grown.map { abs(Self.sdf($0, CGRect(x: -1, y: -1, width: 302, height: 202), 13)) }.max()!, 0.02, "outset grows the radius with it")
    }

    /// The path's own deviation is the bow asked for (the cubic's middle sits exactly there), in and out.
    func testBowIsWhatThePathDraws() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        for bow in stride(from: CGFloat(-8), through: 4, by: 0.5) where bow != 0 {
            for edge in LensSkin.Edge.allCases {
                var bows: [CGFloat] = [0, 0, 0, 0]
                bows[edge.rawValue] = bow
                let pts = Self.polyline(LensOutline(frame: frame, bows: bows, radius: 12, deviation: abs(bow)).path(outset: 0), steps: 64)
                let sd = pts.map { Self.sdf($0, frame, 12) }
                let got = bow > 0 ? sd.max()! : -sd.min()!
                XCTAssertEqual(got, abs(bow), accuracy: 0.03, "\(edge) bow \(bow)")
            }
        }
    }

    /// §10: the corner arc and the cubic leave each other along one tangent, at all 8 joins, for every bow in range and every size of lens.
    func testJoinsAreG1() {
        var seed: UInt64 = 7
        func next() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(UInt64(1) << 31) }
        var cases: [[CGFloat]] = [[4, 4, 4, 4], [-8, -8, -8, -8], [4, -8, 4, -8], [0, 0, 0, 0], [0.3, -0.3, 0.3, -0.3]]
        for _ in 0..<60 { cases.append((0..<4).map { _ in -8 + 12 * next() }) }
        var worst = 0.0, joins = 0
        for size in [CGSize(width: 80, height: 60), CGSize(width: 200, height: 100), CGSize(width: 400, height: 300), CGSize(width: 900, height: 500)] {
            for bows in cases {
                let frame = CGRect(x: 5, y: 7, width: size.width, height: size.height)
                for outset in [CGFloat(0), 1] {
                    let e = Self.elements(LensOutline(frame: frame, bows: bows, radius: 12, deviation: 0).path(outset: outset))
                    let curves = e.filter { $0.type == .addCurveToPoint }.map(\.points)
                    XCTAssertEqual(curves.count, 8)
                    var start = e[0].points[0]
                    var ins: [CGVector] = [], outs: [CGVector] = []
                    for c in curves {
                        ins.append(CGVector(dx: c[0].x - start.x, dy: c[0].y - start.y))
                        outs.append(CGVector(dx: c[2].x - c[1].x, dy: c[2].y - c[1].y))
                        start = c[2]
                    }
                    for k in 0..<8 {
                        let a = outs[k], b = ins[(k + 1) % 8]
                        let angle = abs(atan2(a.dx * b.dy - a.dy * b.dx, a.dx * b.dx + a.dy * b.dy)) * 180 / .pi
                        worst = max(worst, Double(angle)); joins += 1
                    }
                }
            }
        }
        print(String(format: "skin-g1: worst tangent angle at a join %.4f deg over %d joins (< 0.5)", worst, joins))
        XCTAssertLessThan(worst, 0.5)
    }

    /// An edge too short for its bow (the corner arcs take 12 pt at each end; below about 75 pt of side the cubic cannot bulge as asked) still
    /// bows the way it was asked relative to its own ends, and never more than asked: the Newton step must not flip the tilt's sign.
    func testShortEdgesKeepTheDirectionOfTheirBow() {
        for size in [CGSize(width: 90, height: 60), CGSize(width: 60, height: 40), CGSize(width: 40, height: 30), CGSize(width: 25, height: 25)] {
            let frame = CGRect(x: 0, y: 0, width: size.width, height: size.height), rf = frame.insetBy(dx: -1, dy: -1)
            for (edge, curve) in [(LensSkin.Edge.maxY, 0), (.maxX, 2), (.minY, 4), (.minX, 6)] {
                for bow in [CGFloat(4), 2, -2, -8] {
                    var bows: [CGFloat] = [0, 0, 0, 0]
                    bows[edge.rawValue] = bow
                    let path = LensOutline(frame: frame, bows: bows, radius: 12, deviation: abs(bow)).path(outset: 1)
                    let c = Self.elements(path).filter { $0.type == .addCurveToPoint }[curve].points
                    let start = Self.elements(path).filter { $0.type == .addCurveToPoint }[(curve + 7) % 8].points[2]
                    let mid = CGPoint(x: (start.x + 3 * c[0].x + 3 * c[1].x + c[2].x) / 8, y: (start.y + 3 * c[0].y + 3 * c[1].y + c[2].y) / 8)
                    let lift = Self.sdf(mid, rf, 13) - (Self.sdf(start, rf, 13) + Self.sdf(c[2], rf, 13)) / 2
                    let chord = (edge == .maxY || edge == .minY ? size.width : size.height) + 2 - 26
                    if chord >= 2 { XCTAssertGreaterThan(lift * (bow > 0 ? 1 : -1), 0.02, "\(size) \(edge) bow \(bow): bulges the way it was asked (lift \(lift))") }
                    let sd = Self.polyline(path, steps: 32).map { Self.sdf($0, rf, 13) }
                    XCTAssertTrue(sd.allSatisfy { $0.isFinite }, "\(size) \(edge) bow \(bow)")
                    XCTAssertLessThanOrEqual(sd.max()!, max(0, bow) + 0.1, "\(size) \(edge) bow \(bow): no more out than asked")
                }
            }
        }
    }

    func testReduceMotionIsTheRigidRing() {
        for scene in [Self.resize(), Self.fitScene(), Self.placeScene(), Self.settle()] {
            let s = run(scene, reduceMotion: true)
            XCTAssertTrue(s.allSatisfy { $0.bows.allSatisfy { $0 == 0 } && $0.deviation < 0.01 && $0.atRest }, "Reduce Motion: no bows, nothing ticks")
        }
    }

    /// The step is the closed form: any number of frames of any length reach the same state, and it is the textbook step response.
    func testSpringStepIsExactAndFrameRateFree() {
        let target = CGRect(x: 0, y: 0, width: 400, height: 300)
        func edgesAfter(_ hz: Double, seconds: Double) -> [CGFloat] {
            var skin = LensSkin(frame: CGRect(x: 100, y: 50, width: 200, height: 100))
            skin.begin(.fit)
            for _ in 0..<Int((seconds * hz).rounded()) { skin.step(1 / hz, target: target, hand: .none) }
            return skin.edges
        }
        let a = edgesAfter(240, seconds: 0.25), b = edgesAfter(60, seconds: 0.25), c = edgesAfter(1, seconds: 1)   // 1 Hz: one long step
        for j in 0..<4 { XCTAssertEqual(a[j], b[j], accuracy: 1e-9) }
        // the left edge (minX) goes outward from 100 to 0 on `lead`: x = 100·(1 + ωt)·e^(−ωt)
        let w = 2 * Double.pi / LensSkin.lead
        XCTAssertEqual(Double(a[0]), 100 * (1 + w * 0.25) * exp(-w * 0.25), accuracy: 1e-6)
        XCTAssertEqual(Double(c[0]), 100 * (1 + w * 1) * exp(-w * 1), accuracy: 1e-6)
    }

    func testIsAtRest() {
        var skin = LensSkin(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertTrue(skin.isAtRest)
        skin.step(1 / 60, target: CGRect(x: 0, y: 0, width: 300, height: 100), hand: .none)
        XCTAssertFalse(skin.isAtRest)
        for _ in 0..<120 { skin.step(1 / 60, target: CGRect(x: 0, y: 0, width: 300, height: 100), hand: .none) }
        XCTAssertTrue(skin.isAtRest, "2 s later")
        skin.commit(target: CGRect(x: 0, y: 0, width: 300, height: 100), click: CGPoint(x: 10, y: 10))
        XCTAssertFalse(skin.isAtRest, "taking hold")
    }

    /// The commit closes the edge nearest the click first (0.14 s), the farthest last (0.34 s), and shows 3.9 pt at once.
    func testCommitClosesNearestFirst() {
        var skin = LensSkin(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let target = CGRect(x: 0, y: 0, width: 400, height: 200)
        skin.commit(target: target, click: CGPoint(x: 5, y: 100))   // on the left edge's middle
        let first = skin.outline(around: target)
        XCTAssertEqual(Double(first.deviation), 4 * tanh(2.0), accuracy: 1e-9, "3.86 pt out from the first frame")
        XCTAssertEqual(Double(target.minX - first.frame.minX), 4 * tanh(2.0), accuracy: 1e-9, "the whole rect is grown, not bowed")
        XCTAssertTrue(first.isRigid && first.radius > LensSkin.radius, "corners too")
        for _ in 0..<30 { skin.step(1 / 240, target: target, hand: .none) }   // 0.125 s
        let now = skin.outline(around: target)
        XCTAssertLessThan(target.minX - now.frame.minX, now.frame.maxX - target.maxX, "the left edge, nearest the click, has closed more than the right")
        for _ in 0..<(240 * 7 / 10) { skin.step(1 / 240, target: target, hand: .none) }
        XCTAssertTrue(skin.outline(around: target).isRigid && skin.isAtRest)
        XCTAssertEqual(LensSkin.commitRingIn, 0.02, "§10")
    }

    func testMeterSaysWhatTheSkinDid() {
        let fit = run(Self.fitScene())
        let before = fit.last { $0.t < 3.9 }!, direct = read(fit, 1.06, 1.9)
        print("skin-trace: " + before.metered.text)
        XCTAssertEqual(Double(before.metered.peak), Double(direct.peak), accuracy: 0.15, "the meter and the sampled path agree on the peak (the instrument's cross-check)")
        XCTAssertEqual(Double(before.metered.rest), direct.restMs, accuracy: 0.05 * direct.restMs + 2 * Self.dt * 1000)
        XCTAssertTrue(before.metered.text.hasPrefix("skin: fit peak=4.0"), before.metered.text)
    }

    func testAutoFitIsQuieter() {
        let loud = read(run(Self.fitScene()), 1.06, 1.9).peak, quiet = read(run(Self.autoScene()), 1.4, 2.4).peak
        XCTAssertLessThan(quiet, loud * 0.7)
    }

    /// An edge the hand is on is exact whichever edge it is, and a release at speed does not ring a bow (nothing was snapped).
    func testEdgeHandHoldsItsEdgeAndReleasesClean() {
        var skin = LensSkin(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        var frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        for i in 0..<60 {
            frame.size.width = 300 + CGFloat(i) * 6   // 1440 pt/s at 240 Hz
            skin.step(1 / 240, target: frame, hand: .edge(.maxX))
            XCTAssertEqual(skin.outline(around: frame).bows[LensSkin.Edge.maxX.rawValue], 0, accuracy: 1e-9)
        }
        for _ in 0..<120 {
            skin.step(1 / 240, target: frame, hand: .none)
            XCTAssertLessThan(skin.outline(around: frame).deviation, 0.01, "released at speed: no ghost bow")
        }
    }

    // MARK: - Wiring (round skinland117, 2026-10-23): what the lens window and the panel's clip take from the skin

    /// The lens window draws the ring in its own space and the panel cuts its clip in another: `moved` is the same shape elsewhere, point for point,
    /// and `rigid` is today's rounded rect (what Reduce Motion and the corner brackets draw).
    func testAnOutlineMovedIsTheSameShapeElsewhere() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 200)
        var skin = LensSkin(frame: frame)
        skin.begin(.fit)
        for _ in 0..<12 { skin.step(1 / 240, target: frame.insetBy(dx: -40, dy: 0), hand: .none) }
        let o = skin.outline(around: frame), delta = CGVector(dx: -100, dy: -200), moved = o.moved(by: delta)
        XCTAssertGreaterThan(o.deviation, 1, "the scene bows")
        XCTAssertEqual(moved.frame, o.frame.offsetBy(dx: delta.dx, dy: delta.dy))
        XCTAssertEqual(moved.bows, o.bows)
        XCTAssertEqual(moved.radius, o.radius)
        XCTAssertEqual(moved.deviation, o.deviation)
        let a = Self.elements(moved.path(outset: 1)), b = Self.elements(o.path(outset: 1))
        XCTAssertEqual(a.count, b.count)
        for (p, q) in zip(a, b) {
            XCTAssertEqual(p.points.count, q.points.count)
            for (x, y) in zip(p.points, q.points) {
                XCTAssertEqual(x.x - y.x, delta.dx, accuracy: 1e-9)
                XCTAssertEqual(x.y - y.y, delta.dy, accuracy: 1e-9)
            }
        }
        let rigid = LensOutline.rigid(frame)
        XCTAssertTrue(rigid.isRigid && rigid.deviation == 0 && rigid.radius == LensSkin.radius && rigid.frame == frame)
        // `land`: when the link stops because the skin is at rest, the outline is the rounded rect itself (the edges were within 0.05 pt, not on it).
        var late = LensSkin(frame: frame)
        late.begin(.fit)
        for _ in 0..<(240 * 2) { late.step(1 / 240, target: frame.insetBy(dx: -40, dy: 0), hand: .none) }
        let wide = frame.insetBy(dx: -40, dy: 0)
        XCTAssertTrue(late.isAtRest)
        XCTAssertGreaterThan(late.outline(around: wide).deviation, 0, "within 0.05 pt of the rect, not on it")
        late.land()
        XCTAssertEqual(late.outline(around: wide).deviation, 0)
        XCTAssertEqual(late.outline(around: wide).path(outset: 1).boundingBoxOfPath, wide.insetBy(dx: -1, dy: -1))
        var moving = LensSkin(frame: frame)
        for _ in 0..<6 { moving.step(1 / 240, target: wide, hand: .none) }
        moving.land()
        XCTAssertGreaterThan(moving.outline(around: wide).deviation, 1, "land does nothing while the edges are still travelling")
        XCTAssertEqual(skin.outline(around: frame).frame, frame, "a bowed outline is drawn around the rigid frame, not instead of it")
    }

    /// The one-click commit's times (§3.5, §9.4, §10): the ring is in at once, the accent stroke of the picker goes in 0.10 s, the dim in 0.20 s,
    /// the pill comes in in 0.20 s and the glow in 0.35 s.
    func testTheCommitTimesAreTheContracts() {
        XCTAssertEqual(LensSkin.commitRingIn, 0.02)
        XCTAssertEqual(LensSkin.commitAccentIn, 0.10)
        XCTAssertEqual(LensSkin.commitDimOut, 0.20)
        XCTAssertEqual(LensSkin.commitPillIn, 0.20)
        XCTAssertEqual(LensSkin.commitGlowIn, 0.35)
    }
}
