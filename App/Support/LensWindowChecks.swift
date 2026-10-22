#if !MAS
import AppKit
import ImageIO
import MwoyeoCore
import MwoyeoEngines

/// What a lens shows of a block that crosses one of its edges (round edges117, docs/design/recognition.md §16.2, film4 F1 and F2), run by
/// `--capture-ui … check-logic` and alone by `lens-window-checks` (PASS/FAIL lines). Three parts:
/// 1. the renderer lays a translation out in a window and says where its lines are; a window that holds the whole box changes no pixel;
/// 2. the overlay's mask on a real layer tree (the host's, geometry flipped) shows the lines that stand wholly in the lens and nothing of the
///    others, and none for a block wholly inside;
/// 3. a real pipeline (the reader, a mock engine) on a page with two columns and a lens that crosses the first's left edge and 20 pt of the
///    second: the first is laid out in the part the lens covers, the second is not drawn, and a lens over both whole changes neither.
@MainActor
enum LensWindowChecks {
    /// The PASS/FAIL lines of the checks, and how many failed.
    final class Check {
        private(set) var failed = 0
        func callAsFunction(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") lens window: \(what)" + (ok ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
    }

    static func run() async -> Int {
        let check = Check()
        renderer(check)
        mask(check)
        await pipeline(check)
        return check.failed
    }

    // MARK: 1. The renderer

    private static let korean = "렌즈는 화면에서 읽은 글을 번역해서 같은 자리에 보여 줍니다. 렌즈가 문단의 한쪽 가장자리를 가로지르면 번역은 렌즈가 덮는 너비에 맞추어 다시 배치되고, 각 줄은 온전하게 보이거나 아예 보이지 않습니다. 렌즈가 덮는 부분이 너무 좁으면 번역을 그리지 않고 페이지의 원문을 그대로 보여 줍니다."

    private static func input(window: ClosedRange<CGFloat>?) -> BlockRenderer.Input {
        BlockRenderer.Input(size: CGSize(width: 1000, height: 260), text: korean, background: .box(RGBA(255, 255, 255), opacity: 1),
                            appearance: TextAppearance(textColor: RGBA(0, 0, 0), backgroundColor: RGBA(255, 255, 255), backgroundNoise: 0, coverage: 0.2),
                            lineHeight: 34, fontSize: 26, originalLineCount: 4, fontStyle: .system, targetLanguage: "ko", scale: 2,
                            textArea: CGRect(x: 0, y: 0, width: 1000, height: 260), window: window)
    }

    private static func bytes(_ image: CGImage) -> Data { image.dataProvider?.data as Data? ?? Data() }

    private static func renderer(_ check: Check) {
        guard let whole = BlockRenderer.render(input(window: nil)), let narrow = BlockRenderer.render(input(window: 150...600)),
              let everything = BlockRenderer.render(input(window: 0...1000)) else {
            check("the renderer draws the block", false, "no image")
            return
        }
        let wholeRight = whole.lines.map(\.maxX).max() ?? 0
        check("a translation is laid out in a box of 1000 and says where its lines are", whole.lines.count >= 2 && wholeRight > 700,
              "\(whole.lines.count) lines, right edge \(wholeRight)")
        check("its lines stand one under the other inside the image", zip(whole.lines, whole.lines.dropFirst()).allSatisfy { $0.minY < $1.minY } && whole.lines.allSatisfy { $0.minY >= 0 && $0.maxY <= 260 },
              "\(whole.lines)")
        check("in a window of 150 to 600 every line stands inside it", !narrow.lines.isEmpty && narrow.lines.allSatisfy { $0.minX >= 149 && $0.maxX <= 601 }, "\(narrow.lines.map { [$0.minX, $0.maxX] })")
        check("a narrower box needs more lines", narrow.lines.count > whole.lines.count, "\(narrow.lines.count) against \(whole.lines.count)")
        check("a window that holds the whole box changes no pixel", bytes(whole.image) == bytes(everything.image) && whole.lines == everything.lines)
    }

    // MARK: 2. The overlay's mask

    private static func stripes(count: Int = 6) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 100, height: count * 20, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for k in 0..<count {
            ctx.setFillColor(stripeColors[k])
            ctx.fill(CGRect(x: 0, y: (count - k - 1) * 20, width: 100, height: 20))   // the context is y up: stripe 0 is the top one
        }
        return ctx.makeImage()
    }

