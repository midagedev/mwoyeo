// Does replacing a binary at the same path break VNRecognizeTextRequest (e5rt error 13)? (vision-revive Q6, 2026-10-18)
//   build: sed "s/TAGVALUE/v1/" replace.swift > /tmp/r.swift && swiftc -O /tmp/r.swift -o <path>   (new TAG per rebuild: the binary differs, the path does not)
//   run:   <path> <img> [rounds] [gap-seconds]      or  <path> <img> storm [N]
// Each round: accurate rev3, rev2, fast reads, each with its time, or the thrown error. Reads run on a thread with a 150 s deadline.
import AppKit
import Vision
setvbuf(stdout, nil, _IONBF, 0)
let TAG = "TAGVALUE"   // build.sh-style: sed this per build so the binary differs while the path does not
let a = CommandLine.arguments
let img = NSImage(contentsOf: URL(fileURLWithPath: a[1]))!.cgImage(forProposedRect: nil, context: nil, hints: nil)!
if a.count > 2, a[2] == "storm" {
    // The app abandons a read after 8 s and starts the next one: N reads of one cold program in flight at once (arg 3 = N, default 12).
    let n = a.count > 3 ? Int(a[3])! : 12
    let g = DispatchGroup()
    DispatchQueue.global().asyncAfter(deadline: .now() + 900) { print("DEADLINE"); exit(1) }
    for i in 0..<n {
        g.enter()
        Thread.detachNewThread { read("storm\(i) rev3") { $0.recognitionLevel = .accurate }; g.leave() }
        Thread.sleep(forTimeInterval: 8)
    }
    g.wait()
    read("after rev3") { $0.recognitionLevel = .accurate }
    exit(0)
}
let rounds = a.count > 2 ? Int(a[2])! : 1, gap = a.count > 3 ? Double(a[3])! : 0
let t0 = Date()
func read(_ name: String, _ cfg: (VNRecognizeTextRequest) -> Void) {
    let s = Date(); let r = VNRecognizeTextRequest(); cfg(r)
    do { try VNImageRequestHandler(cgImage: img).perform([r]); print("\(TAG) \(name) lines=\(r.results?.count ?? -1) \(String(format: "%.2fs", Date().timeIntervalSince(s))) at \(String(format: "%.0fs", Date().timeIntervalSince(t0)))") }
    catch { print("\(TAG) \(name) ERROR \(error) \(String(format: "%.2fs", Date().timeIntervalSince(s))) at \(String(format: "%.0fs", Date().timeIntervalSince(t0)))") }
}
DispatchQueue.global().asyncAfter(deadline: .now() + 900) { print("DEADLINE"); exit(1) }
for i in 0..<rounds {
    read("r\(i) rev3") { $0.recognitionLevel = .accurate }
    read("r\(i) rev2") { $0.recognitionLevel = .accurate; $0.revision = 2 }
    read("r\(i) fast") { $0.recognitionLevel = .fast }
    if gap > 0 { Thread.sleep(forTimeInterval: gap) }
}
