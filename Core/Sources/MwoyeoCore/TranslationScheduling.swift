import CoreGraphics

/// Which translation work still matters, as a lens and the text around it move. Pure, so it can be tested without the app.
///
/// Rects are all in one coordinate space (the capture's image pixels); `lead` is the motion direction (-1…1 per axis,
/// the side text arrives from), zero while nothing moves.
public enum TranslationScheduling {
    /// Where a piece of text stands relative to the lens.
    public enum Standing: Sendable, Equatable {
        /// No longer on the capture.
        case gone
        /// Inside the lens.
        case lens
        /// Outside the lens, on the side motion brings text from.
        case leading
        /// Anywhere else.
        case other
    }

    /// Why an in-flight batch should be cut short.
    public enum Preemption: Sendable, Equatable {
        /// Nothing left in it is still on the capture.
        case allGone
        /// None of it is in the lens or on the leading side, while lens text waits.
        case lensWaiting
        /// Every unfinished source will have left the lens before the engine could deliver it.
        case tooLate
    }

    /// One source text and where one of its blocks stands (a source may appear in several blocks).
    public struct Candidate: Sendable, Equatable {
        public var source: String
        public var rect: CGRect
        public init(source: String, rect: CGRect) {
            self.source = source
            self.rect = rect
        }
    }

    public static func standing(of r: CGRect, lens: CGRect, lead: CGVector) -> Standing {
        if r.intersects(lens) { return .lens }
        let sx: CGFloat = r.midX < lens.minX ? -1 : r.midX > lens.maxX ? 1 : 0
        let sy: CGFloat = r.midY < lens.minY ? -1 : r.midY > lens.maxY ? 1 : 0
        return sx * lead.dx + sy * lead.dy > 0 ? .leading : .other
    }

    /// Whether to cancel a running batch.
    /// - Parameters:
    ///   - unfinished: the standing of each source of the batch that has no result yet.
    ///   - lensWaiting: some text in the lens is queued and not part of this batch.
    ///   - afterLensPreemption: the batch before this one was cut by `.lensWaiting`. That rule then stays quiet, or no
    ///     batch would ever finish while content moves faster than a batch runs; `.allGone` always applies.
    ///   - moving: content is still moving. Once it has stopped there is no livelock to guard against (the lens text the
    ///     next batch serves cannot be cut again), so the guard is skipped.
    public static func preemption(unfinished: [Standing], lensWaiting: Bool, afterLensPreemption: Bool, moving: Bool = true) -> Preemption? {
        guard !unfinished.isEmpty else { return nil }
        if unfinished.allSatisfy({ $0 == .gone }) { return .allGone }
        guard lensWaiting, !(moving && afterLensPreemption) else { return nil }
        return unfinished.allSatisfy({ $0 == .gone || $0 == .other }) ? .lensWaiting : nil
    }

    /// Whether the engine cannot deliver any of the unfinished sources before each has left the lens.
    /// - Parameters:
    ///   - dwells: `dwell` of each unfinished source (0 for one that is gone), seconds.
    ///   - remaining: seconds the batch still needs.
    public static func tooLate(dwells: [Double], remaining: Double) -> Bool {
        !dwells.isEmpty && dwells.allSatisfy { $0 < remaining }
    }

    /// The velocity of text `r`: `velocity` when the whole lens moves (`region` nil) or `r` lies on the scrolling
    /// `region`; zero for text outside it, which stays where it is (a fixed header, an input box).
    public static func velocity(of r: CGRect, _ velocity: CGVector, scrollRegion region: CGRect?) -> CGVector {
        guard let region else { return velocity }
        return r.intersects(region) ? velocity : .zero
    }

    /// Seconds until `r` has wholly passed the lens's exit edge, with text moving at `velocity` relative to the lens
    /// (image pixels per second, +y toward `lens.maxY`, +x toward `lens.maxX`): after that, a translation is of no use.
    /// Text that has already passed it: 0. Not moving along either axis: nil (no limit). With two moving axes, the
    /// first axis to leave decides.
    public static func dwell(of r: CGRect, lens: CGRect, velocity v: CGVector) -> Double? {
        var out: Double?
        func axis(_ speed: CGFloat, _ rMin: CGFloat, _ rMax: CGFloat, _ lMin: CGFloat, _ lMax: CGFloat) {
            guard speed != 0 else { return }
            let t = speed > 0 ? (lMax - rMin) / speed : (rMax - lMin) / -speed
            out = min(out ?? .infinity, max(0, Double(t)))
        }
        axis(v.dx, r.minX, r.maxX, lens.minX, lens.maxX)
        axis(v.dy, r.minY, r.maxY, lens.minY, lens.maxY)
        return out
    }

    /// Seconds until `r` first touches the lens (0 when it does already); nil when it never will at this velocity:
    /// moving away, or not moving along an axis on which it lies outside the lens. With two axes, both must overlap, so
    /// the later one decides.
    public static func entry(of r: CGRect, lens: CGRect, velocity v: CGVector) -> Double? {
        func axis(_ speed: CGFloat, _ rMin: CGFloat, _ rMax: CGFloat, _ lMin: CGFloat, _ lMax: CGFloat) -> Double? {
            if rMax > lMin, rMin < lMax { return 0 }
            if speed > 0, rMax <= lMin { return Double((lMin - rMax) / speed) }
            if speed < 0, rMin >= lMax { return Double((rMin - lMax) / -speed) }
            return nil
        }
        guard v != .zero,
              let x = axis(v.dx, r.minX, r.maxX, lens.minX, lens.maxX),
              let y = axis(v.dy, r.minY, r.maxY, lens.minY, lens.maxY) else { return nil }
        return max(x, y)
    }

