// first117: watches what a process puts on the screen, on the shared monotonic clock (CLOCK_UPTIME_RAW, ns). One JSON line per event.
//   watch <pid> [x y w h]     windows of <pid>: "win+" when one appears, "win-" when it goes, "win~" when its bounds or layer change
//   (a rect, global points, top-left origin) also: "frame" lines, a Retina capture of the rect every ~100 ms: the mean absolute difference
//   against the first frame (0..255) and the share of pixels that differ by more than 48, over the rect's interior (an inset of 14 pt, the
//   top 34 pt left out: the ring and the pill are the lens's, not the page's). Runs until TERM.
import AppKit
import CoreGraphics
import Foundation
import ImageIO

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
let a = CommandLine.arguments
guard a.count >= 2, let pid = Int32(a[1]) else { FileHandle.standardError.write("usage: watch <pid> [x y w h]\n".data(using: .utf8)!); exit(2) }
var rect: CGRect?
if a.count >= 6, let x = Double(a[2]), let y = Double(a[3]), let w = Double(a[4]), let h = Double(a[5]) { rect = CGRect(x: x, y: y, width: w, height: h) }
signal(SIGTERM) { _ in exit(0) }
var rebase = false   // SIGUSR1: the next frame becomes the one the others are compared with
signal(SIGUSR1) { _ in rebase = true }
setbuf(stdout, nil)

struct W: Equatable { var layer: Int; var b: CGRect; var onscreen: Bool }
var known: [Int: W] = [:]
func windows() -> [Int: W] {
    var out: [Int: W] = [:]
    guard let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return out }
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        guard let n = w[kCGWindowNumber as String] as? Int, let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if r.width < 20 || r.height < 20 { continue }
        out[n] = W(layer: w[kCGWindowLayer as String] as? Int ?? 0, b: r, onscreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
    return out
}
func js(_ r: CGRect) -> String { "[\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))]" }

var base: [UInt8]?
var lastFrame: UInt64 = 0
func grab(_ r: CGRect) -> CGImage? {
    // the system's own screencapture: a tool of ours that used ScreenCaptureKit made macOS ask, once per process, whether "bash" may bypass the window picker
    let path = "/tmp/r117/first117/data/tmp/watch-\(getpid()).png"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    p.arguments = ["-x", "-t", "png", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", path]
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}
func frame(_ img: CGImage, _ t: UInt64, _ r: CGRect) {
    let w = img.width, h = img.height
    let space = CGColorSpaceCreateDeviceRGB()
    var px = [UInt8](repeating: 0, count: w * h * 4)
    guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let sx = Double(w) / r.width, inset = Int(14 * sx), top = Int(34 * sx)
    if base == nil || base!.count != px.count || rebase { base = px; rebase = false }
    var sum = 0.0, n = 0, big = 0
    var y = top
    while y < h - inset {
        var x = inset
        while x < w - inset {
            let i = (y * w + x) * 4
            let d = (abs(Int(px[i]) - Int(base![i])) + abs(Int(px[i + 1]) - Int(base![i + 1])) + abs(Int(px[i + 2]) - Int(base![i + 2]))) / 3
            sum += Double(d); n += 1; if d > 48 { big += 1 }
            x += 2
        }
        y += 2
    }
    print("{\"t\":\(t),\"ev\":\"frame\",\"cap_ms\":\((now() - t) / 1_000_000),\"mean\":\(String(format: "%.3f", n > 0 ? sum / Double(n) : 0)),\"big\":\(String(format: "%.4f", n > 0 ? Double(big) / Double(n) : 0))}")
}
if let r = rect {
    Task.detached {
        while true {
            let t = now()
            if let img = grab(r) { frame(img, t, r) }
            let spent = now() - t
            if spent < 100_000_000 { usleep(UInt32((100_000_000 - spent) / 1000)) }
        }
    }
}
while true {
    let t = now()
    let cur = windows()
    for (n, w) in cur where known[n] != w {
        print("{\"t\":\(t),\"ev\":\"\(known[n] == nil ? "win+" : "win~")\",\"win\":\(n),\"layer\":\(w.layer),\"bounds\":\(js(w.b)),\"onscreen\":\(w.onscreen)}")
    }
    for n in known.keys where cur[n] == nil { print("{\"t\":\(t),\"ev\":\"win-\",\"win\":\(n)}") }
    known = cur
    usleep(4_000)
}
