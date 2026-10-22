import CoreGraphics

/// How much more than the visible lens to capture, and when to move or resize the capture.
///
/// Reading ahead around the lens is what makes a drag or a scroll reveal translations that are already there.
/// The lens moves freely inside the capture; the capture only re-centres when the lens nears its edge.
public enum Overscan {
    public enum Plan: Equatable, Sendable {
        case keep
        /// Same size, new place: only the uncovered strips need reading.
        case move(CGRect)
        /// New size (margins changed or the lens was resized).
        case resize(CGRect)
    }

    /// Margin per side: generous at rest (static content costs nothing — no frames arrive — and is translated ahead
    /// once), wider while content or the lens moves.
    public static func margins(for size: CGSize, wide: Bool) -> CGSize {
        func m(_ v: CGFloat) -> CGFloat { wide ? min(max(v * 0.4, 160), 320) : min(max(v * 0.3, 80), 240) }
        return CGSize(width: m(size.width), height: m(size.height))
    }

    /// Captures are laid on a 2-point grid: one change-detection pixel at both 1× and 2×, so a moved or resized
    /// capture still lines up exactly with what was read before.
    public static let grid: CGFloat = 2

    /// The lens plus margins, slid (not cut) to stay on `display`, snapped to the grid.
    ///
    /// `lead` (-1…1 per axis) is where things are heading: the lens moving that way, or new content arriving from that
    /// side while the page scrolls. Half a margin moves from the trailing side to the leading one, so text is read
    /// before it reaches the lens, and a dragged lens travels further before the capture has to follow.
    public static func rect(around lens: CGRect, wide: Bool, display d: CGRect, lead: CGVector = .zero) -> CGRect {
        let m = margins(for: lens.size, wide: wide)
        var r = lens.insetBy(dx: -m.width, dy: -m.height)
            .offsetBy(dx: max(-1, min(1, lead.dx)) * m.width / 2, dy: max(-1, min(1, lead.dy)) * m.height / 2)
        func snap(_ v: CGFloat, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> CGFloat { (v / grid).rounded(rule) * grid }
        r.size.width = snap(min(r.width, d.width), .down)
        r.size.height = snap(min(r.height, d.height), .down)
        r.origin.x = min(max(snap(r.minX), d.minX), d.maxX - r.width)
        r.origin.y = min(max(snap(r.minY), d.minY), d.maxY - r.height)
        return r
    }

    /// The display's whole width at the lens's rows, the vertical margins as at rest: the one wider read that finds where a column the capture cut
    /// ends (`ColumnFit`, a probe). Never during a drag; the capture goes back to `rect` when the read is in.
    public static func band(around lens: CGRect, display d: CGRect) -> CGRect {
        let m = margins(for: lens.size, wide: false)
        let rows = lens.insetBy(dx: 0, dy: -m.height)
        func snap(_ v: CGFloat, _ rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> CGFloat { (v / grid).rounded(rule) * grid }
        let height = snap(min(rows.height, d.height), .down)
        return CGRect(x: d.minX, y: min(max(snap(rows.minY), d.minY), d.maxY - height), width: snap(d.width, .down), height: height)
    }

    /// `band`: the capture is this rect (the `band(around:display:)` a probe took when it began, kept as it was while the lens moves or grows), whatever
    /// the margins say.
    public static func plan(lens: CGRect, capture: CGRect, wide: Bool, allowResize: Bool, display: CGRect, lead: CGVector = .zero, band probing: CGRect? = nil) -> Plan {
        if let want = probing { return want == capture ? .keep : .resize(want) }
        let want = rect(around: lens, wide: wide, display: display, lead: lead)
        let m = margins(for: lens.size, wide: wide)
        // Each side needs 40 % of its margin, or as much as the display allows there.
        let fits = lens.minX - capture.minX >= min(m.width * 0.4, lens.minX - want.minX) - 0.5
            && capture.maxX - lens.maxX >= min(m.width * 0.4, want.maxX - lens.maxX) - 0.5
            && lens.minY - capture.minY >= min(m.height * 0.4, lens.minY - want.minY) - 0.5
            && capture.maxY - lens.maxY >= min(m.height * 0.4, want.maxY - lens.maxY) - 0.5
        let resized = abs(want.width - capture.width) > 0.5 || abs(want.height - capture.height) > 0.5
        if resized && (allowResize || !fits) { return .resize(want) }
        return fits ? .keep : .move(want)
    }
}
