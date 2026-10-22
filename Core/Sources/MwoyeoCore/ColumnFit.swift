import CoreGraphics
import Foundation

/// Where the text columns of a page are, and what a lens does about them: snap its edges to them, fit to the one under it, grow to it
/// (docs/design/lens-fit.md, round fit117). Pure, in points, in whatever coordinate space the caller works in (the pipeline hands
/// capture-local ones; the session moves them to the screen's).
///
/// A column is read from the lines of the blocks the reader found, never from the patches the overlay draws: a block is the union of its
/// lines (its `core`), and only a block of several lines says anything about where a column ends. The right edge of a column comes out
/// 1.3 pt wide on average (the block's box is a little wider than the justified edge), 2.1 at worst on the paper bench (24 of 26 column
/// cells found, every page with prose; width error 87 % within 2 pt, 100 % within 3 pt), and a capture that cuts a column is never mistaken
/// for the column: its edge is marked unknown (`marked`) and the lens asks for one wider read before it fits.
public enum ColumnFit {
    /// A block with fewer lines is a heading, a caption line or a table cell: it says nothing about a column.
    public static let minLines = 2
    /// Blocks whose left edges lie this close together (single link on the sorted edges) stand in one column.
    public static let tolerance: CGFloat = 6
    /// In one column of blocks, right edges that jump by more than this split it (a full-width paragraph sharing a half-width column's left edge).
    public static let split: CGFloat = 24
    /// A column needs this many lines in all.
    public static let minSupport = 4
    /// `under`: the share of the lens's width a column must hold, and the largest share a rival may hold of the winner's.
    public static let need: CGFloat = 0.4
    public static let rival: CGFloat = 0.5
    /// A fitted lens stands this far outside the text: the ring is stroked on the lens's edge and its grab band is 10 pt wide, and the reader's box
    /// stands within 1.3 pt of the text on the right, so the text stays clear of the ring and of a glyph cut at the edge.
    public static let pad: CGFloat = 6
    /// A column edge this close to the capture's edge (that is not a display edge) is where the capture ends, not where the column does.
    public static let edgeTolerance: CGFloat = 2.5
    /// A snap pulls from this far, and lets go from `release` (so a guide does not flicker at the border).
    public static let reach: CGFloat = 8
    public static let release: CGFloat = 12
    /// What a live resize (the hand drags the edge) takes of the pull: the lens's edge is on the target while the hand is within this, and the pull
    /// tapers to nothing at `release`, so the edge never moves under the hand by more than this (`livePull`).
    public static let plateau: CGFloat = 4
    /// A fit that would change an edge by less than this is nothing to do.
    public static let minChange: CGFloat = 2
    /// The narrowest lens (`RegionFrameWindow`'s resize floor).
    public static let minWidth: CGFloat = 80

    /// One block as the estimator reads it: the union of its lines, and how many there are.
    public struct Block: Sendable, Equatable {
        public var core: CGRect
        public var lines: Int
        public init(core: CGRect, lines: Int) { self.core = core; self.lines = lines }
    }

    public struct Column: Sendable, Equatable {
        public var left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat
        /// Its blocks' count and lines.
        public var blocks: Int, lines: Int
        /// The cores of its blocks: where the lens meets text of this column (`AutoFit`).
        public var cores: [CGRect]
        /// False where the capture ends inside the column (`marked`): the column goes on beyond what was read.
        public var leftKnown = true, rightKnown = true

        public init(left: CGFloat, right: CGFloat, top: CGFloat, bottom: CGFloat, blocks: Int, lines: Int, cores: [CGRect] = [],
                    leftKnown: Bool = true, rightKnown: Bool = true) {
            self.left = left; self.right = right; self.top = top; self.bottom = bottom; self.blocks = blocks; self.lines = lines
            self.cores = cores; self.leftKnown = leftKnown; self.rightKnown = rightKnown
        }

        public var width: CGFloat { right - left }

