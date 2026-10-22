#if !MAS
import AppKit
import CoreText
import MwoyeoCore

/// The captures of games and video (round game117, 2026-10-22), `--capture-ui <dir> game-shots`: a lens over a game-like scene (a HUD at the
/// top right, a dialogue box at the bottom) with the HUD ignored, while the pointer is over the lens (the regions outlined) and at rest, and
/// a lens that keeps its recent lines, and the marker over the lens with its hint pills, each on a light and a dark backdrop. The lens is a real session on a fake capture; the translation in
/// the box is drawn as a block of a snapshot. The pointer of whoever uses the screen must stay away from the lens (it is click-through here,
/// and the outlines are put up by the capture, not by the pointer). Hold /tmp/r117/screen.lock while it runs.
@MainActor
enum GameShots {
    static func run(model: AppModel, out: URL, wait: Double) async {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            await shoot(model: model, out: out, dark: dark, wait: wait)
        }
        NSApp.appearance = nil
    }

    private static let sceneSize = CGSize(width: 600, height: 340)
    /// Around the lens and the hint pills in the marker's shot.
    private static let margin: CGFloat = 20

    /// The scene as a picture (top-left origin): sky and ground, a HUD at the top right, a name tag and a dialogue box at the bottom.
    private static func scene(dark: Bool) -> NSImage {
        let size = sceneSize
        return NSImage(size: size, flipped: true) { rect in
            let sky = dark ? NSColor(srgbRed: 0.10, green: 0.12, blue: 0.22, alpha: 1) : NSColor(srgbRed: 0.62, green: 0.78, blue: 0.92, alpha: 1)
            let ground = dark ? NSColor(srgbRed: 0.08, green: 0.16, blue: 0.12, alpha: 1) : NSColor(srgbRed: 0.45, green: 0.66, blue: 0.40, alpha: 1)
            sky.setFill()
            rect.fill()
            ground.setFill()
            NSRect(x: 0, y: 190, width: size.width, height: size.height - 190).fill()
            func text(_ s: String, at p: NSPoint, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .white) {
                NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]).draw(at: p)
            }
            // The HUD.
            NSColor.black.withAlphaComponent(0.45).setFill()
            NSBezierPath(roundedRect: NSRect(x: 392, y: 24, width: 184, height: 44), xRadius: 8, yRadius: 8).fill()
            text("HP 80/100   00:42", at: NSPoint(x: 408, y: 36), size: 16, weight: .semibold)
            // The dialogue.
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: NSRect(x: 30, y: 236, width: 540, height: 80), xRadius: 10, yRadius: 10).fill()
            text("Mira", at: NSPoint(x: 48, y: 244), size: 13, weight: .bold, color: NSColor(srgbRed: 1, green: 0.85, blue: 0.4, alpha: 1))
            text("Press the green button to open the door.", at: NSPoint(x: 48, y: 268), size: 20)
            return true
        }
    }

    /// A block's picture: `text` on the box's colour, as the lens draws a translation over the line it erased.
    private static func block(_ text: String, size: CGSize, dark: Bool, scale: CGFloat = 2) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // The colour the dialogue box has on this ground (black at 60 %), as the erased line leaves it.
        ctx.setFillColor(dark ? CGColor(srgbRed: 0.032, green: 0.064, blue: 0.048, alpha: 1) : CGColor(srgbRed: 0.18, green: 0.264, blue: 0.16, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.white])
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        ctx.textPosition = CGPoint(x: 0, y: (size.height - ascent - descent) / 2 + descent)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    private static func shoot(model: AppModel, out: URL, dark: Bool, wait: Double) async {
        let suffix = dark ? "dark" : "light"
        let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1512, height: 982)
        // The lens covers the scene; the backdrop has room below it for the stack of recent lines, and above it for the marker's hint pills (they
        // stand 40 points from the lens and 72 tall, and the marker's shot is `margin` more: under the menu bar).
        let lensQuartz = CGRect(x: 160, y: 200, width: sceneSize.width, height: sceneSize.height)
        let lens = ScreenGeometry.appKitRect(fromQuartz: lensQuartz)
        let page = NSWindow(contentRect: lens.insetBy(dx: -30, dy: 0).union(lens.offsetBy(dx: 0, dy: -150)).insetBy(dx: 0, dy: -30), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        page.backgroundColor = NSColor(white: dark ? 0.12 : 0.96, alpha: 1)
        // Above the other windows of the screen (a capture of another round may be open), below the lens's own.
        page.level = .floating
        let picture = NSImageView(frame: NSRect(x: lens.minX - page.frame.minX, y: lens.minY - page.frame.minY, width: lens.width, height: lens.height))
        picture.image = scene(dark: dark)
        page.contentView?.addSubview(picture)
        page.orderFrontRegardless()

        var settings = AppSettings()
        settings.sourceLanguage = "en"
        settings.targetLanguage = "ko"
        var config = RegionConfig(name: "Game", rect: lensQuartz)
        config.follow(nil)
        let s = RegionSession(config: config, settings: settings, translator: model.translator, inpainter: nil, capturer: FakeCapture(),
                              recovery: LensRobustChecks.fast, appUnderLens: { _ in nil })
        await s.start()
        s.lensWindow.ignoresMouseEvents = true

        var version = 0
        func snapshot(_ lines: [(source: String, translation: String)], withBlock: Bool) -> OverlaySnapshot {
            version += 1
            let box = CGRect(x: 48, y: 262, width: 506, height: 34)
            let blocks = withBlock ? [OverlayBlock(id: UUID(), frame: box, image: block(lines.last?.translation ?? "", size: box.size, dark: dark)!, seamless: true)] : []
            let texts = lines.enumerated().map { BlockText(frame: CGRect(x: 48, y: 262 + CGFloat($0.offset) * 0.001, width: 506, height: 34),
                                                          source: $0.element.source, translation: $0.element.translation) }
            return OverlaySnapshot(version: version, blocks: blocks, animated: false, origin: lensQuartz.origin, texts: texts)
        }
        func look(_ name: String) async {
            try? await Task.sleep(for: .seconds(wait))
            let r = page.frame
            let path = out.appendingPathComponent("\(name)-\(suffix).png").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", "\(Int(r.minX)),\(Int(screen.height - r.maxY)),\(Int(r.width)),\(Int(r.height))", path]
            try? p.run()
            p.waitUntilExit()
            print("wrote \(path)")
        }

        // The HUD is ignored: the dialogue is translated over its box, nothing is drawn on the HUD, and the HUD is outlined while the lens is hovered.
        s.showForCapture(snapshot([("Press the green button to open the door.", "초록색 버튼을 눌러 문을 여세요.")], withBlock: true))
        s.addIgnoredRegion(dragged: CGRect(x: lensQuartz.minX + 392, y: lensQuartz.minY + 24, width: 184, height: 44))
        s.previewIgnoredOutlines(true)
        await look("game-ignore-editing")
        s.previewIgnoredOutlines(false)
        await look("game-ignore-rest")

        // Recent lines: the dialogue moves on three times; the lines that left the lens stay below it.
        s.setKeepsRecent(true)
        let story = [("Press the green button to open the door.", "초록색 버튼을 눌러 문을 여세요."), ("The door is stuck. Try the old key.", "문이 걸렸어요. 낡은 열쇠를 써 보세요."),
                     ("Where did you find that key?", "그 열쇠는 어디서 찾았어요?"), ("Under the table, behind the lamp.", "탁자 밑, 램프 뒤에서요."),
                     ("Then we can finally leave.", "그럼 드디어 떠날 수 있겠네요.")]
        for line in story { s.showForCapture(snapshot([line], withBlock: true)) }
        await look("game-recent-lines")
        s.setKeepsRecent(false)

        // The marker over the lens: the screen dims except the lens, the region already ignored is outlined, and one is being placed with the keyboard.
        // The shot is the lens and both hint pills with `margin` points around them (16 asked; the ring and its glow count as the lens), and the stage
        // (`page`) is made as big as that: no pixel of the desktop.
        let marker = RegionMarker()
        let marking = Task { await marker.mark(in: lensQuartz, existing: s.config.ignored.map { $0.rect(in: lensQuartz) }) }
        try? await Task.sleep(for: .seconds(0.6))
        if let view = marker.view as? MarkerView, let window = view.window {
            view.handle(.engage)
            view.handle(.move(.left, resize: false, fine: false))
            let pills = view.hintFrames.map { $0.offsetBy(dx: window.frame.minX, dy: window.frame.minY) }
            let area = pills.reduce(lens) { $0.union($1) }.insetBy(dx: -margin, dy: -margin)
            page.setFrame(area, display: true)
            picture.frame = NSRect(x: lens.minX - area.minX, y: lens.minY - area.minY, width: lens.width, height: lens.height)
            let visible = window.screen?.visibleFrame ?? .zero
            print("game-note: marker shot \(suffix): pills \(pills.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" }), area inside the visible frame: \(visible.contains(area))")
            try? await Task.sleep(for: .seconds(wait))
            let q = ScreenGeometry.quartzRect(fromAppKit: area)
            let path = out.appendingPathComponent("game-marker-\(suffix).png").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-R", "\(Int(q.minX)),\(Int(q.minY)),\(Int(q.width)),\(Int(q.height))", path]
            try? p.run()
            p.waitUntilExit()
            print("wrote \(path)")
        }
        (marker.view as? MarkerView)?.handle(.cancel)
        _ = await marking.value
        await s.stop()
        page.orderOut(nil)
    }
}
#endif
