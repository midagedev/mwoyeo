import Foundation
import Vision
import ImageIO

// usage: locate <image.png> <span> [<span> ...]   -> one JSON line per span: {"span", "found", "x", "y", "w", "h"} in pixels, origin top-left.
// The box of each span as Vision's text recognizer (accurate; ko, ja, en) reads it on the frame: the marks of the film (a thin underline under a bad
// span) are placed from these boxes, never by eye. A span that is not read comes back with found false (the edit then refuses to draw it).
let args = CommandLine.arguments
guard args.count >= 3, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("usage: locate <image> <span> ...\n".utf8)); exit(2)
}
let width = Double(image.width), height = Double(image.height)
// Vision reads a line in the language it ranks first: Korean first garbles a Japanese line and the other way round, so a span is looked for in a read made with
// its own script first (Hangul: ko, else ja), and in the other read only when it is not there.
func read(_ languages: [String]) throws -> [(String, VNRecognizedText)] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { obs in obs.topCandidates(1).first.map { ($0.string, $0) } }
}
let reads = [try read(["ko-KR", "ja-JP", "en-US"]), try read(["ja-JP", "ko-KR", "en-US"])]
func hangul(_ s: String) -> Bool { s.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) } }
func fold(_ s: String) -> String { s.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")").replacingOccurrences(of: " ", with: "") }
for span in args.dropFirst(2) {
    var out: [String: Any] = ["span": span, "found": false]
    for (string, top) in (hangul(span) ? reads : reads.reversed()).flatMap({ $0 }) {
        // compare folded (fullwidth brackets and spaces folded), mapping the position back into the original string
        let folded = fold(string), needle = fold(span)
        guard let r = folded.range(of: needle) else { continue }
        let startOffset = folded.distance(from: folded.startIndex, to: r.lowerBound), length = needle.count
        // walk the original string, skipping spaces, to the same offset
        var count = 0, lo: String.Index? = nil, hi: String.Index? = nil
        var idx = string.startIndex
        while idx < string.endIndex {
            let next = string.index(after: idx)
            if string[idx] != " " {
                if count == startOffset { lo = idx }
                if count == startOffset + length - 1 { hi = next; break }
                count += 1
            }
            idx = next
        }
        guard let a = lo, let b = hi, let box = try? top.boundingBox(for: a..<b) else { continue }
        let bb = box.boundingBox
        out = ["span": span, "found": true, "x": bb.minX * width, "y": (1 - bb.maxY) * height, "w": bb.width * width, "h": bb.height * height]
        break
    }
    let data = try JSONSerialization.data(withJSONObject: out, options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}
