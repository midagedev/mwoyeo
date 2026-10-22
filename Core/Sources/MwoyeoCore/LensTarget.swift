import CoreGraphics
import Foundation

/// The one-click lens (docs/design/first-lens.md section 4, round oneclick117): what a click in the picker places. When the picker opens, one
/// read of the display gives its blocks; `Map` holds their columns (`ColumnFit`), and per pointer position `choose` gives the target: the
/// column's width by whole paragraphs, from the paragraph under the pointer down. Nil wherever there is no reading column (chat, games,
/// subtitles, code, a margin, a figure): the picker shows today's ghost (`ghost`), byte for byte.
///
/// Pure. `Map` and `choose` work in one space with y going down (the picker hands global Quartz points); `ghost` works in the picker view's
/// own space (AppKit, y up), as the picker always did.
public enum LensTarget {
    /// A column narrower than this (a table's cell column, a sidebar item) is not a reading column.
    public static let minWidth: CGFloat = 160
    /// How far beyond a column's padded edge the pointer still means the column (the gutter goes to the nearer column within it).
    public static let slack: CGFloat = 12
    /// The farthest a block may stand from the pointer's y and still anchor the target.
    public static let reach: CGFloat = 40
    /// A new anchor must beat the held one by this much (points of signed distance): no flicker at a gap's midpoint.
    public static let switchBy: CGFloat = 8
    /// A vertical gap between members that ends the target (a figure, a full-width element).
    public static let breakGap: CGFloat = 44
    /// A block is a member of the column whose x range, widened by this, holds it.
    public static let memberTolerance: CGFloat = 8
    /// The height budget is the default lens's area over the target's width (a read costs about what the default lens costs), within these.
    public static let budgetArea: CGFloat = 560 * 320
    public static let minBudget: CGFloat = 160, maxBudget: CGFloat = 560
    /// Short of members below, the target grows upward by whole members until it is this share of the budget.
    public static let upwardShare: CGFloat = 0.6
    /// A target holds at least this many lines and is at least this tall (the lens's resize floor).
    public static let minLines = 2
    public static let minHeight: CGFloat = 40
    /// A window this tall or less has no title bar to keep clear of; a taller one's top `titleBar` points are its title bar.
    public static let titleBarFloor: CGFloat = 120
    public static let titleBar: CGFloat = 28
    /// The preview's glide between targets (and between the ghost and a target): the settling time of the critically damped spring of
    /// ω = 30 (`LensMotion.settle`, the motion contract's `quick`, section 3.5: 90 % at 130 ms, at rest at 267 ms), run by `FitMotion.progress`.
    public static let glide: TimeInterval = LensMotion.settle

    // MARK: - The map

    /// One reading column and the blocks it holds, top to bottom (one-line headings and captions too).
    public struct Column: Sendable, Equatable {
        public var left: CGFloat, right: CGFloat
        public var members: [ColumnFit.Block]
        public init(left: CGFloat, right: CGFloat, members: [ColumnFit.Block]) { self.left = left; self.right = right; self.members = members }
        public var width: CGFloat { right - left }
    }

    /// The columns of one display, built once per picker open from every block the read found.
    public struct Map: Sendable, Equatable {
        public var columns: [Column]
        /// How many blocks the read found (the trace's `n`).
        public var blocks: Int

        public init(blocks: [ColumnFit.Block]) {
            columns = ColumnFit.columns(blocks).map { c in
                let held = blocks.filter { $0.core.minX >= c.left - LensTarget.memberTolerance && $0.core.maxX <= c.right + LensTarget.memberTolerance }
                return Column(left: c.left, right: c.right, members: held.sorted { ($0.core.minY, $0.core.minX) < ($1.core.minY, $1.core.minX) })
            }
            self.blocks = blocks.count
        }

        /// How many columns a target can stand in.
        public var readingColumns: Int { columns.filter { $0.width >= LensTarget.minWidth }.count }
    }

