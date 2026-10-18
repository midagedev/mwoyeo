// Layer probe for the lens ring/glow: a standalone copy of FrameChromeView's ring and glow layers, one variable per
// variant, captured with screencapture -R over a dark and a light backdrop (or dragged, with WindowServer CPU).
// Build: swiftc -O -o /tmp/lens-glow/exp tools/lens-look/layer-probe.swift
// Run:   exp <outdir> name[:raster=0][:blur=0][:ci=0][:go=0.95][:ro=1][:maskgrad=1][:drag=240][:breathe=1][:still=1] ...
// Then:  python3 -I tools/lens-look/profile.py compare <outdir>/name-dark.png <outdir>/name-light.png

import AppKit
import QuartzCore

// One variant per run of the lens's glow/ring layers, captured over a dark and a light backdrop.
struct V { var name: String; var raster = true; var blur = true; var ciFlag = true; var glowOpacity: Float = 0.35
    var ringOpacity: Float = 0.8; var maskOnGradient = false; var ring = true; var drawBand = true; var blurRadius = 6.0
    var glowWidth: CGFloat = 4; var wrap = false; var drag = 0; var breathe = false; var still = false }

let out = CommandLine.arguments[1]
func parse(_ s: String) -> V {
    var v = V(name: s.components(separatedBy: ":")[0])
    for kv in s.components(separatedBy: ":").dropFirst() {
        let p = kv.components(separatedBy: "="); let k = p[0], val = p.count > 1 ? p[1] : "1"
        switch k {
        case "raster": v.raster = val == "1"
        case "blur": v.blur = val == "1"
        case "ci": v.ciFlag = val == "1"
        case "go": v.glowOpacity = Float(val)!
        case "ro": v.ringOpacity = Float(val)!
        case "maskgrad": v.maskOnGradient = val == "1"
        case "ring": v.ring = val == "1"
        case "band": v.drawBand = val == "1"
        case "radius": v.blurRadius = Double(val)!
        case "gw": v.glowWidth = CGFloat(Double(val)!)
        case "wrap": v.wrap = val == "1"
        case "drag": v.drag = Int(val)!
        case "breathe": v.breathe = val == "1"
        case "still": v.still = val == "1"
        default: fatalError("unknown \(k)")
        }
    }
    return v
}

final class Chrome: NSView {
    let v: V
    let ring = CALayer(), ringMask = CAShapeLayer(), ringGradient = CAGradientLayer()
    let glow = CALayer(), glowMask = CAShapeLayer(), glowGradient = CAGradientLayer()
    let holder = CALayer()
    init(_ v: V) {
        self.v = v
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = v.ciFlag
        let colors = [NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1), NSColor(srgbRed: 1, green: 0.22, blue: 0.37, alpha: 1),
                      NSColor(srgbRed: 0.75, green: 0.35, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.37, green: 0.36, blue: 0.9, alpha: 1),
                      NSColor(srgbRed: 0.39, green: 0.82, blue: 1, alpha: 1), NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)].map(\.cgColor)
        let parent: CALayer = v.wrap ? holder : layer!
        if v.wrap { layer!.addSublayer(holder) }
        for (container, mask, gradient) in [(glow, glowMask, glowGradient), (ring, ringMask, ringGradient)] {
            if container === ring && !v.ring { continue }
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5); gradient.endPoint = CGPoint(x: 0.5, y: 0)
            gradient.colors = colors
            mask.fillColor = nil; mask.strokeColor = NSColor.black.cgColor
            if v.maskOnGradient { gradient.mask = mask } else { container.mask = mask }
            container.shouldRasterize = v.raster
            container.addSublayer(gradient)
            parent.addSublayer(container)
        }
        glowMask.lineWidth = v.glowWidth
        ringMask.lineWidth = 1.5
        if v.blur { glow.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: v.blurRadius])!] }
        glow.opacity = v.glowOpacity
        ring.opacity = v.ringOpacity
    }
    required init?(coder: NSCoder) { fatalError() }
    var regionRect: NSRect { bounds.insetBy(dx: 18, dy: 18) }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        let outline = regionRect.insetBy(dx: -1, dy: -1)
        let path = CGPath(roundedRect: outline, cornerWidth: 12, cornerHeight: 12, transform: nil)
        let diagonal = hypot(bounds.width, bounds.height)
        holder.frame = bounds
        for (container, mask, gradient) in [(glow, glowMask, glowGradient), (ring, ringMask, ringGradient)] {
            container.frame = bounds
            mask.frame = v.maskOnGradient ? gradient.bounds : bounds
            mask.path = path
            gradient.bounds = CGRect(x: 0, y: 0, width: diagonal, height: diagonal)
            gradient.position = CGPoint(x: regionRect.midX, y: regionRect.midY)
            if v.maskOnGradient {
                mask.frame = CGRect(x: -gradient.frame.minX, y: -gradient.frame.minY, width: bounds.width, height: bounds.height)
            }
            container.rasterizationScale = window?.backingScaleFactor ?? 2
        }
        CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard v.drawBand else { return }
        let r = regionRect
        let p = NSBezierPath(roundedRect: r.insetBy(dx: -5, dy: -5), xRadius: 16, yRadius: 16)
        p.append(NSBezierPath(roundedRect: r.insetBy(dx: 5, dy: 5), xRadius: 8, yRadius: 8).reversed)
        NSColor.black.withAlphaComponent(0.004).setFill(); p.fill()
    }
}