    private static let stripeColors: [CGColor] = [(1, 0, 0), (0, 0.6, 0), (0, 0, 1), (1, 0, 1), (0, 0.8, 0.8), (1, 0.7, 0), (0.4, 0.4, 0.4)].map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) }

    /// The page's colour at (x, row from the top) of a layer tree drawn into a 300 x 300 picture.
    private static func render(_ root: CALayer) -> [[UInt8]]? {
        guard let ctx = CGContext(data: nil, width: 300, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 300, height: 300))
        root.render(in: ctx)
        guard let data = ctx.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self), stride = ctx.bytesPerRow
        // Row 0 of the bitmap is the top of the picture.
        return (0..<300).map { row in (0..<300).flatMap { x in (0..<3).map { p[row * stride + x * 4 + $0] } } }
    }

    private static func colourAt(_ rows: [[UInt8]], x: Int, y: Int) -> [UInt8] { Array(rows[y][(x * 3)..<(x * 3 + 3)]) }

    /// Which of the six stripes (the lines of a block at x 20, y 40, 100 x 120 on a flipped host, as the overlay has it) show: the stripe's own colour. `margin`: a seventh
    /// stripe above the six, which is no line but the block's erased background (the translation does not fill its patch): it is the block's, and shows where the lens cuts no line.
    private static func shownStripes(lens: CGRect, margin: Bool = false) -> (shows: Bool, stripes: [Bool], masked: Bool)? {
        let extra = margin ? 1 : 0
        guard let image = stripes(count: 6 + extra) else { return nil }
        let root = CALayer(), host = CALayer(), block = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        host.frame = root.bounds
        host.isGeometryFlipped = true   // the overlay's host: block frames are top-left based
        block.frame = CGRect(x: 20, y: 40, width: 100, height: CGFloat(120 + 20 * extra))
        block.contentsGravity = .resize
        block.contentsScale = 1
        block.contents = image
        root.addSublayer(host)
        host.addSublayer(block)
        let lines = (0..<6).map { CGRect(x: 0, y: CGFloat($0 + extra) * 20, width: 100, height: 20) }
        let shows = LensMask.apply(to: block, lines: lines, lens: lens)
        guard let rows = render(root) else { return nil }
        let own = stripeColors.map { c in c.components!.prefix(3).map { UInt8(($0 * 255).rounded()) } }
        // The stripes of the picture, margin first when there is one; the answer is for the six lines (or, with a margin, seven: the margin first).
        let seen = (0..<(6 + extra)).map { k in
            let got = colourAt(rows, x: 70, y: 40 + k * 20 + 10)
            return zip(got, own[k]).allSatisfy { abs(Int($0) - Int($1)) <= 3 }
        }
        return (shows, seen, block.mask != nil)
    }

    private static func mask(_ check: Check) {
        // The lens ends at y 130, inside the fifth line (y 120 to 140): the lines above it are whole.
        if let bottom = shownStripes(lens: CGRect(x: 0, y: 30, width: 300, height: 100)) {
            check("a lens that cuts the block's bottom shows the lines above the cut whole and nothing of the others", bottom.shows && bottom.stripes == [true, true, true, true, false, false] && bottom.masked,
                  "\(bottom)")
        } else { check("the layer tree is drawn", false) }
        // The lens starts at y 70, inside the second line (y 60 to 80).
        if let top = shownStripes(lens: CGRect(x: 0, y: 70, width: 300, height: 200)) {
            check("a lens that cuts the block's top shows the lines below the cut", top.shows && top.stripes == [false, false, true, true, true, true] && top.masked, "\(top)")
        } else { check("the layer tree is drawn", false) }
        // F1 (film4, edges117b): the lens cuts the last line at the bottom and no line at the top. The block's margin above the first line is its erased background,
        // which is the block's own wherever the lens cuts no line: the mask must not take it (the page's English line stood there, whole, above its Korean).
        if let margin = shownStripes(lens: CGRect(x: 0, y: 30, width: 300, height: 120 + 20), margin: true) {
            // The lens ends at y 170, inside the last line (the stripe at y 160 to 180); the stripe at y 40 to 60 is the margin.
            check("a lens that cuts only the bottom shows the block's margin above its first line (the erased background) and the whole lines", margin.stripes == [true, true, true, true, true, true, false] && margin.masked, "\(margin)")
        } else { check("the layer tree is drawn", false) }
        if let inside = shownStripes(lens: CGRect(x: 0, y: 30, width: 300, height: 200)) {
            check("a block wholly inside the lens has no mask and shows every line", inside.shows && inside.stripes == [true, true, true, true, true, true] && !inside.masked, "\(inside)")
        } else { check("the layer tree is drawn", false) }
        if let none = shownStripes(lens: CGRect(x: 0, y: 85, width: 300, height: 20)) {
            check("a lens that holds no whole line hides the block", !none.shows, "\(none)")
        } else { check("the layer tree is drawn", false) }
    }

    // MARK: 3. A pipeline

    private static let scale: CGFloat = 2
    private static let pageSize = CGSize(width: 720, height: 200)
    private static let first = CGRect(x: 40, y: 30, width: 400, height: 140), second = CGRect(x: 480, y: 30, width: 200, height: 160)
    private static let firstText = "The lens reads the words that sit inside it and a little beyond its edges. What it reads beyond the edge is translated ahead of time, so that moving the lens only reveals text that is already there."
    private static let secondText = "A lens that is made larger should keep every translation that is already on the screen. Only the newly covered strip has to be read again."

    private static func page(_ paragraphs: [(CGRect, String)] = [(first, firstText), (second, secondText)]) -> CGImage? {
        let w = Int(pageSize.width * scale), h = Int(pageSize.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for (rect, text) in paragraphs {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: NSColor.black, .paragraphStyle: style])
                .draw(with: rect, options: [.usesLineFragmentOrigin])
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    private final class Latest: @unchecked Sendable {
        private let lock = NSLock()
        private var value: OverlaySnapshot?
        var snapshot: OverlaySnapshot? { lock.withLock { value } }
        func put(_ s: OverlaySnapshot) { lock.withLock { value = s } }
    }

    private static func pipeline(_ check: Check) async {
        guard let mock = ContextChecks.Mock(mode: "ok"), let page = page(), let rgba = RGBAImage(cgImage: page), let readable = rgba.cgImage else {
            check("the mock server starts and the page is drawn", false)
            return
        }
        defer { mock.stop() }
        let engine = EngineConfig(id: UUID(), name: "Window", kind: .openAICompatible(baseURL: mock.base.appendingPathComponent("v1"), model: "m1", thinking: .off, extraHeaders: [:]),
                                  context: nil)
        var settings = ContextChecks.settings(nil)
        settings.engines = [engine]
        settings.customEngineID = engine.id
        settings.settleDelay = 0.15
        settings.renderMode = .seamless
        settings.paragraphReader = .lineGrouping
        settings.useInpaintingModel = false
        let capture = CGRect(origin: .zero, size: pageSize)
        let latest = Latest()

        /// A pipeline over `image` (the picture of `capture`) with its lens at `lens`, read and translated; the lens has settled (`settleLensNow`: the session's
        /// wait is not a gate's). `wait`: whether to wait for every text to be translated (a page that is cut has none to wait for).
        func settled(lens: CGRect, capture: CGRect = capture, image: CGImage = readable, wait: Bool = true,
                     midway: ((RegionPipeline) async -> Void)? = nil) async -> (RegionPipeline, OverlaySnapshot)? {
            guard let rgba = RGBAImage(cgImage: image) else { return nil }
            let gray = rgba.withBGRA { GrayImage(bgra: $0, width: rgba.width, height: rgba.height, bytesPerRow: rgba.width * 4, step: 4) }
            let p = RegionPipeline(options: PipelineOptions(settings), capture: capture, translator: ContextChecks.service(settings), inpainter: nil, lensSettle: 0.02,
                                   onSnapshot: { latest.put($0) })
            await p.setVisible(lens)
            _ = Trace.takeCounts()
            await p.ingest(CapturedFrame(image: image, gray: gray, grayStep: 4, scale: scale, rect: capture, time: ProcessInfo.processInfo.systemUptime))
            if let midway {
                // `midway` runs while the first pass reads (`pass.read` is counted as it starts, before the reader is awaited).
                let giveUp = ProcessInfo.processInfo.systemUptime + 30
                while (Trace.takeCounts()["pass.read"] ?? 0) == 0, ProcessInfo.processInfo.systemUptime < giveUp { try? await Task.sleep(for: .milliseconds(2)) }
                await midway(p)
            }
            let until = ProcessInfo.processInfo.systemUptime + 150
            while ProcessInfo.processInfo.systemUptime < until {
                try? await Task.sleep(for: .milliseconds(50))
                let state = await p.debugState()
                if !state.busy, !state.translating, wait ? state.blocks.count >= 2 && state.blocks.allSatisfy({ $0.1 != nil }) : true { break }
            }
            await p.idle()
            await p.settleLensNow()
            await p.idle()
            guard let s = latest.snapshot else { return nil }
            return (p, s)
        }

        // The lens from x 100 to 500: it cuts 60 of the first column's 400 and covers 20 of the second's 200. The reader may cut the first column's
        // first line off as a block of its own; what is asked is about the columns, not about how many blocks each came to.
        let lens = CGRect(x: 100, y: 10, width: 400, height: 180)
        guard let (p, snapshot) = await settled(lens: lens) else { check("the pipeline reads and translates the page", false); return }
        let state = await p.lensWindowState()
        let leftTexts = snapshot.texts.filter { $0.frame.maxX < 460 }.count, rightTexts = snapshot.texts.filter { $0.frame.minX > 460 }.count
        check("both columns are read and translated", leftTexts >= 1 && rightTexts >= 1 && snapshot.texts.allSatisfy { $0.translation != nil },
              "\(snapshot.texts.map { ($0.frame, $0.translation != nil) })")
        check("the column the lens crosses the side of is laid out in the part it covers", state.narrowed == leftTexts, "narrowed \(state.narrowed) of \(leftTexts) hidden \(state.hidden)")
        check("the column it covers 10 % of is not drawn", state.hidden == rightTexts && snapshot.blocks.count == leftTexts, "hidden \(state.hidden), \(snapshot.blocks.count) of \(snapshot.texts.count) drawn")
        let drawn = snapshot.blocks.max { $0.lines.count < $1.lines.count }
        let linesIn = snapshot.blocks.flatMap { b in b.lines.map { $0.offsetBy(dx: b.frame.minX, dy: b.frame.minY) } }
        check("the drawn blocks say where their lines are, and every one stands between the lens's sides", !linesIn.isEmpty && linesIn.allSatisfy { $0.minX >= lens.minX - 1 && $0.maxX <= lens.maxX + 1 },
              "\(linesIn.map { [$0.minX, $0.maxX] }) in \(lens.minX)...\(lens.maxX)")
        // Seen through the overlay's rule: a lens that ends in the middle of the column's lines shows only the whole ones.
        if let b = drawn, b.lines.count >= 3 {
            let own = b.lines.map { $0.offsetBy(dx: b.frame.minX, dy: b.frame.minY) }
            let cut = CGRect(x: lens.minX, y: lens.minY, width: lens.width, height: own[own.count - 2].midY - lens.minY)
            let shown = LensWindow.shown(lines: own, lens: cut)
            if case let .band(top, bottom) = shown {
                check("a lens that ends inside the last but one line shows the lines above it, from the top of the block", top == nil && abs((bottom ?? .infinity) - own[own.count - 3].maxY) < 0.01, "\(shown)")
            } else { check("a lens that ends inside the last but one line shows the lines above it", false, "\(shown)") }
        } else { check("the longest block came to three lines at least", false, "\(drawn?.lines.count ?? 0)") }

        // A lens over both columns whole changes nothing: no block is laid out again or left out, and the lines are the blocks' own.
        let all = CGRect(x: 10, y: 10, width: 700, height: 180)
        guard let (p2, snapshot2) = await settled(lens: all) else { check("the pipeline reads the page again", false); return }
        let state2 = await p2.lensWindowState()
        check("a lens that holds both columns whole lays out and hides nothing", state2.narrowed == 0 && state2.hidden == 0 && snapshot2.blocks.count == snapshot2.texts.count && snapshot2.texts.count == leftTexts + rightTexts,
              "narrowed \(state2.narrowed) hidden \(state2.hidden), \(snapshot2.blocks.count) of \(snapshot2.texts.count) drawn")
        check("and its lines stand inside the lens", snapshot2.blocks.allSatisfy { b in !b.lines.isEmpty && b.lines.allSatisfy { LensWindow.shown(lines: [$0.offsetBy(dx: b.frame.minX, dy: b.frame.minY)], lens: all) == .all } })

        // The lens grows over the second column: it is laid out again once, and shows.
        await p.setVisible(CGRect(x: 100, y: 10, width: 560, height: 180))
        await p.settleLensNow()
        await p.idle()
        let grown = await p.lensWindowState()
        check("a lens that grows over the column it left out draws it, laid out in the part it covers", grown.hidden == 0 && grown.narrowed == leftTexts + rightTexts && (latest.snapshot?.blocks.count ?? 0) == leftTexts + rightTexts,
              "narrowed \(grown.narrowed) hidden \(grown.hidden), \(latest.snapshot?.blocks.count ?? 0) of \(leftTexts + rightTexts) drawn")

        // A Fit decides the lens it goes to before the lens gets there (film4 F5): the blocks are laid out for it at once, and the lens itself has not moved. The lens that is
        // there (100 to 500) leaves the second column out (10 % covered); the one it goes to (100 to 660) covers 90 % of it.
        if let (p3, s3) = await settled(lens: lens) {
            let before = await p3.lensWindowState()
            let drawnBefore = s3.blocks.count
            let target = CGRect(x: 100, y: 10, width: 560, height: 180)
            await p3.planLens(for: target)
            await p3.idle()
            let after = await p3.lensWindowState()
            let drawnAfter = latest.snapshot?.blocks.count ?? 0
            check("a lens planned for (a Fit's end) has the column it will cover laid out before it is there: nothing hidden, both columns drawn",
                  before.hidden == rightTexts && after.hidden == 0 && drawnAfter == leftTexts + rightTexts && drawnBefore == leftTexts,
                  "hidden \(before.hidden) -> \(after.hidden), drawn \(drawnBefore) -> \(drawnAfter) of \(leftTexts + rightTexts)")
            await p3.setVisible(target)
            await p3.settleLensNow()
            await p3.idle()
            let landed = await p3.lensWindowState()
            check("and the lens that gets there changes nothing of it", landed.hidden == after.hidden && landed.narrowed == after.narrowed && (latest.snapshot?.blocks.count ?? 0) == drawnAfter,
                  "narrowed \(after.narrowed) -> \(landed.narrowed), hidden \(after.hidden) -> \(landed.hidden)")
        } else { check("the pipeline reads the page for the planned lens", false) }

        // A paragraph that the capture's edge cuts (film4 F16, F17): 600 wide on a capture of 500. Every line ends at the edge, so it is not drawn and not translated; it is
        // where a column stands, and the snapshot says a cut paragraph is under the lens (the session then asks the capture to reach it: `Reach`).
        let cutCapture = CGRect(x: 0, y: 0, width: 500, height: pageSize.height)
        if let wide = self.page([(CGRect(x: 40, y: 30, width: 600, height: 120), firstText + " " + secondText)]),
           let crop = wide.cropping(to: CGRect(x: 0, y: 0, width: cutCapture.width * scale, height: cutCapture.height * scale)),
           let (_, cutSnapshot) = await settled(lens: CGRect(x: 100, y: 10, width: 300, height: 180), capture: cutCapture, image: crop, wait: false) {
            check("a paragraph the capture's edge cuts is not drawn and not translated", cutSnapshot.blocks.isEmpty && cutSnapshot.texts.isEmpty,
                  "\(cutSnapshot.blocks.count) drawn, \(cutSnapshot.texts.count) read")
            check("it stands as a column the lens is over, and the snapshot says the capture cut it", cutSnapshot.cut && cutSnapshot.columns.count == 1, "cut \(cutSnapshot.cut), \(cutSnapshot.columns.count) columns")
            check("its column ends where the capture does", abs((cutSnapshot.columns.first?.right ?? 0) - cutCapture.maxX) < 8, "right \(cutSnapshot.columns.first?.right ?? 0)")
        } else { check("the cut paragraph is read", false) }

        // The capture grows while a pass reads (a Reach of the lens, film4 F5): the pass is rebased onto the wider capture, and the strips the growth uncovered are not read. What
        // was read is the capture the pass was given: the read says so, or Fit to Column takes the edge the capture cut for the column's own (it fitted 35 pt short of the column).
        if let wide = self.page([(CGRect(x: 40, y: 30, width: 600, height: 120), firstText + " " + secondText)]),
           let crop = wide.cropping(to: CGRect(x: 0, y: 0, width: cutCapture.width * scale, height: cutCapture.height * scale)),
           let (grown, _) = await settled(lens: CGRect(x: 100, y: 10, width: 300, height: 180), capture: cutCapture, image: crop, wait: false, midway: { p in await p.captureResized(to: capture) }),
           let snap = latest.snapshot {
            _ = grown
            check("a pass that the capture's growth rebased has read the capture it was given, not the wider one", snap.captureSize == capture.size && snap.read == cutCapture,
                  "capture \(snap.captureSize) read \(snap.read)")
        } else { check("the rebased pass is read", false) }
    }
}
#endif
