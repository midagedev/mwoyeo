import CoreGraphics
import Foundation

/// What the one-click picker's spotlight shows while the display's map is read (round picktarget117, film4 defect: the first outline spilled over
/// Preview's dark margin; docs/design/first-lens.md 2.1 and 4.2). The spotlight is a target's rect, the default lens (`ghost`: 560 x 320 round the
/// pointer, kept inside the window, not inside the page: nothing is known of the page before the read), or nothing.
///
/// The read takes 0.3 to 0.6 s (the take: 532 ms), and until then the ghost followed the pointer over whatever stood under it (a dark margin, a
/// sidebar), then glided into the first target. A target stands inside the column it was built from; the ghost cannot. So the ghost does not show
/// while the read is young: the first outline the person sees is a target, which appears where it stands. It shows once the read has taken
/// `ghostGrace` (a read that is slow, or answers nothing within its patience, must not leave the pointer without a preview), and at once where the
/// read gave nothing (chat, games, subtitles: today's ghost). A click never waits: it places the target, else the default lens, as before.
///
/// What the ghost can know before the map: the display, the window list (each window's frame, so the window under the pointer and, by the 28 pt
/// rule of `ghost`, its title bar: a window taller than 120 pt loses its top strip) and the pointer. It is kept inside the window's content below
/// that title bar and inside the display, never over the frame's chrome. A toolbar, a sidebar, a page's margin are in the picture only, and the
/// picture is the read; so before it, the ghost is a guess about a page it has not seen, which is why it waits for the read.
extension LensTarget {
    /// How long a read may keep the default lens off the screen. Measured in the app (Release, a 3024 x 1964 px display, the film4 takes' `picker: map
    /// ... read=` lines, 8 reads): 511, 523, 532, 581, 610, 614, 653, 714 ms; the headless bench (first-lens.md 2.1) 0.30 to 0.44 s on the lines
    /// path, 0.61 s at the worst of the Docs path, 2.4 s when the Docs service answered after its patience and the read was rerouted. 0.8 s is
    /// above every read of the app's own path (the slowest 0.714 s, plus 12 %) and below the rerouted 2.4 s: an ordinary read never shows the
    /// default lens, a stalled one does, after a wait short enough not to read as "nothing is happening". A parameter: the checks inject theirs.
    public static let ghostGrace: TimeInterval = 0.8

    /// Where the picker's read of the display stands.
    public enum MapPhase: Sendable, Equatable {
        /// No read is under way and none will be (no reader).
        case unread
        /// The read began at `since` (seconds on the picker's clock).
        case reading(since: TimeInterval)
        /// The map is there: a target, or the ghost where it has none.
        case ready
        /// The read gave nothing (no column, no permission, no answer within its patience).
        case empty
        /// The picker is gone.
        case closed
    }

    public enum Shown: Sendable, Equatable { case target, ghost, nothing }

    public struct Preview: Sendable, Equatable {
        public var shown: Shown
        /// Seconds after which the picker must ask again though nothing has moved (the grace's end); nil when no moment is due.
        public var recheckIn: TimeInterval?
        public init(shown: Shown, recheckIn: TimeInterval? = nil) { self.shown = shown; self.recheckIn = recheckIn }
    }

    /// What the spotlight shows at `now` (seconds on the picker's clock): the target when `aimed` (only a ready map aims), else per `phase`.
    public static func preview(_ phase: MapPhase, aimed: Bool, now: TimeInterval, grace: TimeInterval = ghostGrace) -> Preview {
        if aimed { return Preview(shown: .target) }
        switch phase {
        case .reading(let since):
            let wait = grace - (now - since)
            return wait > 0 ? Preview(shown: .nothing, recheckIn: wait) : Preview(shown: .ghost)
        case .closed: return Preview(shown: .nothing)
        case .unread, .ready, .empty: return Preview(shown: .ghost)
        }
    }
}

// MARK: - The spotlight's entrance

extension LensTarget {
    /// The side of the square the spotlight starts from: twice the outline's 10 pt corner radius, so the outline is a circle and never degenerate.
    public static let seedSide: CGFloat = 20
}

extension LensTarget.Glide {
    /// The spotlight comes into being (it was nothing: the read was young, the pointer came back, a drag ended) and opens to `rect`. It starts
    /// from the pointer: a `seedSide` square centred on `pointer`, moved inside `rect` (the gutter's slack puts the pointer up to 12 pt outside a
    /// target), and goes to `rect` on the glide's own spring (`quick` of the motion contract 3.5: 0.267 s, 90 % at 130 ms, additive with any
    /// change of mind). Every rect on the way lies inside `rect`: the first outline never stands anywhere its target does not. Under Reduce Motion
    /// (`.jump`) it is at `rect` at once.
    public mutating func appear(from pointer: CGPoint, to rect: CGRect, at t: TimeInterval, _ how: Move) {
        guard how != .jump else { return move(to: rect, at: t, .jump) }
        let side = min(LensTarget.seedSide, rect.width, rect.height)
        let seed = CGRect(x: min(max(pointer.x - side / 2, rect.minX), rect.maxX - side),
                          y: min(max(pointer.y - side / 2, rect.minY), rect.maxY - side), width: side, height: side)
        move(to: seed, at: t, .jump)
        move(to: rect, at: t, .glide)
    }
}
