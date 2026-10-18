// Swift Vision requests and VNRecognizeTextRequest in one process, cold vs warm (vision-revive, 2026-10-18).
//   build: swiftc -O mix.swift -o mix
//   mix warm  <dir>                     one VN rev3 read of a drawn 240-char line, then one complete RecognizeDocumentsRequest and
//                                       one RecognizeTextRequest on chat.png, each timed to completion
//   mix mixed <docs|text> <img> [secs]  start the Swift request, 2 s later a VN rev3 read of <img>; print both ends (deadline secs, default 120)
//   mix vn    <img> [secs]              only the VN rev3 read (the cross-process control)
//   mix swift <docs|text> <img>...      Swift requests only, serially, each timed
//   mix overlap <docs|text> <img>      30 Swift requests in a loop while 10 VN reads run concurrently
//   mix wide  <docs|text> <img>         Swift request on a drawn 240-char line first, then on <img>
// Env WARM=1 before `mixed` runs the `warm` steps first in the same process.
import AppKit
import Vision

setvbuf(stdout, nil, _IONBF, 0)
let a = CommandLine.arguments
let t0 = Date()
func ts() -> String { String(format: "%.2fs", Date().timeIntervalSince(t0)) }
func load(_ p: String) -> CGImage {
    guard let i = NSImage(contentsOf: URL(fileURLWithPath: p))?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("bad image", p); exit(2) }
    return i
}
func line240() -> CGImage {
    let s = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 6).prefix(240)
    let font = NSFont.systemFont(ofSize: 20)
    let str = NSAttributedString(string: String(s), attributes: [.font: font, .foregroundColor: NSColor.black])
    let size = str.size()
    let w = Int(size.width) + 40, h = Int(size.height) + 40
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    str.draw(at: NSPoint(x: 20, y: 20))
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()!
}
func vn(_ img: CGImage, _ tag: String) {
    let s = Date()
    let r = VNRecognizeTextRequest(); r.recognitionLevel = .accurate
    try! VNImageRequestHandler(cgImage: img).perform([r])
    print("VN rev3 \(tag) lines=\(r.results?.count ?? -1) \(String(format: "%.2fs", Date().timeIntervalSince(s))) at \(ts())")
}
func swiftReq(_ kind: String, _ img: CGImage, _ tag: String) async {
    let s = Date()
    var n = -1
    if kind == "docs" { n = (try? await RecognizeDocumentsRequest().perform(on: img))?.count ?? -1 }
    else {
        var r = RecognizeTextRequest(); r.recognitionLevel = .accurate; r.recognitionLanguages = [Locale.Language(identifier: "ja-JP"), Locale.Language(identifier: "ko-KR"), Locale.Language(identifier: "en-US")]
        n = (try? await r.perform(on: img))?.count ?? -1
    }
    print("swift \(kind) \(tag) n=\(n) \(String(format: "%.2fs", Date().timeIntervalSince(s))) at \(ts())")
}
func deadline(_ secs: Double) {
    DispatchQueue.global().asyncAfter(deadline: .now() + secs) { print("DEADLINE \(secs)s hit at \(ts())"); exit(1) }
}
func run(_ body: @escaping () async -> Void) -> Never {
    Task.detached { await body(); exit(0) }
    dispatchMain()
}

guard a.count >= 3 else { print("usage: see header"); exit(2) }
switch a[1] {
case "warm":
    let dir = a[2]
    run {
        vn(line240(), "line240")
        await swiftReq("docs", load(dir + "/chat.png"), "chat")
        await swiftReq("text", load(dir + "/chat.png"), "chat")
    }
case "mixed":
    let kind = a[2], path = a[3]; let secs = a.count > 4 ? Double(a[4])! : 120
    deadline(secs)
    let img = load(path)
    if ProcessInfo.processInfo.environment["WARM"] == "1" {
        let d = (path as NSString).deletingLastPathComponent
        Task.detached {
            vn(line240(), "warm-line240")
            await swiftReq("docs", load(d + "/chat.png"), "warm-chat")
            await swiftReq("text", load(d + "/chat.png"), "warm-chat")
            print("warm done at \(ts())")
            Task.detached { await swiftReq(kind, img, "PENDING") }
            Thread.sleep(forTimeInterval: 2)
            vn(img, "after-2s")
            exit(0)
        }
        dispatchMain()
    }
    Task.detached { await swiftReq(kind, img, "PENDING") }
    Thread.sleep(forTimeInterval: 2)
    print("vn start at \(ts())")
    vn(img, "after-2s")
    exit(0)
case "vn":
    if a.count > 3 { deadline(Double(a[3])!) }
    vn(load(a[2]), "alone"); exit(0)
case "swift":
    let kind = a[2], paths = Array(a.dropFirst(3))
    run { for p in paths { await swiftReq(kind, load(p), (p as NSString).lastPathComponent) } }
case "wide":
    let kind = a[2], p = a[3]
    run { await swiftReq(kind, line240(), "line240"); await swiftReq(kind, load(p), (p as NSString).lastPathComponent); await swiftReq(kind, load(p), "again") }
case "overlap":
    // Swift requests in a loop on one task while VN rev3 reads run on this thread: truly concurrent, warm.
    let kind = a[2], img = load(a[3])
    deadline(180)
    Task.detached { for i in 0..<30 { await swiftReq(kind, img, "loop\(i)") } }
    Thread.sleep(forTimeInterval: 0.3)
    for i in 0..<10 { vn(img, "overlap\(i)") }
    exit(0)
default: print("usage"); exit(2)
}
