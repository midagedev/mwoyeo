import CoreGraphics

/// Which tiles of a frame changed relative to a reference frame.
public struct ChangeMap: Sendable, Equatable {
    public let tile: Int
    public let columns: Int
    public let rows: Int
    public let changed: [Bool]
    /// Size of the gray images that were compared.
    public let imageWidth: Int
    public let imageHeight: Int

    public var changedCount: Int { changed.lazy.filter { $0 }.count }
    public var ratio: Double { changed.isEmpty ? 0 : Double(changedCount) / Double(changed.count) }
    public var isUnchanged: Bool { !changed.contains(true) }

    /// Bounding box of all changed tiles, in gray-image pixels. nil when nothing changed.
    public var dirtyRect: PixelRect? { dirtyRect(outside: []) }

    /// Bounding box of the changed tiles whose centre lies outside all of `areas` (gray-image pixels).
    public func dirtyRect(outside areas: [PixelRect]) -> PixelRect? {
        var minC = Int.max, minR = Int.max, maxC = -1, maxR = -1
        for r in 0..<rows {
            for c in 0..<columns where changed[r * columns + c] {
                let x = min(c * tile + tile / 2, imageWidth - 1), y = min(r * tile + tile / 2, imageHeight - 1)
                if areas.contains(where: { x >= $0.x && x < $0.x + $0.width && y >= $0.y && y < $0.y + $0.height }) { continue }
                minC = min(minC, c); maxC = max(maxC, c)
                minR = min(minR, r); maxR = max(maxR, r)
            }
        }
        guard maxC >= 0 else { return nil }
        return PixelRect(x: minC * tile, y: minR * tile, width: (maxC - minC + 1) * tile, height: (maxR - minR + 1) * tile)
            .clamped(width: imageWidth, height: imageHeight)
    }

    /// True if any changed tile overlaps `rect` (gray-image pixels).
    public func intersects(_ rect: PixelRect) -> Bool {
        let r = rect.clamped(width: imageWidth, height: imageHeight)
        guard !r.isEmpty else { return false }
        let c0 = r.x / tile, c1 = min(columns - 1, (r.x + r.width - 1) / tile)
        let r0 = r.y / tile, r1 = min(rows - 1, (r.y + r.height - 1) / tile)
        for row in r0...r1 { for col in c0...c1 where changed[row * columns + col] { return true } }
        return false
    }

    public static func allChanged(width: Int, height: Int, tile: Int) -> ChangeMap {
        let cols = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        return ChangeMap(tile: tile, columns: cols, rows: rows, changed: Array(repeating: true, count: cols * rows),
                         imageWidth: width, imageHeight: height)
    }
}

/// Tiles that keep changing: an animated emoji, a spinner, a typing indicator, a blinking caret. An edit changes its
/// tiles once and then holds still; these change again and again, and re-reading them each time only burns OCR (and an
/// emoji can read as a different letter every time, which retranslates its line).
public struct Churn: Sendable {
    /// A tile is animated once it changed `hotStreak` times with less than `window` seconds between changes, and stays
    /// so until it has been still for `window`. Three seconds also catches what ticks every second or two (a menu bar
    /// meter caught in the capture's margin).
    public var window: Double = 3
    public var hotStreak = 3
    private var streak: [Int] = []
    private var last: [Double] = []

    public init() {}

    public mutating func reset() { streak = []; last = [] }

    public mutating func add(_ change: ChangeMap, at t: Double) {
        if streak.count != change.changed.count {
            streak = Array(repeating: 0, count: change.changed.count)
            last = Array(repeating: -.infinity, count: change.changed.count)
        }
        for i in change.changed.indices where change.changed[i] {
            streak[i] = t - last[i] < window ? streak[i] + 1 : 1
            last[i] = t
        }
    }

    func isHot(_ i: Int, at t: Double) -> Bool { streak[i] >= hotStreak && t - last[i] < window }

    /// `change` without the animated tiles and the tiles around them: an emoji's edge reaches into its neighbours
    /// only now and then, too seldom to count as animated by itself.
    public func masking(_ change: ChangeMap, at t: Double) -> ChangeMap {
        guard streak.count == change.changed.count else { return change }
        let hot = streak.indices.filter { isHot($0, at: t) }
        guard !hot.isEmpty else { return change }
        var changed = change.changed
        for i in hot {
            let r = i / change.columns, c = i % change.columns
            for y in max(0, r - 1)...min(change.rows - 1, r + 1) {
                for x in max(0, c - 1)...min(change.columns - 1, c + 1) { changed[y * change.columns + x] = false }
            }
        }
        return ChangeMap(tile: change.tile, columns: change.columns, rows: change.rows, changed: changed,
                         imageWidth: change.imageWidth, imageHeight: change.imageHeight)
    }

    /// Seconds until the first animated tile counts as still again; nil when none is animated.
    public func coolsIn(at t: Double) -> Double? {
        streak.indices.filter { isHot($0, at: t) }.map { last[$0] + window - t }.min()
    }
}

