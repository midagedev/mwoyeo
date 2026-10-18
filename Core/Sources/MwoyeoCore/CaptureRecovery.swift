import CoreGraphics
import Foundation

/// The displays as a lens sees them: Quartz global points (origin at the top left of the primary display).
public struct DisplayLayout: Equatable, Sendable {
    /// The frame of every display.
    public var frames: [CGRect]
    /// Where a lens that lost its display goes: the usable area of the primary display (below its menu bar).
    public var primary: CGRect

    public init(frames: [CGRect], primary: CGRect) {
        self.frames = frames
        self.primary = primary
    }

    /// The display that shows most of `rect`, the one a capture of it streams; nil when no display shows any of it.
    public func display(showing rect: CGRect) -> CGRect? {
        func area(_ r: CGRect) -> CGFloat { let i = r.intersection(rect); return i.isNull ? 0 : i.width * i.height }
        guard let best = frames.max(by: { area($0) < area($1) }), area(best) > 0 else { return nil }
        return best
    }
}

/// Where a lens goes when the display it was on is gone (unplugged, a smaller resolution, a saved lens opened on another setup).
public enum LensPlacement {
    /// nil while the lens is on a display (its centre is on one); otherwise the lens moved to the nearest place inside the primary
    /// display's usable area, smaller if it does not fit there. nil too when there is no display to move to.
    public static func resolve(_ lens: CGRect, in layout: DisplayLayout) -> CGRect? {
        let p = layout.primary
        guard !layout.frames.isEmpty, !p.isNull, !p.isEmpty, lens.minX.isFinite, lens.minY.isFinite, lens.width.isFinite, lens.height.isFinite
        else { return nil }
        let centre = CGPoint(x: lens.midX, y: lens.midY)
        if layout.frames.contains(where: { $0.contains(centre) }) { return nil }
        let size = CGSize(width: min(lens.width, p.width), height: min(lens.height, p.height))
        return CGRect(x: min(max(lens.minX, p.minX), p.maxX - size.width), y: min(max(lens.minY, p.minY), p.maxY - size.height),
                      width: size.width, height: size.height)
    }
}

/// What a lens's capture is told by the world around it.
public enum CaptureEvent: Equatable, Sendable {
    /// A saved lens is about to start (the app opened, a pause ended, a lens was turned on).
    case launch
    /// The Mac or its displays woke up.
    case wake
    /// The displays changed (plugged, unplugged, rearranged, another resolution).
    case screensChanged
    /// ScreenCaptureKit ended the stream, for this reason.
    case streamStopped(CaptureStop)
}

/// Why ScreenCaptureKit ended a stream, as far as the recovery tells the cases apart.
public enum CaptureStop: Equatable, Sendable {
    /// The grant, not the stream (`SCStreamError.userDeclined`): the grant's own path (`AppModel.permissionChanged`) starts the lens again.
    case permission
    /// The person stopped sharing (`SCStreamError.userStopped`): not for the app to undo.
    case userStopped
    /// Anything else (the system stopped it, a display went, an internal error): worth starting again.
    case other

    public static let userStoppedCode = -3817

    public static func classify(domain: String, code: Int) -> CaptureStop {
        guard domain == CaptureFailure.screenCaptureKitDomain else { return .other }
        switch code {
        case CaptureFailure.userDeclinedCode: return .permission
        case userStoppedCode: return .userStopped
        default: return .other
        }
    }
}

/// What a lens does about a `CaptureEvent`.
public enum CaptureAction: Equatable, Sendable {
    case nothing
    /// Start the capture again after this many seconds.
    case restart(after: TimeInterval)
    /// The lens's display is gone: the lens moves here, and its capture starts there at once.
    case move(to: CGRect)
}

/// The times of the recovery.
public struct CaptureRecoveryPolicy: Equatable, Sendable {
    /// Seconds before the next restart after a stop or a failed restart; when the list runs out the lens waits for the next event
    /// (a wake, a change of displays, the grant, the lens moved) instead of trying for ever.
    public var backoff: [TimeInterval]
    /// Seconds a display event settles before it is acted on: a wake or an undock arrives as a burst, and the displays are not all
    /// back at once, so the first look would move a lens off a display that comes back a second later.
    public var settle: TimeInterval
    /// A stream that ran this long before it stopped starts a new episode (the backoff begins again).
    public var healthy: TimeInterval

    public init(backoff: [TimeInterval], settle: TimeInterval, healthy: TimeInterval) {
        self.backoff = backoff
        self.settle = settle
        self.healthy = healthy
    }

    public static let standard = CaptureRecoveryPolicy(backoff: [1, 2, 5, 15, 30], settle: 1.5, healthy: 30)
}

/// The one rule for a lens's capture when the Mac sleeps, its displays change or ScreenCaptureKit stops the stream: before this a
/// stopped capture left the lens dead with no signal (the 2026-10-18 footprint audit, F1).
public enum CaptureRecovery {
    /// - `followsWindow`: the lens is placed by its window, so it never moves for a display (the window does).
    /// - `streamDisplay`: the frame of the display the stream runs on; nil while there is no stream.
    /// - `failures`: restarts already tried since the stream last stopped after running healthy.
    public static func decide(_ event: CaptureEvent, lens: CGRect, followsWindow: Bool, streamDisplay: CGRect?, layout: DisplayLayout,
                              failures: Int, policy: CaptureRecoveryPolicy = .standard) -> CaptureAction {
        // The grant and the person's own stop are not the stream's to fix: no restart, and no move that would imply one.
        if case let .streamStopped(stop) = event, stop != .other { return .nothing }
        if !followsWindow, let to = LensPlacement.resolve(lens, in: layout) { return .move(to: to) }
        switch event {
        case .launch:
            return .nothing
        case .wake:
            // No frame comes for content that did not change: a stream that died quietly looks like a still screen.
            return .restart(after: 0)
        case .screensChanged:
            // Only a stream on a display that is no longer there as it was (gone, another size, another place) is wrong.
            return streamDisplay != nil && streamDisplay == layout.display(showing: lens) ? .nothing : .restart(after: 0)
        case .streamStopped:
            return failures >= 0 && failures < policy.backoff.count ? .restart(after: policy.backoff[failures]) : .nothing
        }
    }
}
