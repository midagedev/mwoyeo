import CoreGraphics
import Foundation

/// The ring's organic outline, the "membrane" (1.1.7; motion contract §9, §10). The frame (the window, the capture, the hit band, the pill) is the
/// rigid one and keeps its own springs; over it each straight edge of the outline bows by how far its own edge has got ahead of, or fallen behind,
/// the frame, and settles on the frame. Pure: callers pass `dt`, so tests drive it on a fake clock.
///
/// All rects are in one coordinate space, y up (AppKit). Edges: 0 minX, 1 maxY, 2 maxX, 3 minY; outward is −, +, +, −.
public struct LensSkin: Sendable {
    public enum Edge: Int, CaseIterable, Sendable {
        case minX, maxY, maxX, minY
        /// +1 where growing the rect moves the edge to larger coordinates, −1 where it moves to smaller ones.
        public var outward: CGFloat { self == .minX || self == .minY ? -1 : 1 }
    }
    /// What is holding the lens. `corner`: the pointer is on a corner (no edge is held; the bows' ends are the corners, so the corner is exact).
    /// `edge`: the pointer is on that edge (it is the hand's, exact). `move`: the lens is carried by its top edge.
    public enum Hand: Sendable, Equatable { case none, corner, edge(Edge), move }

    // The table (contract 9.4). Responses are seconds of a critically damped spring; the caps are soft: cap · tanh(raw / cap).
    public static let lead: TimeInterval = 0.18, trail: TimeInterval = 0.34           // an edge moving outward / inward, free
    public static let handLead: TimeInterval = 0.07, handTrail: TimeInterval = 0.12   // the same under the hand
    public static let commitFrom: CGFloat = 8, commitNear: TimeInterval = 0.14, commitFar: TimeInterval = 0.34, takeHold: TimeInterval = 0.6
    public static let capOut: CGFloat = 4, capIn: CGFloat = 8, capHand: CGFloat = 4   // pt
    /// §10: the ring is at full opacity in 0.02 s at the commit (one frame, no double outline); the accent outline fades in 0.10 s.
    public static let commitRingIn: TimeInterval = 0.02, commitAccentIn: TimeInterval = 0.10
    /// §3.5, §9.4: at a one-click commit the pill comes in linearly in 0.20 s, the glow in 0.35 s (the existing glow transaction); the picker's dim goes
    /// out in `commitDimOut` (ease-out), its accent stroke and label in `commitAccentIn`.
    public static let commitPillIn: TimeInterval = 0.20, commitGlowIn: TimeInterval = 0.35, commitDimOut: TimeInterval = 0.20
    /// The frame's corner radius (RegionFrameWindow's `radius`).
    public static let radius: CGFloat = 12
    /// Auto Fit is not started by the person: its bows are this much of Fit's (§3.4, §9.4).
    public static let autoFitAmplitude: CGFloat = 0.6
    /// Bows while the lens is carried (§9.5). Off: a carried lens holds all four edges to the frame, so the cached raster is reused and the
    /// window server does no extra work for a drag. On, only the top edge under the pointer is held and the other three bow. The one place the App
    /// reads; it goes on only after the window-server measurement of phase 2.
    public static let moveBows = false
    /// An outline closer than this to the rigid ring counts as on it (pt), and an edge this close to its target and slower than `restSpeed` is at rest.
    public static let restBand: CGFloat = 0.5, restDistance: CGFloat = 0.05, restSpeed: CGFloat = 0.5

