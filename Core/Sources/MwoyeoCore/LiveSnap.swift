import CoreGraphics
import Foundation

/// Where a live resize shows the lens's right edge as the hand drags it near a column's edge (docs/design/lens-fit.md section 16, round snap117). The guide,
/// the tick and the hysteresis (from 8 pt, kept to 12) are `ColumnFit.snap`'s and the session's; this decides where the edge stands while they are on.
/// Pure: callers pass the time, so the tests drive it on a fake clock.
///
/// Two feels, both built so they can be judged in playback (addendum A2 of round snap117, 2026-10-23):
/// - `instant`, the motion contract's 3.1: the edge is on the target in the very frame the guide comes up and under the hand again in the very frame it
///   goes down. The skin's springs take the jump (`LensSkin`: the corner is the hand's and exact, the middle of the edge bows).
/// - `dwell`, fit117's decision 16 with a capture: while the hand moves the edge follows `ColumnFit.livePull` (on the target within 4 pt, none at 12: it
///   never jumps under the hand); when the hand holds still (`Dwell`) with the guide up, the edge glides the rest of the way onto the target during the drag
///   (`LensMotion.settle`), and goes back to the taper, from where it is, when the hand moves again.
public struct LiveSnap: Sendable {
    public enum Feel: String, Sendable, CaseIterable { case instant, dwell }

    /// The feel the lens has unless a debug switch says another (`MWOYEO_SNAP`, not in the App Store build).
    public static let standard = Feel.instant

    /// When the hand holds still: it has not moved `jitter` pt from where it last rested for `hold` seconds, so it moves less than `jitter / hold` pt/s.
    /// A hand on a trackpad that holds a position shows under 1 pt of jitter; a deliberate slow approach moves 10 pt/s or more (1.5 pt in 0.15 s). The
    /// scripted ease-out of the skinland117 take (`take-s1`, the last drag, `post.jsonl`) moves 1.45 pt in its last 0.18 s before it rests at 751.0, and
    /// its hold is 2 s. A hand that holds still sends no `mouseDragged`, so the session asks again every display frame.
    public struct Dwell: Sendable, Equatable {
        public var jitter: CGFloat, hold: TimeInterval
        public init(jitter: CGFloat, hold: TimeInterval) { self.jitter = jitter; self.hold = hold }
        public static let standard = Dwell(jitter: 1.5, hold: 0.15)
    }

    public let feel: Feel
    public var dwell: Dwell
    /// The edge is being taken onto the target (the hand holds still within the guide): `dwell` only.
    public private(set) var capturing = false

    private var anchor: CGFloat?, anchorTime: TimeInterval = 0
    private var held: ColumnFit.Snap?
    private var from: CGFloat = 0, since: TimeInterval = 0, toward: CGFloat = 0

    public init(feel: Feel = LiveSnap.standard, dwell: Dwell = .standard) { self.feel = feel; self.dwell = dwell }

    /// A new drag: nothing is held.
    public mutating func reset() { self = LiveSnap(feel: feel, dwell: dwell) }

    /// The share of the way from the taper's edge to the target the edge has got at `time`: the contract's `quick` spring from where it was.
    public func level(at time: TimeInterval) -> CGFloat {
        guard time - since < LensMotion.settle else { return toward }
        return from + (toward - from) * FitMotion.progress(time - since, duration: LensMotion.settle)
    }

    /// The width the lens shows for the frame the hand made (`hand`: its left edge stands, its right edge is the hand's), with the snap the guide is in
    /// (`snap`, nil: none) and the targets the lens may be pulled to (none while ⌘ is down or Snap is off), at `time`.
    public mutating func width(hand: CGRect, snap: ColumnFit.Snap?, targets: ColumnFit.Targets, at time: TimeInterval) -> CGFloat {
        switch feel {
        case .instant:
            return max(ColumnFit.minWidth, hand.width + (snap?.offset ?? 0))
        case .dwell:
            let x = hand.maxX
            if anchor.map({ abs(x - $0) >= dwell.jitter }) ?? true { anchor = x; anchorTime = time }
            if let snap { held = snap }
            let wants: CGFloat = snap != nil && time - anchorTime >= dwell.hold ? 1 : 0
            if wants != toward { from = level(at: time); since = time; toward = wants }
            capturing = toward == 1
            let level = level(at: time)
            if level == 0, toward == 0, snap == nil { held = nil }
            // The taper is a function of where the hand is (the nearest target from `release` in): the edge does not jump under it.
            let pull = ColumnFit.snap(hand, edges: .right, targets: targets, entry: ColumnFit.release).map { ColumnFit.livePull($0.offset) } ?? 0
            let tapered = x + pull
            return max(ColumnFit.minWidth, (held.map { tapered + level * ($0.target.x - tapered) } ?? tapered) - hand.minX)
        }
    }
}
