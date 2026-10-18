import CoreGraphics
import Foundation
import ImageIO
import MwoyeoCore
import Vision

// usage: ocrdump <out.jsonl> <language code, e.g. en> <png>...
// The two reads the app makes of a picture, with the parameters it reads with (Shared/VisionExec.swift is linked in, not copied):
//   vn   VNRecognizeTextRequest revision 3, accurate, grouped into blocks by ParagraphGrouper (TextRecognizer.blocks, line grouping)
//   doc  RecognizeDocumentsRequest paragraphs (document layout)
// One JSON line per picture: {"image","size":[w,h],"vn":[block...],"doc":[block...]}, a block {"r":[x,y,w,h],"n":lines,"t":text,
// "w":[[start,end,x,y,w,h,"word"]...]}: the text joined as TextRecognizer.makeBlock joins it, and every word with its box, its
// range in that text counted in Characters (what InlineMath.spans counts), in image pixels, top-left origin.

func makeBlock(_ lines: [OCRLine]) -> (rect: CGRect, text: String, words: [(Int, Int, CGRect, String)]) {
    let rect = lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) }
    var text = ""
    var words: [(Int, Int, CGRect, String)] = []
    for line in lines {
        if let last = text.last, let first = line.text.first, !(VisionExec.isCJK(last) || VisionExec.isCJK(first)) {
            text += last == "-" ? "" : " "
        }
        let base = text.count
        text += line.text
        for w in line.words {
            let s = line.text.distance(from: line.text.startIndex, to: w.range.lowerBound)
            let e = line.text.distance(from: line.text.startIndex, to: w.range.upperBound)
            words.append((base + s, base + e, w.rect, String(line.text[w.range])))
        }
    }
    return (rect, text, words)
}

func r1(_ v: CGFloat) -> String { String(format: "%.1f", Double(v)) }

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

func blockJSON(_ lines: [OCRLine]) -> String {
    let b = makeBlock(lines)
    let w = b.words.map { "[\($0.0),\($0.1),\(r1($0.2.minX)),\(r1($0.2.minY)),\(r1($0.2.width)),\(r1($0.2.height)),\(json($0.3))]" }.joined(separator: ",")
    return "{\"r\":[\(r1(b.rect.minX)),\(r1(b.rect.minY)),\(r1(b.rect.width)),\(r1(b.rect.height))],\"n\":\(lines.count),\"t\":\(json(b.text)),\"w\":[\(w)]}"
}

let args = CommandLine.arguments
guard args.count >= 4 else { FileHandle.standardError.write(Data("usage: ocrdump <out.jsonl> <lang> <png>...\n".utf8)); exit(2) }
let lang = args[2]
// the identifier Vision knows the language by ("en" -> "en-US"), found as the app finds it: by language code (and script)
let probe = VNRecognizeTextRequest()
probe.recognitionLevel = .accurate
probe.revision = 3
let wanted = Locale.Language(identifier: lang)
let visionID = ((try? probe.supportedRecognitionLanguages()) ?? []).first {
    let l = Locale.Language(identifier: $0)
    return l.languageCode == wanted.languageCode && (wanted.script == nil || l.script == wanted.script)
} ?? lang
var out = ""
for path in args[3...] {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
    }
    let vnLines = try await VisionExec.run(.rev3, image: image, roi: nil, languages: [visionID], documentLanguages: [], customWords: []).lines
    let vn = ParagraphGrouper.groups(vnLines, rect: \.rect, text: \.text).map(blockJSON)
    let paragraphs = try await VisionExec.run(.doc, image: image, roi: nil, languages: [], documentLanguages: [Locale.Language(identifier: lang)], customWords: []).paragraphs
    let doc = paragraphs.map(blockJSON)
    let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    out += "{\"image\":\(json(name)),\"size\":[\(image.width),\(image.height)],\"vn\":[\(vn.joined(separator: ","))],\"doc\":[\(doc.joined(separator: ","))]}\n"
    FileHandle.standardError.write(Data("ocrdump \(name): vn \(vn.count) blocks \(vnLines.count) lines, doc \(doc.count) paragraphs\n".utf8))
}
try out.write(toFile: args[1], atomically: true, encoding: .utf8)
