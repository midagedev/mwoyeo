import CoreGraphics

/// 8-bit luminance image, row-major, no padding. Used for cheap change/scroll detection.
public struct GrayImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: UInt8 = 0) {
        self.init(width: width, height: height, pixels: [UInt8](repeating: fill, count: width * height))
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Content moved right by `dx` and down by `dy` pixels (negative = left/up). Vacated pixels get `fill`.
    public func shifted(dx: Int, dy: Int, fill: UInt8 = 0) -> GrayImage {
        reframed(dx: dx, dy: dy, width: width, height: height, fill: fill)
    }

    /// This image placed at (`dx`, `dy`) inside a new `width`×`height` canvas; the rest gets `fill`.
    public func reframed(dx: Int, dy: Int, width w: Int, height h: Int, fill: UInt8 = 0) -> GrayImage {
        var out = GrayImage(width: w, height: h, fill: fill)
        let x0 = max(0, dx), x1 = min(w, width + dx)
        guard x1 > x0 else { return out }
        for y in 0..<h {
            let sy = y - dy
            guard sy >= 0, sy < height else { continue }
            let src = sy * width + (x0 - dx), dst = y * w + x0
            out.pixels.replaceSubrange(dst ..< dst + (x1 - x0), with: pixels[src ..< src + (x1 - x0)])
        }
        return out
    }

    public func cropped(to r: PixelRect) -> GrayImage {
        let c = r.clamped(width: width, height: height)
        var out = GrayImage(width: c.width, height: c.height)
        for y in 0..<c.height {
            let src = (c.y + y) * width + c.x
            out.pixels.replaceSubrange(y * c.width ..< (y + 1) * c.width, with: pixels[src ..< src + c.width])
        }
        return out
    }

    /// Only the content inside `r` moved down by `dy` (negative = up), clipped to `r`: a scrolled column between fixed
    /// parts. Rows of `r` left without content get `fill`.
    public func shifted(dy: Int, within r: PixelRect, fill: UInt8 = 0) -> GrayImage {
        let r = r.clamped(width: width, height: height)
        var out = self
        for y in r.y ..< r.y + r.height {
            let sy = y - dy, dst = y * width + r.x
            if sy >= r.y, sy < r.y + r.height {
                out.pixels.replaceSubrange(dst ..< dst + r.width, with: pixels[sy * width + r.x ..< sy * width + r.x + r.width])
            } else {
                out.pixels.replaceSubrange(dst ..< dst + r.width, with: repeatElement(fill, count: r.width))
            }
        }
        return out
    }

    /// The rows of `r` that `shifted(dy:within:)` leaves without content.
    public static func vacated(dy: Int, within r: PixelRect) -> PixelRect? {
        let h = min(abs(dy), r.height)
        guard h > 0 else { return nil }
        return PixelRect(x: r.x, y: dy > 0 ? r.y : r.y + r.height - h, width: r.width, height: h)
    }

    /// This image with the pixels of `r` taken from `other` (same size).
    public func replacing(_ r: PixelRect, from other: GrayImage) -> GrayImage {
        let r = r.clamped(width: width, height: height)
        var out = self
        for y in r.y ..< r.y + r.height {
            let o = y * width + r.x
            out.pixels.replaceSubrange(o ..< o + r.width, with: other.pixels[o ..< o + r.width])
        }
        return out
    }

    /// Pixels a `shifted(dx:dy:)` leaves without content.
    public func vacatedStrips(dx: Int, dy: Int) -> [PixelRect] {
        uncovered(dx: dx, dy: dy, width: width, height: height)
    }

    /// Parts of a `width`×`height` canvas that `reframed(dx:dy:width:height:)` leaves without content:
    /// up to four strips (top, bottom across the full width; left, right between them).
    public func uncovered(dx: Int, dy: Int, width w: Int, height h: Int) -> [PixelRect] {
        let x0 = min(w, max(0, dx)), x1 = max(x0, min(w, width + dx))
        let y0 = min(h, max(0, dy)), y1 = max(y0, min(h, height + dy))
        guard x1 > x0, y1 > y0 else { return w > 0 && h > 0 ? [PixelRect(x: 0, y: 0, width: w, height: h)] : [] }
        return [PixelRect(x: 0, y: 0, width: w, height: y0),
                PixelRect(x: 0, y: y1, width: w, height: h - y1),
                PixelRect(x: 0, y: y0, width: x0, height: y1 - y0),
                PixelRect(x: x1, y: y0, width: w - x1, height: y1 - y0)].filter { !$0.isEmpty }
    }

