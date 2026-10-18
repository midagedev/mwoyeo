import AppKit
import ImageIO
// usage: crops <page.png> <out dir> <name> [side]
// Cuts lens-sized crops out of a rendered page so that its edges cut text:
//   default: two crops (c1, c2), each as wide as the page and ~1000 px high, whose top and bottom edges run through the middle
//            of a line of text (rows of ink are found from the page itself), for the lines a lens edge cuts;
//   side:    one crop (s1) whose left and right edges cut the words of the column (40 px inside the text) and whose top and
//            bottom edges stay in the gaps between lines, for the words a lens edge cuts.
let a = CommandLine.arguments
guard a.count >= 4, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil) else { FileHandle.standardError.write("usage: crops page.png outdir name [side]\n".data(using: .utf8)!); exit(2) }
let side = a.count > 4 && a[4] == "side"
let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = image.width, h = image.height
let cs = CGColorSpaceCreateDeviceGray()
var gray = [UInt8](repeating: 255, count: w * h)
let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))   // row 0 is the top
let margin = w / 12
var ink = [Bool](repeating: false, count: h)
for y in 0..<h {
    var n = 0
    for x in margin..<(w - margin) where gray[y * w + x] < 150 { n += 1; if n >= 3 { break } }
    ink[y] = n >= 3
}
// Spans of rows with ink, joined across gaps under 4 px (the dots of an i, the space inside a letter row).
var spans: [(Int, Int)] = []
var y = 0
while y < h {
    guard ink[y] else { y += 1; continue }
    var end = y, gap = 0, k = y
    while k < h && gap < 4 { if ink[k] { end = k; gap = 0 } else { gap += 1 }; k += 1 }
    if end - y >= 10 { spans.append((y, end)) }
    y = end + 1
}
func mid(_ s: (Int, Int)) -> Int { (s.0 + s.1) / 2 }
func gapMid(after i: Int) -> Int { i + 1 < spans.count ? (spans[i].1 + spans[i + 1].0) / 2 : h }
let height = 1000
var out: [(String, CGRect)] = []
let fractions: [Double] = side ? [0.30] : [0.12, 0.55]
for (n, f) in fractions.enumerated() {
    guard let first = spans.firstIndex(where: { Double(mid($0)) >= f * Double(h) }) else { continue }
    var top: Int, bottom: Int
    if side {
        top = first > 0 ? gapMid(after: first - 1) : 0
        let target = top + height
        guard let last = spans.indices.filter({ $0 > first }).min(by: { abs(gapMid(after: $0) - target) < abs(gapMid(after: $1) - target) }) else { continue }
        bottom = gapMid(after: last)
    } else {
        top = mid(spans[first])
        let target = top + height
        guard let last = spans.indices.filter({ $0 > first }).min(by: { abs(mid(spans[$0]) - target) < abs(mid(spans[$1]) - target) }) else { continue }
        bottom = mid(spans[last])
    }
    guard bottom - top > 300 else { continue }
    var x0 = 0, x1 = w
    if side {
        var left = w, right = 0
        for yy in top..<min(bottom, h) { for x in 0..<w where gray[yy * w + x] < 150 { left = min(left, x); right = max(right, x) } }
        x0 = left + 40; x1 = right - 40
    }
    out.append(("\(a[3])-\(side ? "s" : "c")\(n + 1)", CGRect(x: x0, y: top, width: x1 - x0, height: bottom - top)))
}
for (name, r) in out {
    guard let cropped = image.cropping(to: r) else { continue }
    let url = URL(fileURLWithPath: "\(a[2])/\(name).png")
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cropped, nil)
    CGImageDestinationFinalize(dest)
    print("\(name) \(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))")
}