    /// §9.6, one row per moment. The numbers are what the prototype measured at 240 Hz (data/organic.txt, data/measure-organic.txt); the
    /// tests drive the same scripts and compare within 10 %.
    public enum Moment: String, CaseIterable, Sendable {
        case cornerDrag, drop, fit, undoFit, autoFit, pickerHop, commit
        /// Auto Fit bows are quieter; every other moment shows the whole bow.
        public var amplitude: CGFloat { self == .autoFit ? LensSkin.autoFitAmplitude : 1 }
    }
    public struct Row: Sendable, Equatable {
        public let moment: Moment, label: String
        public let peak: CGFloat, peakMs: Int?, restMs: Int
        /// `restMs` is a bound (corner drag: "at most 0.15 s after the hand stops"), not a value to match.
        public let restIsBound: Bool
    }
    public static let choreography: [Row] = [
        Row(moment: .cornerDrag, label: "corner drag", peak: 3.97, peakMs: nil, restMs: 150, restIsBound: true),
        Row(moment: .drop, label: "drop 1", peak: 1.62, peakMs: 83, restMs: 225, restIsBound: false),
        Row(moment: .drop, label: "drop 2", peak: 0.61, peakMs: 83, restMs: 133, restIsBound: false),
        Row(moment: .fit, label: "Fit", peak: 4.00, peakMs: 69, restMs: 344, restIsBound: false),
        Row(moment: .undoFit, label: "Undo Fit", peak: 3.35, peakMs: 113, restMs: 358, restIsBound: false),
        Row(moment: .autoFit, label: "Auto Fit", peak: 2.40, peakMs: nil, restMs: 562, restIsBound: false),
        Row(moment: .pickerHop, label: "hop 1", peak: 4.00, peakMs: 83, restMs: 445, restIsBound: false),
        Row(moment: .pickerHop, label: "hop 2", peak: 4.00, peakMs: 46, restMs: 484, restIsBound: false),
        Row(moment: .pickerHop, label: "hop 3", peak: 4.00, peakMs: 4, restMs: 266, restIsBound: false),
        Row(moment: .commit, label: "commit", peak: 3.86, peakMs: 0, restMs: 242, restIsBound: false),
    ]

    public private(set) var edges: [CGFloat], velocities: [CGFloat]                   // 4 each
    public private(set) var meter = Meter()
    public let moveBows: Bool
    /// Reduce Motion (§5): the outline is the rigid ring and nothing ticks.
    public var reduceMotion = false
    private var goals: [CGFloat]
    private var hand = Hand.none
    private var amplitude: CGFloat = 1
    private var takeLeft: TimeInterval = 0
    private var takeResponse: [TimeInterval] = [Self.commitNear, Self.commitNear, Self.commitNear, Self.commitNear]

    public init(frame: CGRect, moveBows: Bool = LensSkin.moveBows) {
        edges = Self.edges(of: frame)
        goals = edges
        velocities = [0, 0, 0, 0]
        self.moveBows = moveBows
    }

    /// A moment begins (the person double-clicked, the picker hopped, ...): the meter starts counting, and Auto Fit's bows are quieter.
    public mutating func begin(_ moment: Moment) {
        amplitude = moment.amplitude
        meter.begin(moment)
    }

    /// One display frame. `target` is where the frame is going (the Fit target, the snap target, the hovered paragraph, or the hand's frame).
    public mutating func step(_ dt: TimeInterval, target: CGRect, hand: Hand) {
        goals = Self.edges(of: target)
        self.hand = hand
        meter.advance(dt)
        guard dt > 0 else { return }
        guard !reduceMotion else {
            edges = goals
            velocities = [0, 0, 0, 0]
            takeLeft = 0
            return
        }
        let held = Self.held(by: hand, moveBows: moveBows)
        for edge in Edge.allCases {
            let j = edge.rawValue
            if held.contains(edge) {
                edges[j] = goals[j]
                velocities[j] = 0
                continue
            }
            let leading = (goals[j] - edges[j]) * edge.outward > 0
            let response = takeLeft > 0 ? takeResponse[j]
                : hand == .none ? (leading ? Self.lead : Self.trail) : (leading ? Self.handLead : Self.handTrail)
            (edges[j], velocities[j]) = Self.advance(edges[j], velocities[j], to: goals[j], response: response, dt: CGFloat(dt))
        }
        takeLeft = max(0, takeLeft - dt)
    }

