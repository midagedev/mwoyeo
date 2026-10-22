import AppKit
import CoreGraphics
import Foundation
import MwoyeoCore

/// What a lens remembers about the columns around it and about its fit (docs/design/lens-fit.md): one value held by `RegionSession`, whose extension
/// in RegionSession.swift owns every transition. The geometry is `ColumnFit` and the Auto Fit table is `AutoFit`, both pure and in Core; this holds
/// what the session saw.
struct LensFit {
    /// The newest snapshot's columns, global Quartz points, edges marked (`ColumnFit.marked`), and the snap targets made from them.
    var columns: [ColumnFit.Column] = []
    var targets = ColumnFit.Targets()
    /// That snapshot's version, when it came (`ProcessInfo.systemUptime`) and the part of the capture its blocks were read from (global Quartz): a snapshot that came before
    /// the last motion of the content is not trusted for a fit, and a probe waits for one read from the band.
    var version = 0
    var receivedAt: TimeInterval = 0
    var captured = CGRect.zero
    /// When the content last moved (a scroll, a change the pipeline saw), not the lens: columns read before it may have moved.
    var contentMovedAt: TimeInterval = 0
    /// Which snapshots Auto Fit has judged, and when one may be (`AutoFit.SettleGate`).
    var gate = AutoFit.SettleGate()

    /// Auto Fit (`AutoFit.step`).
    var machine = AutoFit.Machine()

    /// The snap a drag is in (`ColumnFit.snap`), for its hysteresis and for the guide; nil outside a snap.
    var snap: ColumnFit.Snap?
    /// Where a resize shows its right edge while the guide is up (`LiveSnap`: instant, or the taper with a dwell capture), and the clock it reads (the
    /// checks give a fake one).
    var live = LiveSnap(feel: RegionSession.snapFeel)
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// The rect the lens had before the last fit, kept until the next drag, resize or close: what Undo Fit goes back to.
    var undo: CGRect?
    /// The rect a fit animation is going to; the lens is animating while it is not nil.
    var animatingTo: CGRect?
    var animating: Bool { animatingTo != nil }

    /// One wider read is under way (`Overscan.band`): which edges it looks for, why, and when it began.
    struct Probe {
        /// `scout`: a hand began to resize the lens, whose capture does not follow it: one read of the band at the drag's start gives the snap the edges
        /// ahead of the corner (film4 F4). It fits nothing and waits for nothing: the drop ends it.
        enum Reason { case manual, auto, scout }
        var sides: ColumnFit.Sides
        var reason: Reason
        var since: TimeInterval
        var version: Int
    }
    var probe: Probe?
    /// The capture is this display-wide band (`Overscan.band`, taken when the probe began and kept while the lens moves or grows): from a probe's start
    /// until the lens is committed or the probe gives up.
    var band: CGRect?
    /// A hand is on the lens (a move that began), a settle onto a snap is running: the lens's own frames are not a drag's to judge.
    var handOn = false
    var settling = false
    /// The probe's wait for its snapshot, and the wait for content to stand still before Auto Fit judges.
    var probeTimer: Timer?
    var settleTimer: Timer?
    /// Seconds content must have stood still before Auto Fit judges, and how long a probe waits for its snapshot: the design's numbers, held here so the
    /// checks give a lens none to wait for.
    var calm = AutoFit.calmAfter
    var probeTimeout: TimeInterval = 10
    /// Whether ⌘ is down (no snap): the keyboard's, as the checks give it.
    var commandDown: () -> Bool = { NSEvent.modifierFlags.contains(.command) }
}
