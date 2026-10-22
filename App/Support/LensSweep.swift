#if !MAS
import CoreGraphics
import Foundation
import MwoyeoCore

/// `MWOYEO_LENS_SWEEP=1`: how a translation fits when the lens covers only part of its block, for the one number the lens's side edges need
/// (`LensWindow.minShare`, docs/design/recognition.md §16.2). After each block is drawn, it is drawn again in a window of 100 % to 10 % of the
/// width of its source text (starting at the text's left edge), and one `sweep` line says what the fitter did: the size it returned beside the
/// size at the full width and its floor, whether the translation was cut ("…"), and how many lines it came to. `tools/lens-window/sweep.py`
/// reads the lines of a paper-bench run (`tools/paper-bench/run.sh` with the variable set) and prints, for each share, how many blocks still read.
enum LensSweep {
    static let enabled = ProcessInfo.processInfo.environment["MWOYEO_LENS_SWEEP"] != nil
    static let shares: [CGFloat] = [1.0, 0.9, 0.8, 0.7, 0.6, 0.5, 0.45, 0.4, 0.35, 0.3, 0.25, 0.2, 0.15, 0.1]

    static func report(_ input: BlockRenderer.Input, source: String, core: CGRect) {
        var full: BlockRenderer.Rendered?
        for share in shares {
            var narrowed = input
            narrowed.window = core.minX...(core.minX + share * core.width)
            guard let r = BlockRenderer.render(narrowed) else { continue }
            if share == 1 { full = r }
            let line = "sweep share \(share) size \(TraceNumber.px(r.fontSize)) full \(TraceNumber.px(full?.fontSize ?? r.fontSize)) floor \(TraceNumber.px(r.floorSize)) "
                + "clipped \(r.clipped ? 1 : 0) ellipsis \(r.ellipsis ? 1 : 0) lines \(r.lines.count) wrapped \(input.originalLineCount) core \(TraceNumber.px(core.width))x\(TraceNumber.px(core.height)) "
                + "chars \(input.text.count) src '\(source.prefix(20))'"
            FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        }
        if let full { ink(full, source: source) }
    }

    /// Where the ink of each line of a translation stands in the line's box (`LensWindow.wholeInset`, round edges117b, film4 F16): for the line `i` of `r`, how deep into its
    /// box (a share of the box's height, from the top edge and from the bottom edge) the ink starts and how deep an edge has to stand to have cut 2 %, 5 % and 10 % of it.
    /// The ink is what differs from the line's background (the median colour of its rows), weighted by how much it differs. A line owns the rows up to the middle between its
    /// centre and its neighbour's (the boxes overlap by a few percent), and a quarter of its height beyond the first and the last. One `ink` line per line of text.
    static func ink(_ r: BlockRenderer.Rendered, source: String) {
        let w = r.image.width, h = r.image.height
        guard w > 0, h > 0, !r.lines.isEmpty,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.draw(r.image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return }
        let px = data.assumingMemoryBound(to: UInt8.self)   // row 0 is the top of the image
        for (i, box) in r.lines.enumerated() {
            let top = i == 0 ? box.minY - 0.25 * box.height : (r.lines[i - 1].midY + box.midY) / 2
            let bottom = i == r.lines.count - 1 ? box.maxY + 0.25 * box.height : (box.midY + r.lines[i + 1].midY) / 2
            let y0 = max(0, Int(top.rounded(.down))), y1 = min(h - 1, Int(bottom.rounded(.up))), x0 = max(0, Int(box.minX.rounded(.down))), x1 = min(w - 1, Int(box.maxX.rounded(.up)))
            guard y1 > y0, x1 > x0 else { continue }
            var channels = [[UInt8]](repeating: [], count: 3)
            for y in stride(from: y0, through: y1, by: 2) { for x in stride(from: x0, through: x1, by: 3) { for c in 0..<3 { channels[c].append(px[y * w * 4 + x * 4 + c]) } } }
            let background = channels.map { $0.sorted()[$0.count / 2] }
            var mass = [Double](repeating: 0, count: y1 - y0 + 1)
            for y in y0...y1 {
                var m = 0.0
                for x in x0...x1 {
                    var d = 0
                    for c in 0..<3 { d = max(d, abs(Int(px[y * w * 4 + x * 4 + c]) - Int(background[c]))) }
                    if d >= 48 { m += Double(d) / 255 }   // 48: below the noise of an erased patch
                }
                mass[y - y0] = m
            }
            let total = mass.reduce(0, +)
            guard total > 0 else { continue }
            func depth(from top: Bool, share: Double) -> Double {
                var cumulative = 0.0
                let rows = top ? Array(mass.enumerated()) : Array(mass.enumerated().reversed())
                for (k, m) in rows {
                    cumulative += m
                    if cumulative > share * total {
                        // The row k's own edge: the cut that takes `share` of the ink stands at the row's far edge from the lens (its top edge for the top).
                        let y = Double(y0 + k) + (top ? 0 : 1)
                        return (top ? y - box.minY : box.maxY - y) / box.height
                    }
                }
                return 1
            }
            let t = [0, 0.02, 0.05, 0.10].map { depth(from: true, share: $0) }, b = [0, 0.02, 0.05, 0.10].map { depth(from: false, share: $0) }
            func f(_ v: [Double]) -> String { v.map { String(format: "%.3f", $0) }.joined(separator: " ") }
            FileHandle.standardError.write(("ink line \(i) of \(r.lines.count) height \(TraceNumber.px(box.height)) size \(TraceNumber.px(r.fontSize)) top \(f(t)) bottom \(f(b)) src '\(source.prefix(20))'\n").data(using: .utf8)!)
        }
    }
}
#endif
