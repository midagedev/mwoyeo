import CoreGraphics
import Foundation

/// The one-click lens where the content under the pointer is not a reading column (docs/design/lens-shapes.md, round shapes117): a
/// table, a chat thread, a game's dialog box, a subtitle, or a group set apart from the rest (a list with its title, a code block with the
/// sentence that leads into it, a sidebar note, a popup, a caption, a heading with its lede). `LensTarget.choose` owns the reading column;
/// where it has no target it asks `choose` here, and nil keeps today's ghost.
///
/// Geometry only: the boxes and line counts of the blocks of the picker's one read, the pointer, the bounds. Each kind is one case of
/// `Kind`, tried in `allCases` order (the first that recognises the content under the pointer wins), with its own rect. Every rect is made
/// of whole blocks, stands `pad` outside them, and never cuts a block it does not hold (`settled`). The shape depends on the block the
/// pointer aims at (the anchor), never on where the pointer is inside it; the held anchor stays until another beats it by `switchBy`, as
/// in `LensTarget`.
///
/// What lies in `bounds` is the content (`Map.within`); what a recogniser takes belongs with the anchor (what is set alike, what stands on the
/// rows, the block that pairs), so the kind does not change with a point of the read (docs/design/lens-shapes.md section 13).
///
/// Pure, in one space with y going down (the picker hands global Quartz points).
public enum LensShape {
    /// The farthest a block may stand from the pointer and still be aimed at; a new anchor must beat the held one by `switchBy`.
    public static let reach: CGFloat = 40
    public static let switchBy: CGFloat = 8
    /// A lens stands this far outside the text (`ColumnFit.pad`).
    public static let pad: CGFloat = 6
    /// The height budget, as `LensTarget`'s: the default lens's area over the shape's width, within these.
    public static let budgetArea: CGFloat = 560 * 320
    public static let minBudget: CGFloat = 160, maxBudget: CGFloat = 560
    /// The lens's resize floor (`RegionFrameWindow`).
    public static let minSize = CGSize(width: 80, height: 40)
    /// A line's pitch over its glyph box: the read gives a block's box and its line count, and this spreads the lines over the box.
    public static let leading: CGFloat = 1.35
    /// An edge that reaches into a block by more than this cuts it (the measure of the gates; a box is a little wider than its glyphs).
    public static let cutSlack: CGFloat = 2

    /// One block of the read: the union of its lines, and how many there are (`ColumnFit.Block`'s fields), and the box of its first line when
    /// the picker has it (`head`; a read that merged a speaker's name into its lines is told by it).
    public struct Block: Sendable, Equatable {
        public var core: CGRect
        public var lines: Int
        public var head: CGRect?
        public init(core: CGRect, lines: Int, head: CGRect? = nil) { self.core = core; self.lines = lines; self.head = head }

        /// One line's glyph height: the box itself for one line; for several, the box less the leading between them.
        public var em: CGFloat { core.height / (1 + LensShape.leading * CGFloat(max(lines, 1) - 1)) }

        /// Line `k` of the block, the lines spread evenly over the box.
        func line(_ k: Int) -> CGRect {
            CGRect(x: core.minX, y: core.minY + CGFloat(k) * em * LensShape.leading, width: core.width, height: em)
        }
    }

    /// What the lens is shaped for, in the order they are tried. A new kind of content is a new case here, with its recogniser and its
    /// rect in `region(of:)`; nothing else changes.
    public enum Kind: String, CaseIterable, Sendable {
        /// Rows of cells side by side, three or more: the whole rows, every column.
        case table
        /// Messages stacked down a pane, from one side and the other or under names: the pane's width, whole messages.
        case thread
        /// A short name over a line or two of dialogue: both, with room for the line being typed out.
        case dialog
        /// One to three centred lines, alone in the lower half: a band centred on them with room for two lines.
        case subtitles
        /// Blocks that stand together apart from the rest (a list and its title, a code block and its lead-in, a note, a popup, a caption,
        /// a heading and its lede, a lone paragraph): the group, whole.
        case group
    }

    /// What the pointer aims at: the kind, the lens rect, and the block it was chosen from (the held anchor of the next choice, an index
    /// into `Map.blocks`).
    public struct Shape: Sendable, Equatable {
        public var kind: Kind
        public var rect: CGRect
        public var anchor: Int
        public init(kind: Kind, rect: CGRect, anchor: Int) { self.kind = kind; self.rect = rect; self.anchor = anchor }
    }

    // MARK: - The map

    /// The blocks of one read, ordered, with what every choice needs: each block's group and the rows of lines that stand side by side.
    /// Built once per read.
    public struct Map: Sendable {
        /// Sorted by top, then left (the held anchor indexes this order).
        public let blocks: [Block]
        /// The group of each block: the connected parts of `linked`.
        let group: [Int]
        /// Every line of every block (`Block.line`): its block and its box.
        let lines: [(block: Int, rect: CGRect)]
        /// Lines that stand side by side on one row, left to right; rows by their middle.
        let rows: [[Int]]
        /// The rows each block has a line in.
        let rowsOf: [[Int]]

