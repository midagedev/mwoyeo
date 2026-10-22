#if !MAS
import AppKit
import ImageIO
import MwoyeoCore
import MwoyeoEngines

/// What a lens shows while it is resized over a page that does not change (round hold117, 2026-10-22), run by `--capture-ui … check-logic` and
/// alone by `resize-hold-checks` (PASS/FAIL lines). The user's words: "a lens resize blanks its text; the text was read and drawn ahead, the
/// blocks are anchored to the page, so nothing may disappear unless the screen changes" (docs/design/lens-hold.md).
///
/// A real session (`RegionSession`) on a capture that serves frames of a still page (`PageCapture`), the lens window dragged the way
/// `RegionFrameWindow.mouseDragged` does it (`setRegion`, `onResize`, `onCommit`), a mock engine that answers after a delay. Every snapshot
/// the pipeline makes is kept; the checks compare each with the one before it, inside the lens as it is at that moment: every block the last
/// one drew still changes the pixels it changed, and the overlay changes as many pixels of the page as it did; the last drop lands over
/// another app's window, which changes the reader's context and not the page. Then a second lens is resized while its first read is under
/// way: the pass is kept and its blocks land on the page's paragraphs (addendum H1).
@MainActor
enum ResizeHoldChecks {
    static let scale: CGFloat = 2
    static let pageSize = CGSize(width: 900, height: 620)
    /// The page's top-left on the screen (Quartz points).
    static let pageOrigin = CGPoint(x: 100, y: 120)

    /// Paragraphs of the page, in page points (top-left origin). Some sit inside the first lens, some across its edge, and two run the whole
    /// width of the page, so that what a capture sees of them depends on how wide the capture is.
    private static let paragraphs: [(CGRect, String, CGFloat, Bool)] = [
        (CGRect(x: 20, y: 20, width: 380, height: 40), "Reading text on the screen", 20, true),
        (CGRect(x: 20, y: 70, width: 380, height: 110), "The lens reads the words that sit inside it and a little beyond its edges. What it reads beyond the edge is translated ahead of time, so that moving the lens only reveals text that is already there.", 15, false),
        (CGRect(x: 20, y: 190, width: 380, height: 110), "A lens that is made larger should keep every translation that is already on the screen. Only the newly covered strip has to be read again, and nothing that was drawn may go blank while it is.", 15, false),
        (CGRect(x: 460, y: 70, width: 420, height: 110), "When a page does not change, the words stay where they are. The translation is anchored to the page, and the edge of the lens only decides which of the drawn words are shown at this moment.", 15, false),
        (CGRect(x: 460, y: 190, width: 420, height: 110), "Every line of a paragraph is read together with its neighbours, so that the engine sees whole sentences instead of fragments and the Korean reads like Korean, not like a word list.", 15, false),
        (CGRect(x: 20, y: 310, width: 860, height: 90), "Some paragraphs run across the whole width of the page, far past the edge of a small lens, and the part of them that the capture sees depends on how wide the lens and its margins are at that moment.", 15, false),
        (CGRect(x: 20, y: 420, width: 860, height: 90), "These long lines are the hard case: a wider capture shows more of each line, the same paragraph reads as a longer text, and its translation has to be made again for the longer text while the shorter one stays on the screen.", 15, false),
        (CGRect(x: 20, y: 530, width: 380, height: 70), "Short notes below the long text are read the same way as any other block.", 15, false),
        (CGRect(x: 460, y: 530, width: 420, height: 70), "The last paragraph of the page ends here, with a few more words to fill the line.", 15, false),
    ]

