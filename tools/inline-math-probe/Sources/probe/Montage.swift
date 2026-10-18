// A montage of crops: each span's neighbourhood at native scale with the word boxes' crop in red and the ink-grown box in green,
// and a two-line label (what failed, the numbers, the span text).
import CoreGraphics
import CoreText
import Foundation
import ImageIO

enum Montage {
    struct Tile {
        var row: Row
        var label: String
    }

    static func write(_ tiles: [Tile], to url: URL, title: String, width: Int = 1800) {
        guard !tiles.isEmpty else { print("montage \(url.lastPathComponent): no tiles"); return }
        struct Placed { var tile: Tile; var image: CGImage; var x: Int; var y: Int; var w: Int; var h: Int; var scale: Double; var origin: IntRect }
        var placed: [Placed] = []
        let gap = 10, labelH = 30, titleH = 26
        var x = gap, y = titleH + gap, shelf = 0
        for t in tiles {
            let r = t.row
            let m = max(14, Int(0.8 * r.lh))
            var region = r.base.union(r.crop).union(r.grown ?? r.crop)
            region = IntRect(x0: region.x0 - m, y0: region.y0 - m, x1: region.x1 + m, y1: region.y1 + m).clamped(r.image.width, r.image.height)
            guard let img = r.image.cropping(to: region.cg) else { continue }
            let scale = min(1.0, 600.0 / Double(region.width))
            let w = max(300, Int(Double(region.width) * scale)), h = Int(Double(region.height) * scale)
            if x + w + gap > width { x = gap; y += shelf + gap; shelf = 0 }
            placed.append(Placed(tile: t, image: img, x: x, y: y, w: w, h: h, scale: scale, origin: region))
            x += w + gap
            shelf = max(shelf, h + labelH)
        }
        let height = y + shelf + gap
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 0.94, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        func text(_ s: String, _ px: Int, _ py: Int, size: CGFloat = 11, maxWidth: Int) {
            let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
            let attr = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                                  NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.saveGState()
            ctx.clip(to: CGRect(x: px, y: height - py - 14, width: maxWidth, height: 16))
            ctx.textPosition = CGPoint(x: px, y: height - py - 11)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
        ctx.setFillColor(gray: 0, alpha: 1)
        text(title, gap, 6, size: 13, maxWidth: width - 2 * gap)
        for p in placed {
            let rect = CGRect(x: p.x, y: height - p.y - p.h, width: p.w, height: p.h)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: p.x, y: height - p.y - p.h - labelH, width: p.w, height: p.h + labelH))
            ctx.draw(p.image, in: CGRect(x: rect.minX, y: rect.minY, width: Double(p.image.width) * p.scale, height: Double(p.image.height) * p.scale))
            func box(_ r: IntRect, _ color: CGColor, _ dash: Bool) {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(1.2)
                ctx.setLineDash(phase: 0, lengths: dash ? [4, 3] : [])
                ctx.stroke(CGRect(x: rect.minX + Double(r.x0 - p.origin.x0) * p.scale, y: rect.minY + Double(p.origin.y1 - r.y1) * p.scale,
                                  width: Double(r.width) * p.scale, height: Double(r.height) * p.scale))
            }
            box(p.tile.row.base, CGColor(red: 0.9, green: 0.5, blue: 0.1, alpha: 1), true)    // orange dashed: the word boxes' union
            box(p.tile.row.crop, CGColor(red: 0.85, green: 0.05, blue: 0.05, alpha: 1), false) // red: the crop (trailing punctuation trimmed)
            if let g = p.tile.row.grown { box(g, CGColor(red: 0.05, green: 0.6, blue: 0.1, alpha: 1), false) } // green: ink-grown
            ctx.setFillColor(gray: 0, alpha: 1)
            let parts = p.tile.label.components(separatedBy: "\n")
            text(parts[0], p.x + 2, p.y + p.h + 1, maxWidth: p.w - 4)
            if parts.count > 1 { text(parts[1], p.x + 2, p.y + p.h + 15, maxWidth: p.w - 4) }
        }
        guard let image = ctx.makeImage(), let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        print("montage \(url.path): \(placed.count) tiles \(width)x\(height)")
    }
}
