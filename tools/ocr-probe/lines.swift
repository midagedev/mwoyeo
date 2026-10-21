// Every observation a Vision text request returns for one picture, with the confidence the app judges it by. See README.md.
// build: swiftc -O lines.swift -o lines
// run:   ./lines <png> [--rev 2|3] [--fast] [--roi | --region x,y,w,h] [--lang en-US | --auto]
// `--region` is a region of interest in picture pixels, top-left origin.
// The request is the one `Shared/VisionExec.swift` makes (accurate revision 3, language correction on, English by default). A line under
// the confidence the app keeps (0.3) is marked `DROPPED`; `aspect` is the box's width over its height.
import Foundation
import ImageIO
import Vision

let args = CommandLine.arguments
func option(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
guard args.count >= 2, let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("usage: lines <png> [--rev 2|3] [--fast] [--roi | --region x,y,w,h] [--lang en-US | --auto]"); exit(2)
}
let request = VNRecognizeTextRequest()
let fast = args.contains("--fast")
request.recognitionLevel = fast ? .fast : .accurate
if !fast, let revision = option("--rev").flatMap({ Int($0) }) { request.revision = revision }
request.usesLanguageCorrection = !fast
if args.contains("--auto") { request.automaticallyDetectsLanguage = true } else { request.recognitionLanguages = [option("--lang") ?? "en-US"] }
if args.contains("--roi") { request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1) }
if let r = option("--region")?.split(separator: ",").compactMap({ Double($0) }), r.count == 4 {
    request.regionOfInterest = CGRect(x: r[0] / Double(image.width), y: 1 - (r[1] + r[3]) / Double(image.height),
                                      width: r[2] / Double(image.width), height: r[3] / Double(image.height))
}
let began = Date()
try VNImageRequestHandler(cgImage: image).perform([request])
let width = Double(image.width), height = Double(image.height)
let found = (request.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
print("\(args[1]) \(image.width)x\(image.height): \(found.count) observations, \(Int(Date().timeIntervalSince(began) * 1000)) ms")
for observation in found {
    let top = observation.topCandidates(1).first, box = observation.boundingBox
    let confidence = top.map { Double($0.confidence) } ?? -1
    print(String(format: "  y=%4d x=%4d w=%4d h=%3d aspect=%5.1f conf=%.2f%@ '%@'", Int((1 - box.maxY) * height), Int(box.minX * width),
                 Int(box.width * width), Int(box.height * height), (box.width * width) / (box.height * height), confidence,
                 confidence < 0.3 ? " DROPPED" : "", String((top?.string ?? "<none>").prefix(48))))
}
