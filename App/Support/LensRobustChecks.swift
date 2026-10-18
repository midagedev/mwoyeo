#if !MAS
import AppKit
import MwoyeoCore

/// A capture the checks can stop and fail on demand (`ScreenCapturing`): the harness has no Screen Recording grant, and a real stream
/// could not be made to fail at a chosen moment anyway.
///
/// Used from the main thread only (the session starts it from the main actor, the checks stop it there), so no lock.
final class FakeCapture: ScreenCapturing, @unchecked Sendable {
    var onFrame: (@Sendable (CapturedFrame) -> Void)?
    var onStop: (@Sendable (Error?) -> Void)?
    struct Refused: Error {}
    /// The display a started stream runs on, chosen from the lens it is given (the check's current layout).
    var displayFor: (CGRect) -> CGRect? = { _ in nil }
    /// The next this-many starts throw.
    var failNext = 0
    private(set) var attempts = 0
    private(set) var started: [CGRect] = []
    private(set) var running = false
    private var display: CGRect?

    var streamDisplay: CGRect? { running ? display : nil }

    func start(rect: CGRect, fps: Double) async throws {
        attempts += 1
        if failNext > 0 { failNext -= 1; running = false; throw Refused() }
        started.append(rect)
        display = displayFor(rect)
        running = true
    }

    func update(rect: CGRect, fps: Double) async throws {
        if running { return }
        try await start(rect: rect, fps: fps)
    }

    func stop() async { running = false }

    /// The stream ends with `error`, as ScreenCaptureKit's delegate reports it.
    func die(_ error: Error) {
        running = false
        onStop?(error)
    }
}