    /// The one-click commit: the edges jump to `target` grown by `commitFrom` and close for `takeHold`, the edge nearest the click first. While
    /// they close the outline is the whole grown rect (corners too), not bows.
    public mutating func commit(target: CGRect, click: CGPoint) {
        begin(.commit)
        goals = Self.edges(of: target)
        hand = .none
        guard !reduceMotion else {
            edges = goals
            return
        }
        edges = [target.minX - Self.commitFrom, target.maxY + Self.commitFrom, target.maxX + Self.commitFrom, target.minY - Self.commitFrom]
        velocities = [0, 0, 0, 0]
        let middles = [CGPoint(x: target.minX, y: target.midY), CGPoint(x: target.midX, y: target.maxY),
                       CGPoint(x: target.maxX, y: target.midY), CGPoint(x: target.midX, y: target.minY)]
        let distances = middles.map { hypot($0.x - click.x, $0.y - click.y) }
        let farthest = distances.max() ?? 0
        takeResponse = distances.map { Self.commitNear + (farthest > 0 ? (Self.commitFar - Self.commitNear) * TimeInterval($0 / farthest) : 0) }
        takeLeft = Self.takeHold
    }

    /// What to draw around `frame` (the rigid frame the window is at, in the space of `step`'s targets): a bow per edge, or the whole grown rect
    /// while taking hold. At rest, today's rounded rect.
    public func outline(around frame: CGRect) -> LensOutline {
        guard !reduceMotion else { return .rigid(frame) }
        let rigid = Self.edges(of: frame)
        let inward = hand == .none ? Self.capIn * amplitude : Self.capHand
        let lag = Edge.allCases.map { edge -> CGFloat in
            Self.softCap((edges[edge.rawValue] - rigid[edge.rawValue]) * edge.outward * amplitude, out: Self.capOut * amplitude, in: inward)
        }
        let deviation = lag.map { abs($0) }.max() ?? 0
        guard takeLeft > 0 else { return LensOutline(frame: frame, bows: lag, radius: Self.radius, deviation: deviation) }
        let grown = CGRect(x: frame.minX - lag[0], y: frame.minY - lag[3], width: max(0, frame.width + lag[0] + lag[2]),
                           height: max(0, frame.height + lag[1] + lag[3]))
        return LensOutline(frame: grown, bows: [0, 0, 0, 0], radius: Self.radius + max(0, lag.reduce(0, +) / 4), deviation: deviation)
    }

    /// Every edge is within `restDistance` of its target and slower than `restSpeed`: the display link may stop (the frame permitting).
    public var isAtRest: Bool {
        takeLeft == 0 && Edge.allCases.allSatisfy { abs(edges[$0.rawValue] - goals[$0.rawValue]) < Self.restDistance && abs(velocities[$0.rawValue]) < Self.restSpeed }
    }

    /// The display link stops because the skin is at rest: every edge goes exactly onto its target, so the outline is the rounded rect itself and not a
    /// rounded rect within `restDistance` of it (§9.5: "at rest the outline equals today's rounded rect").
    public mutating func land() {
        guard isAtRest else { return }
        edges = goals
        velocities = [0, 0, 0, 0]
    }

    /// Feeds the meter the outline just drawn (its peak, and the last frame it was off the rigid ring).
    public mutating func record(_ outline: LensOutline) { meter.record(outline.deviation) }

    // MARK: Pieces

    static func edges(of r: CGRect) -> [CGFloat] { [r.minX, r.maxY, r.maxX, r.minY] }

    /// The edges the hand owns.
    static func held(by hand: Hand, moveBows: Bool) -> Set<Edge> {
        switch hand {
        case .none, .corner: []
        case .edge(let edge): [edge]
        case .move: moveBows ? [.maxY] : Set(Edge.allCases)
        }
    }

    /// The exact step of a critically damped spring over `dt` towards a constant `target` (stable at any frame rate): with Δ = x − target and
    /// B = v + ωΔ, x ← target + (Δ + B·dt)·e^(−ω·dt), v ← (B − ω(Δ + B·dt))·e^(−ω·dt).
    static func advance(_ x: CGFloat, _ v: CGFloat, to target: CGFloat, response: TimeInterval, dt: CGFloat) -> (CGFloat, CGFloat) {
        let w = 2 * CGFloat.pi / CGFloat(response)
        let d = x - target, b = v + w * d, k = exp(-w * dt)
        return (target + (d + b * dt) * k, (b - w * (d + b * dt)) * k)
    }

