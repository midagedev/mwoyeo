// first117: shows one picture in an ordinary titled window at a fixed place, so that a lens has real pixels to read.
// usage: pagewin <image> <x> <y> <w> <h>   (x, y: global points, top-left origin; w, h: the content size in points)
// Runs until it is sent TERM. Prints "window <number> pid <pid>" once it is up.
import AppKit

let a = CommandLine.arguments
guard a.count == 6, let img = NSImage(contentsOfFile: a[1]), let x = Double(a[2]), let y = Double(a[3]), let w = Double(a[4]), let h = Double(a[5]) else {
    FileHandle.standardError.write("usage: pagewin <image> <x> <y> <w> <h>\n".data(using: .utf8)!); exit(2)
}
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let screenH = NSScreen.screens[0].frame.height
let win = NSWindow(contentRect: NSRect(x: x, y: screenH - y - h, width: w, height: h), styleMask: [.titled], backing: .buffered, defer: false)
win.title = "first117 page"
let v = NSImageView(frame: NSRect(x: 0, y: 0, width: w, height: h))
v.image = img
v.imageScaling = .scaleAxesIndependently
win.contentView = v
win.isReleasedWhenClosed = false
win.makeKeyAndOrderFront(nil)
app.activate(ignoringOtherApps: true)
let f = win.frame
print("window \(win.windowNumber) pid \(getpid()) frame \(Int(f.minX)) \(Int(screenH - f.maxY)) \(Int(f.width)) \(Int(f.height))"); fflush(stdout)
signal(SIGTERM) { _ in exit(0) }
app.run()
