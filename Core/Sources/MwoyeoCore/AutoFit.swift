import CoreGraphics
import Foundation

/// Auto Fit, a lens option (off by default): after a read settles, a lens that cuts the text of its column at its left or right edge grows to
/// the column once; a lens the user moves onto other content takes that content's shape when let go, as the picker would place it (`landed`).
/// Otherwise it never shrinks, never moves while content scrolls or the user drags, acts at most once per settle, stays inside the display
/// and window, and a manual resize turns it off for that lens (docs/design/lens-fit.md section 7).
///
/// The whole of it is `step`: a table of (state, event) rows over plain values, so every row is a test case and the session only carries out the
/// action it returns. Where a row has a guard the guard is in the event's `Context` (what the session saw) or in `evaluate` (what the column says).
public enum AutoFit {
    /// The column reaches beyond the lens's edge by more than this where the lens meets a block of it: the lens cuts the text.
    public static let cutMargin: CGFloat = 4
    /// A growth under this much is not worth an animation.
    public static let minGrow: CGFloat = 6
    /// A target wider than this many lens widths is not a column the lens was meant for (a full-width abstract over a half-width lens).
    public static let maxGrowth: CGFloat = 2.0
    /// A column whose edges lie this close to the ones of the last fit is the same column.
    public static let sameColumn: CGFloat = 12
    /// Content must have stood still this long (seconds) before a settle counts; the session owns the clock.
    public static let calmAfter: TimeInterval = 1.0

    /// "At most once per settle, never while the page scrolls or a hand is on the lens": a snapshot is judged once, and only when the read is idle, the
    /// content has stood still for `calm` seconds, no hand is on the lens and it is on the screen. The session asks this and nothing else before it lets
    /// `step` see a `settled` event.
    public struct SettleGate: Equatable, Sendable {
        public enum Verdict: Equatable, Sendable {
            /// Not now, and nothing to wait for (the snapshot was judged, a hand is on the lens, the read is not idle, the lens is off the screen).
            case no
            /// The content moved lately: ask again in this many seconds.
            case wait(TimeInterval)
            /// This snapshot is judged now (and not again).
            case judge
        }
        public private(set) var judged = 0
        public init() {}

        public mutating func check(version: Int, now: TimeInterval, lastMotion: TimeInterval, calm: TimeInterval, idle: Bool, dragging: Bool, onScreen: Bool) -> Verdict {
            guard version > judged, idle, !dragging, onScreen else { return .no }
            let wait = lastMotion + calm - now
            guard wait <= 0 else { return .wait(wait) }
            judged = version
            return .judge
        }

        /// The next snapshot is judged afresh, even one already judged (Auto Fit turned on, a lens dropped).
        public mutating func rearm() { judged = 0 }
    }

    public enum State: Equatable, Sendable {
        case off
        /// Waiting for a settle.
        case armed
        /// The capture is wider (`Overscan.band`) for one read, to find an edge the capture cut.
        case probing(ColumnFit.Sides)
        /// The lens is growing (animation under way).
        case fitting
        /// Grown to a column (`Machine.lastFit`): no more until the lens or the column changes.
        case held
    }

    /// Where a fit put the lens's edges, in the column's terms.
    public struct Edges: Equatable, Sendable {
        public var left: CGFloat, right: CGFloat
        public init(left: CGFloat, right: CGFloat) { self.left = left; self.right = right }
    }

    public struct Machine: Equatable, Sendable {
        public var state: State
        public var lastFit: Edges?
        public init(state: State = .off, lastFit: Edges? = nil) { self.state = state; self.lastFit = lastFit }
    }

    /// What the session saw when a read settled (or the probe's snapshot came).
    public struct Context: Equatable, Sendable {
        /// The activity is idle, the content has stood still `calmAfter`, no drag is under way, the lens is on the screen and not paused, and the
        /// snapshot is newer than the last one looked at.
        public var calm: Bool
        public var lens: CGRect
        /// The display, and the window of a window lens, intersected.
        public var bounds: CGRect
        /// `ColumnFit.under(lens)`, its edges marked (`ColumnFit.marked`).
        public var column: ColumnFit.Column?
        public var scale: CGFloat
        public init(calm: Bool, lens: CGRect, bounds: CGRect, column: ColumnFit.Column?, scale: CGFloat = 2) {
            self.calm = calm; self.lens = lens; self.bounds = bounds; self.column = column; self.scale = scale
        }
    }

    public enum Event: Equatable, Sendable {
        /// The menu turned it on, or a lens was made with it on.
        case enable
        case disable
        case settled(Context)
        /// The first snapshot after a probe was asked for.
        case probed(Context)
        /// A probe waited too long for its snapshot.
        case probeLapsed
        /// The user began to move the lens (or the animation was cut short by a hand on it), or the lens went off the screen.
        case dragged
        /// The user resized the lens.
        case resized
        /// The grow animation ended with the lens on these edges.
        case animationDone(Edges)
        /// Fit to Column by hand, ending on these edges.
        case fitted(Edges)
        /// A lens moved by hand came to rest at `lens`: `target` is what the picker would place for the content under its middle (`LensTarget.choose`
        /// on a read of its display), nil where there is none.
        case landed(lens: CGRect, target: CGRect?)
    }

