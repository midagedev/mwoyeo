#if !MAS
import AppKit
import CoreImage
import MwoyeoCore

/// The captures of the lens fit for the vision verdict (round fit117, `--capture-ui <dir> lens-fit-shots`): a lens over page 10 of our own paper, in the
/// light and the dark, as the app draws it: the guide while a resize stands on a column's edge, before and after Fit to Column, and Auto Fit's first
/// and last frame (Reduce Motion on, so the two frames are exactly the lens before and after). The columns are what `ColumnFit` makes of the multi-line
/// blocks the paper bench read on that page (the same numbers as the Core tests' fixture), cut to the crop on the screen; the picture is the page.
/// `FIT_PAGE` names the page image (default: the paper bench's p10.png, 2 pixels to the point).
@MainActor
enum FitShots {
    /// The multi-line blocks of page 10 below y 280 pt: x0, y0, x1, y1, lines (screen points of the page, as the bench read them).
    private static let blocks: [(Double, Double, Double, Double, Int)] = [
        (72.5, 297, 397.5, 387, 6), (72.5, 411.5, 398.5, 444.5, 2), (71.5, 458, 398, 788, 21), (72.5, 790.5, 398, 855, 4), (71.5, 856.5, 398, 966.5, 7),
        (421, 281.5, 746, 327.5, 3), (420, 376.5, 745.5, 532.5, 10), (421, 592, 746.5, 766, 11), (420, 803.5, 746.5, 929, 8),
    ]
    /// The crop of the page on the screen: its top is page y 280, the window's top-left is `origin` (global Quartz points).
    private static let crop = (top: 280.0, size: CGSize(width: 817, height: 520), origin: CGPoint(x: 40, y: 80))