public enum FrameDiff {
    /// A tile counts as changed when at least `minPixels` of its pixels moved by more than `delta` luma levels.
    /// Counting strong pixel changes (instead of averaging) keeps a single edited glyph from being diluted
    /// by the rest of the tile, while ignoring dithering/compression noise.
    /// `ignoring`: pixels that do not count (the strips a larger capture only now shows: there `a` has no content, so they differ without the page
    /// having changed). A tile that the strip cuts is judged by its other pixels.
    public static func changeMap(from a: GrayImage, to b: GrayImage, tile: Int = 16, delta: Int = 24, minPixels: Int = 2,
                                 ignoring: [PixelRect] = []) -> ChangeMap {
        guard a.width == b.width, a.height == b.height else {
            return .allChanged(width: b.width, height: b.height, tile: tile)
        }
        let cols = (b.width + tile - 1) / tile, rows = (b.height + tile - 1) / tile
        var counts = [Int](repeating: 0, count: cols * rows)
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for y in 0..<b.height {
                    let rowBase = (y / tile) * cols
                    let o = y * b.width
                    let skips = ignoring.isEmpty ? [] : ignoring.filter { y >= $0.y && y < $0.y + $0.height }
                    for x in 0..<b.width where abs(Int(pa[o + x]) - Int(pb[o + x])) > delta {
                        if !skips.isEmpty, skips.contains(where: { x >= $0.x && x < $0.x + $0.width }) { continue }
                        counts[rowBase + x / tile] += 1
                    }
                }
            }
        }
        return ChangeMap(tile: tile, columns: cols, rows: rows, changed: counts.map { $0 >= minPixels },
                         imageWidth: b.width, imageHeight: b.height)
    }

    /// Detects a pure vertical scroll: content of `a` shifted by `dy` pixels appears in `b` (positive dy = content
    /// moved down), to a quarter pixel: smooth scrolling moves by less than a downsampled pixel per frame.
    /// Returns nil when no shift explains the change clearly better than no shift.
    public static func verticalShift(from a: GrayImage, to b: GrayImage, maxShift: Int) -> Double? {
        guard a.width == b.width, a.height == b.height, a.height > 8 else { return nil }
        let maxShift = min(maxShift, a.height / 2)
        let base = meanAbsDiff(a, b, dy: 0)
        guard base > 0.5 else { return nil }
        var best = (dy: 0.0, err: base)
        for dy in -maxShift...maxShift where dy != 0 {
            let e = meanAbsDiff(a, b, dy: Double(dy))
            if e < best.err { best = (Double(dy), e) }
        }
        let whole = best.dy
        for f in [-0.5, -0.25, 0.25, 0.5] {
            let e = meanAbsDiff(a, b, dy: whole + f)
            if e < best.err { best = (whole + f, e) }
        }
        // Must explain the change clearly better than "nothing moved", and match well in absolute terms (a fraction of a
        // pixel only approximately: the capture averaged what is now split differently between pixels).
        guard abs(best.dy) >= 0.25, best.err < base * 0.6, best.err < 8 else { return nil }
        return best.dy
    }

    /// Mean |a(x, y) - b(x, y + dy)| over the overlapping rows, sampling every other column; a fractional `dy`
    /// blends the two nearest rows of `b`.
    static func meanAbsDiff(_ a: GrayImage, _ b: GrayImage, dy: Double) -> Double {
        let k = Int(dy.rounded(.down)), f = dy - Double(k)
        let w1 = Int((f * 256).rounded()), w0 = 256 - w1
        let y0 = max(0, -k), y1 = min(a.height, b.height - k - (w1 > 0 ? 1 : 0))
        guard y1 > y0 else { return .infinity }
        var sum = 0, n = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for y in y0..<y1 {
                    let oa = y * a.width, ob = (y + k) * b.width, ob1 = ob + (w1 > 0 ? b.width : 0)
                    var x = 0
                    while x < a.width {
                        let v = (Int(pb[ob + x]) * w0 + Int(pb[ob1 + x]) * w1) >> 8
                        sum += abs(Int(pa[oa + x]) - v)
                        x += 2
                    }
                    n += (a.width + 1) / 2
                }
            }
        }
        return Double(sum) / Double(max(n, 1))
    }

    /// What scrolled between `a` and `b`, found column band by column band: pages keep fixed parts (headers, sidebars,
    /// a message box) beside the part that scrolls, and one shift for the whole frame explains neither. Each band is
    /// matched over its changed rows only; a band too plain to tell on its own (a few short lines, a move of a fraction
    /// of a pixel) takes its neighbour's shift if that explains it better than no move. Neighbouring bands that agree
    /// form one region. Bands that changed without scrolling (a hover, a typing indicator) end a region and are left
    /// to be re-read.
    public static func scrollRegions(from a: GrayImage, to b: GrayImage, change: ChangeMap, maxShift: Int, bandTiles: Int = 2) -> [ScrollRegion] {
        guard a.width == b.width, a.height == b.height, change.imageWidth == b.width, change.imageHeight == b.height else { return [] }
        // Changed bands, left to right, with their own shift if one is clear.
        var bands: [(rect: PixelRect, dy: Double?)] = []
        for c0 in stride(from: 0, to: change.columns, by: bandTiles) {
            // The last band takes in the leftover columns (and the partial tile at the edge) instead of being a sliver.
            let c1 = change.columns - c0 < 2 * bandTiles ? change.columns : c0 + bandTiles
            if c0 > 0, c0 + bandTiles > change.columns { break }
            let rows = (0..<change.rows).filter { r in (c0..<c1).contains { change.changed[r * change.columns + $0] } }
            // Changed rows split by an unchanged tile row are separate things: a scrolling log above a fixed message box
            // with a typing indicator below it. The tallest run is what scrolls; the rest is re-read.
            var runs: [ClosedRange<Int>] = []
            for r in rows { if let last = runs.last, r == last.upperBound + 1 { runs[runs.count - 1] = last.lowerBound...r } else { runs.append(r...r) } }
            guard let run = runs.max(by: { $0.count < $1.count }) else { continue }   // untouched band: neither scrolls nor breaks
            let r0 = run.lowerBound, r1 = run.upperBound
            let rect = PixelRect(x: c0 * change.tile, y: r0 * change.tile, width: (c1 - c0) * change.tile, height: (r1 - r0 + 1) * change.tile)
                .clamped(width: b.width, height: b.height)
            // A short or sliver band matches repeating things (avatars, list rows) at a wrong shift; a scrolling column
            // changes along its whole height, so a real shift stays well within it.
            let dy = rect.width < change.tile ? nil
                : verticalShift(from: a.cropped(to: rect), to: b.cropped(to: rect), maxShift: min(maxShift, rect.height / 4))
            bands.append((rect, dy))
        }
        func neighbours(_ i: Int) -> [Double] { [i - 1, i + 1].filter { bands.indices.contains($0) }.compactMap { bands[$0].dy } }
        func explained(_ i: Int, by shifts: [Double]) -> Double? {
            let ca = a.cropped(to: bands[i].rect), cb = b.cropped(to: bands[i].rect)
            return shifts.first { meanAbsDiff(ca, cb, dy: $0) < 0.8 * meanAbsDiff(ca, cb, dy: 0) }
        }
        // A lone band at odds with every neighbour most likely matched something repeating at a wrong shift: it takes
        // a neighbour's shift if that explains it, or none (a missed band is re-read; a wrong one moves translations).
        for i in bands.indices {
            guard let dy = bands[i].dy else { continue }
            let near = neighbours(i)
            if !near.isEmpty, near.allSatisfy({ abs($0 - dy) > 0.5 }) { bands[i].dy = explained(i, by: near) }
        }
        for i in bands.indices where bands[i].dy == nil {
            bands[i].dy = explained(i, by: neighbours(i))
        }
        var regions: [ScrollRegion] = []
        var open = false
        for band in bands {
            guard let dy = band.dy else { open = false; continue }
            if open, let last = regions.last, abs(last.dy - dy) <= 0.5 {
                // Wider bands weigh more in the shared shift.
                let w0 = Double(last.rect.width), w1 = Double(band.rect.width)
                regions[regions.count - 1] = ScrollRegion(rect: PixelRect(last.rect.cgRect.union(band.rect.cgRect)),
                                                          dy: (last.dy * w0 + dy * w1) / (w0 + w1))
            } else {
                regions.append(ScrollRegion(rect: band.rect, dy: dy))
                open = true
            }
        }
        // A region a tile or two tall is something moving in place (an animated emoji wobbling by a pixel), not a scroll.
        return regions.filter { $0.rect.height >= 3 * change.tile }
    }
}

/// Part of a frame whose content moved vertically: `rect` (gray pixels, in the newer frame) moved down by `dy` pixels.
public struct ScrollRegion: Sendable, Equatable {
    public var rect: PixelRect
    public var dy: Double
    public init(rect: PixelRect, dy: Double) { self.rect = rect; self.dy = dy }
}

/// Turns fractional moves into whole-pixel steps without losing the remainder, so many tiny moves
/// (a slow drag) add up to exactly the same shift as one big move.
public struct ShiftAccumulator: Sendable {
    private var remainder: CGFloat = 0
    public init() {}

    /// Adds `delta` and returns the whole steps to apply now.
    public mutating func add(_ delta: CGFloat) -> Int {
        remainder += delta
        // Nudge by an epsilon so 20 × 0.3 counts as 6, not 5.999….
        let whole = (remainder + (remainder >= 0 ? 1e-9 : -1e-9)).rounded(.towardZero)
        remainder -= whole
        return Int(whole)
    }

    public mutating func reset() { remainder = 0 }
}