    public enum Skip: String, Equatable, Sendable {
        /// The change is under `minGrow`.
        case small
        /// The target is wider than `maxGrowth` lens widths.
        case tooWide
        /// The cut side's lens edge already stands on the display's or window's.
        case atEdge
        /// The probe's snapshot still had no edge to fit to.
        case unknown
    }

    public enum Action: Equatable, Sendable {
        case none
        /// Animate the lens to this rect, then commit.
        case grow(CGRect)
        /// One wider read.
        case probe(ColumnFit.Sides)
        case skip(Skip)
        /// Animate the lens onto the content it was put on (the picker's target), then commit: unlike `grow` it may shrink and move.
        case land(CGRect)
        /// The capture goes back to its usual shape.
        case restoreCapture
        /// The animation ended: follow the window, save the rect, refit the capture.
        case commit
        /// A manual resize: this lens's Auto Fit is off (say so once), and the capture is its usual shape again.
        case disable
    }

    /// The row of the design's table for `event` in `machine`'s state.
    public static func step(_ machine: Machine, _ event: Event) -> (machine: Machine, action: Action) {
        var m = machine
        switch (m.state, event) {
        case (.off, .enable):
            m.state = .armed
            return (m, .none)
        case (_, .fitted(let edges)):
            m.lastFit = edges
            return (m, .none)
        case (.off, _):
            return (m, .none)
        case (let state, .disable):
            m.state = .off
            return (m, isProbing(state) ? .restoreCapture : .none)
        case (_, .resized):
            m.state = .off
            return (m, .disable)
        case (.armed, .landed(let lens, let target)), (.held, .landed(let lens, let target)):
            // Put on other content, the lens takes that content's shape; on the same (every edge within `minGrow`), it stays as the hand left it.
            guard let target, changed(lens, target) else {
                m.state = .armed
                return (m, .none)
            }
            m.state = .fitting
            return (m, .land(target))
        case (.armed, .settled(let c)):
            return decide(&m, c)
        case (.held, .settled(let c)):
            if let column = c.column, let last = m.lastFit, abs(column.left - last.left) <= sameColumn, abs(column.right - last.right) <= sameColumn {
                return (m, .none)
            }
            m.state = .armed
            return decide(&m, c)
        case (.probing, .probed(let c)):
            // One probe per request, never nested: an edge still unknown is a reason to do nothing.
            var (next, action) = decide(&m, c)
            if case .probe = action { next.state = .armed; action = .skip(.unknown) }
            return (next, action)
        case (.probing, .probeLapsed), (.probing, .dragged):
            m.state = .armed
            return (m, .restoreCapture)
        case (.fitting, .animationDone(let edges)):
            m.state = .held
            m.lastFit = edges
            return (m, .commit)
        case (.fitting, .dragged), (.held, .dragged):
            m.state = .armed
            return (m, .none)
        default:
            return (m, .none)
        }
    }

    private static func changed(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) >= minGrow || abs(a.maxX - b.maxX) >= minGrow || abs(a.minY - b.minY) >= minGrow || abs(a.maxY - b.maxY) >= minGrow
    }

    private static func isProbing(_ state: State) -> Bool {
        if case .probing = state { return true }
        return false
    }

    /// An armed lens at a settle: nothing, a probe, a growth or a reason for none.
    private static func decide(_ m: inout Machine, _ c: Context) -> (machine: Machine, action: Action) {
        let action = evaluate(c)
        switch action {
        case .grow: m.state = .fitting
        case .probe(let sides): m.state = .probing(sides)
        default: m.state = .armed
        }
        return (m, action)
    }

    /// What the column under the lens asks of it. The lens grows to the column's edges (never inward) on the sides where it cuts the text and can
    /// still grow; where the edge of the column was cut by the capture it asks for a probe first.
    public static func evaluate(_ c: Context) -> Action {
        guard c.calm, let column = c.column else { return .none }
        let lens = c.lens
        var cut: ColumnFit.Sides = []
        if column.cores.contains(where: { $0.intersects(lens) && $0.minX < lens.minX - cutMargin }) { cut.insert(.left) }
        if column.cores.contains(where: { $0.intersects(lens) && $0.maxX > lens.maxX + cutMargin }) { cut.insert(.right) }
        guard !cut.isEmpty else { return .none }
        var stuck: ColumnFit.Sides = []
        if lens.minX <= c.bounds.minX + 0.5 { stuck.insert(.left) }
        if lens.maxX >= c.bounds.maxX - 0.5 { stuck.insert(.right) }
        let movable = cut.subtracting(stuck)
        guard !movable.isEmpty else { return .skip(.atEdge) }
        switch ColumnFit.fitted(lens, to: column, within: c.bounds, sides: movable, growOnly: true, scale: c.scale, minChange: minGrow) {
        case .probe(let sides): return .probe(sides)
        case .unchanged: return .skip(.small)
        case .to(let rect, _): return rect.width > maxGrowth * lens.width ? .skip(.tooWide) : .grow(rect)
        }
    }
}