    /// cap · tanh(raw / cap): slope 1 at 0, so a small lag shows as itself and a large one flattens towards its cap.
    static func softCap(_ raw: CGFloat, out: CGFloat, in inward: CGFloat) -> CGFloat {
        raw > 0 ? out * tanh(raw / out) : inward * tanh(raw / inward)
    }

    /// Where a moment's outline has been, for the trace and the stats: the peak deviation from the rigid ring and the last time it was off it.
    public struct Meter: Sendable, Equatable {
        public private(set) var moment: Moment?
        public private(set) var peak: CGFloat = 0
        public private(set) var peakAt: TimeInterval = 0
        /// The time of the first frame after the last one that was off the ring by `restBand` or more.
        public private(set) var restAt: TimeInterval = 0
        private var clock: TimeInterval = 0, lastDt: TimeInterval = 0

        mutating func begin(_ moment: Moment) { self = Meter(); self.moment = moment }
        mutating func advance(_ dt: TimeInterval) { clock += dt; lastDt = dt }
        mutating func record(_ deviation: CGFloat) {
            if deviation > peak { peak = deviation; peakAt = clock - lastDt }   // the first frame after the moment began is +0
            if deviation >= LensSkin.restBand { restAt = clock }
        }
        /// `Trace.mark` text: "skin: fit peak=4.00 rest=344ms".
        public var summary: String {
            "skin: \(moment?.rawValue ?? "-") peak=\(String(format: "%.2f", Double(peak))) rest=\(Int((restAt * 1000).rounded()))ms"
        }
    }
}

/// The outline to draw: the frame with a bow per straight edge (outward, pt, already capped), the corner radius, and how far the outline is from
/// the rigid ring at its farthest.
public struct LensOutline: Sendable, Equatable {
    public let frame: CGRect, bows: [CGFloat], radius: CGFloat, deviation: CGFloat

    /// No bow at all: the path is the rounded rect.
    public var isRigid: Bool { bows.allSatisfy { abs($0) < 0.01 } }

    /// The rounded rect: today's lens, and what Reduce Motion and the corner brackets draw.
    public static func rigid(_ frame: CGRect) -> LensOutline {
        LensOutline(frame: frame, bows: [0, 0, 0, 0], radius: LensSkin.radius, deviation: 0)
    }

    /// The same outline `delta` away: the lens window and the panel's clip place one outline in their own spaces.
    public func moved(by delta: CGVector) -> LensOutline {
        LensOutline(frame: frame.offsetBy(dx: delta.dx, dy: delta.dy), bows: bows, radius: radius, deviation: deviation)
    }

    /// The sine of the largest tilt of an edge at its ends: 30°. An edge shorter than about 75 pt reaches it, and then its bow is smaller than asked.
    private static let maxSine: CGFloat = 0.5

