// film: stage windows. Each arg "url|x|y|w|h|title" (Quartz top-left points) opens a borderless-titled WKWebView window; "backdrop|r,g,b" first
// puts a plain full-screen window under them so nothing of the desktop shows. Runs until killed.
import AppKit
import WebKit
let app = NSApplication.shared
app.setActivationPolicy(.regular)
var keep: [NSWindow] = []
let screen = NSScreen.screens[0].frame
for arg in CommandLine.arguments.dropFirst() {
    let f = arg.split(separator: "|").map(String.init)
    if f[0] == "backdrop" {
        let c = f[1].split(separator: ",").compactMap { Double($0) }
        let w = NSWindow(contentRect: screen, styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
        w.orderFront(nil); keep.append(w); continue
    }
    let x = Double(f[1])!, y = Double(f[2])!, wd = Double(f[3])!, ht = Double(f[4])!
    let rect = NSRect(x: x, y: screen.height - y - ht, width: wd, height: ht)
    let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    w.title = f.count > 5 ? f[5] : ""
    w.titlebarAppearsTransparent = true
    let v = WKWebView(frame: NSRect(origin: .zero, size: rect.size))
    v.load(URLRequest(url: URL(string: f[0])!))
    w.contentView = v
    w.setFrame(w.frameRect(forContentRect: rect), display: true)
    w.orderFront(nil); keep.append(w)
}
app.activate(ignoringOtherApps: true)
app.run()