/// The checks of the lens's capture recovery, run by `--capture-ui … check-logic` (PASS/FAIL lines): a stopped stream starts again with
/// backoff, a wake or a change of displays is looked at once things settle, a lens whose display is gone moves to the main display, and
/// the menu bar badge is drawn. Time is the policy's, shrunk to milliseconds.
@MainActor
enum LensRobustChecks {
    static let fast = CaptureRecoveryPolicy(backoff: [0.03, 0.06, 0.12], settle: 0.05, healthy: 0.4)
    static let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    static let usable = CGRect(x: 0, y: 38, width: 1512, height: 944)
    static let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
    static let docked = DisplayLayout(frames: [laptop, external], primary: usable)
    static let undocked = DisplayLayout(frames: [laptop], primary: usable)

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool) {
            print("check-logic: \(ok ? "PASS" : "FAIL") capture recovery: \(what)")
            if !ok { failed += 1 }
        }
        func error(_ code: Int) -> NSError { NSError(domain: CaptureFailure.screenCaptureKitDomain, code: code) }
        func until(_ seconds: Double = 3, _ done: () -> Bool) async -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
            return done()
        }
        /// A lens at `rect` over a layout, its capture the fake; `start` has run once.
        func lens(at rect: CGRect, layout: DisplayLayout = docked, follows: Bool = false,
                  policy: CaptureRecoveryPolicy = fast) async -> (RegionSession, FakeCapture, Box) {
            var config = RegionConfig(name: "Safari", rect: rect)
            if follows { config.anchor = WindowAnchor(windowID: 1, appName: "Safari", title: "", offset: .zero) }
            let fake = FakeCapture()
            let box = Box(layout)
            fake.displayFor = { [box] r in box.layout.display(showing: r) }
            let s = RegionSession(config: config, settings: AppSettings(), translator: model.translator, inpainter: nil, capturer: fake, recovery: policy)
            s.layoutProvider = { [box] in box.layout }
            s.onConfigChange = { [box] c in box.moved.append(c.rect) }
            await s.startCapture()
            return (s, fake, box)
        }

        let on = CGRect(x: 200, y: 300, width: 300, height: 200)
        let far = CGRect(x: 2000, y: 300, width: 300, height: 200)

        // A stream that ends is started again; the lens is not "down" while that is under way.
        var (s, fake, _) = await lens(at: on, policy: CaptureRecoveryPolicy(backoff: [0.4], settle: 0.05, healthy: 0.4))
        check("a started lens runs", fake.running && fake.attempts == 1 && s.errorMessage == nil)
        fake.die(error(-3821))
        check("a stopped stream leaves the error to show, but the lens is not down while a restart is coming",
              await until { s.errorMessage != nil } && !s.needsAttention && !fake.running)
        check("a stopped stream (stopped by the system) is started again", await until { fake.running && fake.attempts == 2 })
        check("and the error is gone", await until { s.errorMessage == nil && !s.needsAttention } && s.recoveryStats.restarts == 1)

        // Restarts that fail go down the backoff, and the third one lands.
        (s, fake, _) = await lens(at: on)
        fake.failNext = 2
        fake.die(error(-3821))
        check("failed restarts are tried again, the third lands", await until { fake.running && fake.attempts == 4 && s.errorMessage == nil })
        check("three restarts, none given up", s.recoveryStats.restarts == 3 && s.recoveryStats.gaveUp == 0)

        // Restarts that never work end, and the lens says it is down; a wake brings it back.
        (s, fake, _) = await lens(at: on)
        fake.failNext = 100
        fake.die(error(-3821))
        check("the backoff ends: the lens is down for good", await until { s.needsAttention } && s.recoveryStats.gaveUp == 1)
        let tried = fake.attempts
        try? await Task.sleep(for: .milliseconds(300))
        check("and tries no more (initial start plus one restart per backoff step)", fake.attempts == tried && tried == 1 + fast.backoff.count)
        fake.failNext = 0
        s.displaysChanged(.wake)
        check("a wake starts it again", await until { fake.running && s.errorMessage == nil && !s.needsAttention })

        // The grant's and the person's own stops are left alone.
        for (name, code) in [("the grant", -3801), ("the person's stop", -3817)] {
            (s, fake, _) = await lens(at: on)
            fake.die(error(code))
            try? await Task.sleep(for: .milliseconds(300))
            check("\(name) is not undone, the lens says it is down", fake.attempts == 1 && !fake.running && s.needsAttention && s.recoveryStats.restarts == 0)
        }

        // A stream that ran healthy starts a new episode; one that flaps does not.
        (s, fake, _) = await lens(at: on)
        for _ in 0..<5 {
            let before = fake.attempts
            fake.die(error(-3821))
            _ = await until { fake.attempts == before + 1 && fake.running }
            try? await Task.sleep(for: .milliseconds(500))   // longer than the policy's `healthy`
        }
        check("a stream that ran healthy before each stop never runs out of backoff", s.recoveryStats.restarts == 5 && s.recoveryStats.gaveUp == 0)
        (s, fake, _) = await lens(at: on)
        for _ in 0..<(fast.backoff.count + 1) {
            let before = fake.attempts
            fake.die(error(-3821))
            _ = await until(1) { fake.attempts == before + 1 && fake.running || s.recoveryStats.gaveUp > 0 }
        }
        check("a stream that stops right after each restart gives up", s.recoveryStats.gaveUp == 1 && s.needsAttention)

        // Display events settle once; a stream on the same display is left alone.
        var box: Box
        (s, fake, box) = await lens(at: on)
        for _ in 0..<5 { s.displaysChanged(.screensChanged) }
        try? await Task.sleep(for: .milliseconds(300))
        check("a burst of display changes that leave the stream's display as it was does nothing", fake.attempts == 1)
        for _ in 0..<5 { s.displaysChanged(.screensChanged) }
        s.displaysChanged(.wake)
        _ = await until { fake.attempts >= 2 }
        try? await Task.sleep(for: .milliseconds(200))
        check("a wake in the burst restarts the capture, once", fake.attempts == 2 && s.recoveryStats.restarts == 1)
        box.layout = DisplayLayout(frames: [CGRect(x: 0, y: 0, width: 1280, height: 800), external], primary: CGRect(x: 0, y: 38, width: 1280, height: 762))
        s.displaysChanged(.screensChanged)
        check("another resolution of the lens's display restarts it on the new frame", await until { fake.attempts == 3 && fake.streamDisplay?.width == 1280 })

        // A lens whose display was unplugged moves to the main display (inside it), and its capture starts there.
        (s, fake, box) = await lens(at: far)
        check("a lens on the external display runs there", fake.streamDisplay == external)
        box.layout = undocked
        s.displaysChanged(.screensChanged)
        let rect = s.config.rect
        check("unplugged: the lens moves inside the main display's usable area", await until { s.config.rect != far } && usable.contains(s.config.rect))
        _ = rect
        check("and keeps its size, the move is saved and counted", s.config.rect.size == far.size && box.moved.last == s.config.rect && s.recoveryStats.moves == 1)
        check("its capture starts on the main display", await until { fake.streamDisplay == laptop && fake.attempts == 2 })

        // A lens that follows a window is placed by the window.
        (s, fake, box) = await lens(at: far, follows: true)
        box.layout = undocked
        s.displaysChanged(.screensChanged)
        _ = await until { fake.attempts == 2 }
        check("a lens that follows a window stays where it is and restarts", s.config.rect == far && s.recoveryStats.moves == 0 && fake.attempts == 2)

        // A session that was stopped does nothing more.
        (s, fake, _) = await lens(at: on)
        fake.die(error(-3821))
        await s.stop()
        try? await Task.sleep(for: .milliseconds(300))
        check("a stopped lens is not started again", fake.attempts == 1 && !fake.running)

        // The displays as the app reads them.
        let now = DisplayLayout.current
        check("the current layout has a display and a primary area inside the first", !now.frames.isEmpty && now.frames[0].contains(now.primary))

        // The menu bar badge: the same glyph, plus a solid dot at its top right.
        failed += badgeChecks()
        return failed
    }

    final class Box {
        var layout: DisplayLayout
        var moved: [CGRect] = []
        init(_ layout: DisplayLayout) { self.layout = layout }
    }

    /// Alpha of `image` rendered at `scale`× into rows of pixels (row 0 is the top).
    private static func alpha(of image: NSImage, scale: Int) -> (w: Int, h: Int, a: [UInt8])? {
        let w = Int(image.size.width) * scale, h = Int(image.size.height) * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.bitmapData else { return nil }
        var a = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { a[y * w + x] = data[y * rep.bytesPerRow + x * 4 + 3] } }
        return (w, h, a)
    }

    private static func badgeChecks() -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool) {
            print("check-logic: \(ok ? "PASS" : "FAIL") menu bar badge: \(what)")
            if !ok { failed += 1 }
        }
        let scale = 4
        for symbol in ["text.viewfinder", "viewfinder", "eye.slash"] {
            let config = NSImage.SymbolConfiguration(pointSize: MenuBarIconImage.pointSize, weight: .regular, scale: .medium)
            guard let plain = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { check("\(symbol) renders", false); continue }
            let drawnLikeTheBadge = NSImage(size: plain.size, flipped: false) { plain.draw(in: $0); return true }
            guard let ref = alpha(of: drawnLikeTheBadge, scale: scale), let badged = alpha(of: MenuBarIconImage.badged(symbol), scale: scale),
                  ref.w == badged.w, ref.h == badged.h else { check("\(symbol) renders", false); continue }
            let w = ref.w, h = ref.h
            // The dot: a disc of `dot` points with its centre half a point plus its radius in from the top right corner.
            let r = Int(MenuBarIconImage.dot / 2 * Double(scale)), cx = w - r - scale / 2, cy = r + scale / 2
            check("\(symbol): the dot is solid at its centre", badged.a[cy * w + cx] >= 250)
            var opaque = 0, total = 0
            for y in 0..<h { for x in 0..<w where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= (r - 2) * (r - 2) { total += 1; if badged.a[y * w + x] >= 250 { opaque += 1 } } }
            check("\(symbol): the dot is solid inside its rim (\(opaque) of \(total) pixels)", opaque == total && total > 0)
            // The ring around the dot is cut out of the glyph, and everywhere else the glyph is as drawn without the badge (the same handler
            // draws it, so any difference is the badge's doing).
            // (a pixel of margin at each edge: the dot's rim and the ring's rim are antialiased)
            let inner = r + 2, outer = r + Int(MenuBarIconImage.ring * Double(scale)) - 1, beyond = r + Int(MenuBarIconImage.ring * Double(scale)) + 2
            var ringPixels = 0, ringLeft = 0, same = 0, differ = 0
            for y in 0..<h { for x in 0..<w {
                let d2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                if d2 >= inner * inner, d2 <= outer * outer { ringPixels += 1; if badged.a[y * w + x] > 2 { ringLeft += 1 } }
                if d2 > beyond * beyond { if abs(Int(ref.a[y * w + x]) - Int(badged.a[y * w + x])) <= 2 { same += 1 } else { differ += 1 } }
            } }
            check("\(symbol): the ring around the dot is cut out (\(ringLeft) of \(ringPixels) pixels left)", ringPixels > 0 && ringLeft == 0)
            check("\(symbol): away from the dot the glyph is untouched (\(differ) pixels differ, \(same) match)", differ == 0 && same > 0)
        }
        check("the badged image is a template (the menu bar tints it)", MenuBarIconImage.badged("text.viewfinder").isTemplate)
        return failed
    }

    // MARK: - The inpainting model's memory

    /// This process's footprint in MB and its graphics (GPU) part, from `footprint -p`; nil where the tool fails.
    private static func footprint(_ tries: Int = 3) -> (total: Int, gpu: Int)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
        p.arguments = ["-p", String(getpid())]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        if !text.contains("Footprint:") { return tries > 1 ? footprint(tries - 1) : nil }   // the first look of a fresh process can come back empty
        func mb(_ n: Substring, _ unit: Substring) -> Int { Int(Double(n) ?? 0) * (unit == "GB" ? 1024 : unit == "KB" ? 0 : 1) }
        var total = 0, gpu = 0
        for line in text.split(separator: "\n") {
            let words = line.split(separator: " ", omittingEmptySubsequences: true)
            if let i = words.firstIndex(of: "Footprint:"), i + 2 < words.count { total = mb(words[i + 1], words[i + 2]) }
            if line.contains("IOAccelerator (graphics)"), words.count > 1 { gpu = mb(words[0], words[1]) }
        }
        return total > 0 ? (total, gpu) : nil
    }

    /// `--capture-ui <dir> inpaint-footprint`: what the inpainting model costs this process, and when. Prints the footprint before the
    /// model, with it found but not loaded, after the first fill, after twenty, and after the idle release (`MWOYEO_INPAINT_IDLE`
    /// seconds, 4 by default), with the time of each fill. The fill is a text-sized hole over a gradient, as the pipeline gives it.
    static func inpaintFootprint() async {
        let idle = Double(ProcessInfo.processInfo.environment["MWOYEO_INPAINT_IDLE"] ?? "4") ?? 4
        func show(_ what: String) {
            let f = footprint()
            print("inpaint-footprint: \(what): \(f.map { "\($0.total) MB, graphics \($0.gpu) MB" } ?? "footprint failed")")
        }
        try? await Task.sleep(for: .seconds(1))   // `footprint` finds nothing in a process that has just started
        show("start")
        let t0 = Trace.now
        guard let inpainter = Inpainter.load() else { print("inpaint-footprint: no model found"); return }
        inpainter.idleSeconds = idle
        print(String(format: "inpaint-footprint: Inpainter.load() %.1f ms, loaded=%@", (Trace.now - t0) * 1000, inpainter.isLoaded ? "yes" : "no"))
        show("model found, not loaded")
        var frame = RGBAImage(width: 1024, height: 768, color: RGBA(0, 0, 0))
        for y in 0..<768 { for x in 0..<1024 { frame.set(x: x, y: y, RGBA(UInt8(40 + x * 150 / 1024), UInt8(30 + y * 120 / 768), UInt8(120 + (x + y) % 40))) } }
        let rect = PixelRect(x: 300, y: 300, width: 400, height: 80)
        var mask = [UInt8](repeating: 0, count: rect.width * rect.height)
        for y in 20..<60 { for x in stride(from: 10, to: 390, by: 9) { for dx in 0..<4 { mask[y * rect.width + x + dx] = 1 } } }
        func fill() -> Double {
            let t = Trace.now
            _ = try? inpainter.inpaint(frame: frame, rect: rect, mask: mask)
            return (Trace.now - t) * 1000
        }
        print(String(format: "inpaint-footprint: fill 1 (loads the model): %.1f ms, loaded=%@", fill(), inpainter.isLoaded ? "yes" : "no"))
        show("after the first fill")
        var times: [Double] = []
        for _ in 0..<19 { times.append(fill()) }
        print(String(format: "inpaint-footprint: fills 2-20: median %.1f ms, max %.1f ms", times.sorted()[times.count / 2], times.max() ?? 0))
        show("after twenty fills")
        _ = await until(idle + 3) { !inpainter.isLoaded }
        print("inpaint-footprint: loaded=\(inpainter.isLoaded ? "yes" : "no") after \(idle) s idle")
        try? await Task.sleep(for: .seconds(2))
        show("after the idle release")
        print(String(format: "inpaint-footprint: fill after the release (loads again): %.1f ms", fill()))
        show("after the reload")
    }

    private static func until(_ seconds: Double, _ done: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !done(), Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        return done()
    }

    // MARK: - The menu bar badge, as a picture

    /// `--capture-ui <dir> menu-icon`: `menu-icon.png`, the three symbols with and without the badge, on a light and a dark menu bar
    /// (the template tinted black and white, at 8× the size), for the eye. The badged image is the one the menu bar item shows while a lens is down.
    static func menuIcon(into url: URL) {
        let scale = 8, cell = NSSize(width: 36, height: 28), symbols = ["text.viewfinder", "viewfinder", "eye.slash"]
        let w = Int(cell.width) * scale * symbols.count * 2, h = Int(cell.height) * scale * 2
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
            NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        for (row, (backdrop, ink)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
            backdrop.setFill()
            NSRect(x: 0, y: CGFloat(h) - CGFloat(row + 1) * cell.height * CGFloat(scale), width: CGFloat(w), height: cell.height * CGFloat(scale)).fill()
            for (i, symbol) in symbols.enumerated() {
                let config = NSImage.SymbolConfiguration(pointSize: MenuBarIconImage.pointSize, weight: .regular, scale: .medium)
                guard let plain = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { continue }
                for (j, image) in [plain, MenuBarIconImage.badged(symbol)].enumerated() {
                    let size = NSSize(width: image.size.width * CGFloat(scale), height: image.size.height * CGFloat(scale))
                    let x = (CGFloat(i * 2 + j) + 0.5) * cell.width * CGFloat(scale) - size.width / 2
                    let y = CGFloat(h) - (CGFloat(row) + 0.5) * cell.height * CGFloat(scale) - size.height / 2
                    tinted(image, ink).draw(in: NSRect(origin: NSPoint(x: x, y: y), size: size))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("wrote \(url.path)")
    }
}
#endif
