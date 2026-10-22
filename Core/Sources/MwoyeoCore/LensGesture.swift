import CoreGraphics
import Foundation

/// A double-click on the lens's ring. The ring is dragged by the window server (`performDrag`): the app is not told of the second mouse-up or of
/// `clickCount`, only of a button that went up with the pointer where it went down. So the tap is the app's own: a release that did not move, and a
/// second one within the system's double-click interval and a few points of the first (docs/design/lens-fit.md section 6).
public struct DoubleTap: Sendable {
    /// How far the pointer may stand from the first tap's place.
    public static let slop: CGFloat = 4
    private var first: (point: CGPoint, time: TimeInterval)?

    public init() {}

    /// A release that did not move, at `point` and `time` (seconds on one clock). True for the second of a double-click; that tap is used up, so a
    /// third one starts a new pair.
    public mutating func tap(at point: CGPoint, time: TimeInterval, interval: TimeInterval) -> Bool {
        if let f = first, time >= f.time, time - f.time <= interval, hypot(point.x - f.point.x, point.y - f.point.y) <= Self.slop {
            first = nil
            return true
        }
        first = (point, time)
        return false
    }

    /// A drag, or any other click: the first tap is forgotten.
    public mutating func reset() { first = nil }
}

/// The curve a lens moves to a column or to a snap on: a spring with no overshoot (a lens never leaves the display or the window it was clamped to).
/// How long it takes is `LensMotion`'s.
public enum FitMotion {
    /// A critically damped spring from 0 to 1: `1 − (1 + ωt)·e^(−ωt)`, with ω = 8 / `duration`, so that it stands 0.3 % short of 1 at `duration` (the last
    /// frame is the target itself). Zero at 0, rising without overshoot.
    public static func progress(_ t: TimeInterval, duration: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 1 }
        let x = 8 * max(0, t) / duration
        return CGFloat(1 - (1 + x) * exp(-x))
    }

    /// The frame `progress` of the way from `from` to `to`.
    public static func frame(from: CGRect, to: CGRect, progress p: CGFloat) -> CGRect {
        CGRect(x: from.minX + (to.minX - from.minX) * p, y: from.minY + (to.minY - from.minY) * p,
               width: from.width + (to.width - from.width) * p, height: from.height + (to.height - from.height) * p)
    }
}
