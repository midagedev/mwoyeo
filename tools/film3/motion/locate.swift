import Foundation
import Vision
import ImageIO

// usage: locate <image.png> <span>[::<part>] ...  -> one JSON line per argument: {"span", "part", "found", "x", "y", "w", "h", "line": {x, y, w, h}} in pixels,
// origin top-left. The box is Vision's box of <part> inside the first read of <span> (the whole span when no part is given); "line" is the box of the
// whole recognized line it sits on. The film's marks and callouts are placed from these boxes, never by eye; a span that is not read comes back with
// found false and prep.py stops. (film3/edit/locate.swift reads whole spans; this one adds the part, so "컨트롤이 표시::컨트롤" marks only the word.)
let args = CommandLine.arguments
guard args.count >= 3, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("usage: locate <image> <span>[::<part>] ...\n".utf8)); exit(2)
}
let width = Double(image.width), height = Double(image.height)
func read(_ languages: [String]) throws -> [(String, VNRecognizedText)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { obs in obs.topCandidates(1).first.map { ($0.string, $0) } }
}
let reads = [try read(["ko-KR", "en-US"]), try read(["en-US", "ko-KR"])]
func hangul(_ s: String) -> Bool { s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
func box(_ r: CGRect) -> [String: Double] { ["x": r.minX * width, "y": (1 - r.maxY) * height, "w": r.width * width, "h": r.height * height] }
// the range of characters [offset, offset+length) of `s` counted without spaces, mapped back to `s`
func range(in s: String, offset: Int, length: Int) -> Range<String.Index>? {
    var count = 0, lo: String.Index? = nil, idx = s.startIndex
    while idx < s.endIndex {
        let next = s.index(after: idx)
        if s[idx] != " " {
            if count == offset { lo = idx }
            if count == offset + length - 1, let a = lo { return a..<next }
            count += 1
        }
        idx = next
    }
    return nil
}
for arg in args.dropFirst(2) {
    let bits = arg.components(separatedBy: "::")
    let span = bits[0], part = bits.count > 1 ? bits[1] : bits[0]
    var out: [String: Any] = ["span": span, "part": part, "found": false]
    let folded = { (s: String) in s.replacingOccurrences(of: " ", with: "") }
    for (string, top) in (hangul(span) ? reads : reads.reversed()).flatMap({ $0 }) {
        guard let r = folded(string).range(of: folded(span)), let p = folded(span).range(of: folded(part)) else { continue }
        let spanStart = folded(string).distance(from: folded(string).startIndex, to: r.lowerBound)
        let partStart = folded(span).distance(from: folded(span).startIndex, to: p.lowerBound)
        guard let rr = range(in: string, offset: spanStart + partStart, length: folded(part).count),
              let b = try? top.boundingBox(for: rr), let whole = try? top.boundingBox(for: string.startIndex..<string.endIndex) else { continue }
        out = ["span": span, "part": part, "found": true, "line": box(whole.boundingBox)].merging(box(b.boundingBox)) { a, _ in a }
        break
    }
    let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
