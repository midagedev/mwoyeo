import CoreGraphics
import Foundation

/// Where the region marker's hint pills go (gamepill, 2026-10-22). The pills were drawn at the screen's middle at a fixed distance from its top
/// and fell on a lens near the top or the right; now they are placed against the lens, in the marker view's coordinates (y up).
public enum MarkerHints {
    /// Between two pills.
    public static let spacing: CGFloat = 8
    /// How far a pill stays from the visible frame's edge when it sits inside the lens (the one case where it cannot stay away from it).
    public static let inset: CGFloat = 8

    /// The frames of `pills` (sizes, the first on top, `spacing` between), as one stack: above the lens when it fits there, else below, else
    /// to its right, else to its left. The stack is `clearance` away from `lens` on every side, centred on it where it can be, and inside
    /// `visible`. A lens that leaves no room on any side gets the stack just inside the top of `visible`.
    public static func place(pills: [CGSize], lens: CGRect, visible: CGRect, clearance: CGFloat) -> [CGRect] {
        guard !pills.isEmpty else { return [] }
        let height = pills.reduce(0) { $0 + $1.height } + spacing * CGFloat(pills.count - 1)
        let width = pills.map(\.width).max() ?? 0
        let keep = lens.insetBy(dx: -clearance, dy: -clearance)
        // `top` is the stack's top edge; each pill is centred on `midX`, or flush to `edge` when the stack stands beside the lens.
        func stack(top: CGFloat, align: (CGSize) -> CGFloat) -> [CGRect] {
            var y = top
            return pills.map { size in
                y -= size.height
                defer { y -= spacing }
                return CGRect(x: align(size), y: y, width: size.width, height: size.height)
            }
        }
        func centred(on midX: CGFloat) -> (CGSize) -> CGFloat {
            { size in max(visible.minX, min(midX - size.width / 2, visible.maxX - size.width)) }
        }
        if keep.maxY + height <= visible.maxY { return stack(top: keep.maxY + height, align: centred(on: lens.midX)) }
        if keep.minY - height >= visible.minY { return stack(top: keep.minY, align: centred(on: lens.midX)) }
        let top = max(visible.minY + height, min(lens.midY + height / 2, visible.maxY))
        if keep.maxX + width <= visible.maxX { return stack(top: top, align: { _ in keep.maxX }) }
        if keep.minX - width >= visible.minX { return stack(top: top, align: { keep.minX - $0.width }) }
        return stack(top: min(lens.maxY, visible.maxY) - inset, align: centred(on: lens.midX))
    }
}
