// One Vision text request, timed, with a deadline. See README.md.
// build: swiftc -O probe.swift -o probe
// run:   ./probe <png> <accurate|fast|accurate-cpu|fast-cpu> [revision] [ja] [wait-seconds]
import Vision
import CoreML
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let img = NSImage(contentsOf: URL(fileURLWithPath: args[1]))?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: probe <png> <accurate|fast|accurate-cpu|fast-cpu> [revision] [ja] [wait-seconds]"); exit(2)
}
let mode = args[2]
let req = VNRecognizeTextRequest()
req.recognitionLevel = mode.hasPrefix("fast") ? .fast : .accurate
if mode.hasSuffix("cpu") {
    // Every compute stage on the CPU: separates the Neural Engine compiler from the model itself.
    for (stage, list) in (try! req.supportedComputeStageDevices) {
        if let cpu = list.first(where: { if case .cpu = $0 { return true } else { return false } }) { req.setComputeDevice(cpu, for: stage) }
    }
}
if let n = args.dropFirst(3).compactMap({ Int($0) }).first(where: { $0 < 10 }) { req.revision = n }
if args.contains("ja") { req.recognitionLanguages = ["ja-JP"] }
let wait = args.dropFirst(3).compactMap({ Int($0) }).first(where: { $0 >= 10 }) ?? 40
print("revisions", VNRecognizeTextRequest.supportedRevisions.map { $0 }, "using", req.revision,
      "languages", (try? req.supportedRecognitionLanguages()) ?? [])

let t0 = Date()
let done = DispatchSemaphore(value: 0)
Thread.detachNewThread {
    try! VNImageRequestHandler(cgImage: img).perform([req])
    print(mode, "lines=\(req.results?.count ?? -1)", String(format: "%.2fs", Date().timeIntervalSince(t0)))
    done.signal()
}
if done.wait(timeout: .now() + .seconds(wait)) == .timedOut {
    print(mode, "no answer in \(wait) s")   // a stalled newest model: ANECompilerService spins while this waits
    exit(1)
}