        /// The index in the read's own map of each block (the identity for that map; `within` keeps what is left of it).
        let origin: [Int]

        public init(blocks: [Block]) {
            let sorted = blocks.sorted { ($0.core.minY, $0.core.minX, $0.core.width) < ($1.core.minY, $1.core.minX, $1.core.width) }
            self.init(sorted: sorted, origin: Array(sorted.indices))
        }

        /// The blocks that lie in `bounds` (the hovered window's content; the read is of the display): the title bar, the menu bar and the
        /// windows beside this one are not what the lens is made of, and a lens can only cover what is inside it. The same map when all are.
        func within(_ bounds: CGRect) -> Map {
            let kept = blocks.indices.filter { i in
                let o = bounds.intersection(blocks[i].core)
                return !o.isNull && o.width > LensShape.cutSlack && o.height > LensShape.cutSlack
            }
            return kept.count == blocks.count ? self : Map(sorted: kept.map { blocks[$0] }, origin: kept.map { origin[$0] })
        }

        private init(sorted: [Block], origin: [Int]) {
            self.origin = origin
            self.blocks = sorted
            var parent = Array(sorted.indices)
            func root(_ i: Int) -> Int { var i = i; while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }; return i }
            // Sorted by top: a block further below `i` than the largest gap `linked` allows is out of reach of it and of the blocks after it.
            let farthest = LensShape.stackGap * (sorted.map(\.em).max() ?? 0)
            for i in sorted.indices {
                for j in sorted.indices.dropFirst(i + 1) {
                    if sorted[j].core.minY - sorted[i].core.maxY > farthest { break }
                    if LensShape.linked(sorted[i], sorted[j]) { parent[root(j)] = root(i) }
                }
            }
            group = sorted.indices.map(root)
            var lines: [(block: Int, rect: CGRect)] = []
            for (i, b) in sorted.enumerated() { for k in 0..<max(b.lines, 1) { lines.append((i, b.line(k))) } }
            self.lines = lines
            let order = lines.indices.sorted { (lines[$0].rect.midY, lines[$0].rect.minX) < (lines[$1].rect.midY, lines[$1].rect.minX) }
            var rows: [[Int]] = []
            for l in order {
                let r = lines[l].rect
                if let first = rows.last?.first, abs(r.midY - lines[first].rect.midY) <= LensShape.rowTolerance * min(r.height, lines[first].rect.height),
                   !rows[rows.count - 1].contains(where: { lines[$0].rect.minX < r.maxX && r.minX < lines[$0].rect.maxX }) {
                    rows[rows.count - 1].append(l)
                } else {
                    rows.append([l])
                }
            }
            self.rows = rows.map { $0.sorted { lines[$0].rect.minX < lines[$1].rect.minX } }
            var rowsOf = Array(repeating: [Int](), count: sorted.count)
            for (r, row) in self.rows.enumerated() { for l in row { rowsOf[lines[l].block].append(r) } }
            self.rowsOf = rowsOf.map { $0.sorted() }
        }
    }

    // MARK: - Choosing

    /// The shape at `pointer` for `blocks`, or nil (the ghost). Builds the map; a caller that asks per pointer move keeps a `Map`.
    public static func choose(blocks: [Block], pointer: CGPoint, bounds: CGRect, held: Shape? = nil, scale: CGFloat = 2) -> Shape? {
        choose(Map(blocks: blocks), pointer: pointer, bounds: bounds, held: held, scale: scale)
    }

    /// The shape at `pointer`, or nil (the ghost). `held` is the previous choice: its anchor stays until another block beats it by
    /// `switchBy`. `bounds` is what the lens may cover (`LensTarget.content`).
    public static func choose(_ map: Map, pointer p: CGPoint, bounds: CGRect, held: Shape? = nil, scale: CGFloat = 2) -> Shape? {
        pick(map, pointer: p, bounds: bounds, held: held, scale: scale, log: nil)
    }

    /// Why `choose` answered what it did, line by line, for the trace of the picker and the tests: the blocks inside `bounds`, the block the
    /// pointer aims at, and for each kind in the order they are tried what it gave (the members it holds and the rect, or that it recognised
    /// nothing or could not stand whole), the last line the choice. The indices are those of the read's `Map.blocks`.
    public static func explain(_ map: Map, pointer p: CGPoint, bounds: CGRect, held: Shape? = nil, scale: CGFloat = 2) -> [String] {
        var lines: [String] = []
        _ = pick(map, pointer: p, bounds: bounds, held: held, scale: scale, log: { lines.append($0) })
        return lines
    }

    private static func pick(_ map: Map, pointer p: CGPoint, bounds: CGRect, held: Shape?, scale: CGFloat, log: ((String) -> Void)?) -> Shape? {
        let content = map.within(bounds)
        log?("blocks \(content.blocks.count) of \(map.blocks.count) inside \(bounds)")
        // The held anchor and the answer's are indices of `map`, the recognisers' those of `content`.
        let heldHere = held.flatMap { h in content.origin.firstIndex(of: h.anchor).map { Shape(kind: h.kind, rect: h.rect, anchor: $0) } }
        let aimed = anchors(content, p, held: heldHere)
        if aimed.isEmpty { log?("no block within \(reach) of \(p)") }
        for a in aimed {
            log?("anchor \(content.origin[a]) \(content.blocks[a].core) lines \(content.blocks[a].lines)")
            for kind in Kind.allCases {
                guard let r = region(of: kind, at: a, in: content, bounds: bounds) else { log?("  \(kind.rawValue): nothing recognised"); continue }
                let members = r.members.map { content.origin[$0] }
                guard let rect = settled(r.want, holding: r.members, in: content, bounds: bounds, scale: scale) else {
                    log?("  \(kind.rawValue): members \(members) cannot stand whole inside the bounds"); continue
                }
                log?("  \(kind.rawValue): members \(members) rect \(rect) chosen")
                return Shape(kind: kind, rect: rect, anchor: content.origin[a])
            }
        }
        return nil
    }

    /// The blocks the pointer aims at, best first: the block with the best signed distance to `p` (depth inside, less the distance
    /// outside), the held one while it is not beaten by `switchBy`; none farther than `reach` from every block. A shape is taken within
    /// `reach` of any of its blocks, so the held one lets go only `switchBy` beyond that from all of them, and not at all while the pointer is
    /// inside its outline (a table's white space between cells is still the table): no flicker between a shape and the ghost either. A held
    /// anchor that is beaten but not let go comes second: a block that gives no shape (a lone label) is as good as empty space, and the held
    /// shape stays over it.
    static func anchors(_ map: Map, _ p: CGPoint, held: Shape?) -> [Int] {
        func score(_ b: CGRect) -> CGFloat {
            let dx = max(b.minX - p.x, 0, p.x - b.maxX), dy = max(b.minY - p.y, 0, p.y - b.maxY)
            return dx == 0 && dy == 0 ? min(p.x - b.minX, b.maxX - p.x, p.y - b.minY, b.maxY - p.y) : -(dx * dx + dy * dy).squareRoot()
        }
        var best = -1, top = -CGFloat.infinity
        for (i, b) in map.blocks.enumerated() where score(b.core) > top { best = i; top = score(b.core) }
        let taken = best >= 0 && top >= -reach ? [best] : []
        guard let held, map.blocks.indices.contains(held.anchor) else { return taken }
        let inside = held.rect.contains(p), outline = held.rect.insetBy(dx: -cutSlack, dy: -cutSlack)
        let h = inside ? max(score(map.blocks[held.anchor].core), 0) : score(map.blocks[held.anchor].core)
        let nearest = map.blocks.lazy.filter { outline.contains($0.core) }.map { score($0.core) }.reduce(h, max)
        guard inside || nearest >= -(reach + switchBy) else { return taken }
        return held.anchor == best || top - h < switchBy || top < -reach ? [held.anchor] : taken + [held.anchor]
    }

    // MARK: - The kinds

    /// Two stacked blocks of one group: the gap between them at most this many ems (of the larger), their x ranges overlapping.
    static let stackGap: CGFloat = 1.2
    /// Two blocks on one row of one group: overlapping by half the shorter's height, at most this many ems apart.
    static let rowGap: CGFloat = 1.5
    /// Lines on one row: middles within this share of the shorter line's height.
    static let rowTolerance: CGFloat = 0.4

    /// Whether `a` and `b` stand together (`Map.group`).
    static func linked(_ a: Block, _ b: Block) -> Bool {
        let em = max(a.em, b.em)
        let xOverlap = min(a.core.maxX, b.core.maxX) - max(a.core.minX, b.core.minX)
        let yOverlap = min(a.core.maxY, b.core.maxY) - max(a.core.minY, b.core.minY)
        let yGap = max(a.core.minY, b.core.minY) - min(a.core.maxY, b.core.maxY)
        if xOverlap > 0, yGap <= stackGap * em { return true }
        return yOverlap >= 0.5 * min(a.core.height, b.core.height) && -xOverlap <= rowGap * em
    }

    /// What a kind holds at anchor `a`: the blocks (whole) and the rect it wants before `settled` keeps it whole and inside `bounds`.
    struct Region { var members: [Int]; var want: CGRect }

    static func region(of kind: Kind, at a: Int, in map: Map, bounds: CGRect) -> Region? {
        switch kind {
        case .table: table(at: a, in: map)
        case .thread: thread(at: a, in: map)
        case .dialog: dialog(at: a, in: map, bounds: bounds)
        case .subtitles: subtitles(at: a, in: map, bounds: bounds)
        case .group: group(at: a, in: map)
        }
    }

    // Table: lanes of cells side by side, row after row. The anchor's line and the lines beside it on its row (`rowTolerance`), each
    // `cellGap` ems from the next, are the lanes; the anchor's own lane, followed down and up within `tableRowGap` ems, gives the rows;
    // another lane stays when it has a cell on `laneShare` of them and `laneShare` of its lines down them stand on a row (a page or a chat
    // beside the table meets its rows only now and then, and has more lines than rows). At least `minRows` rows with a cell in another lane;
    // cells mostly one line (`cellShare`), the one-line ones alike in height down a lane (`laneSpread`).
    static let cellGap: CGFloat = 1.5
    static let tableRowGap: CGFloat = 3
    static let minRows = 3
    static let laneShare: CGFloat = 0.6
    /// The lines of one lane are alike: their glyph heights within this ratio of the lane's median (a heading in a page's column is not a cell).
    /// The messages of one thread are alike the same way (a heading over a pane is not a message of it). A box is as tall as its letters: in
    /// one table's lane the cells' boxes run from digits (10 pt) to words with descenders (18 pt), 1.45 to 1.6 apart with a point of read noise;
    /// headings stand 1.8 to 2.2 over the text in the film stage's reads (docs/design/lens-shapes.md section 13). 1.7 is between, where 1.4 cut the lane.
    static let laneSpread: CGFloat = 1.7
    static func alike(_ a: CGFloat, _ b: CGFloat) -> Bool { a <= b * laneSpread && a * laneSpread >= b }
    /// Cells are mostly one line: at least this share of a table's blocks (the read merges a column's cells into one block now and then;
    /// two columns of a page are blocks of many lines).
    static let cellShare: CGFloat = 0.6

    static func table(at a: Int, in map: Map) -> Region? {
        // The title of a table aims at the table: its first row is the block just under it.
        let under = map.blocks.indices.filter { i in
            let t = map.blocks[a].core, b = map.blocks[i].core
            return i != a && b.minY >= t.maxY - 1 && b.minY - t.maxY <= stackGap * map.blocks[a].em && b.minX < t.maxX && t.minX < b.maxX
        }.min { map.blocks[$0].core.minY < map.blocks[$1].core.minY }
        return lanes(at: a, in: map) ?? under.flatMap { lanes(at: $0, in: map) }.map { r in
            Region(members: r.members, want: r.want.union(map.blocks[a].core.insetBy(dx: -pad, dy: -pad)))
        }
    }

    static func lanes(at a: Int, in map: Map) -> Region? {
        let lines = map.lines
        func sameRow(_ l: Int, _ m: Int) -> Bool {
            abs(lines[l].rect.midY - lines[m].rect.midY) <= rowTolerance * min(lines[l].rect.height, lines[m].rect.height)
        }
        func overlapsX(_ r: CGRect, _ s: CGRect) -> Bool { r.minX < s.maxX && s.minX < r.maxX }
        guard let seed = lines.indices.first(where: { lines[$0].block == a }) else { return nil }
        // The cells of the anchor's row: the lines beside it, each `cellGap` ems from the next (closer, they are another text's).
        let all = lines.indices.filter { $0 == seed || (sameRow($0, seed) && !overlapsX(lines[$0].rect, lines[seed].rect)) }
            .sorted { lines[$0].rect.minX < lines[$1].rect.minX }
        func apart(_ l: Int, _ m: Int) -> Bool {
            lines[m].rect.minX - lines[l].rect.maxX >= cellGap * max(lines[l].rect.height, lines[m].rect.height)
        }
        guard var first = all.firstIndex(of: seed) else { return nil }
        var last = first
        while last + 1 < all.count, apart(all[last], all[last + 1]) { last += 1 }
        while first > 0, apart(all[first - 1], all[first]) { first -= 1 }
        let row = Array(all[first...last])
        guard row.count >= 2 else { return nil }
        // The rows: the anchor's lane followed down and up.
        let own = lines[seed].rect
        let lane = lines.indices.filter { overlapsX(lines[$0].rect, own) }.sorted { lines[$0].rect.midY < lines[$1].rect.midY }
        guard var lo = lane.firstIndex(of: seed) else { return nil }
        var hi = lo
        func near(_ l: Int, _ m: Int) -> Bool {
            lines[m].rect.minY - lines[l].rect.maxY <= tableRowGap * max(lines[l].rect.height, lines[m].rect.height)
        }
        while hi + 1 < lane.count, near(lane[hi], lane[hi + 1]) { hi += 1 }
        while lo > 0, near(lane[lo - 1], lane[lo]) { lo -= 1 }
        let rows = Array(lane[lo...hi])
        // The other lanes, each with its cells on those rows, and no more lines than cells down them (a text column beside the table has its
        // own rhythm and meets a row or two by chance).
        let down = lines[rows.first!].rect.minY...lines[rows.last!].rect.maxY
        var cells: [[Int]] = []
        for c in row where c != seed {
            func beside(_ l: Int) -> Bool { overlapsX(lines[l].rect, lines[c].rect) && !overlapsX(lines[l].rect, own) }
            let hits = rows.compactMap { r in lines.indices.first { beside($0) && sameRow($0, r) } }
            let standing = lines.indices.filter { beside($0) && down.contains(lines[$0].rect.midY) }.count
            if CGFloat(hits.count) >= laneShare * CGFloat(rows.count), CGFloat(hits.count) >= laneShare * CGFloat(standing) { cells.append(hits) }
        }
        let filled = rows.filter { r in cells.contains { $0.contains { sameRow($0, r) } } }
        guard !cells.isEmpty, filled.count >= minRows else { return nil }
        let top = lines[filled.first!].rect.minY, bottom = lines[filled.last!].rect.maxY
        let held = (rows.filter { lines[$0].rect.minY >= top && lines[$0].rect.maxY <= bottom } + cells.joined())
        for laneLines in cells + [rows] {
            // A merged block's lines have no glyph height of their own (the read gives the box of all of them): its lane is judged by its one-line cells.
            let h = laneLines.filter { map.blocks[lines[$0].block].lines == 1 }.map { lines[$0].rect.height }.sorted()
            guard h.isEmpty || h.allSatisfy({ alike($0, h[h.count / 2]) }) else { return nil }
        }
        var members = Array(Set(held.map { lines[$0].block })).sorted()
        guard CGFloat(members.filter { map.blocks[$0].lines == 1 }.count) >= cellShare * CGFloat(members.count) else { return nil }
        // Its title: a line of the same group just above it, within its width.
        let box = members.map { map.blocks[$0].core }.reduce(CGRect.null) { $0.union($1) }
        members += map.blocks.indices.filter { i in
            let t = map.blocks[i]
            return !members.contains(i) && members.contains { map.group[$0] == map.group[i] } && t.lines == 1 && t.core.maxY <= box.minY + 1
                && box.minY - t.core.maxY <= stackGap * t.em && t.core.minX >= box.minX - t.em && t.core.maxX <= box.maxX + t.em
        }
        return windowed(members.sorted(), anchor: a, in: map)
    }

    // Thread: messages down a pane. A message is a block of at most `messageLines` lines that is not a name or a time (one line at most `timeWidth` ems wide). The
    // message under the pointer (or nearest to the name or time under it) keeps to an edge of the pane with others: two-sided when the
    // messages of the other side keep to the opposite edge (bubbles), one-sided when `minMessages` messages of two lines or more (a name
    // over its message) keep to its left edge with ragged right edges. The thread is the messages of the two lanes, one after another
    // within `messageGap` ems, with the names and times between them; its pane holds nothing else. Its messages are set alike (`alike`).
    static let messageLines = 4
    static let messageGap: CGFloat = 4.5
    static let gapBreak: CGFloat = 2
    static let laneTolerance: CGFloat = 1.5
    static let laneSlack: CGFloat = 3
    static let ragged: CGFloat = 6
    static let minMessages = 3
    /// A name or a time beside a message: one line at most this many ems wide, or in print this much smaller than the messages'.
    static let timeWidth: CGFloat = 4
    static let finePrint: CGFloat = 0.8
    /// The other side's edge is looked for among the messages within this many ems up and down.
    static let neighbourhood: CGFloat = 20

    static func thread(at a: Int, in map: Map) -> Region? {
        let b = map.blocks
        guard b[a].lines <= messageLines else { return nil }
        func apart(_ i: Int, _ j: Int) -> CGFloat {
            let dx = max(b[i].core.minX - b[j].core.maxX, b[j].core.minX - b[i].core.maxX, 0)
            return dx + max(b[i].core.minY - b[j].core.maxY, b[j].core.minY - b[i].core.maxY, 0)
        }
        let typical = b.filter { $0.lines <= messageLines }.map(\.em).sorted()
        let body = typical.isEmpty ? 0 : typical[typical.count / 2]
        func small(_ i: Int) -> Bool { b[i].lines == 1 && (b[i].core.width <= timeWidth * b[i].em || b[i].em <= finePrint * body) }
        let messages = b.indices.filter { b[$0].lines <= messageLines && !small($0) }
        guard let m = small(a) ? messages.min(by: { (apart(a, $0), $0) < (apart(a, $1), $1) }) : a else { return nil }
        let em = b[m].em
        // Its messages are set like it (`alike`): the pane's other text is not a message of it.
        let kin = messages.filter { alike(b[$0].em, em) }
        func flush(_ x: CGFloat, _ y: CGFloat) -> Bool { abs(x - y) <= laneTolerance * em }
        // The edge the other side keeps to: the most common one among the messages near this one that stand clear of this side's edge.
        func lane(_ edges: [CGFloat]) -> CGFloat? {
            edges.max { l, r in (edges.filter { flush($0, l) }.count, -l) < (edges.filter { flush($0, r) }.count, -r) }
        }
        let nearby = kin.filter { abs(b[$0].core.midY - b[m].core.midY) <= neighbourhood * em }
        for fromLeft in [true, false] {
            var left = b[m].core.minX, right = b[m].core.maxX
            if fromLeft {
                right = lane(nearby.filter { b[$0].core.minX >= left + 2 * em && b[$0].core.maxX > right }.map { b[$0].core.maxX }) ?? .infinity
            } else {
                left = lane(nearby.filter { b[$0].core.maxX <= right - 2 * em && b[$0].core.minX < left }.map { b[$0].core.minX }) ?? -.infinity
            }
            let lanes = kin.filter { i in
                (flush(b[i].core.minX, left) && (!right.isFinite || b[i].core.maxX <= right - em))
                    || (flush(b[i].core.maxX, right) && (!left.isFinite || b[i].core.minX >= left + em))
            }.sorted { (b[$0].core.minY, $0) < (b[$1].core.minY, $1) }
            // One after another from the message under the pointer, up and down, within `messageGap` ems.
            guard let at = lanes.firstIndex(of: m) else { continue }
            var lo = at, hi = at
            while hi + 1 < lanes.count, b[lanes[hi + 1]].core.minY - b[lanes[hi]].core.maxY <= messageGap * em { hi += 1 }
            while lo > 0, b[lanes[lo]].core.minY - b[lanes[lo - 1]].core.maxY <= messageGap * em { lo -= 1 }
            // A gap `gapBreak` times the thread's usual one ends it too (the pane's last message, then a page's line under it).
            let gaps = (lo..<hi).map { b[lanes[$0 + 1]].core.minY - b[lanes[$0]].core.maxY }
            if gaps.count >= 2 {
                let usual = max(gaps.sorted()[gaps.count / 2], em)
                while let g = (lo..<at).last(where: { b[lanes[$0 + 1]].core.minY - b[lanes[$0]].core.maxY > gapBreak * usual }) { lo = g + 1 }
                if let g = (at..<hi).first(where: { b[lanes[$0 + 1]].core.minY - b[lanes[$0]].core.maxY > gapBreak * usual }) { hi = g }
            }
            var thread = Array(lanes[lo...hi])
            let span = thread.map { b[$0].core }.reduce(CGRect.null) { $0.union($1) }
            guard thread.count >= minMessages, span.width >= 12 * em else { continue }
            if left.isFinite && right.isFinite {
                // Bubbles go both ways: two messages or more on each side.
                let onLeft = thread.filter { flush(b[$0].core.minX, left) }.count
                guard onLeft >= 2, thread.count - onLeft >= 2 else { continue }
            } else {
                let rights = thread.filter { b[$0].lines >= 2 }.map { b[$0].core.maxX }
                guard fromLeft, rights.count >= minMessages, rights.max()! - rights.min()! >= ragged * em else { continue }
            }
            // The pane holds the thread and nothing else but names and times (a page's heading beside a chat is not a message of it).
            let others = b.indices.filter { !thread.contains($0) && b[$0].core.intersects(span.insetBy(dx: -0.5 * em, dy: 0)) }
            guard others.allSatisfy(small) else { continue }
            thread += b.indices.filter { i in
                small(i) && !thread.contains(i) && b[i].core.minX >= span.minX - laneSlack * em && b[i].core.maxX <= span.maxX + em
                    && b[i].core.minY >= span.minY - messageGap * em && b[i].core.maxY <= span.maxY + em
            }
            return windowed(thread.sorted(), anchor: a, in: map)
        }
        return nil
    }

    // Dialog: a short name (one line, at most `nameWidth` ems) over a body of one to `bodyLines` lines, the name at the body's left edge or a
    // little inside it, within `nameGap` ems above it; the name no taller than a heading would be. A read that merged the name into the first line
    // of the body's block gives the box of that line (`Block.head`): the block is split there. The lens holds both and leaves room for
    // the text still being typed: `typing` ems wide (no wider than the mirror of its left margin in the bounds: a dialog box is centred)
    // and three lines of body tall.
    static let nameWidth: CGFloat = 8
    /// A speaker's name sits on the box's line pitch, a doc's heading a paragraph's space above its text (bench reads: names 0.58-0.74
    /// ems above the body, headings over a one-line paragraph 0.94-1.26).
    static let nameGap: CGFloat = 0.85
    static let bodyLines = 4
    static let bodyWidth: CGFloat = 10
    static let typing: CGFloat = 28
    static let headingRatio: CGFloat = 1.25
    /// Dialogue is set large: the body's glyphs at least this tall (a titled note in a page is not a dialog box).
    static let dialogEm: CGFloat = 16

    static func dialog(at a: Int, in map: Map, bounds: CGRect) -> Region? {
        func pair(_ name: Block, _ body: Block) -> Bool {
            name.lines == 1 && name.core.width <= nameWidth * name.em && body.lines <= bodyLines && body.em >= dialogEm
                && body.core.width >= bodyWidth * body.em && name.em < headingRatio * body.em
                && body.core.minY - name.core.maxY >= -0.2 * body.em && body.core.minY - name.core.maxY <= nameGap * body.em
                && name.core.minX - body.core.minX >= -0.5 * body.em && name.core.minX - body.core.minX <= 1.5 * body.em
        }
        let blocks = map.blocks
        // The read now and then merges the name into its lines: one block whose first line (`head`) is the name, over the lines of the body.
        func split(_ i: Int) -> (name: Block, body: Block)? {
            let b = blocks[i]
            guard b.lines >= 2, let head = b.head, head.maxY < b.core.maxY else { return nil }
            let top = b.core.minY + b.em * leading, rest = CGRect(x: b.core.minX, y: top, width: b.core.width, height: b.core.maxY - top)
            return (Block(core: head, lines: 1), Block(core: rest, lines: b.lines - 1))
        }
        // The nearest block that pairs with this one as its body, else as its name (the nearest block is not enough: it may be the next panel's).
        let found: (name: Block, body: Block, members: [Int])? = {
            if let (n, b) = split(a), pair(n, b) { return (n, b, [a]) }
            if let b = blocks.indices.filter({ $0 != a && pair(blocks[a], blocks[$0]) }).min(by: { blocks[$0].core.minY < blocks[$1].core.minY }) {
                return (blocks[a], blocks[b], [a, b])
            }
            if let n = blocks.indices.filter({ $0 != a && pair(blocks[$0], blocks[a]) }).max(by: { blocks[$0].core.maxY < blocks[$1].core.maxY }) {
                return (blocks[n], blocks[a], [n, a])
            }
            return nil
        }()
        guard let (name, body, members) = found else { return nil }
        // The box ends with its body: nothing under it within an em (a list's title over its items is not a name over a line).
        let under = CGRect(x: body.core.minX, y: body.core.maxY, width: body.core.width, height: body.em)
        guard !blocks.indices.contains(where: { !members.contains($0) && blocks[$0].core.intersects(under) }) else { return nil }
        let em = body.em
        let mirror = bounds.maxX - (min(name.core.minX, body.core.minX) - bounds.minX)
        let right = max(body.core.maxX, min(mirror, body.core.minX + typing * em)) + pad
        let bottom = max(body.core.maxY, body.core.minY + em * (1 + 2 * leading)) + pad
        let box = name.core.union(body.core)
        return Region(members: members, want: CGRect(x: box.minX - pad, y: box.minY - pad, width: right - box.minX + pad, height: bottom - box.minY + pad))
    }

    // Subtitles: one to three lines in blocks stacked within `subtitleGap` ems, their middles within an em of each other, set large
    // (`subtitleEm`), no text of like size within `subtitleClear` ems of them (a player's controls and a menu's small print may be near), in
    // the lower half of the bounds. The band is centred on them, `subtitleRoom` ems wider on each side (at least `subtitleWidth` ems wide),
    // and two lines tall from their last line up.
    static let subtitleLines = 3
    static let subtitleGap: CGFloat = 0.8
    static let subtitleRoom: CGFloat = 2
    static let subtitleWidth: CGFloat = 18
    /// Subtitles are set large: glyphs at least this tall (a figure's caption, alone under its picture, is not a subtitle).
    static let subtitleEm: CGFloat = 16
    /// A page's lone line stands a paragraph's space from the next (bench reads: 1.0-2.0 ems), a subtitle on its picture (6 ems or more,
    /// besides controls' print at 0.4-0.6 of its size).
    static let subtitleClear: CGFloat = 3
    static let subtitleFine: CGFloat = 0.6

    static func subtitles(at a: Int, in map: Map, bounds: CGRect) -> Region? {
        let first = map.blocks[a]
        guard first.lines <= subtitleLines else { return nil }
        var stack = [a]
        func next(from i: Int, down: Bool) -> Int? {
            let b = map.blocks[i]
            return map.blocks.indices.first { j in
                let c = map.blocks[j]
                let gap = down ? c.core.minY - b.core.maxY : b.core.minY - c.core.maxY
                return j != i && !stack.contains(j) && stack.reduce(c.lines, { $0 + map.blocks[$1].lines }) <= subtitleLines
                    && gap >= -0.2 * b.em && gap <= subtitleGap * max(b.em, c.em)
                    && abs(c.core.midX - first.core.midX) <= first.em
            }
        }
        var i = a
        while let j = next(from: i, down: true) { stack.append(j); i = j }
        i = a
        while let j = next(from: i, down: false) { stack.insert(j, at: 0); i = j }
        let box = stack.map { map.blocks[$0].core }.reduce(CGRect.null) { $0.union($1) }
        let em = stack.map { map.blocks[$0].em }.max()!
        guard box.maxY >= bounds.midY, em >= subtitleEm else { return nil }
        let around = box.insetBy(dx: -subtitleClear * em, dy: -subtitleClear * em)
        guard !map.blocks.indices.contains(where: { !stack.contains($0) && map.blocks[$0].em >= subtitleFine * em && map.blocks[$0].core.intersects(around) })
        else { return nil }
        let half = max(box.width / 2 + subtitleRoom * em, subtitleWidth * em / 2)
        let bottom = box.maxY + pad
        let top = min(box.minY, box.maxY - em * (1 + leading)) - pad
        return Region(members: stack, want: CGRect(x: box.midX - half, y: top, width: 2 * half, height: bottom - top))
    }

    // Group: the anchor's group (`Map.group`) with two lines or more.
    static func group(at a: Int, in map: Map) -> Region? {
        let members = map.blocks.indices.filter { map.group[$0] == map.group[a] }
        guard members.reduce(0, { $0 + map.blocks[$1].lines }) >= 2 else { return nil }
        return windowed(members, anchor: a, in: map)
    }

    // MARK: - Rects

    /// The budget for a shape `width` wide.
    static func budget(_ width: CGFloat) -> CGFloat { max(minBudget, min(maxBudget, budgetArea / max(width + 2 * pad, 1))) }

    /// `members` whole when they fit the budget; else, as `LensTarget` extends a column, from the anchor's top down over whole blocks until
    /// the budget (a block that crosses it stays when half of it fits), then up over whole blocks while it is short of `upwardShare` of it.
    static let upwardShare: CGFloat = 0.6

    static func windowed(_ members: [Int], anchor a: Int, in map: Map) -> Region {
        let box = members.map { map.blocks[$0].core }.reduce(CGRect.null) { $0.union($1) }
        let limit = budget(box.width)
        var kept = members
        if box.height > limit {
            let byTop = members.sorted { (map.blocks[$0].core.minY, $0) < (map.blocks[$1].core.minY, $1) }
            var top = map.blocks[a].core.minY, bottom = map.blocks[a].core.maxY
            for i in byTop where map.blocks[i].core.minY > top {
                let b = map.blocks[i].core
                guard bottom - top < limit, b.maxY - top <= limit || limit - (b.minY - top) >= b.height / 2 else { break }
                bottom = max(bottom, b.maxY)
            }
            for i in byTop.reversed() where map.blocks[i].core.maxY < map.blocks[a].core.minY {
                guard bottom - top < limit * upwardShare else { break }
                top = min(top, map.blocks[i].core.minY)
            }
            kept = members.filter { map.blocks[$0].core.minY >= top - 0.5 && map.blocks[$0].core.maxY <= bottom + 0.5 }
            if kept.isEmpty { kept = [a] }
        }
        let held = kept.map { map.blocks[$0].core }.reduce(CGRect.null) { $0.union($1) }
        return Region(members: kept, want: CGRect(x: box.minX - pad, y: held.minY - pad, width: box.width + 2 * pad, height: held.height + 2 * pad))
    }

    /// Whether `rect` cuts `block`: they overlap by more than `cutSlack` both ways and the block is not inside.
    public static func cuts(_ rect: CGRect, _ block: CGRect) -> Bool {
        let o = rect.intersection(block)
        guard !o.isNull, o.width > cutSlack, o.height > cutSlack else { return false }
        return !rect.insetBy(dx: -cutSlack, dy: -cutSlack).contains(block)
    }

    /// `want` made a lens: inside `bounds`, holding its members whole, never cutting another block (an edge that would is moved off it,
    /// the side that keeps the most; a block that overlaps the members is taken in whole), at least `minSize`, on the pixel grid. Nil when
    /// no such rect holds the members.
    static func settled(_ want: CGRect, holding members: [Int], in map: Map, bounds: CGRect, scale: CGFloat) -> CGRect? {
        var core = members.map { map.blocks[$0].core }.reduce(CGRect.null) { $0.union($1) }
        var r = want.union(core).intersection(bounds)
        guard !r.isNull else { return nil }
        if r.width < minSize.width { r = r.insetBy(dx: -(minSize.width - r.width) / 2, dy: 0) }
        if r.height < minSize.height { r = r.insetBy(dx: 0, dy: -(minSize.height - r.height) / 2) }
        r = r.intersection(bounds)
        for _ in map.blocks.indices {
            guard let i = map.blocks.indices.first(where: { !members.contains($0) && cuts(r, map.blocks[$0].core) }) else { break }
            let b = map.blocks[i].core
            if b.intersects(core) {
                core = core.union(b); r = r.union(b).intersection(bounds); continue
            }
            let options = [
                b.maxY <= core.minY ? CGRect(x: r.minX, y: b.maxY, width: r.width, height: r.maxY - b.maxY) : nil,
                b.minY >= core.maxY ? CGRect(x: r.minX, y: r.minY, width: r.width, height: b.minY - r.minY) : nil,
                b.maxX <= core.minX ? CGRect(x: b.maxX, y: r.minY, width: r.maxX - b.maxX, height: r.height) : nil,
                b.minX >= core.maxX ? CGRect(x: r.minX, y: r.minY, width: b.minX - r.minX, height: r.height) : nil,
            ].compactMap { $0 }
            guard let best = options.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
            r = best
        }
        let grid = max(scale, 1)
        func aligned(_ v: CGFloat) -> CGFloat { (v * grid).rounded() / grid }
        let out = CGRect(x: aligned(r.minX), y: aligned(r.minY), width: aligned(r.maxX) - aligned(r.minX), height: aligned(r.maxY) - aligned(r.minY))
        guard out.width >= minSize.width - 1 / grid, out.height >= minSize.height - 1 / grid,
              !map.blocks.indices.contains(where: { !members.contains($0) && !map.blocks[$0].core.intersects(core) && cuts(out, map.blocks[$0].core) })
        else { return nil }
        return out
    }
}