@MainActor func run(_ v: V) async {
    let screen = NSScreen.main!.frame
    let region = NSRect(x: 200, y: screen.height - 520, width: 360, height: 200)
    if v.drag > 0 { await drag(v); return }
    for dark in [true, false] {
        let page = NSWindow(contentRect: region.insetBy(dx: -40, dy: -70).offsetBy(dx: 0, dy: -10), styleMask: [.borderless], backing: .buffered, defer: false)
        page.backgroundColor = NSColor(white: dark ? 0.12 : 0.96, alpha: 1)
        page.orderFrontRegardless()
        let lens = NSPanel(contentRect: region.insetBy(dx: -18, dy: -18), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        lens.isOpaque = false; lens.backgroundColor = .clear; lens.hasShadow = false
        lens.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        lens.contentView = Chrome(v)
        lens.orderFrontRegardless()
        if v.name.hasPrefix("probe") { let c = lens.contentView as! Chrome; print("filters", c.glow.filters as Any, "ci", c.layerUsesCoreImageFilters) }
        try? await Task.sleep(for: .seconds(0.6))
        let r = page.frame
        let path = "\(out)/\(v.name)-\(dark ? "dark" : "light").png"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-R", "\(Int(r.minX)),\(Int(screen.height - r.maxY)),\(Int(r.width)),\(Int(r.height))", path]
        try! p.run(); p.waitUntilExit()
        lens.orderOut(nil); page.orderOut(nil)
    }
}

func cpuTime(_ pid: Int32) -> Double {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/ps"); p.arguments = ["-o", "time=", "-p", "\(pid)"]
    let pipe = Pipe(); p.standardOutput = pipe; try! p.run(); p.waitUntilExit()
    let t = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.trimmingCharacters(in: .whitespacesAndNewlines)
    // [[hh:]mm:]ss.cc
    return t.split(separator: ":").reduce(0.0) { $0 * 60 + Double($1)! }
}
let ws: Int32 = {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-x", "WindowServer"]
    let pipe = Pipe(); p.standardOutput = pipe; try! p.run(); p.waitUntilExit()
    return Int32(String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)!.split(separator: "\n")[0])!
}()

@MainActor func drag(_ v: V) async {
    let screen = NSScreen.main!.frame
    let region = NSRect(x: 200, y: screen.height - 520, width: 360, height: 200)
    let page = NSWindow(contentRect: region.insetBy(dx: -40, dy: -70).offsetBy(dx: 0, dy: -10), styleMask: [.borderless], backing: .buffered, defer: false)
    page.backgroundColor = NSColor(white: 0.96, alpha: 1)
    page.orderFrontRegardless()
    let lens = NSPanel(contentRect: region.insetBy(dx: -18, dy: -18), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    lens.isOpaque = false; lens.backgroundColor = .clear; lens.hasShadow = false
    lens.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
    let c = Chrome(v)
    lens.contentView = c
    lens.orderFrontRegardless()
    if v.breathe {
        let b = CABasicAnimation(keyPath: "opacity"); b.fromValue = v.glowOpacity * 0.45; b.toValue = v.glowOpacity
        b.duration = 0.9; b.autoreverses = true; b.repeatCount = .infinity
        b.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        c.glow.add(b, forKey: "breathe")
    }
    try? await Task.sleep(for: .seconds(0.5))
    let me = ProcessInfo.processInfo.processIdentifier
    let w0 = cpuTime(ws), m0 = cpuTime(me), t0 = Date()
    let start = lens.frame
    for i in 0..<v.drag {
        let dx = v.still ? 0 : CGFloat(i % 120) * 3
        lens.setFrame(start.offsetBy(dx: dx, dy: 0), display: true)
        try? await Task.sleep(for: .milliseconds(16))
    }
    let wall = Date().timeIntervalSince(t0)
    let w1 = cpuTime(ws), m1 = cpuTime(me)
    print(String(format: "%@ frames %d wall %.2fs WindowServer %.1f%% harness %.1f%%", v.name, v.drag, wall, (w1 - w0) / wall * 100, (m1 - m0) / wall * 100))
    lens.orderOut(nil); page.orderOut(nil)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    for s in CommandLine.arguments.dropFirst(2) { await run(parse(s)) }
    exit(0)
}
app.run()
