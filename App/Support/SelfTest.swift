import AppKit
import ImageIO
import MwoyeoCore
import MwoyeoEngines
import UniformTypeIdentifiers

/// Headless end-to-end run on a still image:
///   Mwoyeo --render in.png out.png [--src ja] [--tgt ko] [--mode fast|seamless] [--engine auto|translation|intelligence]
///                                  [--no-inpaint] [--scale 2] [--then en,ko,style] [--then-early ms] [--max-wait s] [--warm]
/// Prints what was read and translated, and writes the composited result. Exits when done.
/// `--then-early ms` fires the `--then` steps `ms` after a translation batch is first in flight (a settings change
/// mid-translation) and settles once at the end; `--max-wait s` is the settle ceiling (default 120); `--warm` waits for the text
/// model first, as the app loads it at launch (the first run of a new binary compiles it, up to a minute; killing a run
/// mid-compile restarts it).
/// `MWOYEO_FAKE_ENGINE=hang|fail|fail-once|slow:<ms>` replaces the translation engine (see `TranslationService`).
/// `MWOYEO_FAKE_OCR=stall|stall-vn|slow:<ms>` makes the text model (revision 3) never answer, or answer late (see
/// `TextRecognizer`); the work counts then show `ocr.stalled.vn3`, `ocr.fallback.vn3|rev2|fast` and `ocr.recovered.vn3`.
/// `--engine-config file.json` runs the pass through an added engine (an `EngineShare` file, as the app exports it) with
/// the key from `MWOYEO_ENGINE_KEY` held in memory only; Apple stands in when the engine fails. It prints `engine: <name>
/// <kind>`, `engine_ms` per phase, and at the end the issue count, the request fields the engine's server refused, and how
/// many translations each cache namespace was given. A `--then` step `wait<ms>` just waits (a cooldown to run out).
///
/// Simulated lens drag over a still "screen" (points; writes the lens view per step as outdir/frame_NNN.png):
///   Mwoyeo --render screen.png outdir --pan --lens x,y,w,h --to x,y [--steps 40] [--step-ms 100] [--hold-ms 3000]
/// With `--scroll`, the lens stays and the content scrolls by `--to` instead (screen.png is the whole page); `--scroll-rect x,y,w,h`
/// scrolls only that part (a message log between a fixed sidebar, header and footer), `--ease` decelerates like inertial scrolling.
/// `--back` holds at the end, then scrolls back. Work counts (OCR, erase, engine calls) are printed per phase.
/// `--wheel N` also sends N trackpad scroll events per captured frame and shows the translations where the scroll
/// predictor puts them between frames (`--no-predict`: where the last frame left them).
/// Each step prints how far the shown translations are from the text they translate ("drift", points).
/// `--blink x,y,w,h` (with `--pan`): instead of moving, an animated emoji plays there for `--hold-ms`, a frame every
/// 100 ms; the work it causes is printed.
///
/// Keeping what the lens read (both modes; the lens is the whole capture unless `--lens x,y,w,h` — points in the image — is given):
///   `--transcript dir` writes the lens's transcript (Markdown + two SRTs) into `dir`, with fake times in `--render` runs;
///   `--transcript-formats markdown,srt,jsonl` picks the files (jsonl: one JSON line per translated line);
///   (one second per phase; `--then again` re-reads the same frame, a held subtitle);
///   `--save-lens out.png` writes the lens image (the app's "Save Lens Image");
///   `--copy` prints the original and translation lines the lens's copy actions would put on the pasteboard.
enum SelfTest {
    static func run(_ args: [String]) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        Task.detached {
            do {
                try await render(args)
                exit(0)
            } catch {
                FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(0)
    }

    private struct Failure: Error, CustomStringConvertible { let description: String }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: OverlaySnapshot?
        private var reports: [ScrollReport] = []
        var latest: OverlaySnapshot? { lock.withLock { snapshot } }
        func put(_ s: OverlaySnapshot) { lock.withLock { snapshot = s } }
        func report(_ r: ScrollReport) { lock.withLock { reports.append(r) } }
        func drainReports() -> [ScrollReport] { lock.withLock { defer { reports = [] }; return reports } }
    }

    /// What `--transcript`, `--save-lens` and `--copy` ask for, fed the way the app feeds the lens's own actions.
    private struct Keeping {
        let writer: TranscriptWriter?
        let saveTo: URL?
        let copies: Bool

