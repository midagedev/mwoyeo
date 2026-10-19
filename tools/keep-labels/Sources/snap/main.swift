// usage: snap <html> <png> <width> <height>     the picture of an html case at 2x (the recipe the use-case pictures were drawn with)
//   height 0: the height of the page's content (document.documentElement.scrollHeight, at least 200 points); the H2 screens take this
import AppKit
import WebKit
let a = CommandLine.arguments
let html = URL(fileURLWithPath: a[1]), out = a[2]
let w = Double(a[3])!, h0 = Double(a[4])!
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: w, height: h0 > 0 ? h0 : 600))
let win = NSWindow(contentRect: wv.frame, styleMask: [.borderless], backing: .buffered, defer: false)
win.contentView = wv
final class D: NSObject, WKNavigationDelegate {
    func webView(_ v: WKWebView, didFinish n: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            if h0 > 0 { Self.shoot(v, height: h0); return }
            v.evaluateJavaScript("document.documentElement.scrollHeight") { r, _ in
                let h = max(200, ceil((r as? Double) ?? 200))
                v.frame = NSRect(x: 0, y: 0, width: w, height: h)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Self.shoot(v, height: h) }
            }
        }
    }
    static func shoot(_ v: WKWebView, height h: Double) {
        let c = WKSnapshotConfiguration()
        c.rect = NSRect(x: 0, y: 0, width: w, height: h)
        // the picture is 2x whatever the display's scale is (the existing pictures are 1720 px for a 860 pt case)
        c.snapshotWidth = NSNumber(value: w * 2 / Double(NSScreen.main?.backingScaleFactor ?? 1))
        v.takeSnapshot(with: c) { img, err in
            guard let img, let t = img.tiffRepresentation, let r = NSBitmapImageRep(data: t),
                  let p = r.representation(using: .png, properties: [:]) else { print("fail \(String(describing: err))"); exit(1) }
            try! p.write(to: URL(fileURLWithPath: out)); print("ok \(r.pixelsWide)x\(r.pixelsHigh)"); exit(0)
        }
    }
}
let d = D(); wv.navigationDelegate = d
wv.loadFileURL(html, allowingReadAccessTo: URL(fileURLWithPath: "/"))
app.run()