    /// What the pointer aims at: a lens rect, and the column and member it was chosen from (the held anchor of the next choice).
    public struct Target: Sendable, Equatable {
        public var rect: CGRect
        public var column: Int
        public var anchor: Int
        public init(rect: CGRect, column: Int, anchor: Int) { self.rect = rect; self.column = column; self.anchor = anchor }
    }

    // MARK: - Choosing

    /// The target at `pointer`, or nil (the ghost). `held` is the previous choice: its anchor stays until another member beats it by `switchBy`.
    /// `bounds` is what the lens may cover: the display, and the content of the window under the pointer below its title bar (`content`).
    /// The rect does not depend on the pointer's y inside the anchor: the outline steps from paragraph to paragraph, it does not follow the hand.
    public static func choose(_ map: Map, pointer p: CGPoint, held: Target? = nil, bounds: CGRect, scale: CGFloat = 2) -> Target? {
        // 1. The column whose padded range, widened by `slack`, holds the pointer; the nearer one when two do.
        let pad = ColumnFit.pad
        var nearest: (distance: CGFloat, index: Int)?
        for (i, c) in map.columns.enumerated() where p.x >= c.left - pad - slack && p.x <= c.right + pad + slack {
            let d = max(0, c.left - pad - p.x, p.x - (c.right + pad))
            if nearest.map({ d < $0.distance }) ?? true { nearest = (d, i) }
        }
        guard let ci = nearest?.index, map.columns[ci].width >= minWidth else { return nil }
        let column = map.columns[ci], members = column.members.map(\.core)

        // 2. The anchor: the member with the best signed distance (depth inside, less the distance outside); the held one while it is not beaten.
        func score(_ b: CGRect) -> CGFloat { b.minY <= p.y && p.y <= b.maxY ? min(p.y - b.minY, b.maxY - p.y) : -min(abs(p.y - b.minY), abs(p.y - b.maxY)) }
        var anchor = -1, best = -CGFloat.infinity
        for (i, b) in members.enumerated() where score(b) > best { anchor = i; best = score(b) }
        if let h = held, h.column == ci, members.indices.contains(h.anchor), h.anchor != anchor, score(members[h.anchor]) >= -reach,
           best - score(members[h.anchor]) < switchBy {
            anchor = h.anchor
            best = score(members[h.anchor])
        }
        guard anchor >= 0, best >= -reach else { return nil }

        // 3. The extent: from the anchor down over members closer than `breakGap`, until the height budget; a member crossing the budget stays
        //    when at least half of it fits. Short of members (or room) below, up over whole members.
        let width = column.width + 2 * pad
        let budget = max(minBudget, min(maxBudget, budgetArea / width))
        var top = members[anchor].minY, bottom = members[anchor].maxY
        var j = anchor
        while j + 1 < members.count, bottom - top < budget, members[j + 1].minY - bottom <= breakGap,
              members[j + 1].maxY - top <= budget || budget - (bottom - top) >= members[j + 1].height / 2 {
            j += 1
            bottom = max(bottom, members[j].maxY)
        }
        bottom = min(bottom, bounds.maxY)
        var k = anchor
        while bottom - top < budget * upwardShare, k > 0, top - members[k - 1].maxY <= breakGap, members[k - 1].minY >= bounds.minY {
            k -= 1
            top = min(top, members[k].minY)
        }
        top = max(top, bounds.minY)
        let lines = column.members.filter { top - 1 <= $0.core.minY && $0.core.maxY <= bottom + 1 }.reduce(0) { $0 + $1.lines }
        guard lines >= minLines, bottom - top >= minHeight else { return nil }

        // 4. The width: the column, padded as a fit pads it, kept inside `bounds`, on the pixel grid.
        let grid = max(scale, 1)
        func aligned(_ v: CGFloat) -> CGFloat { (v * grid).rounded() / grid }
        let left = aligned(max(column.left - pad, bounds.minX)), right = aligned(min(column.right + pad, bounds.maxX))
        let y0 = aligned(top), y1 = aligned(bottom)
        guard right - left >= minWidth else { return nil }
        return Target(rect: CGRect(x: left, y: y0, width: right - left, height: y1 - y0), column: ci, anchor: anchor)
    }