    /// The batch to start while content moves at `velocity`: lens text first (reading order), then text that will enter
    /// soonest. Greedy: the k-th source (1-based) is taken only if it stays in the lens at least
    /// `expectedSeconds(k) + margin` seconds, so what the engine delivers is still on show. Empty when nothing qualifies.
    /// `scrollRegion`: the area that scrolls at `velocity`, or nil when the whole lens moves; text outside it never leaves.
    public static func batch(from candidates: [Candidate], lens: CGRect, velocity: CGVector, scrollRegion: CGRect? = nil, limit: Int,
                             expectedSeconds: (Int) -> Double, margin: Double = 0.5) -> [String] {
        struct Entry { var source: String; var dwell: Double; var inLens: Bool; var y: CGFloat; var entry: Double }
        var entries: [String: Entry] = [:]
        var order: [String] = []
        for c in candidates {
            let v = Self.velocity(of: c.rect, velocity, scrollRegion: scrollRegion)
            let dwell = dwell(of: c.rect, lens: lens, velocity: v) ?? .infinity
            let inLens = c.rect.intersects(lens)
            let e = entry(of: c.rect, lens: lens, velocity: v) ?? .infinity
            if var old = entries[c.source] {
                old.dwell = max(old.dwell, dwell)
                old.entry = min(old.entry, e)
                if inLens { old.y = old.inLens ? min(old.y, c.rect.minY) : c.rect.minY; old.inLens = true }
                entries[c.source] = old
            } else {
                entries[c.source] = Entry(source: c.source, dwell: dwell, inLens: inLens, y: c.rect.minY, entry: e)
                order.append(c.source)
            }
        }
        // Text that never reaches the lens at this velocity waits until the content stops.
        let ranked = order.compactMap { entries[$0] }.filter { $0.inLens || $0.entry.isFinite }
            .sorted { a, b in
                if a.inLens != b.inLens { return a.inLens }
                return a.inLens ? a.y < b.y : a.entry < b.entry
            }
        var out: [String] = []
        for e in ranked where out.count < limit && e.dwell >= expectedSeconds(out.count + 1) + margin { out.append(e.source) }
        return out
    }

    /// Text that motion has left behind: while `lead` is set, a rect that lies wholly on the trailing side (by its
    /// edges) and farther from the lens than one lens extent along that axis. Lens text is never trailing.
    public static func isTrailing(_ r: CGRect, lens: CGRect, lead: CGVector) -> Bool {
        if lead.dx > 0, lens.minX - r.maxX > lens.width { return true }
        if lead.dx < 0, r.minX - lens.maxX > lens.width { return true }
        if lead.dy > 0, lens.minY - r.maxY > lens.height { return true }
        if lead.dy < 0, r.minY - lens.maxY > lens.height { return true }
        return false
    }
}

/// How long an engine takes, learned from what it does: a fixed cost until the first line arrives, then so much per
/// further line. Fed with the arrival delta of each streamed line (first: since the call began; then: since the
/// previous one), so a cut batch teaches it too. No seed: until the first line arrives nothing is known (`nil`).
/// The first `meanSamples` samples of each kind are a running mean, after that an EWMA.
public struct TranslationPace: Sendable, Equatable {
    public private(set) var first: Double?
    public private(set) var next: Double?
    public private(set) var firstSamples = 0
    public private(set) var nextSamples = 0

    public static let weight = 0.3
    public static let meanSamples = 5

    public init() {}

    /// Seconds a call of `lines` lines is expected to take; nil while no first line has been seen. Until a later line
    /// has been seen too, a line is assumed to cost as much as the first.
    public func expectedSeconds(lines: Int) -> Double? {
        guard let first else { return nil }
        return lines <= 0 ? 0 : first + Double(lines - 1) * (next ?? first)
    }

    /// Seconds a running call of `lines` lines, `delivered` of which have come back after `elapsed` seconds, still needs;
    /// nil while no first line has been seen. Before its first result only the part of the fixed cost not yet spent is
    /// owed (a call that is nearly done is not worth cutting), and a call past its expected time owes just its later lines.
    public func remainingSeconds(lines: Int, delivered: Int, elapsed: Double) -> Double? {
        guard let first else { return nil }
        let each = next ?? first, left = max(0, lines - delivered)
        guard left > 0 else { return 0 }
        return delivered == 0 ? max(first - elapsed, 0) + Double(left - 1) * each : Double(left) * each
    }

    /// `isFirst`: the delta of the first line of a call; otherwise of a later one.
    public mutating func record(seconds: Double, isFirst: Bool) {
        let s = min(max(seconds, 0), 60)
        func fold(_ old: Double?, _ n: Int) -> Double {
            guard let old else { return s }
            return n < Self.meanSamples ? (old * Double(n) + s) / Double(n + 1) : old + Self.weight * (s - old)
        }
        if isFirst {
            first = fold(first, firstSamples)
            firstSamples += 1
        } else {
            next = fold(next, nextSamples)
            nextSamples += 1
        }
    }
}