        /// The column in other coordinates (capture-local to the screen's).
        public func offset(dx: CGFloat, dy: CGFloat) -> Column {
            var c = self
            c.left += dx; c.right += dx; c.top += dy; c.bottom += dy
            c.cores = cores.map { $0.offsetBy(dx: dx, dy: dy) }
            return c
        }
    }

    /// Sides of a column or lens.
    public struct Sides: OptionSet, Sendable, Equatable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let left = Sides(rawValue: 1), right = Sides(rawValue: 2)
        public static let both: Sides = [.left, .right]
    }

    // MARK: - Columns

    /// The columns of `blocks`, left to right. Stacks of blocks with the same left edge, split where the right edges jump; the column's left
    /// is the median of its lefts and its right the furthest right (a lower bound where the text is ragged).
    public static func columns(_ blocks: [Block]) -> [Column] {
        let evidence = blocks.enumerated().filter { $0.element.lines >= minLines }
            .sorted { ($0.element.core.minX, $0.offset) < ($1.element.core.minX, $1.offset) }.map(\.element)
        var stacks: [[Block]] = [], current: [Block] = []
        for b in evidence {
            if let last = current.last, b.core.minX - last.core.minX > tolerance { stacks.append(current); current = [] }
            current.append(b)
        }
        if !current.isEmpty { stacks.append(current) }
        var out: [Column] = []
        for stack in stacks {
            let byRight = stack.enumerated().sorted { ($0.element.core.maxX, $0.offset) < ($1.element.core.maxX, $1.offset) }.map(\.element)
            var subs: [[Block]] = [], sub: [Block] = []
            for b in byRight {
                if let last = sub.last, b.core.maxX - last.core.maxX > split { subs.append(sub); sub = [] }
                sub.append(b)
            }
            if !sub.isEmpty { subs.append(sub) }
            for s in subs {
                let lines = s.reduce(0) { $0 + $1.lines }
                guard lines >= minSupport else { continue }
                let lefts = s.map(\.core.minX).sorted()
                let left = lefts.count % 2 == 1 ? lefts[lefts.count / 2] : (lefts[lefts.count / 2 - 1] + lefts[lefts.count / 2]) / 2
                out.append(Column(left: left, right: s.map(\.core.maxX).max() ?? left, top: s.map(\.core.minY).min() ?? 0,
                                  bottom: s.map(\.core.maxY).max() ?? 0, blocks: s.count, lines: lines, cores: s.map(\.core)))
            }
        }
        return out.sorted { ($0.left, $0.right) < ($1.left, $1.right) }
    }

    /// `columns` with the edges the capture cut marked unknown: an edge within `edgeTolerance` of the capture's side is where the capture
    /// ends, unless that side is the display's too (the page ends there).
    public static func marked(_ columns: [Column], capture: CGRect, display: CGRect) -> [Column] {
        columns.map { c in
            var c = c
            let box = CGRect(x: c.left, y: c.top, width: c.width, height: c.bottom - c.top)
            c.leftKnown = !(CaptureEdge.touchesSide(box, .left, in: capture, tolerance: edgeTolerance) && capture.minX > display.minX + 1)
            c.rightKnown = !(CaptureEdge.touchesSide(box, .right, in: capture, tolerance: edgeTolerance) && capture.maxX < display.maxX - 1)
            return c
        }
    }

    /// The column under `lens`: the one holding the largest share of the lens's width (at least `need`) among those that touch it vertically,
    /// when no other holds more than `rival` of that share. Nil is the answer "ambiguous" (across the gutter, across both columns, none).
    /// The share is of the lens's width, not the column's: a column the capture cut is narrower than it is, and normalising by it made rivals of it.
    public static func under(_ lens: CGRect, in columns: [Column]) -> Column? {
        guard lens.width > 0 else { return nil }
        let held = columns.enumerated().filter { $0.element.bottom >= lens.minY && $0.element.top <= lens.maxY }.map { entry -> (share: CGFloat, at: Int) in
            (max(0, min(lens.maxX, entry.element.right) - max(lens.minX, entry.element.left)) / lens.width, entry.offset)
        }.filter { $0.share > 0 }.sorted { ($1.share, $0.at) < ($0.share, $1.at) }
        guard let best = held.first, best.share >= need else { return nil }
        if held.count > 1, held[1].share > rival * best.share { return nil }
        return columns[best.at]
    }

    // MARK: - Fit

    public enum Fit: Equatable, Sendable {
        /// Nothing worth moving: the edges are where the column puts them, within `minChange`.
        case unchanged
        /// The lens's new rect (its y and height are the lens's own). `runsOff`: the column goes on past the display's or window's edge, and the lens takes that edge.
        case to(CGRect, runsOff: Bool)
        /// An edge the capture cut is unknown: one wider read first.
        case probe(Sides)
    }

    /// The lens fitted to `column`: x from `column.left - pad` to `column.right + pad`, clamped to `bounds` (the display, and the window of a window
    /// lens), aligned to the pixel grid of `scale`; y and height stay. `sides` are the edges that may move; with `growOnly` an edge never moves
    /// inward (Auto Fit never shrinks a lens).
    public static func fitted(_ lens: CGRect, to column: Column, within bounds: CGRect, sides: Sides = .both, growOnly: Bool = false,
                              pad: CGFloat = pad, scale: CGFloat = 2, minChange: CGFloat = minChange) -> Fit {
        var unknown: Sides = []
        if sides.contains(.left), !column.leftKnown { unknown.insert(.left) }
        if sides.contains(.right), !column.rightKnown { unknown.insert(.right) }
        guard unknown.isEmpty else { return .probe(unknown) }
        let grid = max(scale, 1)
        func aligned(_ v: CGFloat) -> CGFloat { (v * grid).rounded() / grid }
        var left = lens.minX, right = lens.maxX, runsOff = false
        if sides.contains(.left) {
            let want = max(column.left - pad, bounds.minX)
            runsOff = runsOff || column.left <= bounds.minX + edgeTolerance
            left = growOnly ? min(lens.minX, aligned(want)) : aligned(want)
        }
        if sides.contains(.right) {
            let want = min(column.right + pad, bounds.maxX)
            runsOff = runsOff || column.right >= bounds.maxX - edgeTolerance
            right = growOnly ? max(lens.maxX, aligned(want)) : aligned(want)
        }
        guard right - left >= minWidth else { return .unchanged }
        guard abs(left - lens.minX) >= minChange || abs(right - lens.maxX) >= minChange else { return .unchanged }
        return .to(CGRect(x: left, y: lens.minY, width: right - left, height: lens.height), runsOff: runsOff)
    }

    // MARK: - Snap

    /// One vertical line a lens edge may be pulled to: where the lens's edge should stand (the column's edge, pad included), and the extent of
    /// the column along it, for the guide.
    public struct Target: Sendable, Equatable {
        public var x: CGFloat, top: CGFloat, bottom: CGFloat
        public init(x: CGFloat, top: CGFloat, bottom: CGFloat) { self.x = x; self.top = top; self.bottom = bottom }
    }

    public struct Targets: Sendable, Equatable {
        /// For the lens's left edge (a column's left, less the pad) and its right edge (a column's right, plus it).
        public var lefts: [Target], rights: [Target]
        public init(lefts: [Target] = [], rights: [Target] = []) { self.lefts = lefts; self.rights = rights }
        /// Only an edge that is known is a target: an edge the read ended at (`marked`) is where the capture stopped, not where the column does, and a
        /// guide there would put the lens short of the column (film4 F4: the right edge came out 44 pt inside the column).
        public init(columns: [Column], pad: CGFloat = ColumnFit.pad) {
            lefts = columns.filter(\.leftKnown).map { Target(x: $0.left - pad, top: $0.top, bottom: $0.bottom) }
            rights = columns.filter(\.rightKnown).map { Target(x: $0.right + pad, top: $0.top, bottom: $0.bottom) }
        }
        public var isEmpty: Bool { lefts.isEmpty && rights.isEmpty }
    }

    public struct Snap: Sendable, Equatable {
        public var edge: Sides
        public var target: Target
        /// What to add to the lens's x so that its edge stands on the target.
        public var offset: CGFloat
        public init(edge: Sides, target: Target, offset: CGFloat) { self.edge = edge; self.target = target; self.offset = offset }
    }

    /// What a new pull is to the person, against the one before it: a guide (and one tick) as an edge comes within reach or another target takes over,
    /// the guide's end as it lets go, nothing while the same target holds. The session reads only this to decide when to draw and when to tick.
    public enum Change: Equatable, Sendable {
        case none, enter(Snap), leave
    }

    public static func change(from previous: Snap?, to next: Snap?) -> Change {
        switch (previous, next) {
        case (nil, nil): .none
        case (_, nil): .leave
        case (let p?, let n?) where p.edge == n.edge && p.target == n.target: .none
        case (_, let n?): .enter(n)
        }
    }

    /// The sides of the columns that touch the lens's rows whose edge the read ended at (`marked`): where a snap has no target yet, and a wider read
    /// would give one.
    public static func unknownEdges(near lens: CGRect, in columns: [Column]) -> Sides {
        columns.filter { $0.bottom >= lens.minY && $0.top <= lens.maxY }.reduce(into: Sides()) { sides, c in
            if !c.leftKnown { sides.insert(.left) }
            if !c.rightKnown { sides.insert(.right) }
        }
    }

    /// How far a live resize moves the edge the hand holds, for a pull of `offset` (a snap's: the target less the hand's edge): all of it while the hand is
    /// within `plateau` of the target (the edge stands on the target), less and less out to `release`, where it is none. Continuous, so the edge never jumps
    /// under the hand: it moves 0.5 to 1.5 pt for each point the hand moves while in reach (the first build moved it 8.5 pt on entering and 12 pt on leaving,
    /// in one frame, measured on the film4 take of 10-22). A move is the window server's and not pulled live; it settles on release (`settleFrame`).
    public static func livePull(_ offset: CGFloat) -> CGFloat {
        let a = abs(offset)
        guard a < release else { return 0 }
        let tapered = plateau * (release - a) / (release - plateau)
        return offset < 0 ? -min(a, tapered) : min(a, tapered)
    }

    /// The pull on `lens` (the rect the hand put it at, never the snapped one): the target nearest to one of `edges` within `reach`, kept until the
    /// edge is `release` away. Left edges go to left targets, right edges to right ones; the nearer edge wins, a tie goes to the left. `bypass`
    /// (⌘ held): no snap at all. `entry` is the distance a new target is taken from (`reach`): the live pull of a resize takes it from `release`, so the
    /// pull is a function of where the hand is and nothing else (no jump on entering).
    public static func snap(_ lens: CGRect, edges: Sides = .both, targets: Targets, previous: Snap? = nil, bypass: Bool = false, entry: CGFloat = ColumnFit.reach) -> Snap? {
        guard !bypass else { return nil }
        var best: Snap?
        func offer(_ edge: Sides, _ target: Target, from x: CGFloat) {
            let offset = target.x - x
            let held = previous?.edge == edge && previous?.target == target
            guard abs(offset) <= (held ? release : entry) else { return }
            if let b = best, abs(b.offset) < abs(offset) || (abs(b.offset) == abs(offset) && (b.edge == .left || !(held))) { return }
            best = Snap(edge: edge, target: target, offset: offset)
        }
        if edges.contains(.left) { targets.lefts.forEach { offer(.left, $0, from: lens.minX) } }
        if edges.contains(.right) { targets.rights.forEach { offer(.right, $0, from: lens.maxX) } }
        return best
    }
}
