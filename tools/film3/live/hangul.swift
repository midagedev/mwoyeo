// Counts the Hangul characters Vision reads in a PNG: the recorder's "the lens has translated" probe (a lens over English text shows none).
// usage: hangul <png>   prints the count
import Foundation
import Vision
import AppKit

guard CommandLine.arguments.count == 2, let image = NSImage(contentsOfFile: CommandLine.arguments[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: hangul <png>\n".data(using: .utf8)!)
    exit(2)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["ko-KR", "en-US"]
request.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
print(text.unicodeScalars.filter { $0.value >= 0xAC00 && $0.value <= 0xD7A3 }.count)
