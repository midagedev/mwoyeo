#if !MAS
import AppKit
import CoreText
import MwoyeoCore

/// The checks of games and video (round game117, 2026-10-22), run by `--capture-ui … check-logic` and alone by `game-checks` (PASS/FAIL lines):
///
/// - a part of a lens marked not to be read is not read: a picture of two lines is read through the pipeline with a region over one of them, the
///   line is absent from what was read, and clearing the region reads it again (real Vision through the reader host, a translation engine that
///   is not there so that Apple Translation, which needs the main queue, is never asked);
/// - a scene that moves beside the text does not make the pipeline read again, and the text changing in the same frame does (`ReadWatch` wired
///   into `RegionPipeline`; the rule itself is `ReadWatchTests`);
/// - the lens keeps its regions and its recent-lines option (menu rows that answer a press, the saved lens, a drag that is too small or outside),
///   the recent lines stack from what the lens read, and a region placed with the keyboard;
/// - the marker's hint pills stand clear of the lens and inside the screen's visible frame (`marker-hint-checks` runs only this one: it needs no window).
///
/// Every check was seen to FAIL first on a stub of what it checks (the lines are in the round's report).
@MainActor
enum GameChecks {
    static func run(_ model: AppModel) async -> Int {
        let check = Check()
        await ignoredRegionReading(check)
        await movingBand(check)
        await movingBandDuringAPass(check)
        await lensOptions(model, check)
        await recentLines(model, check)
        keyboardMarker(check)
        markerHints(check)
        await markerFocus(check)
        settings(check)
        return check.failed
    }