    /// Box-downsamples a BGRA8 buffer by `step` (each output pixel = mean luma of a step×step block).
    public init(bgra base: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, step: Int) {
        let step = max(1, step)
        let w = width / step, h = height / step
        var out = [UInt8](repeating: 0, count: w * h)
        let src = base.assumingMemoryBound(to: UInt8.self)
        let area = UInt32(step * step)
        out.withUnsafeMutableBufferPointer { dst in
            for oy in 0..<h {
                for ox in 0..<w {
                    var sum: UInt32 = 0
                    for dy in 0..<step {
                        let row = src + (oy * step + dy) * bytesPerRow + ox * step * 4
                        for dx in 0..<step {
                            let p = row + dx * 4
                            // BGRA → Rec.601 luma in fixed point.
                            sum += (UInt32(p[2]) * 77 + UInt32(p[1]) * 150 + UInt32(p[0]) * 29) >> 8
                        }
                    }
                    dst[oy * w + ox] = UInt8(sum / area)
                }
            }
        }
        self.init(width: w, height: h, pixels: out)
    }
}

/// Straight (non-premultiplied) RGBA8 image, row-major, no padding.
public struct RGBAImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height * 4)
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, color: RGBA) {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) {
            px[i * 4] = color.r; px[i * 4 + 1] = color.g; px[i * 4 + 2] = color.b; px[i * 4 + 3] = color.a
        }
        self.init(width: width, height: height, pixels: px)
    }

    @inline(__always) public func color(x: Int, y: Int) -> RGBA {
        let i = (y * width + x) * 4
        return RGBA(pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3])
    }

    @inline(__always) public mutating func set(x: Int, y: Int, _ c: RGBA) {
        let i = (y * width + x) * 4
        pixels[i] = c.r; pixels[i + 1] = c.g; pixels[i + 2] = c.b; pixels[i + 3] = c.a
    }

    @inline(__always) public func luma(x: Int, y: Int) -> Int {
        let i = (y * width + x) * 4
        return (Int(pixels[i]) * 77 + Int(pixels[i + 1]) * 150 + Int(pixels[i + 2]) * 29) >> 8
    }

    public func cropped(to r: PixelRect) -> RGBAImage {
        let r = r.clamped(width: width, height: height)
        var out = [UInt8](repeating: 0, count: r.width * r.height * 4)
        for y in 0..<r.height {
            let s = ((r.y + y) * width + r.x) * 4
            out.replaceSubrange(y * r.width * 4 ..< (y + 1) * r.width * 4, with: pixels[s ..< s + r.width * 4])
        }
        return RGBAImage(width: r.width, height: r.height, pixels: out)
    }

    /// Writes `patch` into self with its top-left at (x, y), clipping at the edges.
    public mutating func paste(_ patch: RGBAImage, x: Int, y: Int) {
        for py in 0..<patch.height where y + py >= 0 && y + py < height {
            for px in 0..<patch.width where x + px >= 0 && x + px < width {
                set(x: x + px, y: y + py, patch.color(x: px, y: py))
            }
        }
    }
}

public struct RGBA: Sendable, Equatable, Hashable {
    public var r, g, b, a: UInt8
    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }
    public var luma: Int { (Int(r) * 77 + Int(g) * 150 + Int(b) * 29) >> 8 }
    /// Euclidean RGB distance.
    public func distance(to o: RGBA) -> Double {
        let dr = Double(r) - Double(o.r), dg = Double(g) - Double(o.g), db = Double(b) - Double(o.b)
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}

/// Integer pixel rectangle, top-left origin.
public struct PixelRect: Sendable, Equatable, Hashable {
    public var x, y, width, height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ r: CGRect) {
        let i = r.integral
        self.init(x: Int(i.minX), y: Int(i.minY), width: Int(i.width), height: Int(i.height))
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public func insetBy(_ d: Int) -> PixelRect { PixelRect(x: x + d, y: y + d, width: width - 2 * d, height: height - 2 * d) }
    public func clamped(width w: Int, height h: Int) -> PixelRect {
        let x0 = max(0, min(x, w)), y0 = max(0, min(y, h))
        let x1 = max(x0, min(x + width, w)), y1 = max(y0, min(y + height, h))
        return PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
    /// `rects` moved with the content by (`dx`, `dy`) onto a `width`×`height` canvas: the parts that fall outside it are gone, a frame of
    /// that size has no pixels there. The strips a grow uncovered and a shrink back to the old size took away leave nothing to read
    /// (holdfix117 A2: left in place, the one left of the capture made the first frame after a shrink a read of every row).
    public static func moved(_ rects: [PixelRect], dx: Int, dy: Int, width w: Int, height h: Int) -> [PixelRect] {
        rects.map { PixelRect(x: $0.x + dx, y: $0.y + dy, width: $0.width, height: $0.height).clamped(width: w, height: h) }.filter { !$0.isEmpty }
    }
}
