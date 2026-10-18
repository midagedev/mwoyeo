// The ink of a page: a mask, its 8-connected components, and the same components of the mask dilated by a few pixels (glyph parts
// that nearly touch, like a subscript under its letter, are one there). Pixel rows run top-down, as the OCR rects do.
import CoreGraphics
import Foundation
import ImageIO

struct IntRect: Equatable {
    var x0, y0, x1, y1: Int   // half-open
    var width: Int { x1 - x0 }
    var height: Int { y1 - y0 }
    func union(_ o: IntRect) -> IntRect { IntRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1)) }
    func clamped(_ w: Int, _ h: Int) -> IntRect { IntRect(x0: max(0, x0), y0: max(0, y0), x1: min(w, x1), y1: min(h, y1)) }
    init(x0: Int, y0: Int, x1: Int, y1: Int) { self.x0 = x0; self.y0 = y0; self.x1 = x1; self.y1 = y1 }
    init(_ r: CGRect) { self.init(x0: Int(r.minX.rounded(.down)), y0: Int(r.minY.rounded(.down)), x1: Int(r.maxX.rounded(.up)), y1: Int(r.maxY.rounded(.up))) }
    var cg: CGRect { CGRect(x: x0, y: y0, width: width, height: height) }
}

struct Component {
    var box: IntRect
    var count = 0
    var cx = 0.0, cy = 0.0
}

final class Ink {
    let width: Int, height: Int
    let image: CGImage
    var mask: [UInt8]
    /// 0 = no ink, else 1-based index into `comps` (+1).
    var labels: [Int32]
    var comps: [Component]
    var dlabels: [Int32]
    /// For each dilated component (1-based), the raw components inside it.
    var inDilated: [[Int32]]

    init(image: CGImage, threshold: Int, dilate: Int) {
        self.image = image
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        var gray = [UInt8](repeating: 255, count: width * height)
        gray.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        mask = gray.map { Int($0) < threshold ? 1 : 0 }
        let (l, n) = Ink.label(mask, width, height)
        labels = l
        comps = [Component](repeating: Component(box: IntRect(x0: Int.max, y0: Int.max, x1: Int.min, y1: Int.min)), count: n + 1)
        var sx = [Double](repeating: 0, count: n + 1), sy = [Double](repeating: 0, count: n + 1)
        for y in 0..<height {
            for x in 0..<width {
                let k = Int(labels[y * width + x])
                guard k > 0 else { continue }
                comps[k].count += 1
                comps[k].box = comps[k].box.union(IntRect(x0: x, y0: y, x1: x + 1, y1: y + 1))
                sx[k] += Double(x); sy[k] += Double(y)
            }
        }
        for k in 1...max(1, n) where comps[k].count > 0 { comps[k].cx = sx[k] / Double(comps[k].count); comps[k].cy = sy[k] / Double(comps[k].count) }
        let dilated = Ink.dilate(mask, width, height, dilate)
        let (dl, dn) = Ink.label(dilated, width, height)
        // The dilated mask contains the ink, so every ink pixel has a dilated label.
        var members = [Set<Int32>](repeating: [], count: dn + 1)
        for i in 0..<(width * height) where mask[i] != 0 { members[Int(dl[i])].insert(labels[i]) }
        dlabels = dl
        inDilated = members.map { Array($0) }
    }

    /// Two-pass 8-connected labelling; labels are 1...n.
    static func label(_ mask: [UInt8], _ w: Int, _ h: Int) -> ([Int32], Int) {
        var lab = [Int32](repeating: 0, count: w * h)
        var parent: [Int32] = [0]
        func find(_ a: Int32) -> Int32 {
            var r = a
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = a
            while parent[Int(c)] != r { let n = parent[Int(c)]; parent[Int(c)] = r; c = n }
            return r
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard mask[i] != 0 else { continue }
                var m: Int32 = 0
                for (dx, dy) in [(-1, 0), (-1, -1), (0, -1), (1, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < w, ny >= 0 else { continue }
                    let l = lab[ny * w + nx]
                    guard l > 0 else { continue }
                    if m == 0 { m = find(l) } else {
                        let r = find(l)
                        if r != m { parent[Int(max(r, m))] = min(r, m); m = min(r, m) }
                    }
                }
                if m == 0 { m = Int32(parent.count); parent.append(m) }
                lab[i] = m
            }
        }
        var compact = [Int32](repeating: 0, count: parent.count)
        var n: Int32 = 0
        for i in 0..<lab.count where lab[i] > 0 {
            let r = find(lab[i])
            if compact[Int(r)] == 0 { n += 1; compact[Int(r)] = n }
            lab[i] = compact[Int(r)]
        }
        return (lab, Int(n))
    }

    /// Chebyshev dilation by `r` pixels (two separable passes).
    static func dilate(_ mask: [UInt8], _ w: Int, _ h: Int, _ r: Int) -> [UInt8] {
        guard r > 0 else { return mask }
        var tmp = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w where mask[y * w + x] != 0 {
                for xx in max(0, x - r)...min(w - 1, x + r) { tmp[y * w + xx] = 1 }
            }
        }
        var out = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            for y in 0..<h where tmp[y * w + x] != 0 {
                for yy in max(0, y - r)...min(h - 1, y + r) { out[yy * w + x] = 1 }
            }
        }
        return out
    }

    func has(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < width && y < height && mask[y * width + x] != 0 }
}