        init(settings: AppSettings, option: (String) -> String?, args: [String]) {
            writer = option("--transcript").map {
                let formats = option("--transcript-formats").map { $0.split(separator: ",").compactMap { TranscriptFileFormat(rawValue: String($0)) } }
                    ?? settings.transcriptFormats
                return TranscriptWriter(directory: URL(fileURLWithPath: $0), lens: "Lens", sourceCode: settings.sourceLanguage,
                                 targetCode: settings.targetLanguage, formats: formats, engine: settings.activeEngineConfig?.name ?? "apple", onError: { FileHandle.standardError.write("error: transcript write failed\n".data(using: .utf8)!) })
            }
            saveTo = option("--save-lens").map { URL(fileURLWithPath: $0) }
            copies = args.contains("--copy")
        }

        func observe(_ snapshot: OverlaySnapshot?, lens: CGRect, time: TimeInterval) {
            guard let snapshot else { return }
            writer?.observe(time: time, lines: LensText.observed(snapshot, lens: lens))
        }

        /// The end of the run: closes the transcript, writes the lens image, prints the copy lines.
        func finish(_ snapshot: OverlaySnapshot?, lens: CGRect, time: TimeInterval) throws {
            writer?.finishAndWait(time: time)
            guard let snapshot else { return }
            if let saveTo {
                guard let frame = snapshot.frame,
                      let image = LensImage.composite(frame: frame, scale: snapshot.scale,
                                                      layers: snapshot.blocks.map { .init(frame: $0.frame, image: $0.image) },
                                                      crop: lens.offsetBy(dx: -snapshot.origin.x, dy: -snapshot.origin.y))
                else { throw Failure(description: "no frame to save the lens image from") }
                try LensImage.writePNG(image, to: saveTo)
                print("wrote lens image \(saveTo.path) (\(image.width)×\(image.height))")
            }
            if copies {
                let blocks = LensText.inLens(snapshot, lens: lens)
                let originals = LensText.originals(blocks), translations = LensText.translations(blocks)
                print("copy original: \(originals.count) lines")
                originals.forEach { print("  \($0)") }
                print("copy translation: \(translations.count) lines")
                translations.forEach { print("  \($0)") }
            }
        }
    }

    private static func lensOption(_ option: (String) -> String?, default whole: CGRect) -> CGRect {
        let v = (option("--lens") ?? "").split(separator: ",").compactMap { Double($0) }
        return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : whole
    }

    private static func render(_ args: [String]) async throws {
        guard args.count >= 2 else { throw Failure(description: "usage: --render in.png out.png [options]") }
        func option(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let input = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])

        var settings = AppSettings()
        settings.sourceLanguage = option("--src") ?? "auto"
        settings.targetLanguage = option("--tgt") ?? "ko"
        settings.renderMode = option("--mode") == "fast" ? .fast : .seamless
        settings.engine = TranslationEngineChoice(rawValue: option("--engine") ?? "auto") ?? .auto
        settings.useInpaintingModel = !args.contains("--no-inpaint")
        // `--reader automatic|documentLayout|lineGrouping` is the global choice; `--lens-app <bundleID> [--lens-category <type>]`
        // renders as if that app were in the lens (what automatic reads from the app).
        settings.paragraphReader = option("--reader").flatMap(ParagraphReader.init(rawValue:)) ?? .automatic
        let lensApp = ReaderContext(bundleID: option("--lens-app"), category: option("--lens-category"))
        let scale = CGFloat(Double(option("--scale") ?? "2") ?? 2)
        guard let decoded = try? StillTranslation.decode(url: input, scale: scale) else { throw Failure(description: "cannot read \(input.path)") }
        let image = decoded.image