    static func renderPage() -> CGImage? {
        let w = Int(pageSize.width * scale), h = Int(pageSize.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A flipped context in points: the paragraphs are placed from the page's top-left.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        for (rect, text, size, bold) in paragraphs {
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            let font = bold ? NSFont.systemFont(ofSize: size, weight: .bold) : NSFont.systemFont(ofSize: size)
            NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
                .draw(with: rect, options: [.usesLineFragmentOrigin])
        }
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// A capture of a still page: the first frame of every start and every change of rect, like a stream after its configuration.
    final class PageCapture: ScreenCapturing, @unchecked Sendable {
        var onFrame: (@Sendable (CapturedFrame) -> Void)?
        var onStop: (@Sendable (Error?) -> Void)?
        let page: CGImage
        let display: CGRect
        private(set) var running = false
        /// Set: a change of rect delivers no frame (the stream has not answered yet), so that nothing but a read already under way can show the page.
        var withholdFrames = false
        /// The frames handed on, their rects and uptimes (the last few): `settle` waits for the frame of the lens's capture and the pass it may start.
        var handedOn: [(rect: CGRect, time: Double)] { lock.withLock { frames } }
        private let lock = NSLock()
        private var frames: [(rect: CGRect, time: Double)] = []
        var streamDisplay: CGRect? { running ? display : nil }

        init(page: CGImage, display: CGRect) {
            self.page = page
            self.display = display
        }

        func start(rect: CGRect, fps: Double) async throws {
            running = true
            deliver(rect)
        }

        func update(rect: CGRect, fps: Double) async throws { deliver(rect) }
        func stop() async { running = false }

        private func deliver(_ rect: CGRect) {
            guard !withholdFrames, let frame = frame(of: rect) else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self else { return }
                self.lock.withLock { self.frames = Array(self.frames.suffix(15)) + [(frame.rect, ProcessInfo.processInfo.systemUptime)] }
                self.onFrame?(frame)
            }
        }

        /// The page as `ctx` (a bottom-left context of `rect`'s size in pixels) shows it for the screen rect `rect`.
        func draw(into ctx: CGContext, rect: CGRect) {
            let s = ResizeHoldChecks.scale, h = CGFloat(ctx.height)
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
            ctx.draw(page, in: CGRect(x: (ResizeHoldChecks.pageOrigin.x - rect.minX) * s,
                                      y: h - (ResizeHoldChecks.pageOrigin.y - rect.minY + ResizeHoldChecks.pageSize.height) * s,
                                      width: ResizeHoldChecks.pageSize.width * s, height: ResizeHoldChecks.pageSize.height * s))
        }

        func frame(of rect: CGRect) -> CapturedFrame? {
            let s = ResizeHoldChecks.scale
            guard let ctx = CGContext(data: nil, width: Int((rect.width * s).rounded()), height: Int((rect.height * s).rounded()), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            draw(into: ctx, rect: rect)
            guard let crop = ctx.makeImage(), let rgba = RGBAImage(cgImage: crop), let image = rgba.cgImage else { return nil }
            let gray = rgba.withBGRA { GrayImage(bgra: $0, width: rgba.width, height: rgba.height, bytesPerRow: rgba.width * 4, step: 4) }
            return CapturedFrame(image: image, gray: gray, grayStep: 4, scale: s, rect: rect, time: ProcessInfo.processInfo.systemUptime)
        }
    }

    /// One snapshot, and the lens as it was when the panel got it.
    struct Seen {
        let time: Double
        let lens: CGRect
        let snapshot: OverlaySnapshot
        /// Where the drawn blocks are on the screen (Quartz points).
        var rects: [CGRect] { snapshot.blocks.map { $0.frame.offsetBy(dx: snapshot.origin.x, dy: snapshot.origin.y) } }
        /// How many of them stand in the lens.
        var inLens: Int { rects.filter { $0.intersects(lens) }.count }
        /// Every text the lens holds has its translation.
        var translated: Bool {
            let texts = snapshot.texts.filter { $0.frame.offsetBy(dx: snapshot.origin.x, dy: snapshot.origin.y).intersects(lens) }
            return !texts.isEmpty && texts.allSatisfy { $0.translation != nil }
        }
    }

    @MainActor final class Recorder {
        var seen: [Seen] = []
        var marks: [(time: Double, label: String)] = []
    }

    /// The lens as the page shows it, bare and under the overlay of `snapshot`: the luma of every pixel, row by row, and the row length.
    static func lumas(of snapshot: OverlaySnapshot, in lens: CGRect, over page: PageCapture) -> (bare: [UInt8], drawn: [UInt8], width: Int)? {
        let s = scale
        let w = Int((lens.width * s).rounded()), h = Int((lens.height * s).rounded())
        func pixels(withBlocks: Bool) -> [UInt8]? {
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let data = ctx.data else { return nil }
            page.draw(into: ctx, rect: lens)
            if withBlocks {
                for b in snapshot.blocks {
                    let f = b.frame.offsetBy(dx: snapshot.origin.x - lens.minX, dy: snapshot.origin.y - lens.minY)
                    ctx.draw(b.image, in: CGRect(x: f.minX * s, y: CGFloat(h) - f.maxY * s, width: f.width * s, height: f.height * s))
                }
            }
            let rowBytes = ctx.bytesPerRow
            var out = [UInt8](repeating: 0, count: w * h)
            let base = data.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let p = base + y * rowBytes + x * 4
                    out[y * w + x] = UInt8((Int(p[0]) * 3 + Int(p[1]) * 6 + Int(p[2])) / 10)
                }
            }
            return out
        }
        guard let bare = pixels(withBlocks: false), let drawn = pixels(withBlocks: true) else { return nil }
        return (bare, drawn, w)
    }

    /// The pixels of `lens` that the overlay of `snapshot` changes on the page (erased text, drawn text), row by row, and the row length.
    static func changed(by snapshot: OverlaySnapshot, in lens: CGRect, over page: PageCapture) -> (mask: [Bool], width: Int) {
        guard let l = lumas(of: snapshot, in: lens, over: page) else { return ([], Int((lens.width * scale).rounded())) }
        return (zip(l.bare, l.drawn).map { abs(Int($0) - Int($1)) > 24 }, l.width)
    }

    /// The largest share, over the blocks of `before` (their places, screen points) that stand over at least 150 of the page's text pixels inside
    /// `lens`, of those text pixels that are dark again under the overlay `now`: about 0.35 where a translation is drawn over the erased text
    /// (its own ink falls on some of them), 1 where the page's own text shows. A translation replaced by another one in the same block reads the
    /// same; only a block that is no longer drawn there reads high. The instrument of `tools/lens-hold/luma.py`, on the snapshots. 0 when no block counts.
    static func worstRestored(_ before: [CGRect], in lens: CGRect, now l: (bare: [UInt8], drawn: [UInt8], width: Int)) -> Double {
        let s = scale, w = l.width
        guard w > 0, !l.bare.isEmpty, l.bare.count == l.drawn.count else { return 0 }
        let h = l.bare.count / w
        var worst = 0.0
        for b in before {
            let r = b.intersection(lens)
            guard !r.isNull else { continue }
            let x0 = max(0, Int(((r.minX - lens.minX) * s).rounded(.down))), x1 = min(w, Int(((r.maxX - lens.minX) * s).rounded(.up)))
            let y0 = max(0, Int(((r.minY - lens.minY) * s).rounded(.down))), y1 = min(h, Int(((r.maxY - lens.minY) * s).rounded(.up)))
            var n = 0, dark = 0
            for y in y0..<max(y0, y1) {
                for x in x0..<max(x0, x1) where l.bare[y * w + x] < 110 {
                    n += 1
                    if l.drawn[y * w + x] < 110 { dark += 1 }
                }
            }
            if n >= 150 { worst = max(worst, Double(dark) / Double(n)) }
        }
        return worst
    }

    /// What the snapshots of a run show from the settled one on (`settledAt`), each against the one before it.
    struct Judgement {
        /// The settled lens: the share of the page's text dark under its blocks (the control of `worstBack`).
        var level = 1.0
        /// The most of the page's text, under a block the snapshot before drew, that is dark again, and the snapshots where it is 0.6 or more.
        var worstBack = 0.0, worstAt = 0, englishOver = 0
        /// The least share of the pixels the overlay changed in the snapshot before that it still changes.
        var worstInk = 1.0, worstInkAt = 0
        /// The first snapshot with no drawn block in the lens where the one before had some (0: none).
        var emptyAt = 0
        /// Snapshots in which a drawn block of the lens is replaced by another that stands over it (a new identity): the panel fades the one
        /// out and the other in at once, and the page's text shows through both. A block that keeps its identity is dissolved in its layer.
        var swaps = 0
        var timeline: [String] = []
        var count = 0
    }

    static func judge(_ rec: Recorder, from settledAt: Int, over page: PageCapture) -> Judgement {
        var j = Judgement()
        let settled = rec.seen[settledAt]
        j.level = lumas(of: settled.snapshot, in: settled.lens, over: page).map { worstRestored(settled.rects, in: settled.lens, now: $0) } ?? 1
        for i in rec.seen.indices where i > settledAt {
            let before = rec.seen[i - 1], after = rec.seen[i]
            // The overlay's pixels of the lens as it is now, of both snapshots.
            let wasMask = changed(by: before.snapshot, in: after.lens, over: page), hasMask = changed(by: after.snapshot, in: after.lens, over: page)
            let was = wasMask.mask.filter { $0 }.count, has = hasMask.mask.filter { $0 }.count
            let back = lumas(of: after.snapshot, in: after.lens, over: page).map { worstRestored(before.rects, in: after.lens, now: $0) } ?? 1
            let ink = was == 0 ? 1 : Double(has) / Double(was)
            j.count += 1
            if back > j.worstBack { j.worstBack = back; j.worstAt = i }
            if back >= 0.6 { j.englishOver += 1 }
            if ink < j.worstInk { j.worstInk = ink; j.worstInkAt = i }
            if after.inLens == 0, before.inLens > 0, j.emptyAt == 0 { j.emptyAt = i }
            let kept = Set(after.snapshot.blocks.map(\.id)), had = Set(before.snapshot.blocks.map(\.id))
            let gone = zip(before.snapshot.blocks, before.rects).filter { !kept.contains($0.0.id) && $0.1.intersects(after.lens) }.map(\.1)
            let came = zip(after.snapshot.blocks, after.rects).filter { !had.contains($0.0.id) }.map(\.1)
            if gone.contains(where: { g in came.contains { c in let i = g.intersection(c); return !i.isNull && i.width * i.height >= 0.5 * g.width * g.height } }) { j.swaps += 1 }
            j.timeline.append(String(format: "%6.0f ms v%-3d blocks %2d in lens %2d texts %2d untranslated %2d page text back %.2f ink %5d→%5d lens %.0f×%.0f%@", after.time * 1000, after.snapshot.version,
                                     after.snapshot.blocks.count, after.inLens, after.snapshot.texts.count, after.snapshot.texts.filter { $0.translation == nil }.count,
                                     back, was, has, after.lens.width, after.lens.height, rec.marks.filter { $0.time <= after.time && $0.time > before.time }.map { "  <- " + $0.label }.joined()))
        }
        return j
    }

    static func run(_ model: AppModel) async -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") resize hold: \(what)" + (ok ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
        // 120 ms: long enough that a block waiting for its translation is seen waiting (the mock answers after it), short enough to wait for.
        guard let mock = ContextChecks.Mock(mode: "slow:120"), let page = renderPage() else {
            check("the mock server starts and the page is drawn", false)
            return failed
        }
        defer { mock.stop() }
        // For a screen recording of the run (tools/lens-hold): the page as it is drawn, beside the timeline.
        if let path = ProcessInfo.processInfo.environment["MWOYEO_HOLD_TIMELINE"], let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path + ".page.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, page, nil)
            CGImageDestinationFinalize(dest)
        }
        let engine = EngineConfig(id: UUID(), name: "Hold", kind: .openAICompatible(baseURL: mock.base.appendingPathComponent("v1"), model: "m1", thinking: .off, extraHeaders: [:]),
                                  context: nil)
        var settings = ContextChecks.settings(nil)
        settings.engines = [engine]
        settings.customEngineID = engine.id
        settings.settleDelay = 0.15
        let layout = DisplayLayout.current
        let pageRect = CGRect(origin: pageOrigin, size: pageSize)
        let capture = PageCapture(page: page, display: layout.display(showing: pageRect) ?? pageRect)

        // The page on the screen where the lens is, so that a screen recording of this run (tools/lens-fit style) sees what a person would.
        let window = NSWindow(contentRect: ScreenGeometry.appKitRect(fromQuartz: pageRect), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = NSImageView(image: NSImage(cgImage: page, size: pageSize))
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }

        let first = CGRect(x: pageOrigin.x + 10, y: pageOrigin.y + 10, width: 420, height: 290)
        // No app under the lens, as FitChecks has it: the window of the desktop behind the page (another app, another round's check) is the
        // reader's context, and a drop whose centre lands over another one read the page again from nothing (holdfix117, addendum A1). The
        // step "over another app" below changes it on purpose.
        let noApp: @MainActor (RegionConfig) -> LensWatch.Read? = { _ in nil }
        let session = RegionSession(config: RegionConfig(name: "Hold", rect: first), settings: settings, translator: ContextChecks.service(settings),
                                    inpainter: nil, capturer: capture, recovery: LensRobustChecks.fast, appUnderLens: noApp)
        let rec = Recorder()
        let t0 = ProcessInfo.processInfo.systemUptime
        func now() -> Double { ProcessInfo.processInfo.systemUptime - t0 }
        session.snapshotObserver = { [unowned session] s in rec.seen.append(Seen(time: now(), lens: session.config.rect, snapshot: s)) }
        _ = Trace.takeCounts()
        await session.start()
        guard let lens = session.lensWindow as? RegionFrameWindow else {
            check("the lens window is the lens", false)
            await session.stop()
            return failed
        }

        /// Quiet: the pipeline idle, no snapshot for `quiet` seconds (the settle delay is 0.15 s below, so a pass that is coming has begun by then),
        /// and `ready` holds of the last one. A drop makes a snapshot at once, so the wait counts from it. With `frames`, also: a capture that
        /// changed since `since` (the capture and the uptime at the step's start) has had its frame handed on, and no frame came for `quiet`
        /// seconds, so that a pass the frame starts is counted in its step (holdfix117 A2: the frame of a shrink came after the quiet snapshots,
        /// and the read of every row it started was counted in no step).
        func settle(_ s: RegionSession, _ r: Recorder, quiet: Double = 0.6, limit: Double = 240, frames: PageCapture? = nil,
                    since: (capture: CGRect, time: Double)? = nil, ready: (Seen) -> Bool) async -> Bool {
            let began = now()
            while now() - began < limit {
                try? await Task.sleep(for: .milliseconds(50))
                if let frames, let since {
                    let handed = frames.handedOn, uptime = ProcessInfo.processInfo.systemUptime
                    let fed = s.captureRect == since.capture || handed.contains { $0.rect == s.captureRect && $0.time >= since.time }
                    guard fed, uptime - (handed.last?.time ?? 0) >= quiet else { continue }
                }
                if let last = r.seen.last, s.activity == .idle, now() - max(last.time, began) >= quiet, ready(last) { return true }
            }
            return false
        }
        /// The bottom-right corner dragged to `size` in a few steps, then dropped, as the mouse does it. One step is a jump: Fit to Column and its
        /// Undo put the lens at its new size in one move.
        func drag(_ session: RegionSession, _ lens: RegionFrameWindow, _ rec: Recorder, to size: CGSize, label: String, steps: Int = 8) async {
            rec.marks.append((now(), label))
            let from = session.config.rect
            for i in 1...steps {
                let f = CGFloat(i) / CGFloat(steps)
                let r = CGRect(x: from.minX, y: from.minY, width: (from.width + (size.width - from.width) * f).rounded(), height: (from.height + (size.height - from.height) * f).rounded())
                let ak = ScreenGeometry.appKitRect(fromQuartz: r)
                lens.setRegion(ak)
                lens.onResize?(ak)
                try? await Task.sleep(for: .milliseconds(16))
            }
            rec.marks.append((now(), label + " dropped"))
            lens.onCommit?()
        }

        /// The lens dragged by its pill `dx` points to the right in a few steps, then dropped.
        func slide(_ session: RegionSession, _ lens: RegionFrameWindow, _ rec: Recorder, by dx: CGFloat, label: String, steps: Int = 8) async {
            rec.marks.append((now(), label))
            let from = session.config.rect
            for i in 1...steps {
                let ak = ScreenGeometry.appKitRect(fromQuartz: from.offsetBy(dx: (dx * CGFloat(i) / CGFloat(steps)).rounded(), dy: 0))
                lens.setRegion(ak)
                lens.onMove?(ak)
                try? await Task.sleep(for: .milliseconds(16))
            }
            rec.marks.append((now(), label + " dropped"))
            lens.onCommit?()
        }

        let ready = await settle(session, rec) { $0.inLens >= 3 && $0.translated }
        check("the lens reads and translates its page first (blocks drawn, every text in the lens translated)", ready, "snapshots \(rec.seen.count)")
        guard ready else {
            await session.stop()
            return failed
        }
        let settledAt = rec.seen.count - 1
        let steps: [(label: String, size: CGSize)] = [
            ("grow a little", CGSize(width: 450, height: 310)), ("grow inside the margin", CGSize(width: 520, height: 350)),
            ("shrink", CGSize(width: 330, height: 220)), ("grow past the margin", CGSize(width: 760, height: 520)),
            ("shrink to the start", CGSize(width: 420, height: 290))]
        var unsettled: [String] = []
        var total: [String: Int] = [:], passesIn: [String: Int] = [:]
        func drain() -> [String: Int] {
            let c = Trace.takeCounts()
            for (k, v) in c { total[k, default: 0] += v }
            return c
        }
        _ = drain()
        for (label, size) in steps {
            let since = (session.captureRect, ProcessInfo.processInfo.systemUptime)
            await drag(session, lens, rec, to: size, label: label)
            if await settle(session, rec, frames: capture, since: since, ready: { $0.inLens >= 1 && $0.translated }) == false { unsettled.append(label) }
            passesIn[label] = drain()["pass.read", default: 0]
        }
        check("after every resize the lens reads its page again and every text in it is translated", unsettled.isEmpty, "not settled after: \(unsettled)")
        // A lens made smaller shows what the blocks already describe: nothing is read again (film4 F8: every narrowing of a game lens's overscan
        // was a whole read of 3 to 5 s, in the way of the next line of text).
        let readAgain = ["shrink", "shrink to the start"].reduce(0) { $0 + passesIn[$1, default: 0] }
        check("a lens that shrinks to inside what was read is not read again (\(readAgain) passes)", readAgain == 0,
              "passes per step: \(steps.map { "\($0.label) \(passesIn[$0.label, default: 0])" })")

        // The lens dropped where its centre is over another app's window (holdfix117, A1: a lens across two windows): the reader's context
        // changes, the page does not. The page is read again for that app's reader, and what is drawn stays meanwhile (the snapshots below).
        session.appUnderLens = { _ in LensWatch.Read(bundleID: "dev.midagedev.mwoyeo.checks.other", appName: "Other", title: "") }
        rec.marks.append((now(), "over another app"))
        lens.onCommit?()
        // The pipeline says it read again (`reader.context_reread`), not started over: a pass alone may be another one's (A2).
        var overOther = 0, readsAgain = 0
        func countOverOther() {
            let c = drain()
            overOther += c["pass.read", default: 0]
            readsAgain += c["reader.context_reread", default: 0]
        }
        let rereadBy = now() + 240
        while overOther == 0, now() < rereadBy {
            try? await Task.sleep(for: .milliseconds(50))
            countOverOther()
        }
        let reread = await settle(session, rec) { $0.inLens >= 1 && $0.translated }
        countOverOther()
        check("a drop over another app's window reads the page again for that app (\(readsAgain) read(s) again, \(overOther) pass(es)) and the lens ends translated",
              reread && readsAgain >= 1 && overOther >= 1, "settled \(reread)")

        // Snapshot by snapshot, from the settled one: what the lens had drawn stays drawn. A translation that is replaced by the one the engine
        // answers (the old one is shown meanwhile) changes the pixels of its block, and is not a block gone: the page's own text must not come
        // back under any block of the snapshot before (`worstRestored`, the level the settled lens shows is the control).
        // 2026-10-22 (hold117): this replaces "the pixels each block changed are still changed (worst >= 0.5)", which read a replaced translation
        // as a block gone (0.46 in one of six runs under load, where the engine answered between two snapshots); derivation: translated lens 0.35,
        // a block gone 0.74 to 1 (tools/lens-hold README), the limit 0.6 between them as luma.py has it. FAIL-first on the base: see the design doc.
        let j = judge(rec, from: settledAt, over: capture)
        if let path = ProcessInfo.processInfo.environment["MWOYEO_HOLD_TIMELINE"] {
            let marks = rec.marks.map { String(format: "%6.0f ms mark %@", $0.time * 1000, $0.label) }
            try? (j.timeline + marks).joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
        _ = drain()
        let counts = total
        check("the settled lens draws over the page's text: its blocks leave \(String(format: "%.2f", j.level)) of it dark (translated about 0.35, the page's own text 1)", j.level < 0.6)
        check("no snapshot of the resize brings the page's own text back under a block the snapshot before drew: of the page's text under each such block the most that is dark again is \(String(format: "%.2f", j.worstBack)) (\(j.englishOver) of \(j.count) snapshots)",
              j.worstBack < 0.6, "snapshot \(j.worstAt) of \(rec.seen.count), \(j.timeline.indices.contains(j.worstAt - settledAt - 1) ? j.timeline[j.worstAt - settledAt - 1] : "")")
        check("and no snapshot changes fewer pixels of the lens than the one before it (worst \(String(format: "%.2f", j.worstInk)))", j.worstInk >= 0.7,
              "snapshot \(j.worstInkAt) of \(rec.seen.count)")
        check("the lens never shows no drawn block where it had some", j.emptyAt == 0, "snapshot \(j.emptyAt)")
        check("the pipeline counts no block that was drawn and then left undrawn (overlay.blanked)", counts["overlay.blanked", default: 0] == 0, "\(counts["overlay.blanked", default: 0])")
        check("and no snapshot swaps a drawn block of the lens for another that stands over it (\(j.swaps) of \(j.count) snapshots): the panel would fade both at once", j.swaps == 0,
              "swaps \(j.swaps)")

        await session.stop()

        // A pass that a resize interrupts (round hold117, H1: game117's film defect F8). The first read of a lens is under way, from the
        // frame the capture had; the lens is resized, and the capture with it, while the reader is still at work, and the stream delivers no
        // frame of the new capture (`withholdFrames`): the page can only be shown by that read. It is not thrown away: its blocks are carried to the
        // new capture (`Move.resized`), where the page is what it was.
        _ = Trace.takeCounts()
        let capture2 = PageCapture(page: page, display: capture.display)
        let session2 = RegionSession(config: RegionConfig(name: "Hold", rect: first), settings: settings, translator: ContextChecks.service(settings),
                                     inpainter: nil, capturer: capture2, recovery: LensRobustChecks.fast, appUnderLens: noApp)
        let rec2 = Recorder()
        session2.snapshotObserver = { [unowned session2] s in rec2.seen.append(Seen(time: now(), lens: session2.config.rect, snapshot: s)) }
        await session2.start()
        var reading = false
        if let lens2 = session2.lensWindow as? RegionFrameWindow {
            let until = now() + 30
            while session2.activity != .reading, now() < until { try? await Task.sleep(for: .milliseconds(5)) }
            reading = session2.activity == .reading
            capture2.withholdFrames = true
            let grown = ScreenGeometry.appKitRect(fromQuartz: CGRect(x: first.minX, y: first.minY, width: first.width + 40, height: first.height + 30))
            lens2.setRegion(grown)
            lens2.onResize?(grown)
            lens2.onCommit?()
        }
        let landed = await settle(session2, rec2) { $0.inLens >= 3 && $0.translated }
        let passes = Trace.takeCounts()
        // Where the page's paragraphs are on the screen, a little larger: a block's patch carries the margin of its erased ring.
        let onPage = paragraphs.map { $0.0.offsetBy(dx: pageOrigin.x, dy: pageOrigin.y).insetBy(dx: -14, dy: -14) }
        let firstDrawn = rec2.seen.first { $0.snapshot.blocks.count >= 3 }
        let astray = firstDrawn.map { f in f.rects.filter { r in !onPage.contains { $0.contains(CGPoint(x: r.midX, y: r.midY)) } }.count } ?? -1
        check("the first read is under way when the lens is resized and no frame of the new capture comes: the page is drawn and translated all the same", reading && landed,
              "reading \(reading) landed \(landed)")
        check("a pass that the resize interrupted is carried to the new capture, not thrown away (pass.rebased \(passes["pass.rebased", default: 0]), \(passes["pass.read", default: 0]) pass(es))",
              passes["pass.rebased", default: 0] >= 1 && passes["pass.read", default: 0] == 1)
        check("and its blocks sit on the paragraphs of the page in the new capture (\(astray) of \(firstDrawn?.rects.count ?? 0) off)", astray == 0, "snapshot of the first blocks: \(firstDrawn.map { "\($0.rects)" } ?? "none")")
        await session2.stop()

        // Fit to Column and its Undo (round fit117; the user's report that a translated lens turned English when it was fitted, and for seconds
        // after its Undo). Both put the lens at its new size in one move. This lens is narrow, and its capture ends inside the first column and
        // short of the second: the paragraphs that run past it are cut at the capture's edge. The Fit's capture reaches the page's right edge
        // and reads them longer, so each of them is a new block whose text the engine has not translated, and the Undo takes the capture back
        // to what the blocks already describe. `which` names the lens in the lines of the second run of these steps below (empty: these).
        func fitUndoMove(_ narrow: CGRect, _ which: String, timeline suffix: String) async {
            _ = Trace.takeCounts()
            let capture3 = PageCapture(page: page, display: capture.display)
            let session3 = RegionSession(config: RegionConfig(name: "Hold", rect: narrow), settings: settings, translator: ContextChecks.service(settings),
                                         inpainter: nil, capturer: capture3, recovery: LensRobustChecks.fast, appUnderLens: noApp)
            let rec3 = Recorder()
            session3.snapshotObserver = { [unowned session3] s in rec3.seen.append(Seen(time: now(), lens: session3.config.rect, snapshot: s)) }
            await session3.start()
            let lens3 = session3.lensWindow as? RegionFrameWindow
            let first3 = await settle(session3, rec3) { $0.inLens >= 3 && $0.translated }
            if let lens3, first3 {
                let from = rec3.seen.count - 1
                var fit: [String: Int] = [:], undo: [String: Int] = [:]
                func gather(into counts: inout [String: Int]) { for (k, v) in Trace.takeCounts() { counts[k, default: 0] += v } }
                _ = Trace.takeCounts()
                await drag(session3, lens3, rec3, to: CGSize(width: 860, height: narrow.height), label: "fit", steps: 1)
                // The read of what the Fit uncovered has begun before anything else is waited for: a machine that is slow to deliver the frame of
                // the new capture does not make the Undo come first.
                let readBy = now() + 240
                while fit["pass.read", default: 0] == 0, now() < readBy {
                    try? await Task.sleep(for: .milliseconds(50))
                    gather(into: &fit)
                }
                let fitted = await settle(session3, rec3) { $0.inLens >= 1 && $0.translated }
                gather(into: &fit)
                await drag(session3, lens3, rec3, to: narrow.size, label: "undo", steps: 1)
                let undone = await settle(session3, rec3) { $0.inLens >= 1 && $0.translated }
                gather(into: &undo)
                // The lens is moved on, and the page is read again where it was uncovered and once more when the lens rests (the settled reading groups
                // the lines of a paragraph as the fast one did not): every text the lens held has its translation all the while.
                var move: [String: Int] = [:]
                await slide(session3, lens3, rec3, by: 220, label: "move")
                let readBy2 = now() + 240
                while move["pass.read", default: 0] == 0, now() < readBy2 {
                    try? await Task.sleep(for: .milliseconds(50))
                    gather(into: &move)
                }
                let moved = await settle(session3, rec3) { $0.inLens >= 1 && $0.translated }
                gather(into: &move)
                let j = judge(rec3, from: from, over: capture3)
                if let path = ProcessInfo.processInfo.environment["MWOYEO_HOLD_TIMELINE"] {
                    let marks = rec3.marks.map { String(format: "%6.0f ms mark %@", $0.time * 1000, $0.label) }
                    try? (j.timeline + marks).joined(separator: "\n").write(toFile: path + suffix, atomically: true, encoding: .utf8)
                }
                check(which + "Fit to Column reads what its capture uncovered, and the lens ends translated (\(fit["pass.read", default: 0]) pass(es), \(fit["render.carried", default: 0]) blocks carried a translation)",
                      fitted && fit["pass.read", default: 0] >= 1, "fitted \(fitted)")
                check(which + "the Undo takes the lens back and nothing is read again (\(undo["pass.read", default: 0]) passes)", undone && undo["pass.read", default: 0] == 0, "undone \(undone)")
                check(which + "moving the lens reads what it uncovered and the lens ends translated (\(move["pass.read", default: 0]) pass(es), \(move["render.carried", default: 0]) blocks carried a translation)",
                      moved && move["pass.read", default: 0] >= 1, "moved \(moved)")
                check(which + "no snapshot of the Fit, its Undo and the move brings the page's own text back under a block the snapshot before drew: the most that is dark again is \(String(format: "%.2f", j.worstBack)) (\(j.englishOver) of \(j.count) snapshots)",
                      j.worstBack < 0.6, "snapshot \(j.worstAt) of \(rec3.seen.count), \(j.timeline.indices.contains(j.worstAt - from - 1) ? j.timeline[j.worstAt - from - 1] : "")")
                let blanked = fit["overlay.blanked", default: 0] + undo["overlay.blanked", default: 0] + move["overlay.blanked", default: 0]
                check(which + "and the lens never shows no drawn block where it had some, and the pipeline counts no block drawn and then left undrawn", j.emptyAt == 0 && blanked == 0,
                      "snapshot \(j.emptyAt), blanked \(blanked)")
                check(which + "and no snapshot swaps a drawn block of the lens for another that stands over it (\(j.swaps) of \(j.count) snapshots)", j.swaps == 0, "swaps \(j.swaps)")
            } else {
                check(which + "the lens of the Fit reads and translates its page first", false, "lens \(lens3 != nil) read \(first3)")
            }
            await session3.stop()
        }
        await fitUndoMove(CGRect(x: first.minX, y: first.minY, width: 280, height: first.height), "", timeline: ".fit")
        // The same steps on a lens whose capture ends between the columns (holdfix117, 2026-10-23). The 280 lens above draws its title alone on
        // main 7c58403: its capture (page x -74…374) ends inside the first column (x 20…400), and main's side-cut rule (5cad301,
        // `CaptureEdge.cutAtSides`, docs/design/recognition.md §16.1) leaves a column as written when three of its lines reach a side of the
        // capture (§16.2 item 4, round edges117). This one keeps the column whole: margins 0.3 × size (`Overscan.margins`) put its capture at page
        // x -86…426, between the columns (400, 460), where the two lines of the first long paragraph alone reach its side; the capture's rows
        // -83…413 end above the second long paragraph (420), and the lens's rows 10…320 hold the first line of the first one (310). Its Fit
        // carries the cut paragraph, and its move, whose capture cuts both columns, reads nothing of them again: the drawn blocks stay
        // (`TranslationCarry.unread`; FAIL-first on main: the page's text back at 1.00 after the move).
        await fitUndoMove(CGRect(x: first.minX, y: first.minY, width: 320, height: 310), "a lens whose capture ends between the columns: ", timeline: ".fit2")
        return failed
    }
}
#endif