    /// 4 arcs (the frame's corners, radius + `radiusOutset`, which is `outset` unless given) and 4 cubics (the edges), 8 cubics in all: a fixed
    /// element count, so a path can be animated into any other. The ends of every edge are on its corner arcs and the cubic leaves them along the
    /// arc's tangent, so every join is G1: a bowed edge tilts at its ends and the arc beside it gets that much shorter (outward) or longer (inward).
    /// With no bow it is the rounded rect.
    public func path(outset: CGFloat, radiusOutset: CGFloat? = nil) -> CGPath {
        let r = frame.insetBy(dx: -outset, dy: -outset)
        let rad = max(0.5, min(radius + (radiusOutset ?? outset), r.width / 2, r.height / 2))
        // clockwise from the top edge: top, right, bottom, left (u: the way it runs); edge k runs from corner centre k to corner centre k + 1
        let edges: [(edge: LensSkin.Edge, u: CGVector)] = [(.maxY, CGVector(dx: 1, dy: 0)), (.maxX, CGVector(dx: 0, dy: -1)),
                                                           (.minY, CGVector(dx: -1, dy: 0)), (.minX, CGVector(dx: 0, dy: 1))]
        let centres = [CGPoint(x: r.minX + rad, y: r.maxY - rad), CGPoint(x: r.maxX - rad, y: r.maxY - rad),
                       CGPoint(x: r.maxX - rad, y: r.minY + rad), CGPoint(x: r.minX + rad, y: r.minY + rad)]
        // per edge: its tangents at both ends (tilted by θ towards the bow), its end points on the corner arcs, and its cubic's handle length
        struct Cubic { var start: CGPoint, end: CGPoint, startTangent: CGVector, endTangent: CGVector, handle: CGFloat }
        let cubics = (0..<4).map { k -> Cubic in
            let (edge, u) = edges[k], n = CGVector(dx: -u.dy, dy: u.dx)
            let from = centres[k], to = centres[(k + 1) % 4]
            let chord = hypot(to.x - from.x, to.y - from.y)
            let theta = Self.tilt(bow: bows[edge.rawValue], chord: chord, radius: rad)
            let c = cos(theta), s = sin(theta)
            let ts = CGVector(dx: c * u.dx + s * n.dx, dy: c * u.dy + s * n.dy), te = CGVector(dx: c * u.dx - s * n.dx, dy: c * u.dy - s * n.dy)
            return Cubic(start: CGPoint(x: from.x - rad * ts.dy, y: from.y + rad * ts.dx), end: CGPoint(x: to.x - rad * te.dy, y: to.y + rad * te.dx),
                         startTangent: ts, endTangent: te, handle: chord / 3)
        }
        let p = CGMutablePath()
        p.move(to: cubics[0].start)
        for k in 0..<4 {
            let a = cubics[k], b = cubics[(k + 1) % 4]
            p.addCurve(to: a.end, control1: CGPoint(x: a.start.x + a.handle * a.startTangent.dx, y: a.start.y + a.handle * a.startTangent.dy),
                       control2: CGPoint(x: a.end.x - a.handle * a.endTangent.dx, y: a.end.y - a.handle * a.endTangent.dy))
            // the corner arc from a's end to b's start: its tangents are theirs, and one cubic per arc has handle 4/3·tan(sweep / 4)·R
            let sweep = acos(min(1, max(-1, a.endTangent.dx * b.startTangent.dx + a.endTangent.dy * b.startTangent.dy)))
            let h = 4 / 3 * tan(sweep / 4) * rad
            p.addCurve(to: b.start, control1: CGPoint(x: a.end.x + h * a.endTangent.dx, y: a.end.y + h * a.endTangent.dy),
                       control2: CGPoint(x: b.start.x - h * b.startTangent.dx, y: b.start.y - h * b.startTangent.dy))
        }
        p.closeSubpath()
        return p
    }

    /// The tilt of an edge's tangent at its ends (radians, towards the bow) for a bow `b` at its middle. The cubic's middle sits
    /// f(θ) = −R(1 − cos θ) + ¾·h·sin θ from the edge's line (its ends are R(1 − cos θ) inside it, its handles h long), h a third of the chord.
    /// Starts from the small-angle answer 4b / 3h (soft-limited to 30°) and takes two Newton steps. An outward bow stops growing where f peaks
    /// (tan θ = ¾h / R): an edge too short for its bow gets the most it can bulge, never a tilt that sinks it.
    static func tilt(bow b: CGFloat, chord: CGFloat, radius rad: CGFloat) -> CGFloat {
        let h = chord / 3
        guard h > 1e-3, abs(b) > 1e-6 else { return 0 }
        let sign: CGFloat = b > 0 ? 1 : -1, limit = min(asin(maxSine), b > 0 ? atan2(0.75 * h, rad) : .infinity)
        var theta = sign * min(limit, asin(maxSine * tanh(4 * abs(b) / (3 * h) / maxSine)))
        for _ in 0..<2 {
            let slope = -rad * sin(theta) + 0.75 * h * cos(theta)
            guard abs(slope) > 1e-6 else { break }
            let next = theta - (-rad * (1 - cos(theta)) + 0.75 * h * sin(theta) - b) / slope
            guard next * sign > 0, abs(next) <= limit else { break }
            theta = next
        }
        return theta
    }
}