        // `--profile-app <bundleID>` renders as if that app were in front: its profile (from the app's saved settings, or
        // `--profile <bundleID>=<src>:<tgt>`) lays over the languages above, as in the app.
        if let app = option("--profile-app") {
            if let saved = UserDefaults.standard.data(forKey: "settings").flatMap({ try? JSONDecoder().decode(AppSettings.self, from: $0) }) {
                settings.appProfiles = saved.appProfiles
            }
            for (i, a) in args.enumerated() where a == "--profile" && i + 1 < args.count {
                let kv = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init), pair = (kv.last ?? "").split(separator: ":").map(String.init)
                if kv.count == 2, pair.count == 2 {
                    settings.appProfiles = AppProfiles.remembering(AppProfile(bundleID: kv[0], appName: kv[0], source: pair[0], target: pair[1]), in: settings.appProfiles)
                }
            }
            let base = settings
            settings = base.effective(frontmost: app)
            print("profile: \(app) \(AppProfiles.profile(for: app, in: base.appProfiles) == nil ? "none (base kept)" : "applied") "
                  + "\(base.sourceLanguage)>\(base.targetLanguage) → \(settings.sourceLanguage)>\(settings.targetLanguage)")
        }

        var secrets = MemorySecrets()
        if let path = option("--engine-config") {
            let config = try EngineShare.decode(try String(contentsOfFile: path, encoding: .utf8))
            secrets = MemorySecrets([config.id: ProcessInfo.processInfo.environment["MWOYEO_ENGINE_KEY"] ?? ""])
            settings.engines = [config]
            settings.customEngineID = config.id
            print("engine: \(config.name) \(kindName(config.kind))")
        }
        let translator = TranslationService(settings: settings, secrets: secrets)
        let issues = Counter()
        let report: @Sendable (TranslationIssue?) -> Void = { issue in
            if let issue { issues.bump(); FileHandle.standardError.write("issue: \(issue.message)\n".data(using: .utf8)!) }
        }
        await translator.setIssueHandler(report)
        TextRecognizer.setNoticeHandler(report)
        // A render is a fresh process, the cold case: the text model loads in the background, as at the app's launch, and `--warm`
        // waits for it.
        let source = settings.sourceLanguage
        let loading = Task.detached(priority: .utility) { await AppModel.loadVision(source: source) }
        let t0 = Date()
        let inpainter = settings.useInpaintingModel ? Inpainter.load() : nil
        print("inpainter: \(inpainter != nil ? "MI-GAN loaded (\(ms(t0)) ms)" : "none")")
        if args.contains("--pan") {
            if option("--mode") == nil { settings.renderMode = .adaptive }
            try await pan(screen: image, scale: scale, settings: settings, translator: translator, inpainter: inpainter,
                          outdir: output, issues: issues, option: option)
            return
        }

        // `--warm`: load the text model first, as the app does at launch (a fresh binary compiles it once, up to a minute).
        if args.contains("--warm") {
            let w = Date()
            await loading.value
            print("warm-up: \(ms(w)) ms")
        }
        let still = StillTranslation(decoded, settings: settings, translator: translator, inpainter: inpainter, lensApp: lensApp)
        let pipeline = still.pipeline
        let capture = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let start = Date()
        await still.ingest()
        let keeping = Keeping(settings: settings, option: option, args: args)
        let lensRect = lensOption(option, default: capture)
        var phase = 0.0

        // Wait for reading + translation to finish (or give up after `--max-wait`, 120 s by default).
        let maxWait = Double(option("--max-wait") ?? "120") ?? 120
        func settle(from start: Date) async throws { try await still.settle(from: start, maxWait: maxWait) }
        // `--then en,ko,style`: change the settings as the user would (target language, or "style" = font and box
        // opacity), and report what each change costs.
        func applyThen(_ step: String) async {
            if step.hasPrefix("wait"), let ms = Int(step.dropFirst(4)) {
                try? await Task.sleep(for: .milliseconds(ms))
                return
            }
            if step == "again" {
                await still.ingest()   // the same screen read again: a held subtitle
            } else if step == "style" {
                settings.fontStyle = settings.fontStyle == .serif ? .system : .serif
                settings.boxOpacity = settings.boxOpacity == 1 ? 0.94 : 1
            } else {
                settings.targetLanguage = step
            }
            await translator.update(settings: settings)
            await pipeline.update(options: PipelineOptions(settings, lensApp: lensApp))
        }
        let steps = (option("--then") ?? "").split(separator: ",").map(String.init)
        if let early = option("--then-early").flatMap({ Double($0) }) {
            // Wait for a batch to be in flight, then change the settings `early` ms later.
            while Date().timeIntervalSince(start) < maxWait {
                try await Task.sleep(for: .milliseconds(20))
                if await pipeline.debugState().translating { break }
            }
            try await Task.sleep(for: .milliseconds(Int(early)))
            for step in steps {
                await applyThen(step)
                print("then-early \(step): \(ms(start)) ms")
            }
            try await settle(from: start)
            print("pipeline: \(ms(start)) ms")
            await printCounts("still", pipeline)
            keeping.observe(still.latest, lens: lensRect, time: phase)
        } else {
            try await settle(from: start)
            print("pipeline: \(ms(start)) ms")
            await printCounts("still", pipeline)
            keeping.observe(still.latest, lens: lensRect, time: phase)
            for step in steps {
                let t = Date()
                await applyThen(step)
                try await settle(from: t)
                print("then \(step): \(ms(t)) ms")
                await printCounts(step, pipeline)
                phase += 1
                keeping.observe(still.latest, lens: lensRect, time: phase)
            }
        }
        for (source, translation) in await pipeline.debugState().blocks {
            print("  \(source)\n    → \(translation ?? "(no translation)")")
        }
        await printEngineSummary(translator, issues: issues, wasAdded: !settings.engines.isEmpty)

        // Composite: original + overlay blocks, the same function the lens image uses.
        guard let out = still.composite(still.latest) else { throw Failure(description: "context") }
        do { try LensImage.writePNG(out, to: output) } catch { throw Failure(description: "cannot write \(output.path)") }
        print("wrote \(output.path)")
        try keeping.finish(still.latest, lens: lensRect, time: phase + 1)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }

    private static func kindName(_ kind: EngineKind) -> String {
        switch kind {
        case .openAICompatible: "openAICompatible"
        case .anthropic: "anthropic"
        case .deepL: "deepL"
        case .httpTemplate: "httpTemplate"
        case .command: "command"
        }
    }

    /// `engine_ms` of every phase so far, kept because each phase's report drains the samples.
    private nonisolated(unsafe) static var engineMs: [Double] = []

    private static func printEngineSummary(_ translator: TranslationService, issues: Counter, wasAdded: Bool) async {
        print("issues=\(issues.value)")
        guard wasAdded else { return }
        let ms = engineMs.sorted()
        print(ms.isEmpty ? "engine_ms[n=0]" : String(format: "engine_ms[p50=%.0f max=%.0f n=%d]", ms[ms.count / 2], ms[ms.count - 1], ms.count))
        print("learned=\(await translator.learnedFields())")
        for (space, n) in translator.storeCounts.sorted(by: { $0.key < $1.key }) { print("cache[\(space)] stores=\(n)") }
    }

    private static func ms(_ since: Date) -> Int { Int(Date().timeIntervalSince(since) * 1000) }

    /// The work done since the last call: OCR requests, erases, engine calls.
    private static func printCounts(_ phase: String, _ pipeline: RegionPipeline? = nil) async {
        var counts = Trace.takeCounts()
        for key in ["translate.cancelled", "translate.wasted", "translate.lens_unserved"] where counts[key] == nil { counts[key] = 0 }
        var parts = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        // How long text waited for its translation while in the lens (first seen there → translated).
        let samples = Trace.takeSamples()
        let waits = (samples["translate.lens_wait_ms"] ?? []).sorted()
        let engine = (samples["translate.engine_ms"] ?? []).sorted()
        engineMs += engine
        if !engine.isEmpty { parts.append(String(format: "engine_ms[p50=%.0f max=%.0f n=%d]", engine[engine.count / 2], engine[engine.count - 1], engine.count)) }
        parts.append(waits.isEmpty ? "lens_wait=n/a" : String(format: "lens_wait_ms[p50=%.0f max=%.0f n=%d]", waits[waits.count / 2], waits[waits.count - 1], waits.count))
        if let pipeline { parts.append("parked=\(await pipeline.debugState().parked)") }
        print("work[\(phase)]: " + parts.joined(separator: " "))
    }

    /// Drives the pipeline the way `RegionSession` does while a lens is dragged, with frames cropped from `screen`.
    private static func pan(screen: CGImage, scale: CGFloat, settings: AppSettings, translator: TranslationService, inpainter: Inpainter?,
                            outdir: URL, issues: Counter, option: (String) -> String?) async throws {
        func numbers(_ name: String) -> [CGFloat] {
            (option(name) ?? "").split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
        }
        let l = numbers("--lens"), to = numbers("--to")
        guard l.count == 4, to.count == 2 else { throw Failure(description: "--pan needs --lens x,y,w,h and --to x,y") }
        let scrolling = option("--scroll") != nil || CommandLine.arguments.contains("--scroll")
        let sr = numbers("--scroll-rect")
        let scrollRect = sr.count == 4 ? CGRect(x: sr[0], y: sr[1], width: sr[2], height: sr[3]) : CGRect.infinite
        let ease = CommandLine.arguments.contains("--ease")
        let wheelsPerFrame = Int(option("--wheel") ?? "0") ?? 0, predicting = !CommandLine.arguments.contains("--no-predict")
        var predictor = ScrollPredictor()
        predictor.latency = 0   // the "app" here shows a scroll at once
        var scrollArea: CGRect?
        // Content offset (points): the screen shows the page from here. Only `--scroll` changes it.
        var scroll = CGVector.zero
        let bl = numbers("--blink"), blink = bl.count == 4 ? CGRect(x: bl[0], y: bl[1], width: bl[2], height: bl[3]) : nil
        var blinkFrame = 0
        let steps = Int(option("--steps") ?? "40") ?? 40
        let stepMs = Int(option("--step-ms") ?? "100") ?? 100
        let holdMs = Int(option("--hold-ms") ?? "3000") ?? 3000
        var display = CGRect(x: 0, y: 0, width: CGFloat(screen.width) / scale, height: CGFloat(screen.height) / scale)
        if scrolling { display.size.width -= max(0, to[0]); display.size.height -= max(0, to[1]) }
        try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)

        var lens = CGRect(x: l[0], y: l[1], width: l[2], height: l[3])
        var wide = false
        var capture = Overscan.rect(around: lens, wide: wide, display: display)
        let collector = Collector()
        let keeping = Keeping(settings: settings, option: option, args: CommandLine.arguments)
        let began = ProcessInfo.processInfo.systemUptime
        let pipeline = RegionPipeline(options: PipelineOptions(settings), capture: capture, translator: translator, inpainter: inpainter,
                                      onSnapshot: { collector.put($0) })
        await pipeline.setVisible(lens)
        let motion = Collector()   // reused as a flag: any snapshot stored = motion seen
        await pipeline.setMotionHandler { motion.put(OverlaySnapshot(version: 0, blocks: [], animated: false, origin: .zero)) }
        await pipeline.setScrollHandler { collector.report($0) }

        /// What the display shows in `r` (points): the page, scrolled by `scroll` inside `scrollRect`.
        func compose(_ r: CGRect) -> CGImage? {
            let w = Int((r.width * scale).rounded()), h = Int((r.height * scale).rounded()), sh = CGFloat(screen.height)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return nil }
            func draw(from o: CGPoint) {
                ctx.draw(screen, in: CGRect(x: -o.x * scale, y: CGFloat(h) + o.y * scale - sh, width: CGFloat(screen.width), height: sh))
            }
            draw(from: r.origin)
            let s = scrollRect.intersection(r)
            if !s.isNull {
                ctx.clip(to: CGRect(x: (s.minX - r.minX) * scale, y: CGFloat(h) - (s.maxY - r.minY) * scale, width: s.width * scale, height: s.height * scale))
                draw(from: CGPoint(x: r.minX + scroll.dx, y: r.minY + scroll.dy))
            }
            // A face that pulses and changes colour, like an animated emoji.
            if let blink, case let s = blink.intersection(r), !s.isNull {
                ctx.resetClip()
                let hue = CGFloat(blinkFrame % 6) / 6, inset = CGFloat(blinkFrame % 3) * blink.width * 0.08
                ctx.setFillColor(NSColor(hue: hue, saturation: 0.8, brightness: 1, alpha: 1).cgColor)
                ctx.fillEllipse(in: CGRect(x: (blink.minX - r.minX) * scale, y: CGFloat(h) - (blink.maxY - r.minY) * scale,
                                           width: blink.width * scale, height: blink.height * scale).insetBy(dx: inset * scale, dy: inset * scale))
            }
            return ctx.makeImage()
        }
        func feed() async {
            guard let crop = compose(capture), let rgba = RGBAImage(cgImage: crop), let image = rgba.cgImage else { return }
            let gray = rgba.withBGRA { GrayImage(bgra: $0, width: rgba.width, height: rgba.height, bytesPerRow: rgba.width * 4, step: 4) }
            await pipeline.ingest(CapturedFrame(image: image, gray: gray, grayStep: 4, scale: scale, rect: capture,
                                                time: ProcessInfo.processInfo.systemUptime))
        }
        func apply(_ plan: Overscan.Plan) async {
            switch plan {
            case .keep: return
            case .move(let r): capture = r; await pipeline.captureMoved(to: r.origin)
            case .resize(let r): capture = r; await pipeline.captureResized(to: r)
            }
            await feed()
        }
        var frameIndex = 0
        // Where each shown block sat on the page when first seen (page points), to measure drift from its text.
        var anchors: [UUID: (page: CGPoint, size: CGSize, scrolls: Bool)] = [:]
        var drifts: [CGFloat] = []
        func shoot() async throws {
            let w = Int(lens.width * scale), h = Int(lens.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                  let under = compose(lens)
            else { throw Failure(description: "context") }
            ctx.draw(under, in: CGRect(x: 0, y: 0, width: w, height: h))
            var shown = 0, drift: CGFloat = 0
            if let snap = collector.latest {
                let predicted = predicting ? CGFloat(predictor.offset(from: snap.time, to: ProcessInfo.processInfo.systemUptime)) : 0
                for b in snap.blocks {
                    // Snapshot frames are relative to the capture origin; the lens is the overlay panel.
                    var onScreen = b.frame.offsetBy(dx: snap.origin.x, dy: snap.origin.y)
                    if scrollArea?.contains(CGPoint(x: onScreen.midX, y: onScreen.midY)) == true { onScreen.origin.y += predicted }
                    let g = onScreen.offsetBy(dx: -lens.minX, dy: -lens.minY)
                    guard g.intersects(CGRect(origin: .zero, size: lens.size)) else { continue }
                    shown += 1
                    ctx.draw(b.image, in: CGRect(x: g.minX * scale, y: CGFloat(h) - g.maxY * scale, width: g.width * scale, height: g.height * scale))
                    var a = anchors[b.id]
                    // A re-read may re-lay a block out; measure from there.
                    if a == nil || a!.size != b.frame.size {
                        let scrolls = scrollRect.contains(CGPoint(x: onScreen.midX, y: onScreen.midY))
                        a = (CGPoint(x: onScreen.minX + (scrolls ? scroll.dx : 0), y: onScreen.minY + (scrolls ? scroll.dy : 0)), b.frame.size, scrolls)
                        anchors[b.id] = a
                    }
                    let page = CGPoint(x: onScreen.minX + (a!.scrolls ? scroll.dx : 0), y: onScreen.minY + (a!.scrolls ? scroll.dy : 0))
                    drift = max(drift, hypot(page.x - a!.page.x, page.y - a!.page.y))
                }
            }
            drifts.append(drift)
            keeping.observe(collector.latest, lens: lens, time: ProcessInfo.processInfo.systemUptime - began)
            let flight = await pipeline.debugState().flight
            guard let out = ctx.makeImage() else { return }
            let url = outdir.appendingPathComponent(String(format: "frame_%03d.png", frameIndex))
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, out, nil)
                CGImageDestinationFinalize(dest)
            }
            frameIndex += 1
            print(String(format: "frame %03d lens (%4.0f,%4.0f) capture (%4.0f,%4.0f %4.0f×%4.0f) blocks shown %d drift %.1f flight [%@]",
                         frameIndex - 1, lens.minX, lens.minY, capture.minX, capture.minY, capture.width, capture.height, shown, drift,
                         flight.joined(separator: " ")))
        }

        // At rest: read and translate the start position completely.
        let start = Date()
        await feed()
        var quiet = Date()
        while Date().timeIntervalSince(start) < 120 {
            try await Task.sleep(for: .milliseconds(200))
            let state = await pipeline.debugState()
            if state.busy || state.paused { quiet = Date() } else if Date().timeIntervalSince(quiet) > 0.6 { break }
        }
        print("settled at start: \(ms(start)) ms")
        await printCounts("start")
        try await shoot()

        if blink != nil {
            for i in 1 ... max(1, holdMs / 100) {
                blinkFrame += 1
                await feed()
                try await Task.sleep(for: .milliseconds(100))
                if i % 5 == 0 { try await shoot() }
            }
            await printCounts("blink")
        } else if scrolling {
            // Scroll: frames change under a still capture; the pipeline notices the motion and asks for wide margins.
            let sub = max(1, wheelsPerFrame)
            // `--back`: hold at the end, then scroll back to the start (revisiting what was already read).
            let legs = CommandLine.arguments.contains("--back") ? 2 : 1
            for leg in 0..<legs {
            if leg > 0 {
                for _ in 0 ..< max(1, holdMs / 250) {
                    try await Task.sleep(for: .milliseconds(250))
                    try await shoot()
                }
                await printCounts("down")
            }
            for i in 1...(steps * sub) {
                let t = CGFloat(i) / CGFloat(steps * sub), e = ease ? 1 - pow(1 - t, 3) : t, f = leg == 0 ? e : 1 - e
                let next = CGVector(dx: (to[0] * f).rounded(), dy: (to[1] * f).rounded())
                // Scrolling the page down moves its content up.
                if wheelsPerFrame > 0 { predictor.wheel(delta: Double(scroll.dy - next.dy), time: ProcessInfo.processInfo.systemUptime, precise: true) }
                scroll = next
                if i % sub == 0 {
                    if !wide, motion.latest != nil {
                        wide = true
                        await apply(Overscan.plan(lens: lens, capture: capture, wide: wide, allowResize: true, display: display))
                    }
                    await feed()
                    // The pointer (as RegionSession sees it) rests in the middle of the lens.
                    for r in collector.drainReports() {
                        // As `RegionSession.scrolled`: every report steers the lead, only the lens's own area is learned from.
                        await pipeline.setLead(CGVector(dx: 0, dy: r.shift < 0 ? 1 : -1))
                        guard r.area.contains(CGPoint(x: lens.midX, y: lens.midY)) else { continue }
                        scrollArea = r.area
                        predictor.confirm(shift: Double(r.shift), from: r.from, to: r.to)
                    }
                }
                try await Task.sleep(for: .milliseconds(stepMs / sub))
                try await shoot()
            }
            }
        } else {
            // Drag: margins widen at once (as `noteMotion` does), then the lens moves in steps.
            wide = true
            await apply(Overscan.plan(lens: lens, capture: capture, wide: wide, allowResize: true, display: display))
            let from = lens.origin
            // As `RegionSession` while dragging: the lead is the unit direction of the drag.
            let len = hypot(to[0] - from.x, to[1] - from.y)
            if len > 4 { await pipeline.setLead(CGVector(dx: (to[0] - from.x) / len, dy: (to[1] - from.y) / len)) }
            for i in 1...steps {
                let f = CGFloat(i) / CGFloat(steps)
                lens.origin = CGPoint(x: from.x + (to[0] - from.x) * f, y: from.y + (to[1] - from.y) * f)
                await pipeline.setVisible(lens)
                await apply(Overscan.plan(lens: lens, capture: capture, wide: wide, allowResize: false, display: display))
                try await Task.sleep(for: .milliseconds(stepMs))
                try await shoot()
            }
        }
        // Dropped: the lead ends with the motion, then keep watching while it settles into seamless.
        await pipeline.setLead(.zero)
        for _ in 0 ..< max(1, holdMs / 250) {
            try await Task.sleep(for: .milliseconds(250))
            try await shoot()
        }
        // Let the queue finish what the lens still shows, bounded by `--max-wait`.
        let settleStart = Date(), maxWait = Double(option("--max-wait") ?? "120") ?? 120
        while Date().timeIntervalSince(settleStart) < maxWait {
            let state = await pipeline.debugState()
            if !state.busy, !state.paused { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        print("settled at end: \(ms(settleStart)) ms")
        for (source, translation) in await pipeline.debugState().blocks {
            print("  \(source) → \(translation ?? "(no translation)")")
        }
        await printCounts(CommandLine.arguments.contains("--back") ? "back" : "moved")
        try keeping.finish(collector.latest, lens: lens, time: ProcessInfo.processInfo.systemUptime - began)
        print(String(format: "drift: mean %.1f pt, max %.1f pt, %d of %d frames over 2 pt", drifts.reduce(0, +) / CGFloat(max(1, drifts.count)),
                     drifts.max() ?? 0, drifts.filter { $0 > 2 }.count, drifts.count))
        await printEngineSummary(translator, issues: issues, wasAdded: !settings.engines.isEmpty)
    }
}
