/// What we learned about one line of text sitting on its background.
public struct TextAppearance: Sendable, Equatable {
    public var textColor: RGBA
    public var backgroundColor: RGBA
    /// Standard deviation of border luma. Low = flat background.
    public var backgroundNoise: Double
    /// Fraction of the text rect classified as glyph pixels.
    public var coverage: Double
    /// Colour of the outline around outlined text (video subtitles: white letters with a black edge); nil = plain text.
    public var outlineColor: RGBA?

    public var isFlatBackground: Bool { backgroundNoise < 6 }

    public init(textColor: RGBA, backgroundColor: RGBA, backgroundNoise: Double, coverage: Double, outlineColor: RGBA? = nil) {
        self.textColor = textColor
        self.backgroundColor = backgroundColor
        self.backgroundNoise = backgroundNoise
        self.coverage = coverage
        self.outlineColor = outlineColor
    }
}

public struct TextMask: Sendable {
    public let width: Int
    public let height: Int
    /// 1 = glyph (to erase), 0 = background.
    public var bits: [UInt8]
    public var appearance: TextAppearance
    /// Bounding box of the detected glyph pixels before dilation (patch coordinates); nil if none were found.
    public var glyphBounds: PixelRect?

    public var count: Int { bits.reduce(0) { $0 + Int($1) } }
}

/// A column run of glyph pixels in a line: a letter or a few touching ones, or an icon.
public struct InkCluster: Sendable, Equatable {
    public var minX: Int
    public var maxX: Int
    public var color: RGBA
    public var ink: Int
    public var solid: Bool

    public init(minX: Int, maxX: Int, color: RGBA, ink: Int, solid: Bool) {
        self.minX = minX
        self.maxX = maxX
        self.color = color
        self.ink = ink
        self.solid = solid
    }
}