    /// What a lens may cover in `display` when the pointer is over `window` (y down): the window's content below its title bar, on the display.
    public static func content(of window: CGRect?, on display: CGRect) -> CGRect {
        guard let w = window else { return display }
        let bar = w.height > titleBarFloor ? titleBar : 0
        return CGRect(x: w.minX, y: w.minY + bar, width: w.width, height: w.height - bar).intersection(display)
    }

    // MARK: - The ghost

    /// Today's click lens, where there is no target: the default lens size centred on `p`, kept inside the window's content and the view.
    /// In the picker view's own space (AppKit, y up: a window's title bar is its top strip); `window` is the hovered window's frame in it.
    /// Moved here unchanged from `PickerView.clickLens` (the default path: `LensTargetTests` holds it to the old code, byte for byte).
    public static func ghost(at p: CGPoint, window: CGRect?, in bounds: CGRect, size: CGSize = KeyboardLens.defaultSize) -> CGRect {
        var area = bounds
        if let w = window {
            let bar: CGFloat = w.height > titleBarFloor ? titleBar : 0
            area = w.intersection(bounds)
            area.size.height -= bar // AppKit y is up: the title bar is the top strip
        }
        let size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        let x = min(max(p.x - size.width / 2, area.minX), area.maxX - size.width)
        let y = min(max(p.y - size.height / 2, area.minY), area.maxY - size.height)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    // MARK: - The glide

    /// The preview's rect over time. A change of target adds its own step of the spring (`FitMotion.progress` over `glide`), so a change of
    /// mind in mid-glide keeps the velocity (motion contract 3.5: additive); a follow (the ghost under a moving pointer) moves at once and keeps
    /// whatever glide is under way; under Reduce Motion everything jumps. Times are seconds on one clock (the display link's, or a check's).
    public struct Glide: Sendable, Equatable {
        /// What is left to travel when a step starts (the previous target less the new one, edge by edge; a CGRect would standardize it).
        private struct Step: Sendable, Equatable { var dx, dy, dw, dh: CGFloat; var start: TimeInterval }
        /// Where the preview goes; nil before the first rect.
        public private(set) var target: CGRect?
        private var steps: [Step] = []

        public init() {}

        public enum Move: Sendable { case glide, follow, jump }

        /// The preview goes to `rect` from time `t`.
        public mutating func move(to rect: CGRect, at t: TimeInterval, _ how: Move) {
            defer { target = rect }
            guard let from = target, how != .jump else { steps = []; return }
            guard how == .glide, from != rect else { return }
            steps.append(Step(dx: from.minX - rect.minX, dy: from.minY - rect.minY, dw: from.width - rect.width, dh: from.height - rect.height, start: t))
        }

        /// The preview is gone (the pointer left, a drag began): the next rect appears where it is.
        public mutating func clear() { target = nil; steps = [] }

        /// The rect at time `t`: the target less what is left of every step.
        public func rect(at t: TimeInterval) -> CGRect? {
            guard var r = target else { return nil }
            for s in steps where t < s.start + LensTarget.glide {
                let left = 1 - FitMotion.progress(t - s.start, duration: LensTarget.glide)
                r = CGRect(x: r.minX + s.dx * left, y: r.minY + s.dy * left, width: r.width + s.dw * left, height: r.height + s.dh * left)
            }
            return r
        }

        /// Whether a step is still under way at `t` (the display link keeps running until none is); finished steps are dropped.
        public mutating func moving(at t: TimeInterval) -> Bool {
            steps.removeAll { t >= $0.start + LensTarget.glide }
            return !steps.isEmpty
        }
    }
}
