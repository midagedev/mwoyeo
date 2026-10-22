import CoreGraphics

/// Which changes of a frame are about the text the last read found (design games-and-video §3).
///
/// A scene that moves in a game beside its text box changes tiles every frame. Counting them all made each frame a read of the band
/// and a line change one read of everything between the band and the box, and the text waited behind the reader. Here a tile inside
/// a box of the last read, grown by one tile, counts at once; a tile away from every box is held until it has been still for `hold`:
/// new text appears once and stays, a scene keeps changing. A held tile that rests is handed back as an area to read
/// (`takeRested`), like a strip a scroll uncovered.
///
/// It also owns the animated tiles (`Churn`): they are taken out of a frame's change before it is weighed.
public struct ReadWatch: Sendable {
    /// How long a tile away from the text must hold still before it counts (the pipeline's; a check may inject another).
    public static let standardHold: Double = 0.4
    /// Tiles a change may lie from a box and still count (a line that grows, the next line).
    public static let marginTiles = 1

    public let hold: Double
    public var churn = Churn()
    /// Per tile of the last grid, when it last changed while away from the text; -infinity when it is not held.
    private var held: [Double] = []
    private var columns = 0, rows = 0, tile = 16, imageWidth = 0, imageHeight = 0

    public init(hold: Double = ReadWatch.standardHold) { self.hold = hold }

    /// What a frame's change comes to.
    public struct Noted: Sendable, Equatable {
        /// The tiles that count now: animated ones and tiles held for being away from the text are left out.
        public var counted: ChangeMap
        /// Tiles that changed away from the text and are held.
        public var held: Int
        /// Tiles left out as animated.
        public var animated: Int
    }

    /// A frame's change `raw` against the previous frame, at `t`. `boxes` are the last read's text in gray pixels; nil (a scroll, a capture
    /// that grew) or none (nothing read yet) weighs nothing: every change counts, as it did before. `learns`: a small change feeds the
    /// animated-tile memory (a big one is motion, not animation).
    public mutating func frame(_ raw: ChangeMap, boxes: [PixelRect]?, at t: Double, learns: Bool) -> Noted {
        if learns { churn.add(raw, at: t) }
        let masked = churn.masking(raw, at: t)
        let animated = raw.changedCount - masked.changedCount
        guard let boxes, !boxes.isEmpty else {
            forget()
            return Noted(counted: masked, held: 0, animated: animated)
        }
        fit(to: masked)
        let near = Self.nearTiles(of: masked, boxes: boxes)
        var counted = masked.changed, away = 0
        for i in counted.indices where counted[i] && !near[i] {
            counted[i] = false
            held[i] = t
            away += 1
        }
        return Noted(counted: masked.with(changed: counted), held: away, animated: animated)
    }

    /// `diff`, the difference between the picture the blocks describe and the newest frame, with the animated tiles out and, where the text is
    /// known, the tiles held for being away from it. A tile that differs and was never seen changing away from the text counts.
    public func stale(_ diff: ChangeMap, boxes: [PixelRect]?, at t: Double) -> ChangeMap {
        let masked = churn.masking(diff, at: t)
        guard boxes?.isEmpty == false, held.count == masked.changed.count else { return masked }
        var changed = masked.changed
        for i in changed.indices where changed[i] && held[i] > -.infinity { changed[i] = false }
        return masked.with(changed: changed)
    }

    /// The held tiles that have been still for `hold` at `t`, as gray-pixel areas (a run of tiles in a row is one), and no longer held.
    public mutating func takeRested(at t: Double) -> [PixelRect] {
        var areas: [PixelRect] = []
        for r in 0..<rows {
            var start: Int?
            for c in 0...columns {
                let rested = c < columns && held[r * columns + c] > -.infinity && t - held[r * columns + c] >= hold
                if rested {
                    if start == nil { start = c }
                    held[r * columns + c] = -.infinity
                } else if let s = start {
                    areas.append(PixelRect(x: s * tile, y: r * tile, width: (c - s) * tile, height: tile).clamped(width: imageWidth, height: imageHeight))
                    start = nil
                }
            }
        }
        return areas
    }

    /// `area` (gray pixels; nil = all of the frame) of the frame captured at `time` was read: tiles held inside it that changed no later than
    /// that frame are not held any more (the read has what they showed). A tile that changed after the frame stays held: the scene moved on.
    public mutating func didRead(_ area: PixelRect?, frameTime time: Double) {
        for r in 0..<rows {
            for c in 0..<columns where held[r * columns + c] > -.infinity && held[r * columns + c] <= time {
                let x = min(c * tile + tile / 2, imageWidth - 1), y = min(r * tile + tile / 2, imageHeight - 1)
                if area.map({ x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }) ?? true { held[r * columns + c] = -.infinity }
            }
        }
    }

    /// Seconds until the first held tile has been still long enough; nil when none is held.
    public func restsIn(at t: Double) -> Double? {
        held.filter { $0 > -.infinity }.map { max(0, $0 + hold - t) }.min()
    }

    /// Seconds until a look again is due: an animated tile counting as still, or a held one resting. nil when neither is pending.
    public func wake(at t: Double) -> Double? {
        [churn.coolsIn(at: t), restsIn(at: t)].compactMap { $0 }.min()
    }

    /// Another picture or position: what was seen is not comparable any more.
    public mutating func reset() {
        churn.reset()
        forget()
    }

    private mutating func forget() { held = [] ; columns = 0; rows = 0 }

    private mutating func fit(to change: ChangeMap) {
        if held.count != change.changed.count || change.columns != columns || change.tile != tile {
            held = Array(repeating: -.infinity, count: change.changed.count)
        }
        columns = change.columns; rows = change.rows; tile = change.tile
        imageWidth = change.imageWidth; imageHeight = change.imageHeight
    }

    /// Tiles whose centre lies inside a box grown by `marginTiles` tiles.
    static func nearTiles(of change: ChangeMap, boxes: [PixelRect]) -> [Bool] {
        var near = [Bool](repeating: false, count: change.changed.count)
        let margin = marginTiles * change.tile
        for box in boxes {
            let x0 = box.x - margin, x1 = box.x + box.width + margin, y0 = box.y - margin, y1 = box.y + box.height + margin
            let c0 = max(0, x0 / change.tile - 1), c1 = min(change.columns - 1, x1 / change.tile + 1)
            let r0 = max(0, y0 / change.tile - 1), r1 = min(change.rows - 1, y1 / change.tile + 1)
            guard c0 <= c1, r0 <= r1 else { continue }
            for r in r0...r1 {
                for c in c0...c1 {
                    let x = min(c * change.tile + change.tile / 2, change.imageWidth - 1), y = min(r * change.tile + change.tile / 2, change.imageHeight - 1)
                    if x >= x0, x < x1, y >= y0, y < y1 { near[r * change.columns + c] = true }
                }
            }
        }
        return near
    }
}

extension ChangeMap {
    /// The same grid with other tiles marked.
    func with(changed: [Bool]) -> ChangeMap {
        ChangeMap(tile: tile, columns: columns, rows: rows, changed: changed, imageWidth: imageWidth, imageHeight: imageHeight)
    }
}
