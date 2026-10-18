import CoreGraphics
import Foundation
import ImageIO
import MwoyeoCore

// usage: regionfeed <KEEP_WORK> > feed.jsonl
// The inputs CodeRegion takes, for every block of every read of the labelled pictures (papers and code cases): the text, the block rect,
// the line rects (the words of the OCR read grouped by baseline), the background colour the app computes for the block
// (RegionPipeline.appearance(of:in:) per line, the per-channel median over the lines) and the frame's dominant background.
// {"id","pic","read","idx","r":[x,y,w,h],"t","lines":[{"r":[x,y,w,h],"t"}...],"bg":[r,g,b],"frame":[r,g,b]}; ids as label.py / code_labels.py write them.

func rgba(_ cg: CGImage, crop: PixelRect) -> RGBAImage? {
    let r = crop.clamped(width: cg.width, height: cg.height)
    guard !r.isEmpty, let source = (r == PixelRect(x: 0, y: 0, width: cg.width, height: cg.height)) ? cg : cg.cropping(to: r.cgRect) else { return nil }
    var px = [UInt8](repeating: 0, count: r.width * r.height * 4)
    let ok = px.withUnsafeMutableBytes { buf -> Bool in
        guard let ctx = CGContext(data: buf.baseAddress, width: r.width, height: r.height, bitsPerComponent: 8, bytesPerRow: r.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        return true
    }
    return ok ? RGBAImage(width: r.width, height: r.height, pixels: px) : nil
}

/// RegionPipeline.appearance(of:in:), unchanged.
func appearance(of lineRect: CGRect, in image: CGImage) -> TextAppearance {
    let ring = max(2, Int(lineRect.height * 0.15))
    let crop = PixelRect(lineRect.insetBy(dx: -CGFloat(ring), dy: -CGFloat(ring))).clamped(width: image.width, height: image.height)
    let text = PixelRect(lineRect).clamped(width: image.width, height: image.height)
    guard let patch = rgba(image, crop: crop) else {
        return TextAppearance(textColor: RGBA(255, 255, 255), backgroundColor: RGBA(0, 0, 0), backgroundNoise: 0, coverage: 0.2)
    }
    let local = PixelRect(x: text.x - crop.x, y: text.y - crop.y, width: text.width, height: text.height)
    return TextEraser.mask(for: patch, textRect: local, dilation: 0).appearance
}

func frameBackground(_ img: RGBAImage) -> RGBA {
    var count: [UInt32: Int] = [:]
    var y = 0
    while y < img.height {
        var x = 0
        while x < img.width {
            let c = img.color(x: x, y: y)
            count[(UInt32(c.r) << 16) | (UInt32(c.g) << 8) | UInt32(c.b), default: 0] += 1
            x += 3
        }
        y += 3
    }
    let k = count.max { $0.value < $1.value }?.key ?? 0
    return RGBA(UInt8(k >> 16), UInt8((k >> 8) & 255), UInt8(k & 255))
}

func medianByte(_ v: [UInt8]) -> Int { v.isEmpty ? 0 : Int(v.sorted()[v.count / 2]) }

func lines(of words: [[Any]]) -> [(rect: CGRect, start: Int, end: Int)] {
    guard !words.isEmpty else { return [] }
    func num(_ a: Any) -> Double { (a as? NSNumber)?.doubleValue ?? 0 }
    let hs = words.map { num($0[5]) }.sorted()
    let h = hs[hs.count / 2]
    var out: [(cy: Double, rect: CGRect, start: Int, end: Int)] = []
    for w in words.sorted(by: { (num($0[3]) + num($0[5]) / 2, num($0[2])) < (num($1[3]) + num($1[5]) / 2, num($1[2])) }) {
        let r = CGRect(x: num(w[2]), y: num(w[3]), width: num(w[4]), height: num(w[5]))
        let cy = num(w[3]) + num(w[5]) / 2
        let s = Int(num(w[0])), e = Int(num(w[1]))
        if let last = out.last, abs(cy - last.cy) <= 0.6 * h {
            out[out.count - 1].rect = last.rect.union(r); out[out.count - 1].start = min(last.start, s); out[out.count - 1].end = max(last.end, e)
        } else { out.append((cy, r, s, e)) }
    }
    return out.map { ($0.rect, $0.start, $0.end) }
}

func json(_ s: String) -> String {
    var o = "\""
    for u in s.unicodeScalars {
        switch u {
        case "\"": o += "\\\""
        case "\\": o += "\\\\"
        default: o += u.value < 32 ? String(format: "\\u%04x", u.value) : String(u)
        }
    }
    return o + "\""
}

func r1(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

func lineJSON(_ l: (rect: CGRect, start: Int, end: Int), _ chars: [Character]) -> String {
    let a = min(l.start, chars.count), b = min(max(l.end, l.start), chars.count)
    return "{\"r\":[\(r1(l.rect.minX)),\(r1(l.rect.minY)),\(r1(l.rect.width)),\(r1(l.rect.height))],\"t\":\(json(String(chars[a..<b])))}"
}

func emit(ocr: [String: Any], png: String, idPrefix: (String) -> String, pic: String) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: png) as CFURL, nil), let cg = CGImageSourceCreateImageAtIndex(src, 0, nil),
          let full = rgba(cg, crop: PixelRect(x: 0, y: 0, width: cg.width, height: cg.height)) else {
        FileHandle.standardError.write(Data("cannot read \(png)\n".utf8)); exit(1)
    }
    let frame = frameBackground(full)
    for read in ["vn", "doc"] {
        for (idx, b) in ((ocr[read] as? [[String: Any]]) ?? []).enumerated() {
            guard let r = b["r"] as? [NSNumber], let t = b["t"] as? String, let w = b["w"] as? [[Any]] else { continue }
            let ls = lines(of: w)
            let bgs = ls.map { appearance(of: $0.rect, in: cg).backgroundColor }
            let chars = Array(t)
            let bg = (medianByte(bgs.map(\.r)), medianByte(bgs.map(\.g)), medianByte(bgs.map(\.b)))
            let id = idPrefix(read) + "-\(idx)"
            print("{\"id\":\(json(id)),\"pic\":\(json(pic)),\"read\":\"\(read)\",\"idx\":\(idx),\"r\":[\(r.map { r1(CGFloat($0.doubleValue)) }.joined(separator: ","))],"
                  + "\"t\":\(json(t)),\"lines\":[\(ls.map { lineJSON($0, chars) }.joined(separator: ","))],"
                  + "\"bg\":[\(bg.0),\(bg.1),\(bg.2)],\"frame\":[\(frame.r),\(frame.g),\(frame.b)]}")
        }
    }
}

let work = CommandLine.arguments[1]
let fm = FileManager.default
for pid in ["1706.03762", "2401.10066", "2310.06142"] {
    guard let text = try? String(contentsOfFile: "\(work)/\(pid)/ocr.jsonl", encoding: .utf8) else { continue }
    for (page0, line) in text.split(separator: "\n").enumerated() {
        guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
        let page = page0 + 1
        emit(ocr: o, png: "\(work)/\(pid)/pages/p\(page).png", idPrefix: { "\(pid)-p\(page)-\($0)" }, pic: "\(pid)-p\(page)")
    }
}
for f in ((try? fm.contentsOfDirectory(atPath: "\(work)/code")) ?? []).sorted() where f.hasSuffix(".ocr.jsonl") {
    let name = String(f.dropLast(".ocr.jsonl".count))
    guard let data = fm.contents(atPath: "\(work)/code/\(f)"), let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
    emit(ocr: o, png: "\(work)/code/\(name).png", idPrefix: { "\(name)-\($0)" }, pic: name)
}
