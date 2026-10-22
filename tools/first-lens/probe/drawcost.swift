// first117: what one redraw of the picker costs when it is drawn the way PickerView.draw does it (CoreGraphics, the whole display):
// a 0.32 black fill of 3024 x 1964 px, a clear rounded rect punched with .copy, an accent stroke, a pill. 200 frames, median and p90, ms.
import AppKit
func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
let W = 3024, H = 1964
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W / 2, height: H / 2)
var ts: [Double] = []
for i in 0..<200 {
    let t = now()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    NSColor.black.withAlphaComponent(0.32).setFill()
    NSRect(x: 0, y: 0, width: W / 2, height: H / 2).fill()
    let r = NSRect(x: 100 + CGFloat(i % 50), y: 300, width: 337, height: 520)
    ctx.compositingOperation = .copy
    NSColor.clear.setFill()
    NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
    ctx.compositingOperation = .sourceOver
    let p = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: 10, yRadius: 10)
    p.lineWidth = 3; NSColor.controlAccentColor.setStroke(); p.stroke()
    NSColor(white: 0.12, alpha: 0.88).setFill()
    NSBezierPath(roundedRect: NSRect(x: 500, y: 800, width: 600, height: 36), xRadius: 18, yRadius: 18).fill()
    ts.append(Double(now() - t) / 1e6)
}
ts.sort()
print(String(format: "full-display CoreGraphics redraw: median %.1f ms, p90 %.1f ms, max %.1f ms", ts[100], ts[180], ts[199]))