    static func run(_ model: AppModel, into out: URL) async -> Int {
        let path = ProcessInfo.processInfo.environment["FIT_PAGE"] ?? "/tmp/paper-quality/pages-own/p10.png"
        guard let src = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("lens-fit-shots: cannot read the page image \(path)")
            return 1
        }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        Motion.shared.force(true)
        defer { Motion.shared.force(nil); NSApp.appearance = nil }
        var failed = 0
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            failed += await shoot(dark: dark, page: src, model: model, into: out)
        }
        return failed
    }

    /// Whether the guide is in a capture: of the rows from `y0` to `y1` (global points) of the capture `png` of `shot` (global points), the share where
    /// the two device pixels of a one point line at `x` differ from the page four points to its left. The colour is not judged (the accent is the user's).
    private static func guideRows(in png: URL, shot: CGRect, x: Double, from y0: Double, to y1: Double) -> (hit: Int, rows: Int) {
        guard let source = CGImageSourceCreateWithURL(png as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return (0, 0) }
        let (w, h) = (image.width, image.height), k = Double(w) / shot.width
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let context = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        func rgb(_ cx: Int, _ cy: Int) -> [Int] { (0..<3).map { Int(px[(cy * w + cx) * 4 + $0]) } }
        let line = Int(((x - 0.5 - shot.minX) * k).rounded()), page = line - Int(4 * k)
        let rows = Int((y0 - shot.minY) * k)..<Int((y1 - shot.minY) * k)
        guard line >= 0, page >= 0, line + 1 < w, rows.lowerBound >= 0, rows.upperBound <= h else { return (0, 0) }
        let hit = rows.filter { y in zip(rgb(line, y), rgb(page, y)).map { abs($0 - $1) }.reduce(0, +) > 90 && zip(rgb(line + 1, y), rgb(page, y)).map { abs($0 - $1) }.reduce(0, +) > 90 }.count
        return (hit, rows.count)
    }

    /// A double-click on a live lens's ring, as the pointer makes it (`--capture-ui <dir> lens-fit-click`): real mouse events posted at the lens's ring,
    /// two clicks 60 ms apart. Needs the accessibility grant to post events; without it the line says so and nothing is judged. The pointer goes back
    /// where it was. Prints PASS/FAIL: the second click fits the lens to the column (a third is its Undo Fit).
    static func click(_ model: AppModel) async -> Int {
        guard AccessibilityChecks.canAsk else {
            print("check-logic: SKIP lens-fit-click: this process may not post mouse events (no accessibility grant)")
            return 0
        }
        Motion.shared.force(true)
        defer { Motion.shared.force(nil) }
        let capture = CGRect(origin: crop.origin, size: crop.size)
        var config = RegionConfig(name: "Paper", rect: CGRect(x: 150, y: 250, width: 230, height: 220))
        config.follow(nil)
        let s = RegionSession(config: config, settings: AppSettings(), translator: model.translator, inpainter: nil, capturer: FakeCapture(), recovery: LensRobustChecks.fast)
        s.appUnderLens = { _ in nil }
        s.fit.calm = -1
        await s.start()
        let cut = blocks.compactMap { b -> ColumnFit.Block? in
            let y0 = max(capture.minY, capture.minY + b.1 - crop.top), y1 = min(capture.maxY, capture.minY + b.3 - crop.top)
            guard y1 - y0 >= 4 else { return nil }
            return ColumnFit.Block(core: CGRect(x: crop.origin.x + b.0 - capture.minX, y: y0 - capture.minY, width: b.2 - b.0, height: y1 - y0), lines: b.4)
        }
        s.received(OverlaySnapshot(version: 1000, blocks: [], animated: false, origin: capture.origin, columns: ColumnFit.columns(cut), captureSize: capture.size,
                                   read: CGRect(origin: .zero, size: capture.size)))
        let before = s.config.rect
        let home = CGEvent(source: nil)?.location ?? .zero
        // The bottom edge of the ring, left of its middle: not the pill (top), not the corner (bottom right).
        let at = CGPoint(x: before.minX + 60, y: before.maxY)
        func post(_ type: CGEventType, clicks: Int64) {
            let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: at, mouseButton: .left)
            e?.setIntegerValueField(.mouseEventClickState, value: clicks)
            e?.post(tap: .cghidEventTap)
        }
        CGWarpMouseCursorPosition(at)
        try? await Task.sleep(for: .milliseconds(200))
        var failed = 0
        for (i, expected) in [false, true].enumerated() {
            post(.leftMouseDown, clicks: Int64(i + 1))
            try? await Task.sleep(for: .milliseconds(30))
            post(.leftMouseUp, clicks: Int64(i + 1))
            try? await Task.sleep(for: .milliseconds(i == 0 ? 60 : 400))
            let fitted = s.config.rect != before
            let ok = fitted == expected
            print("check-logic: \(ok ? "PASS" : "FAIL") lens-fit-click: after the \(expected ? "second" : "first") click the lens is \(fitted ? "fitted" : "as it was") (\(s.config.rect))")
            if !ok { failed += 1 }
        }
        CGWarpMouseCursorPosition(home)
        await s.stop()
        return failed
    }

    private static func shoot(dark: Bool, page src: CGImage, model: AppModel, into out: URL) async -> Int {
        let tag = dark ? "dark" : "light"
        // The page: the crop of the picture (2 px to the point), darkened by inversion for the dark look.
        let c = crop
        guard var image = src.cropping(to: CGRect(x: 0, y: c.top * 2, width: c.size.width * 2, height: c.size.height * 2)) else { return 1 }
        if dark, let inverted = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: CIImage(cgImage: image)])?.outputImage,
           let made = CIContext().createCGImage(inverted, from: inverted.extent) { image = made }
        let region = ScreenGeometry.appKitRect(fromQuartz: CGRect(origin: c.origin, size: c.size))
        let window = NSWindow(contentRect: region, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .normal
        window.backgroundColor = dark ? .black : .white
        let view = NSImageView(frame: NSRect(origin: .zero, size: c.size))
        view.image = NSImage(cgImage: image, size: c.size)
        view.imageScaling = .scaleAxesIndependently
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        // What the reader makes of the page: the columns of the multi-line blocks, in the crop's capture, on the screen.
        let capture = CGRect(origin: c.origin, size: c.size)
        var version = 1000          // above the pipeline's own count: its empty first snapshots, which come late, do not replace these
        func snapshot() -> OverlaySnapshot {
            version += 1
            let cut = blocks.compactMap { b -> ColumnFit.Block? in
                let x0 = c.origin.x + b.0, x1 = c.origin.x + b.2, y0 = max(c.origin.y, c.origin.y + b.1 - c.top), y1 = min(c.origin.y + c.size.height, c.origin.y + b.3 - c.top)
                guard y1 - y0 >= 4 else { return nil }
                return ColumnFit.Block(core: CGRect(x: x0 - capture.minX, y: y0 - capture.minY, width: x1 - x0, height: y1 - y0), lines: b.4)
            }
            return OverlaySnapshot(version: version, blocks: [], animated: false, origin: capture.origin, columns: ColumnFit.columns(cut), captureSize: capture.size,
                                   read: CGRect(origin: .zero, size: capture.size))
        }
        func lens(_ rect: CGRect, autoFit: Bool = false) async -> RegionSession {
            var config = RegionConfig(name: "Paper", rect: rect)
            config.autoFit = autoFit
            config.follow(nil)
            let s = RegionSession(config: config, settings: AppSettings(), translator: model.translator, inpainter: nil, capturer: FakeCapture(), recovery: LensRobustChecks.fast)
            s.appUnderLens = { _ in nil }
            s.fit.calm = -1
            s.fit.commandDown = { false }       // not the machine's keyboard: a held ⌘ is no snap, and no guide to shoot
            await s.start()
            // The pointer of whoever uses the screen must not hover the lens: hovering brightens it.
            s.lensWindow.ignoresMouseEvents = true
            return s
        }
        let shotRect = capture.insetBy(dx: -30, dy: -30)
        func shot(_ name: String) async {
            try? await Task.sleep(for: .seconds(0.6))
            let r = shotRect
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", out.appendingPathComponent("\(name)-\(tag).png").path]
            try? p.run()
            p.waitUntilExit()
            print("wrote \(out.appendingPathComponent("\(name)-\(tag).png").path)")
        }

        // A lens narrower than the left column on both sides (the column stands at global x 112...438).
        let narrow = CGRect(x: 150, y: 250, width: 230, height: 220)

        // 1. Before and after Fit to Column.
        let a = await lens(narrow)
        a.received(snapshot())
        await shot("fit-before")
        a.fitToColumn()
        await shot("fit-after")

        // 2. The guide while a resize stands on the column's right edge: the corner dragged 4 pt short of it.
        await a.stop()
        let g = await lens(narrow)
        g.received(snapshot())
        let w = g.lensWindow as? RegionFrameWindow
        var dragged = ScreenGeometry.appKitRect(fromQuartz: g.config.rect)
        dragged.size.width = 398.5 + 40 + 6 - 4 - g.config.rect.minX
        if let w, let snapped = w.onSnapResize?(dragged) { w.setRegion(snapped); w.onResize?(snapped) }
        w?.setEmphasized(true)
        let guideAt = g.fit.snap?.target
        await shot("guide-resize")
        // The capture shows the guide: a line along the column's edge above the lens (inside it the page is the lens's own translation, none here).
        var failed = 0
        if let t = guideAt {
            let rows = (from: max(t.top, shotRect.minY) + 2, to: g.config.rect.minY - 8)
            let seen = guideRows(in: out.appendingPathComponent("guide-resize-\(tag).png"), shot: shotRect, x: t.x, from: rows.from, to: rows.to)
            let ok = seen.rows > 0 && Double(seen.hit) >= 0.6 * Double(seen.rows)
            print("check-logic: \(ok ? "PASS" : "FAIL") lens-fit-shots: the guide is in the capture, \(tag): \(seen.hit) of \(seen.rows) rows above the lens at x \(t.x)")
            if !ok { failed += 1 }
            // The control: the lens let go takes the guide down, and the same reading of a capture without it finds no line (the detector is not always true).
            w?.onCommit?()
            await shot("guide-down")
            let down = out.appendingPathComponent("guide-down-\(tag).png")
            let none = guideRows(in: down, shot: shotRect, x: t.x, from: rows.from, to: rows.to)
            try? FileManager.default.removeItem(at: down)
            let clear = none.rows > 0 && Double(none.hit) <= 0.1 * Double(none.rows)
            print("check-logic: \(clear ? "PASS" : "FAIL") lens-fit-shots: with the guide down the capture has no line, \(tag): \(none.hit) of \(none.rows) rows")
            if !clear { failed += 1 }
        } else {
            print("check-logic: FAIL lens-fit-shots: no guide target while the corner stands 4 pt short of the column's edge (\(tag))")
            failed += 1
        }
        w?.onCommit?()
        await g.stop()

        // 3. Auto Fit: the lens before it judges, and after.
        let b = await lens(narrow, autoFit: true)
        await shot("auto-first")
        b.received(snapshot())
        await shot("auto-last")
        await b.stop()
        return failed
    }
}
#endif
