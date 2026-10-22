import CoreGraphics
import Foundation

/// Every number of how the lens moves when a fit or a snap moves it, in one table (round fit117, addendum A3, 2026-10-22): the frame window's
/// animation, the session's calls and the snap guide read it and nothing else holds a duration for them, so the motion contract's numbers drop in as
/// an edit of this table. The curve is `FitMotion.progress`; the pull of a column's edge is not animated at all (what the hand drags is taken in the
/// same frame it is dragged to, `ColumnFit.reach` and `release` are its geometry).
///
/// The values are the design's (docs/design/lens-fit.md: no overshoot, short enough that the capture and the translations following the lens do not
/// fall behind) except where the motion contract (/tmp/r117/motion117/motion-contract.md) has set one: `fit`.
public enum LensMotion {
    /// Fit to Column, and its Undo Fit: the motion contract's `fit` spring (addendum A9, 2026-10-22; critically damped, response 0.30 s), which
    /// `FitMotion.progress` runs for the 8 / ω = 8 · response / 2π = 0.382 s it takes to settle to 0.3 % of the target.
    public static let fit: TimeInterval = 8 * 0.30 / (2 * Double.pi)
    /// Auto Fit's one growth: the contract's `calm` spring (addendum A1 of round skinland117, 2026-10-23; response 0.50 s, which is SwiftUI's `.smooth`),
    /// settling to 0.3 % in 8 · response / 2π = 0.637 s. Motion the person did not start: a low onset (2.3 pt in the first frame for 122 pt), 90 % at 310 ms.
    public static let autoFit: TimeInterval = 8 * 0.50 / (2 * Double.pi)
    /// The glide onto a column's edge after a drop within its reach, and the picker spotlight's hop between targets: the contract's `quick` spring
    /// (A1, 2026-10-23; response 2π / 30 s, stiffness 900, the block correction's own), settling in 8 · response / 2π = 8 / 30 = 0.267 s, 90 % at 130 ms.
    public static let settle: TimeInterval = 8 * (2 * Double.pi / 30) / (2 * Double.pi)
    /// The snap guide's fade in and out, and how opaque it stands.
    public static let guideFade: TimeInterval = 0.1
    public static let guideAlpha: CGFloat = 0.9

    /// What a duration is where the person asked for less motion: none (a jump, an instant guide).
    public static func seconds(_ duration: TimeInterval, reduced: Bool) -> TimeInterval { reduced ? 0 : duration }
}
