// Reads pages with Vision the way Shared/VisionExec.swift does (VN accurate revision 3 lines; RecognizeDocumentsRequest paragraphs)
// and writes each answer as JSON: <out>/<vn|docs>-<page>.json. Words carry Character offsets into their line's text.
//   usage: read <out dir> <page.png>...         (Bash sandbox off: Vision needs the Neural Engine)
import CoreGraphics
import Foundation
import ImageIO
import Vision

struct Word: Codable { var x, y, w, h: Double; var s, e: Int }
struct Line: Codable { var x, y, w, h: Double; var text: String; var words: [Word] }
struct Page: Codable { var path: String; var page: String; var width: Int; var height: Int; var seconds: Double; var paragraphs: [[Line]] }

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: read <out dir> <page.png>..."); exit(2) }
let out = URL(fileURLWithPath: args[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func isCJK(_ c: Character) -> Bool {
    c.unicodeScalars.contains { s in
        (0x3040...0x30FF).contains(s.value) || (0x3400...0x9FFF).contains(s.value) || (0xF900...0xFAFF).contains(s.value) ||
            (0xFF00...0xFFEF).contains(s.value) || (0x3000...0x303F).contains(s.value)
    }
}

func wordRanges(_ s: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var i = s.startIndex
    while i < s.endIndex {
        guard !s[i].isWhitespace else { i = s.index(after: i); continue }
        let j = s[i...].firstIndex(where: \.isWhitespace) ?? s.endIndex
        if s[i..<j].contains(where: isCJK) {
            ranges += s[i..<j].indices.map { $0..<s.index(after: $0) }
        } else {
            ranges.append(i..<j)
        }
        i = j
    }
    return ranges
}

func pixelRect(_ n: CGRect, w: Double, h: Double) -> CGRect {
    CGRect(x: n.minX * w, y: (1 - n.maxY) * h, width: n.width * w, height: n.height * h)
}

func line(_ rect: CGRect, _ text: String, _ words: [(CGRect, Range<String.Index>)]) -> Line {
    Line(x: rect.minX, y: rect.minY, w: rect.width, h: rect.height, text: text, words: words.map { r, range in
        Word(x: r.minX, y: r.minY, w: r.width, h: r.height, s: text.distance(from: text.startIndex, to: range.lowerBound),
             e: text.distance(from: text.startIndex, to: range.upperBound))
    })
}

func vnLines(_ image: CGImage) throws -> [[Line]] {
    let w = Double(image.width), h = Double(image.height)
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.revision = 3
    req.usesLanguageCorrection = true
    req.customWords = []
    req.recognitionLanguages = ["en-US"]
    req.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
    try VNImageRequestHandler(cgImage: image).perform([req])
    let lines = (req.results ?? []).compactMap { obs -> Line? in
        guard let c = obs.topCandidates(1).first, c.confidence >= 0.3 else { return nil }
        let words = wordRanges(c.string).compactMap { r in
            (try? c.boundingBox(for: r)).flatMap { $0 }.map { (pixelRect($0.boundingBox, w: w, h: h), r) }
        }
        return line(pixelRect(obs.boundingBox, w: w, h: h), c.string, words)
    }
    return [lines]   // the grouping into paragraphs is the probe's (ParagraphGrouper), not stored
}

func documentLines(_ image: CGImage) async throws -> [[Line]] {
    let w = Double(image.width), h = Double(image.height)
    var req = RecognizeDocumentsRequest()
    req.textRecognitionOptions.customWords = []
    req.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "en")]
    req.regionOfInterest = NormalizedRect(normalizedRect: CGRect(x: 0, y: 0, width: 1, height: 1))
    var result: [[Line]] = []
    for doc in try await req.perform(on: image) {
        for paragraph in doc.document.paragraphs {
            let lines = paragraph.lines.compactMap { obs -> Line? in
                guard let c = obs.topCandidates(1).first, !c.string.isEmpty else { return nil }
                let words = wordRanges(c.string).compactMap { r in
                    c.boundingBox(for: r).map { (pixelRect($0.boundingBox.cgRect, w: w, h: h), r) }
                }
                return line(pixelRect(obs.boundingBox.cgRect, w: w, h: h), c.string, words)
            }
            if !lines.isEmpty { result.append(lines) }
        }
    }
    return result
}

func save(_ page: Page) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    try enc.encode(page).write(to: out.appendingPathComponent("\(page.path)-\(page.page).json"))
}

for path in args.dropFirst(2) {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        print("cannot read \(path)"); exit(1)
    }
    let name = url.deletingPathExtension().lastPathComponent
    var t = Date()
    let vn = try vnLines(image)
    try save(Page(path: "vn", page: name, width: image.width, height: image.height, seconds: Date().timeIntervalSince(t), paragraphs: vn))
    print("vn \(name) lines=\(vn[0].count) \(String(format: "%.2f", Date().timeIntervalSince(t))) s"); fflush(stdout)
    t = Date()
    let docs = try await documentLines(image)
    try save(Page(path: "docs", page: name, width: image.width, height: image.height, seconds: Date().timeIntervalSince(t), paragraphs: docs))
    print("docs \(name) paragraphs=\(docs.count) lines=\(docs.reduce(0) { $0 + $1.count }) \(String(format: "%.2f", Date().timeIntervalSince(t))) s"); fflush(stdout)
}
