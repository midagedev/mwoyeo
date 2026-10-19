import CoreGraphics
import MwoyeoCore

/// The colour most of a captured frame has: the page, the window or the desktop behind the text. `CodeRegion` calls a block tinted
/// when its own background differs from this one, so a code box or a terminal view on a page is told from the page.
enum FrameBackground {
    /// Every third pixel of every third row, counted in 5-bit buckets of the three channels. The answer is the mean of the winning
    /// bucket, so a flat page gives its exact colour and a soft gradient the middle of its largest band. nil when the frame cannot be
    /// sampled; the caller then keeps nothing as code.
    static func dominant(of image: CGImage) -> RGBA? {
        let step = 3
        let w = max(1, image.width / step), h = max(1, image.height / step)
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? dominant(of: RGBAImage(width: w, height: h, pixels: pixels)) : nil
    }

    /// The same count over every pixel of `image` (the sampling is the caller's).
    static func dominant(of image: RGBAImage) -> RGBA {
        var count = [Int](repeating: 0, count: 1 << 15)
        var sum = [Int](repeating: 0, count: 3 << 15)
        image.pixels.withUnsafeBufferPointer { px in
            var i = 0
            while i + 3 < px.count {
                let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                let bucket = (r >> 3) << 10 | (g >> 3) << 5 | (b >> 3)
                count[bucket] += 1
                sum[bucket * 3] += r; sum[bucket * 3 + 1] += g; sum[bucket * 3 + 2] += b
                i += 4
            }
        }
        var best = 0
        for bucket in 1..<count.count where count[bucket] > count[best] { best = bucket }
        let n = max(1, count[best])
        func mean(_ channel: Int) -> UInt8 { UInt8((sum[best * 3 + channel] + n / 2) / n) }
        return RGBA(mean(0), mean(1), mean(2))
    }
}
