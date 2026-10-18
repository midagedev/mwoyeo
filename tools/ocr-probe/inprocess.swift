// Swift `RecognizeDocumentsRequest` and `VNRecognizeTextRequest` in ONE process: start the Swift request (its model still loading),
// and 2 s later run a `VNRecognizeTextRequest`; print when each ends.
// Measured on macOS 27 with the document model compiling: accurate revision 3 blocked for more than 60 s, revision 2 for
// more than 30 s, `.fast` answered in 0.12 s; the same request in another process at that moment answered in 0.3 s.
// The block was first read as "a pending Swift request blocks VN" (ocr-vn, 2026-10-17, which dropped every Swift request).
// vision-revive (2026-10-18, mix.swift) found it is a cold compile in the system's ANE service: warm, the Swift requests and
// VN revision 3 run side by side at 0.2-0.5 s. The app loads the Swift models itself at launch (`SwiftVisionGate`).
//   build: swiftc -O inprocess.swift -o inprocess
//   run:   ./inprocess chat.png rev3|rev2|fast [seconds]      (no [seconds]: waits for the answer, however long)
// With [seconds] it prints "blocked" and exits 1 then. Exiting abandons the pending Swift request, and a client that goes
// away restarts the system's model compile: run it on a machine where that does not matter.
import AppKit
import Vision

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 3, let picture = NSImage(contentsOf: URL(fileURLWithPath: args[1]))?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: inprocess <image> rev3|rev2|fast [seconds]")
    exit(2)
}
let mode = args[2]
let t0 = Date()
func ts() -> String { String(format: "%.2fs", Date().timeIntervalSince(t0)) }

Task.detached {
    let request = RecognizeDocumentsRequest()
    let r = try? await request.perform(on: picture)
    print("swift documents done", r?.count ?? -1, ts())
}
if args.count >= 4, let limit = Double(args[3]) {
    DispatchQueue.global().asyncAfter(deadline: .now() + 2 + limit) {
        print("blocked: the \(mode) request did not answer in \(Int(limit)) s", ts())
        exit(1)
    }
}
Thread.sleep(forTimeInterval: 2)

let vn = VNRecognizeTextRequest()
vn.recognitionLevel = mode == "fast" ? .fast : .accurate
if mode == "rev2" { vn.revision = 2 }
print(mode, "start", ts())
try! VNImageRequestHandler(cgImage: picture).perform([vn])
print("\(mode) lines=\(vn.results?.count ?? -1)", ts())
exit(0)