    /// The PASS/FAIL lines of the checks, and how many failed.
    final class Check {
        private(set) var failed = 0
        func callAsFunction(_ what: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") game: \(what)" + (ok ? "" : " [\(detail())]"))
            if !ok { failed += 1 }
        }
    }

    // MARK: Scenes

    nonisolated static let size = CGSize(width: 900, height: 360)
    nonisolated static let capture = CGRect(origin: .zero, size: size)

    /// A picture: a white page with each line of text at (40, y) and, when `band` is a phase, a texture of cells that moves 13 points a phase
    /// along the top (a game's background; random cells, so no shift of it is a scroll).
    nonisolated static func picture(_ lines: [(String, CGFloat)], band: Int? = nil) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(capture)
        if let phase = band {
            let cell = 16, shift = phase * 13
            for row in 0..<7 {
                for col in -1...(w / cell + 1) {
                    let x = col * cell + shift % cell, u = col - shift / cell
                    let v = Double((u &* 73_856_093 ^ row &* 19_349_663) & 0xFF) / 255
                    ctx.setFillColor(CGColor(gray: 0.35 + 0.55 * v, alpha: 1))
                    ctx.fill(CGRect(x: x, y: 20 + row * cell, width: cell, height: cell))
                }
            }
        }
        let font = CTFontCreateUIFontForLanguage(.system, 24, nil)!
        for (text, y) in lines {
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                             NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            var ascent: CGFloat = 0
            _ = CTLineGetTypographicBounds(line, &ascent, nil, nil)
            ctx.textPosition = CGPoint(x: 40, y: y + ascent)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }

    nonisolated static func frame(_ image: CGImage?, at time: TimeInterval, rect: CGRect = capture) -> CapturedFrame? {
        guard let image, let rgba = RGBAImage(cgImage: image), let readable = rgba.cgImage else { return nil }
        let gray = rgba.withBGRA { GrayImage(bgra: $0, width: rgba.width, height: rgba.height, bytesPerRow: rgba.width * 4, step: 4) }
        return CapturedFrame(image: readable, gray: gray, grayStep: 4, scale: 1, rect: rect, time: time)
    }

    /// The frame, stamped as it is fed (a capture stamps a frame as it takes it).
    nonisolated static func stamped(_ f: CapturedFrame) -> CapturedFrame {
        CapturedFrame(image: f.image, gray: f.gray, grayStep: f.grayStep, scale: f.scale, rect: f.rect, time: ProcessInfo.processInfo.systemUptime)
    }

    /// A pipeline over the whole picture that reads as the lens does and translates through an engine that is not there (nothing is sent).
    static func pipeline(_ reads: ReadCounter, mode: RenderMode = .seamless, readHold: Double = ReadWatch.standardHold,
                         onSnapshot: @escaping @Sendable (OverlaySnapshot) -> Void = { _ in }) async -> RegionPipeline {
        var s = ContextChecks.settings(ContextChecks.engine("openai", base: URL(string: "http://127.0.0.1:1")!))
        s.renderMode = mode
        s.paragraphReader = .lineGrouping
        s.useInpaintingModel = false
        let p = RegionPipeline(options: PipelineOptions(s), capture: capture, translator: ContextChecks.service(s), inpainter: nil, readHold: readHold, onSnapshot: onSnapshot)
        await p.setReadHandler { _ in reads.read() }
        await p.setVisible(capture)
        return p
    }

    /// What the pipeline read, one string, lower case.
    private static func read(_ p: RegionPipeline) async -> String {
        await p.debugState().blocks.map(\.0).joined(separator: " ").lowercased()
    }

    /// Counts the reads a pipeline reports; a wait ends at the read, and `bound` only stops one that never comes (a cold compile takes a minute).
    final class ReadCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        /// Called on every read, from the pipeline's own call (a check that needs something to happen while a pass is running).
        var onRead: (@Sendable () -> Void)?
        func read() { lock.withLock { n += 1 }; onRead?() }
        func wait(beyond seen: Int, bound: Double = 150) async -> Bool {
            let until = ProcessInfo.processInfo.systemUptime + bound
            while count <= seen, ProcessInfo.processInfo.systemUptime < until { try? await Task.sleep(for: .milliseconds(10)) }
            return count > seen
        }
    }

    // MARK: A region that is not read

    private static func ignoredRegionReading(_ check: Check) async {
        let top = "Mission objective: find the silver key", bottom = "Press the green button to open the door"
        let image = picture([(top, 40), (bottom, 250)])
        // The region lies over the bottom line: 62 % to 84 % of the lens's height, nearly all its width.
        let region = UnitRect(x: 0.03, y: 0.62, width: 0.94, height: 0.22)
        let t0 = ProcessInfo.processInfo.systemUptime

        let plain = ReadCounter(), p0 = await pipeline(plain)
        await p0.ingest(frame(image, at: t0)!)
        let readPlain = await plain.wait(beyond: 0)
        await p0.idle()
        let seenPlain = await read(p0)
        check("with no region both lines of the picture are read (the control)", readPlain && seenPlain.contains("mission") && seenPlain.contains("button"), seenPlain)

        let marked = ReadCounter(), p1 = await pipeline(marked)
        await p1.setIgnored([region])
        await p1.ingest(frame(image, at: t0)!)
        let readMarked = await marked.wait(beyond: 0)
        await p1.idle()
        let seenMarked = await read(p1)
        check("with a region over the bottom line only the top line is read: the line is not in the read set",
              readMarked && seenMarked.contains("mission") && !seenMarked.contains("button") && !seenMarked.contains("door"), seenMarked)

        // The region goes: the line is read again, from the frame the pipeline already has (no new frame comes of a screen that did not change).
        let before = marked.count
        await p1.setIgnored([])
        let readAgain = await marked.wait(beyond: before)
        await p1.idle()
        let seenAgain = await read(p1)
        check("clearing the region reads the line again", readAgain && seenAgain.contains("button") && seenAgain.contains("mission"), seenAgain)

        // A region over the top line, set after both were read: its text goes, the other stays.
        let before2 = marked.count
        await p1.setIgnored([UnitRect(x: 0.03, y: 0.06, width: 0.94, height: 0.2)])
        let readLate = await marked.wait(beyond: before2)
        await p1.idle()
        let seenLate = await read(p1)
        check("a region set after the text was read takes it out of the read set at the next read", readLate && !seenLate.contains("mission") && seenLate.contains("button"), seenLate)
    }

    // MARK: A scene that moves beside the text

    private static func movingBand(_ check: Check) async {
        let box = 250.0
        let first = "Press the green button to open the door", second = "Take the silver key from the old table"
        let counter = ReadCounter(), p = await pipeline(counter)
        // Every picture is made before the first is fed, and each frame is stamped as it is fed: the frames of the scene follow each other at
        // once, as a scene that never rests does, and nothing here waits on the clock (a tile held for 0.4 s rests only after the last frame).
        let scene = (1...12).map { frame(picture([(first, box)], band: $0), at: 0)! }
        let change = frame(picture([(second, box)], band: 13), at: 0)!
        func fed(_ f: CapturedFrame) -> CapturedFrame { stamped(f) }
        await p.ingest(fed(frame(picture([(first, box)], band: 0), at: 0)!))
        let started = await counter.wait(beyond: 0)
        await p.idle()
        let baseline = counter.count
        let seenFirst = await read(p)
        check("the text under a moving scene is read", started && seenFirst.contains("button"), seenFirst)

        // Twelve frames in which only the scene moves, in the band above the text.
        for f in scene { await p.ingest(fed(f)) }
        await p.idle()
        check("twelve frames of a scene that moves above the text make no new read (\(counter.count - baseline) of them did)", counter.count == baseline, "\(counter.count - baseline) reads")

        // The text changes in the same frame the scene moves on: read at once, whatever the scene does.
        await p.ingest(fed(change))
        let read2 = await counter.wait(beyond: baseline)
        await p.idle()
        let seenSecond = await read(p)
        check("the text changing while the scene moves is read, and read as the new text", read2 && seenSecond.contains("silver") && !seenSecond.contains("button"), seenSecond)
    }

    /// Until nothing is running or waiting on a timer to run (`idle` returns when a pass is not running; a look the timer is to take is still to come).
    private static func quiet(_ p: RegionPipeline, bound: Double = 150) async {
        let until = ProcessInfo.processInfo.systemUptime + bound
        while await p.debugState().busy, ProcessInfo.processInfo.systemUptime < until { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// Until nothing is running and no tile away from the text waits to rest: `quiet` is true between a read and the timer that reads what rests next.
    private static func rested(_ p: RegionPipeline, bound: Double = 150) async {
        let until = ProcessInfo.processInfo.systemUptime + bound
        while ProcessInfo.processInfo.systemUptime < until {
            let busy = await p.debugState().busy, holds = await p.holdsTiles()
            if !busy && !holds { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Runs `block` on the next snapshot the pipeline publishes, once (from inside the pipeline's own call, so it holds the pipeline's actor).
    private final class OnNextSnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var armed: (@Sendable () -> Void)?
        func arm(_ block: @escaping @Sendable () -> Void) { lock.withLock { armed = block } }
        func snapshot(_ s: OverlaySnapshot) {
            let block = lock.withLock { () -> (@Sendable () -> Void)? in defer { armed = nil }; return armed }
            block?()
        }
    }

    /// A pass that holds the pipeline for longer than the watch's hold, while the scene beside the text goes on moving: the frames that came in
    /// during the pass go stale for the hold while it is held, and the frames that came in behind it count before a tile is judged to rest, so
    /// the scene does not rest on the stamp of a frame from before the end of the pass and is not read at the end of every pass. The hold is
    /// injected (0.6 s) and the pass is held for 0.8 s from inside its snapshot, as a long erase holds it; a thread feeds the scene (a frame
    /// every 10 ms, each in a task of its own, as a capture does) from the start of the pass until the reads are counted, 60 frames made after the
    /// pass was let go have been counted. The reads counted are those up to then: the scene has not rested (only a gap of 0.6 s between two frames would make it).
    static func movingBandDuringAPass(_ check: Check) async {
        let box = 250.0, hold = 0.6
        let first = "Press the green button to open the door", second = "Take the silver key from the old table"
        let counter = ReadCounter(), gate = OnNextSnapshot(), feed = Feed()
        let p = await pipeline(counter, readHold: hold, onSnapshot: { gate.snapshot($0) })
        await p.ingest(stamped(frame(picture([(first, box)], band: 0), at: 0)!))
        let started = await counter.wait(beyond: 0)
        await quiet(p)
        // Three frames of the scene, a pause longer than the hold between the second and the third (a slow machine makes one by itself), then it
        // stops: what rests is read, and read again once the scene has gone on and rested; the reads are counted from where nothing is left to rest.
        let afterFirst = counter.count
        for k in 1...3 {
            await p.ingest(stamped(frame(picture([(first, box)], band: k), at: 0)!))
            if k == 2 { try? await Task.sleep(for: .seconds(hold + 0.1)) }
        }
        let restRead = await counter.wait(beyond: afterFirst, bound: 10)
        await rested(p)
        let baseline = counter.count
        check("a scene that stops after a few frames is read when it has been still for the hold", started && restRead && baseline > afterFirst, "\(baseline - afterFirst) reads")
        let scene = (5...44).map { frame(picture([(second, box)], band: $0), at: 0)! }
        gate.arm {
            Thread.sleep(forTimeInterval: 0.8)
            feed.letGo()
        }
        await p.ingest(stamped(frame(picture([(second, box)], band: 4), at: 0)!))
        feed.start(p, scene)
        let readSecond = await counter.wait(beyond: baseline)
        let until = ProcessInfo.processInfo.systemUptime + 150
        while !feed.isLetGo || feed.count < feed.letGoAt + 60, ProcessInfo.processInfo.systemUptime < until { try? await Task.sleep(for: .milliseconds(5)) }
        let during = counter.count - baseline
        let stall = feed.stall
        feed.stop()
        let backlog = feed.backlog
        print(String(format: "game-note: the scene after the pass: longest gap %.0f ms, longest count %.0f ms (hold %.0f ms), %d read; %d frames waited behind the pass, counted in %.0f ms",
                     stall.gap * 1000, stall.lag * 1000, hold * 1000, during, backlog.frames, (backlog.drain ?? .nan) * 1000))
        check("a pass that outlasts the hold is not followed by a read of the scene while the scene goes on (\(during) read: the new text)",
              started && readSecond && during == 1, "\(during) reads, longest gap \(Int(stall.gap * 1000)) ms, longest count \(Int(stall.lag * 1000)) ms")
        // The scene stops; what has rested by then is read, and the pipeline goes quiet with the new text.
        await quiet(p)
        let seen = await read(p)
        check("and the text of the pass is what was read", seen.contains("silver") && !seen.contains("button"), seen)
    }

    /// The frames of a moving scene, fed to a pipeline from a thread a frame every 10 ms until stopped (the pictures go round).
    private final class Feed: @unchecked Sendable {
        private let lock = NSLock()
        private var created = 0, ingested = 0, stopped = false, passLetGo: Int?
        private var letGoTime: Double?, backlogAtLetGo = 0, drainedAt: Double?
        /// The frames stamped after the pass was let go: when each was stamped and when the pipeline had counted it.
        private var after: [(stamp: Double, done: Double)] = []
        var count: Int { lock.withLock { ingested } }
        var isLetGo: Bool { lock.withLock { passLetGo != nil } }
        /// How many frames had been made when the pass was let go: the frames that waited behind it are among them.
        var letGoAt: Int { lock.withLock { passLetGo ?? 0 } }
        func letGo() { lock.withLock { passLetGo = created; letGoTime = ProcessInfo.processInfo.systemUptime; backlogAtLetGo = created - ingested } }
        /// The frames that waited behind the pass when it was let go, and how long the pipeline took to count them (nil: not yet).
        var backlog: (frames: Int, drain: Double?) { lock.withLock { (backlogAtLetGo, drainedAt.flatMap { d in letGoTime.map { d - $0 } }) } }
        /// What the machine did to the scene after the pass: the longest time between two frames, and the longest a frame took to be counted.
        /// A scene counts as one that goes on only while both stay under the watch's hold (a gap of the hold is a scene that stopped).
        var stall: (gap: Double, lag: Double) {
            lock.withLock {
                let frames = after.sorted { $0.stamp < $1.stamp }
                let gap = zip(frames, frames.dropFirst()).map { $1.stamp - $0.stamp }.max() ?? 0
                return (gap, frames.map { $0.done - $0.stamp }.max() ?? 0)
            }
        }
        func stop() { lock.withLock { stopped = true } }
        func start(_ p: RegionPipeline, _ frames: [CapturedFrame]) {
            Thread.detachNewThread { [self] in
                var k = 0
                while !lock.withLock({ stopped }) {
                    let source = frames[k % frames.count]
                    lock.withLock { created += 1 }
                    // Stamped when the task runs, as a capture stamps a frame as it takes it: a task a loaded machine is slow to start has
                    // not taken its frame yet (a frame stamped before it waits would be old when it comes in, and the check would measure
                    // the machine and not the pipeline).
                    Task {
                        let f = stamped(source)
                        await p.ingest(f)
                        let done = ProcessInfo.processInfo.systemUptime
                        lock.withLock {
                            ingested += 1
                            if let g = passLetGo, drainedAt == nil, ingested >= g { drainedAt = done }
                            if let t = letGoTime, f.time >= t { after.append((f.time, done)) }
                        }
                    }
                    k += 1
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
    }

    // MARK: The lens keeps its options

    private static func session(_ rect: CGRect, _ model: AppModel, settings: AppSettings = AppSettings()) -> RegionSession {
        RegionSession(config: RegionConfig(name: "Games", rect: rect), settings: settings, translator: model.translator, inpainter: nil,
                      capturer: FakeCapture(), recovery: LensRobustChecks.fast, appUnderLens: { _ in nil })
    }

    private static func lensOptions(_ model: AppModel, _ check: Check) async {
        let rect = CGRect(x: 120, y: 200, width: 320, height: 180)
        let s = session(rect, model)
        var saved: [RegionConfig] = []
        s.onConfigChange = { saved.append($0) }
        await s.start()
        func item(_ title: String) -> (index: Int, item: NSMenuItem)? {
            let menu = s.contextMenu()
            return menu.items.enumerated().first { $0.element.title == title }.map { ($0.offset, $0.element) }
        }
        func press(_ title: String) {
            if let row = item(title)?.item, row.isEnabled, let action = row.action { _ = NSApp.sendAction(action, to: row.target, from: row) }
        }
        check("the lens menu has Ignore Region…, Clear Ignored Regions and Keep Recent Lines",
              item(String(localized: "Ignore Region…"))?.item.isEnabled == true && item(String(localized: "Clear Ignored Regions")) != nil
              && item(String(localized: "Keep Recent Lines")) != nil)
        check("Clear Ignored Regions is dimmed while the lens has none", item(String(localized: "Clear Ignored Regions"))?.item.isEnabled == false)

        // A drag over part of the lens is a region of it, in fractions of the lens; one outside it, or too small, is none.
        s.addIgnoredRegion(dragged: CGRect(x: 200, y: 260, width: 80, height: 40))
        let want = UnitRect(x: 80.0 / 320, y: 60.0 / 180, width: 80.0 / 320, height: 40.0 / 180)
        let got = s.config.ignored.first
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-9 } ?? false }
        check("a drag inside the lens is kept as fractions of it", s.config.ignored.count == 1 && near(got?.x, want.x) && near(got?.y, want.y)
              && near(got?.width, want.width) && near(got?.height, want.height), "\(s.config.ignored)")
        check("and the lens is saved with it (the model's copy of the lens)", saved.last?.ignored == s.config.ignored)
        s.addIgnoredRegion(dragged: CGRect(x: 10, y: 10, width: 50, height: 50))
        s.addIgnoredRegion(dragged: CGRect(x: 200, y: 260, width: 3, height: 3))
        check("a drag outside the lens, or too small to be a region, is none", s.config.ignored.count == 1, "\(s.config.ignored.count)")
        check("Clear Ignored Regions is on now", item(String(localized: "Clear Ignored Regions"))?.item.isEnabled == true)

        // The saved lens: what a relaunch restores, and a lens saved before this has none of it.
        if let data = try? JSONEncoder().encode(s.config), let back = try? JSONDecoder().decode(RegionConfig.self, from: data) {
            check("the lens's regions and option survive being saved and read", back.ignored == s.config.ignored && back.keepsRecent == s.config.keepsRecent)
            var old = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            old["ignored"] = nil
            old["keepsRecent"] = nil
            let older = (try? JSONSerialization.data(withJSONObject: old)).flatMap { try? JSONDecoder().decode(RegionConfig.self, from: $0) }
            check("a lens saved before them has no region and keeps no lines", older?.ignored.isEmpty == true && older?.keepsRecent == false && older?.name == s.config.name)
            old["ignored"] = [["x": "a"], ["x": -3, "y": 0, "width": 9, "height": 9]]
            let mended = (try? JSONSerialization.data(withJSONObject: old)).flatMap { try? JSONDecoder().decode(RegionConfig.self, from: $0) }
            check("a saved region that is not sound is mended, never a lens lost", mended?.name == s.config.name && mended?.ignored.allSatisfy { $0.x >= 0 && $0.x + $0.width <= 1 } == true,
                  "\(String(describing: mended?.ignored))")
        } else {
            check("the lens can be saved and read", false)
        }

        // The menu rows are pressed as VoiceOver's press does: the item's action runs.
        press(String(localized: "Keep Recent Lines"))
        check("pressing Keep Recent Lines turns it on, marks the row and saves the lens", s.config.keepsRecent && item(String(localized: "Keep Recent Lines"))?.item.state == .on && saved.last?.keepsRecent == true)
        press(String(localized: "Keep Recent Lines"))
        check("and pressing it again turns it off", !s.config.keepsRecent && item(String(localized: "Keep Recent Lines"))?.item.state == .off && saved.last?.keepsRecent == false)
        press(String(localized: "Clear Ignored Regions"))
        check("pressing Clear Ignored Regions takes every region away and saves the lens", s.config.ignored.isEmpty && saved.last?.ignored.isEmpty == true
              && item(String(localized: "Clear Ignored Regions"))?.item.isEnabled == false)
        check("Ignore Region… is a row that acts when pressed", item(String(localized: "Ignore Region…"))?.item.action != nil && item(String(localized: "Ignore Region…"))?.item.target != nil)
        // More than a lens can use: the oldest go.
        for i in 0..<(IgnoredRegions.limit + 3) {
            s.addIgnoredRegion(dragged: CGRect(x: 120 + Double(i) * 20, y: 200, width: 12, height: 12))
        }
        check("a lens keeps at most \(IgnoredRegions.limit) regions", s.config.ignored.count == IgnoredRegions.limit, "\(s.config.ignored.count)")
        await s.stop()
    }

    // MARK: Recent lines

    private static func recentLines(_ model: AppModel, _ check: Check) async {
        let rect = CGRect(x: 520, y: 240, width: 320, height: 180)
        var settings = AppSettings()
        settings.recentLineCount = 3
        let s = session(rect, model, settings: settings)
        s.recentHold = 0   // the lines below come one look after another; the wait is the Core tests' (RecentLinesTests, injected times)
        await s.start()
        func say(_ lines: [String]) {
            s.received(OverlaySnapshot(version: 1, blocks: [], animated: false, origin: rect.origin,
                                       texts: lines.enumerated().map { BlockText(frame: CGRect(x: 40, y: 20 + CGFloat($0.offset) * 40, width: 200, height: 30), source: $0.element, translation: "t\($0.element)") }))
        }
        func kept() -> [String] { s.keptRecentLines.map(\.source) }
        say(["A"]); say(["B"])
        check("a lens that does not keep lines keeps none, and shows none", kept().isEmpty && s.recentPanelLines.isEmpty)
        s.setKeepsRecent(true)
        say(["C"]); say(["D"]); say(["E"])
        check("with the option on, the lines that left the lens are kept, newest first", kept() == ["D", "C", "B"], "\(kept())")
        check("what the lens shows is not in the stack", !kept().contains("E"))
        say(["F"])
        check("the stack holds the setting's number of lines: the oldest goes", kept() == ["E", "D", "C"], "\(kept())")
        check("the panel shows their translations in that order", s.recentPanelLines == ["tE", "tD", "tC"], "\(s.recentPanelLines)")
        let lens = ScreenGeometry.appKitRect(fromQuartz: rect)
        if let place = s.recentPanelPlace {
            check("the stack is outside the lens, never on the text in it", !place.frame.intersects(lens) && abs(place.frame.minX - lens.minX) < 0.5,
                  "\(place.frame) lens \(lens)")
            check("and on the side nearest the screen with room (below it when it fits)", place.below == (place.frame.maxY <= lens.minY), "below \(place.below)")
        } else {
            check("the stack has a panel", false)
        }
        // A line that comes back is on screen again: it leaves the stack.
        say(["D"])
        check("a line that returns to the lens leaves the stack", kept() == ["F", "E", "C"], "\(kept())")

        // The number is a setting.
        var fewer = settings
        fewer.recentLineCount = 1
        await s.update(settings: fewer)
        check("recentLineCount sets how many lines are kept", kept().count == 1, "\(kept())")
        // Show Original takes the stack off the screen without forgetting it.
        s.setTranslationsVisible(false)
        let hidden = s.recentPanelLines.isEmpty && kept().count == 1
        s.setTranslationsVisible(true)
        check("Show Original takes the stack off the screen and it comes back with the translations", hidden && s.recentPanelLines.count == 1, "\(hidden) \(s.recentPanelLines)")
        // Another language: the lines were translated another way.
        var other = fewer
        other.targetLanguage = fewer.targetLanguage == "en" ? "ja" : "en"
        await s.update(settings: other)
        check("another target language forgets the lines it kept", kept().isEmpty && s.recentPanelLines.isEmpty, "\(kept())")
        s.setKeepsRecent(false)
        check("turning the option off keeps nothing", kept().isEmpty && s.recentPanelLines.isEmpty)
        await s.stop()

        // Whole lines only (recent117, film 4 F21): a game types its line out and the lens reads parts of it, one by one; a name over the box and
        // a HUD read before it was ignored are not lines either.
        let g = session(rect, model, settings: settings)
        g.recentHold = 0
        await g.start()
        g.setKeepsRecent(true)
        let tag = CGRect(x: 10, y: 20, width: 80, height: 26), box = CGRect(x: 20, y: 60, width: 280, height: 50)
        let hud = CGRect(x: 200, y: 4, width: 110, height: 24)
        func look(_ blocks: [(String, CGRect)]) {
            g.received(OverlaySnapshot(version: 1, blocks: [], animated: false, origin: rect.origin,
                                       texts: blocks.map { BlockText(frame: $0.1, source: $0.0, translation: "t:" + $0.0) }))
        }
        let one = "はい、シュザンヌ様。足元にお気をつけください", two = "エルヴェ、大丈夫よ。ゆっくり行きましょう", three = "九十九、ここが月影の祠よ。間違いないわ"
        look([("所持金 1,280 G", hud), ("九十九", tag)])
        g.addIgnoredRegion(dragged: CGRect(x: rect.minX + 190, y: rect.minY, width: 130, height: 40))
        look([("九十九", tag), ("ュザ", CGRect(x: 120, y: 62, width: 40, height: 44))])
        look([("九十九", tag), ("はい、シュザンヌ様。足元にお気をつけ", box), ("い", CGRect(x: 160, y: 84, width: 20, height: 24))])
        look([("九十九", tag), (one, box)])
        look([("エルヴェ", tag), (two, box)])
        look([("シュザンヌ", tag), (three, box)])
        func keptGame() -> [String] { g.keptRecentLines.map(\.source) }
        check("the lines a game typed out are kept whole, without their parts, the names or the HUD", keptGame() == [two, one], "\(keptGame())")
        check("and the panel shows those translations", g.recentPanelLines == ["t:" + two, "t:" + one], "\(g.recentPanelLines)")
        // A line that left waits `RecentLines.hold` on the lens's own clock (a part can leave a read before the line that holds it shows).
        let four = "次の行はここです。それから、また別の行が続きます"
        g.recentHold = 3600
        look([("九十九", tag), (four, box)])
        check("a line that left waits the hold before the stack shows it, and the panel stays off the screen", keptGame().isEmpty && g.recentPanelLines.isEmpty,
              "\(keptGame()) \(g.recentPanelLines)")
        g.recentHold = 0
        look([("九十九", tag), (four, box)])
        check("and shows once it has waited", keptGame() == [three, two, one], "\(keptGame())")
        await g.stop()
    }

    // MARK: A region placed with the keyboard

    private static func keyboardMarker(_ check: Check) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { check("a screen to place a region on", false, "none"); return }
        let lens = CGRect(x: 200, y: 200, width: 400, height: 200)
        var result: CGRect??
        let view = MarkerView(screen: screen, lens: lens, existing: [], done: { result = .some($0) })
        view.handle(.engage)
        let start = view.placement?.rect
        check("an arrow key shows a small region in the middle of the lens", start?.size == CGSize(width: 120, height: 48), "\(String(describing: start))")
        view.handle(.move(.right, resize: false, fine: false))
        view.handle(.move(.right, resize: true, fine: false))
        view.handle(.confirm)
        let region = result.flatMap { $0 }.flatMap { IgnoredRegions.region(dragged: $0, in: lens) }
        func near(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 1e-6 } ?? false }
        check("moved 10 points right and made 10 wider, Return places it: a region of the lens", near(region?.x, 0.375) && near(region?.width, 0.325)
              && near(region?.y, 0.38) && near(region?.height, 0.24), "\(String(describing: region))")
        var cancelled: CGRect??
        let second = MarkerView(screen: screen, lens: lens, existing: [], done: { cancelled = .some($0) })
        second.handle(.cancel)
        check("Esc leaves without a region", cancelled != nil && cancelled! == nil)
        let edge = MarkerView(screen: screen, lens: lens, existing: [], done: { _ in })
        edge.handle(.engage)
        // 140 points from the lens's left edge: fourteen steps of ten reach it.
        for _ in 0..<14 { edge.handle(.move(.left, resize: false, fine: false)) }
        check("fourteen steps left reach the lens's edge and no further", edge.placement.map { $0.rect.minX == $0.bounds.minX } == true, "\(String(describing: edge.placement?.rect))")
    }

    /// The marker's hint pills are placed against the lens (`MarkerHints`): for a lens at the top right of this Mac's screen, and for one that fills its
    /// height, no pill is within the ring's room of the lens or outside the visible frame, and the two keep their order and 8 pt (the rule itself is
    /// `MarkerHintsTests`; this is the view's wiring of it: the fixed place at the screen's middle, 120 points from its top, was over such a lens).
    static func markerHints(_ check: Check) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { check("a screen to place the hints on", false, "none"); return }
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let room = RegionFrameWindow.tabExtra
        // View coordinates (y up) to the Quartz rect the marker takes.
        func quartz(_ r: CGRect) -> CGRect { ScreenGeometry.quartzRect(fromAppKit: r.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)) }
        let lenses = [("top right", CGRect(x: visible.maxX - 30 - 600, y: visible.maxY - 60 - 340, width: 600, height: 340)),
                      ("full height", CGRect(x: visible.midX - 210, y: visible.minY, width: 420, height: visible.height))]
        for (name, lens) in lenses {
            let view = MarkerView(screen: screen, lens: quartz(lens), existing: [], done: { _ in })
            let frames = view.hintFrames
            let clear = frames.allSatisfy { !$0.intersects(lens.insetBy(dx: -room, dy: -room)) }
            check("the hint pills stand clear of a lens at the \(name) of the screen", frames.count == 2 && clear, "\(frames) against the lens \(lens)")
            check("and inside the visible frame, the drag hint above the arrow keys one with 8 points between",
                  frames.count == 2 && frames.allSatisfy({ visible.contains($0) }) && frames[0].minY - frames[1].maxY == MarkerHints.spacing, "\(frames) in \(visible)")
        }
    }

    /// The marker gives the app that was in front its focus back, however it ends: a game with a lens over it is where the person goes on, and
    /// a first click that only activated it is lost (film4 F12: after a drag the first click into the game did nothing). The system is replaced:
    /// Finder is "in front", and the focus given back is a list.
    private static func markerFocus(_ check: Check) async {
        let lens = CGRect(x: 200, y: 200, width: 400, height: 200)
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let screen = ScreenGeometry.screen(for: lens) else { check("a screen and an app in front to give focus back to", false, "none"); return }
        let marker = RegionMarker()
        var given: [String] = []
        marker.frontmost = { finder }
        marker.refocus = { given.append($0.bundleIdentifier ?? "?") }
        func up() async -> Bool {
            let until = ProcessInfo.processInfo.systemUptime + 10
            while !marker.isUp, ProcessInfo.processInfo.systemUptime < until { try? await Task.sleep(for: .milliseconds(5)) }
            return marker.isUp
        }
        // A drag inside the lens.
        let dragged = Task { await marker.mark(in: lens, existing: []) }
        let shown = await up()
        let local = ScreenGeometry.appKitRect(fromQuartz: lens).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        if let view = marker.view as? MarkerView, let window = view.window {
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown, CGPoint(x: local.minX + 50, y: local.minY + 50)))
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: local.minX + 150, y: local.minY + 100)))
            view.mouseUp(with: event(.leftMouseUp, CGPoint(x: local.minX + 150, y: local.minY + 100)))
        }
        let region = await dragged.value
        check("a region marked with the mouse gives the app that was in front its focus back", shown && region != nil && given == ["com.apple.finder"],
              "region \(String(describing: region)), focus given to \(given)")
        // Esc, and the keys.
        let cancelled = Task { await marker.mark(in: lens, existing: []) }
        _ = await up()
        (marker.view as? MarkerView)?.handle(.cancel)
        _ = await cancelled.value
        let placed = Task { await marker.mark(in: lens, existing: []) }
        _ = await up()
        (marker.view as? MarkerView)?.handle(.engage)
        (marker.view as? MarkerView)?.handle(.confirm)
        let byKey = await placed.value
        check("and so does Esc, and so does a region placed with the keys", given == ["com.apple.finder", "com.apple.finder", "com.apple.finder"] && byKey != nil,
              "focus given to \(given)")
    }

    // MARK: The number of recent lines is a setting

    private static func settings(_ check: Check) {
        func decoded(_ json: String) -> AppSettings? { try? JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)) }
        check("recentLineCount is 3 by default", AppSettings().recentLineCount == 3 && decoded("{}")?.recentLineCount == 3)
        check("one the file holds is kept, and one out of range or not a number is brought back into it", decoded("{\"recentLineCount\": 5}")?.recentLineCount == 5
              && decoded("{\"recentLineCount\": 99}")?.recentLineCount == 8 && decoded("{\"recentLineCount\": 0}")?.recentLineCount == 1
              && decoded("{\"recentLineCount\": \"many\"}")?.recentLineCount == 3)
        let base = AppSettings()
        let ok = SettingsFileCheck.read(Data("{\"recentLineCount\": 5}".utf8), over: base)
        check("settings.json takes recentLineCount from 1 to 8", ok.issues.isEmpty && ok.settings.recentLineCount == 5, "\(ok.issues)")
        let bad = SettingsFileCheck.read(Data("{\"recentLineCount\": 20}".utf8), over: base)
        check("a value out of range is reported with the range and the setting keeps its value",
              bad.issues.count == 1 && bad.issues[0].message.contains("recentLineCount") && bad.issues[0].message.contains("1 to 8") && bad.settings.recentLineCount == base.recentLineCount,
              "\(bad.issues)")
        let wrong = SettingsFileCheck.read(Data("{\"recentLineCount\": \"many\"}".utf8), over: base)
        check("a value that is not a whole number is reported", wrong.issues.count == 1 && wrong.settings.recentLineCount == base.recentLineCount, "\(wrong.issues)")
        var five = AppSettings()
        five.recentLineCount = 5
        let plain = String(decoding: SettingsFileFormat.render(AppSettings()), as: UTF8.self), written = String(decoding: SettingsFileFormat.render(five), as: UTF8.self)
        check("a file from before the setting saves as it was (the default is not written); a number that differs is",
              !plain.contains("recentLineCount") && written.contains("\"recentLineCount\": 5"), "default: \(plain.contains("recentLineCount")), five: \(written.contains("recentLineCount"))")
        check("Ignore Region and Keep Recent Lines are shortcut actions, unassigned until the person assigns them",
              HotKeyAction.allCases.contains(.ignoreRegion) && HotKeyAction.allCases.contains(.keepRecentLines)
              && HotKeyAction.defaults[HotKeyAction.ignoreRegion.rawValue] == nil && HotKeyAction.defaults[HotKeyAction.keepRecentLines.rawValue] == nil
              && Set(HotKeyAction.defaults.keys) == [HotKeyAction.addLens.rawValue, HotKeyAction.toggleOriginal.rawValue])
        let known = SettingsFileCheck.read(Data("{\"shortcuts\": {\"ignoreRegion\": {\"keyCode\": 34, \"modifiers\": 6144, \"display\": \"⌃⌥I\"}}}".utf8), over: base)
        check("settings.json accepts a shortcut for them", known.issues.isEmpty && known.settings.shortcuts["ignoreRegion"]?.display == "⌃⌥I", "\(known.issues)")
    }
}
#endif