public enum TextEraser {
    /// Builds a glyph mask for `patch`, where `textRect` (patch coordinates) bounds the text and the ring of
    /// pixels around it is background.
    ///
    /// - Background colour and noise are robust (median / MAD) so a box edge or a bit of another UI element
    ///   in the ring does not skew them.
    /// - Glyph pixels are the Otsu class farther from the background, kept only as connected components that
    ///   reach into the text rect and do not run off the patch's outer edge — glyphs sit inside the ring,
    ///   while box borders, rules and neighbouring backgrounds continue past it.
    /// - The mask is dilated by `dilation` px to swallow anti-aliased edges.
    /// `outlines`: also look for outlined text (white letters, black edge) and take both tones into the mask — for
    /// erasing only; colour runs and labels want the plain one-tone mask.
    public static func mask(for patch: RGBAImage, textRect: PixelRect, dilation: Int, outlines: Bool = false) -> TextMask {
        let w = patch.width, h = patch.height
        let inner = textRect.clamped(width: w, height: h)
        @inline(__always) func inInner(_ x: Int, _ y: Int) -> Bool {
            x >= inner.x && x < inner.x + inner.width && y >= inner.y && y < inner.y + inner.height
        }

        var border: [RGBA] = []
        for y in 0..<h { for x in 0..<w where !inInner(x, y) { border.append(patch.color(x: x, y: y)) } }
        if border.isEmpty {
            for x in 0..<w { border.append(patch.color(x: x, y: 0)); border.append(patch.color(x: x, y: h - 1)) }
        }
        let bg = medianColor(border)
        let lumas = border.map(\.luma)
        let medL = median(lumas)
        let noise = 1.4826 * Double(median(lumas.map { abs($0 - medL) }))

        var hist = [Int](repeating: 0, count: 256)
        for y in inner.y..<(inner.y + inner.height) { for x in inner.x..<(inner.x + inner.width) { hist[patch.luma(x: x, y: y)] += 1 } }
        let t = otsuThreshold(hist)
        let darkGlyphs = bg.luma > t
        let minContrast = max(12, Int(noise * 2.5))

        var candidate = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let l = patch.luma(x: x, y: y)
                candidate[y * w + x] = (darkGlyphs ? l <= t : l > t) && abs(l - bg.luma) >= minContrast
            }
        }

        // Connected components (8-neighbour). Only edges that have a ring count as "outer": if the patch was
        // clipped at the screen edge, glyphs may legitimately touch it.
        let ringLeft = inner.x > 0, ringTop = inner.y > 0
        let ringRight = inner.x + inner.width < w, ringBottom = inner.y + inner.height < h
        var bits = [UInt8](repeating: 0, count: w * h)
        var seen = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        var component: [Int] = []
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var glyphColors: [(RGBA, Int)] = []
        var innerGlyphs = 0
        for start in 0..<(w * h) where candidate[start] && !seen[start] {
            component.removeAll(keepingCapacity: true)
            var touchesOuter = false, reachesInner = false
            stack.append(start)
            seen[start] = true
            while let i = stack.popLast() {
                component.append(i)
                let x = i % w, y = i / w
                if (x == 0 && ringLeft) || (x == w - 1 && ringRight) || (y == 0 && ringTop) || (y == h - 1 && ringBottom) { touchesOuter = true }
                if inInner(x, y) { reachesInner = true }
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                        let j = ny * w + nx
                        if candidate[j] && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            guard reachesInner, !touchesOuter else { continue }
            for i in component {
                bits[i] = 1
                let x = i % w, y = i / w
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                let c = patch.color(x: x, y: y)
                glyphColors.append((c, abs(c.luma - bg.luma)))
                if inInner(x, y) { innerGlyphs += 1 }
            }
        }

        var coverage = Double(innerGlyphs) / Double(max(1, inner.width * inner.height))
        var glyphBounds: PixelRect? = maxX >= 0 ? PixelRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
        // Segmentation failed (textured or low-contrast background): erase the whole text rect instead.
        if coverage > 0.6 || glyphColors.isEmpty {
            bits = [UInt8](repeating: 0, count: w * h)
            for y in inner.y..<(inner.y + inner.height) { for x in inner.x..<(inner.x + inner.width) { bits[y * w + x] = 1 } }
            coverage = 1
            glyphBounds = nil
        }

        // Text colour from the most contrasting half of glyph pixels — edge pixels are blended with the background.
        let textColor: RGBA
        if glyphColors.isEmpty || coverage == 1 {
            textColor = bg.luma > 128 ? RGBA(0, 0, 0) : RGBA(255, 255, 255)
        } else {
            let core = glyphColors.sorted { $0.1 > $1.1 }.prefix(max(1, glyphColors.count / 2)).map(\.0)
            textColor = meanColor(Array(core))
        }

        var appearance = TextAppearance(textColor: textColor, backgroundColor: bg, backgroundNoise: noise, coverage: coverage)
        // Outlined text (subtitles over video): the Otsu split keeps only one of its two tones, so the letters' fill
        // or their edge would survive the erase and the translation would be drawn in the edge colour.
        if outlines, let o = outline(in: patch, inner: inner, background: bg) {
            appearance.textColor = o.fill
            appearance.outlineColor = o.edge
            for i in o.pixels { bits[i] = 1 }
        }
        var m = TextMask(width: w, height: h, bits: bits, appearance: appearance, glyphBounds: glyphBounds)
        m.bits = dilate(m.bits, width: w, height: h, radius: dilation)
        return m
    }

    /// Outlined text in `inner`: enough very light and very dark pixels, nearly every light one within a few pixels of
    /// a dark one (the edge hugs the fill), on a background that is neither tone — white text on black, or black on
    /// white, is plain text. Returns the two tones and the pixels of both (patch indices).
    static func outline(in patch: RGBAImage, inner: PixelRect, background: RGBA) -> (fill: RGBA, edge: RGBA, pixels: [Int])? {
        guard background.luma > 75, background.luma < 185 else { return nil }
        let w = patch.width
        var light: [Int] = [], dark: [Int] = []
        var isDark = [Bool](repeating: false, count: w * patch.height)
        for y in inner.y..<(inner.y + inner.height) {
            for x in inner.x..<(inner.x + inner.width) {
                let l = patch.luma(x: x, y: y)
                if l >= 200 { light.append(y * w + x) } else if l <= 60 { dark.append(y * w + x); isDark[y * w + x] = true }
            }
        }
        let area = max(1, inner.width * inner.height)
        guard light.count * 25 >= area, dark.count * 25 >= area else { return nil }
        let r = max(3, inner.height / 8)   // about half a stroke of subtitle text
        var hugged = 0
        for i in light {
            let x = i % w, y = i / w
            search: for dy in -r...r {
                for dx in -r...r {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, ny >= 0, nx < w, ny < patch.height, isDark[ny * w + nx] { hugged += 1; break search }
                }
            }
        }
        guard hugged * 100 >= light.count * 80 else { return nil }
        return (meanColor(light.map { patch.color(x: $0 % w, y: $0 / w) }), meanColor(dark.map { patch.color(x: $0 % w, y: $0 / w) }), light + dark)
    }

    /// Fills masked pixels from their surroundings: onion-peel propagation (each ring takes the mean of its
    /// already-known 8-neighbours), then Jacobi smoothing so gradients continue through the hole.
    public static func fill(_ img: inout RGBAImage, mask: [UInt8], smoothing: Int = 12) {
        let w = img.width, h = img.height
        precondition(mask.count == w * h)
        var known = mask.map { $0 == 0 }
        guard known.contains(true) else { return }
        var pending = (0..<(w * h)).filter { !known[$0] }
        let holes = pending
        var px = img.pixels.map { Int($0) }

        while !pending.isEmpty {
            var ring: [(i: Int, r: Int, g: Int, b: Int, a: Int)] = []
            var rest: [Int] = []
            for i in pending {
                let x = i % w, y = i / w
                var r = 0, g = 0, b = 0, a = 0, n = 0
                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx, ny = y + dy
                        guard nx >= 0, ny >= 0, nx < w, ny < h, known[ny * w + nx] else { continue }
                        let j = (ny * w + nx) * 4
                        r += px[j]; g += px[j + 1]; b += px[j + 2]; a += px[j + 3]
                        n += 1
                    }
                }
                if n > 0 { ring.append((i, r / n, g / n, b / n, a / n)) } else { rest.append(i) }
            }
            if ring.isEmpty { break } // unreachable while at least one pixel is known; guards against a hang
            for c in ring {
                px[c.i * 4] = c.r; px[c.i * 4 + 1] = c.g; px[c.i * 4 + 2] = c.b; px[c.i * 4 + 3] = c.a
                known[c.i] = true
            }
            pending = rest
        }

        for _ in 0..<smoothing {
            var next = px
            for i in holes {
                let x = i % w, y = i / w
                for c in 0..<4 {
                    var sum = 0, n = 0
                    if x > 0 { sum += px[(i - 1) * 4 + c]; n += 1 }
                    if x < w - 1 { sum += px[(i + 1) * 4 + c]; n += 1 }
                    if y > 0 { sum += px[(i - w) * 4 + c]; n += 1 }
                    if y < h - 1 { sum += px[(i + w) * 4 + c]; n += 1 }
                    next[i * 4 + c] = sum / max(n, 1)
                }
            }
            px = next
        }
        img.pixels = px.map { UInt8(clamping: $0) }
    }

    /// Glyph pixels of `mask` (built without dilation) gathered into column runs — letters, or an icon or avatar
    /// in the line — left to right, in patch coordinates. `solid` marks filled shapes at least half a line tall:
    /// an avatar or an emoji, not a stroke of text.
    public static func clusters(_ mask: TextMask, in patch: RGBAImage, lineHeight: Int) -> [InkCluster] {
        let w = mask.width, h = mask.height, bg = mask.appearance.backgroundColor
        guard mask.appearance.coverage < 1 else { return [] }
        var out: [InkCluster] = []
        var x = 0
        while x < w {
            guard (0..<h).contains(where: { mask.bits[$0 * w + x] != 0 }) else { x += 1; continue }
            var end = x
            while end + 1 < w, (0..<h).contains(where: { mask.bits[$0 * w + end + 1] != 0 }) { end += 1 }
            var colors: [(RGBA, Int)] = []
            var top = h, bottom = -1
            for y in 0..<h {
                for cx in x...end where mask.bits[y * w + cx] != 0 {
                    let c = patch.color(x: cx, y: y)
                    colors.append((c, abs(c.luma - bg.luma)))
                    top = min(top, y); bottom = max(bottom, y)
                }
            }
            let rows = bottom - top + 1, width = end - x + 1
            let core = colors.sorted { $0.1 > $1.1 }.prefix(max(1, colors.count / 2)).map(\.0)
            let solid = rows * 2 >= lineHeight && width * 2 >= rows && Double(colors.count) >= 0.7 * Double(rows * width)
            out.append(InkCluster(minX: x, maxX: end + 1, color: meanColor(Array(core)), ink: colors.count, solid: solid))
            x = end + 1
        }
        return out
    }

    /// Marks every unmasked pixel that cannot reach the image border without crossing the mask — the gaps
    /// inside and between big glyphs. Left alone, an inpainter treats them as known pixels and they show up
    /// as islands of the old glyph colour.
    public static func fillEnclosedHoles(_ bits: inout [UInt8], width w: Int, height h: Int) {
        var outside = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        func seed(_ i: Int) { if bits[i] == 0 && !outside[i] { outside[i] = true; stack.append(i) } }
        for x in 0..<w { seed(x); seed((h - 1) * w + x) }
        for y in 0..<h { seed(y * w); seed(y * w + w - 1) }
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if x > 0 { seed(i - 1) }
            if x < w - 1 { seed(i + 1) }
            if y > 0 { seed(i - w) }
            if y < h - 1 { seed(i + w) }
        }
        for i in bits.indices where bits[i] == 0 && !outside[i] { bits[i] = 1 }
    }

    public static func otsuThreshold(_ hist: [Int]) -> Int {
        let total = hist.reduce(0, +)
        guard total > 0 else { return 127 }
        let sumAll = hist.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var sumB = 0.0, wB = 0, best = 0.0, threshold = 127
        for t in 0..<256 {
            wB += hist[t]
            guard wB > 0 else { continue }
            let wF = total - wB
            if wF == 0 { break }
            sumB += Double(t * hist[t])
            let mB = sumB / Double(wB), mF = (sumAll - sumB) / Double(wF)
            let between = Double(wB) * Double(wF) * (mB - mF) * (mB - mF)
            if between > best { best = between; threshold = t }
        }
        return threshold
    }

    public static func dilate(_ bits: [UInt8], width w: Int, height h: Int, radius: Int) -> [UInt8] {
        guard radius > 0 else { return bits }
        // Separable square dilation: horizontal pass then vertical pass.
        var tmp = [UInt8](repeating: 0, count: bits.count)
        for y in 0..<h {
            for x in 0..<w where bits[y * w + x] != 0 {
                for nx in max(0, x - radius)...min(w - 1, x + radius) { tmp[y * w + nx] = 1 }
            }
        }
        var out = [UInt8](repeating: 0, count: bits.count)
        for y in 0..<h {
            for x in 0..<w where tmp[y * w + x] != 0 {
                for ny in max(0, y - radius)...min(h - 1, y + radius) { out[ny * w + x] = 1 }
            }
        }
        return out
    }

    static func meanColor(_ cs: [RGBA]) -> RGBA {
        guard !cs.isEmpty else { return RGBA(255, 255, 255) }
        var r = 0, g = 0, b = 0, a = 0
        for c in cs { r += Int(c.r); g += Int(c.g); b += Int(c.b); a += Int(c.a) }
        let n = cs.count
        return RGBA(UInt8(r / n), UInt8(g / n), UInt8(b / n), UInt8(a / n))
    }

    static func median(_ xs: [Int]) -> Int {
        guard !xs.isEmpty else { return 0 }
        return xs.sorted()[xs.count / 2]
    }

    /// Per-channel median.
    static func medianColor(_ cs: [RGBA]) -> RGBA {
        guard !cs.isEmpty else { return RGBA(255, 255, 255) }
        return RGBA(UInt8(median(cs.map { Int($0.r) })), UInt8(median(cs.map { Int($0.g) })),
                    UInt8(median(cs.map { Int($0.b) })), UInt8(median(cs.map { Int($0.a) })))
    }

    static func stddev(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return 0 }
        let m = xs.reduce(0, +) / Double(xs.count)
        return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(xs.count)).squareRoot()
    }
}
