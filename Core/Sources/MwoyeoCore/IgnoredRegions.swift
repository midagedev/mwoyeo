import CoreGraphics

/// A part of a lens as fractions of it, y down: (0, 0) is the lens's top-left corner and (1, 1) its bottom-right. Kept in fractions so a
/// region stays on what it covered while the lens is moved or resized (design games-and-video §1).
public struct UnitRect: Codable, Equatable, Sendable {
    public var x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    /// The region as a rect in the same space as `lens`.
    public func rect(in lens: CGRect) -> CGRect {
        CGRect(x: lens.minX + x * lens.width, y: lens.minY + y * lens.height, width: width * lens.width, height: height * lens.height)
    }
}

/// What a lens does not read: the regions its person marked (HUD, name tag, timer), as one owner of their geometry. Points are global
/// Quartz points, as the lens and the capture are; pixels are the capture's, y down.
public enum IgnoredRegions {
    /// Regions one lens keeps; a newer one pushes the oldest out.
    public static let limit = 12
    /// A drag with a side shorter than this (points) is a click, not a region.
    public static let minimumSide: CGFloat = 8

    /// A drag (global points) as a region of `lens`, cut at the lens's edge; nil when nothing of it lies in the lens or it is too small.
    public static func region(dragged: CGRect, in lens: CGRect) -> UnitRect? {
        guard lens.width > 0, lens.height > 0 else { return nil }
        let r = dragged.standardized.intersection(lens)
        guard !r.isNull, r.width >= minimumSide, r.height >= minimumSide else { return nil }
        return UnitRect(x: (r.minX - lens.minX) / lens.width, y: (r.minY - lens.minY) / lens.height,
                        width: r.width / lens.width, height: r.height / lens.height)
    }

    /// `list` with `region` added: one inside a region already there adds nothing, regions inside the new one go, and at most `limit` stay
    /// (the newest).
    public static func adding(_ region: UnitRect, to list: [UnitRect]) -> [UnitRect] {
        func holds(_ a: UnitRect, _ b: UnitRect) -> Bool {
            let e = 1e-9
            return a.x <= b.x + e && a.y <= b.y + e && a.x + a.width >= b.x + b.width - e && a.y + a.height >= b.y + b.height - e
        }
        if list.contains(where: { holds($0, region) }) { return list }
        let kept = list.filter { !holds(region, $0) } + [region]
        return Array(kept.suffix(limit))
    }

    /// A list read from a saved lens, made sound: values cut to the lens, what has no area or is not a number dropped, at most `limit`.
    public static func sanitized(_ list: [UnitRect]) -> [UnitRect] {
        let mended: [UnitRect] = list.compactMap { r in
            guard [r.x, r.y, r.width, r.height].allSatisfy(\.isFinite) else { return nil }
            // One that lies in the lens stays as it is (cutting it would move its width by the last digit of a sum).
            let e = 1e-9
            if r.x >= 0, r.y >= 0, r.width > 0, r.height > 0, r.x + r.width <= 1 + e, r.y + r.height <= 1 + e { return r }
            let x0 = min(max(r.x, 0), 1), y0 = min(max(r.y, 0), 1)
            let x1 = min(max(r.x + r.width, 0), 1), y1 = min(max(r.y + r.height, 0), 1)
            guard x1 > x0, y1 > y0 else { return nil }
            return UnitRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        return Array(mended.suffix(limit))
    }

    /// The regions as areas of a capture's picture (`capture` global points, `scale` pixels per point), rounded outward and kept inside it;
    /// a region that lies wholly outside the picture is left out.
    public static func pixels(_ regions: [UnitRect], lens: CGRect, capture: CGRect, scale: CGFloat, imageWidth: Int, imageHeight: Int) -> [PixelRect] {
        // Float noise at a whole pixel must not widen the area by one.
        let noise: CGFloat = 1e-6
        return regions.compactMap { region in
            let r = region.rect(in: lens)
            let x0 = Int(((r.minX - capture.minX) * scale + noise).rounded(.down)), y0 = Int(((r.minY - capture.minY) * scale + noise).rounded(.down))
            let x1 = Int(((r.maxX - capture.minX) * scale - noise).rounded(.up)), y1 = Int(((r.maxY - capture.minY) * scale - noise).rounded(.up))
            let area = PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).clamped(width: imageWidth, height: imageHeight)
            return area.isEmpty ? nil : area
        }
    }

    /// The same areas in the gray picture, where one pixel stands for `step` × `step` of the capture's: rounded outward.
    public static func gray(_ pixels: [PixelRect], step: Int, width: Int, height: Int) -> [PixelRect] {
        pixels.compactMap { p in
            let x0 = p.x / step, y0 = p.y / step
            let x1 = (p.x + p.width + step - 1) / step, y1 = (p.y + p.height + step - 1) / step
            let area = PixelRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0).clamped(width: width, height: height)
            return area.isEmpty ? nil : area
        }
    }
}

extension GrayImage {
    /// This picture with `areas` flat: what is in them no longer changes a pixel, so it is never a change.
    public func filled(_ areas: [PixelRect], with value: UInt8 = 128) -> GrayImage {
        var out = self
        for a in areas {
            let c = a.clamped(width: width, height: height)
            guard !c.isEmpty else { continue }
            for y in c.y ..< c.y + c.height {
                out.pixels.replaceSubrange(y * width + c.x ..< y * width + c.x + c.width, with: repeatElement(value, count: c.width))
            }
        }
        return out
    }
}

extension RGBAImage {
    /// This picture with `areas` painted flat in the colour just outside each (the mean of a two-pixel ring; mid-gray where an area has no
    /// outside): what the reader is given in place of a HUD, a name tag or a timer, so that no glyph of it is read and no edge of a patch is
    /// taken for text. An area is cut at the picture's edge.
    public func filled(_ areas: [PixelRect]) -> RGBAImage {
        var out = self
        for a in areas {
            let r = a.clamped(width: width, height: height)
            guard !r.isEmpty else { continue }
            let color = out.ringColor(around: r)
            for y in r.y ..< r.y + r.height {
                for x in r.x ..< r.x + r.width { out.set(x: x, y: y, color) }
            }
        }
        return out
    }

    private func ringColor(around r: PixelRect) -> RGBA {
        let ring = 2
        let outer = PixelRect(x: r.x - ring, y: r.y - ring, width: r.width + 2 * ring, height: r.height + 2 * ring).clamped(width: width, height: height)
        let strips = [PixelRect(x: outer.x, y: outer.y, width: outer.width, height: r.y - outer.y),
                      PixelRect(x: outer.x, y: r.y + r.height, width: outer.width, height: outer.y + outer.height - (r.y + r.height)),
                      PixelRect(x: outer.x, y: r.y, width: r.x - outer.x, height: r.height),
                      PixelRect(x: r.x + r.width, y: r.y, width: outer.x + outer.width - (r.x + r.width), height: r.height)]
        var sum = [0, 0, 0], n = 0
        for s in strips where !s.isEmpty {
            for y in s.y ..< s.y + s.height {
                for x in s.x ..< s.x + s.width {
                    let c = color(x: x, y: y)
                    sum[0] += Int(c.r); sum[1] += Int(c.g); sum[2] += Int(c.b)
                    n += 1
                }
            }
        }
        guard n > 0 else { return RGBA(128, 128, 128) }
        return RGBA(UInt8(sum[0] / n), UInt8(sum[1] / n), UInt8(sum[2] / n))
    }
}
