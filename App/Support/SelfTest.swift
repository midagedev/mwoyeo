#if !MAS
import AppKit
import ImageIO
import MwoyeoCore
import MwoyeoEngines
import UniformTypeIdentifiers
import os

/// Headless end-to-end run on a still image:
///   Mwoyeo --render in.png out.png [--src ja] [--tgt ko] [--mode fast|seamless|adaptive] [--engine auto|translation|intelligence]
///                                  [--glossary "term=translation;…"] [--no-inpaint] [--scale 2] [--then en,ko,style,reader-ready] [--then-early ms] [--max-wait s] [--warm]
///                                  [--no-drain]
/// Prints what was read and translated, and writes the composited result. Exits when done, after the drain below.
/// `--mode` defaults to seamless here (the bench baselines are measured in it), not to the app's own default, adaptive: `--mode adaptive` is
/// what a lens runs, a still read twice (fast boxes, then the rewrite).
/// A run ends with the numbers of the shipped behaviour (`Instruments`):
///   `hint: <case> at <ms>` one line per change of what the lens pill would say (`LensSignals.hint`, `none` when it clears), then
///   `silence: longest=<ms> total=<ms>` the time the lens showed neither a translated block nor a hint, sampled every 100 ms from the
///   start of the pass to the exit, then `drain: <ms> in-flight=<n>`: the exit waits (180 s at most) until no recognition request is in
///   flight, so that a compile is not thrown away; `--no-drain` exits at once, as before (`drain: skipped`). Then `reader: <line>` for
///   each line of the host's stats.
/// `--then reader-ready` waits until the recognition host says both readers are warm (`reader-ready: <ms>`, `n/a` while no host has
/// registered, `timeout <ms>` after `--max-wait`, default 600 for this wait). The host registers `SelfTest.register(inFlight:readerReady:statsLines:)`.
/// `Mwoyeo --render --check-instruments` checks the silence meter, the hint names and the hooks' registry on made-up input (no render).
/// `--then-early ms` fires the `--then` steps `ms` after a translation batch is first in flight (a settings change
/// mid-translation) and settles once at the end; `--max-wait s` bounds the waits of the run (the settle, default 120; `--warm`; `--then
/// reader-ready`, default 600); the drain before the exit has its own bound, 180 s, whatever `--max-wait` is: a run that gave up
/// waiting is the very run that exits mid-compile. `--warm` waits for the text
/// model first, as the app loads it at launch (the first run of a new binary compiles it, up to a minute; killing a run
/// mid-compile restarts it).
/// `MWOYEO_FAKE_ENGINE=hang|fail|fail-once|slow:<ms>` replaces the translation engine (see `TranslationService`).
/// `MWOYEO_PLAN=off` turns the time-aware scheduling rules off (content then counts as moving at an unknown speed, as before them), to measure against.
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
/// `--late-fixed x,y,w,h` keeps that fixed part blank until the scroll starts, then shows it (a sticky banner or an input box
/// appearing while the log scrolls): its text must be translated during the scroll, not after it.
/// `--watch text` adds `watch=translated|waiting|absent` to each frame line: the state of the blocks whose source contains `text`.
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
        if args.first == "--check-instruments" {
            Task.detached { exit(await checkInstruments() ? 0 : 1) }
            RunLoop.main.run()
        }
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
        // However the run ends, it drains before it exits (a compile the exit interrupts is thrown away) and prints its numbers.
        let instruments = Instruments(args: args)
        do { try await renderPass(args, instruments) } catch {
            await instruments.finish()
            throw error
        }
        await instruments.finish()
    }

    private static func renderPass(_ args: [String], _ instruments: Instruments) async throws {
        func option(_ name: String) -> String? {
            args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        }
        let input = URL(fileURLWithPath: args[0]), output = URL(fileURLWithPath: args[1])

        var settings = AppSettings()
        settings.sourceLanguage = option("--src") ?? "auto"
        settings.targetLanguage = option("--tgt") ?? "ko"
        // Seamless unless asked: the bench baselines are measured in it. `adaptive` is the app's own default (`AppSettings.renderMode`).
        settings.renderMode = switch option("--mode") {
        case "fast": .fast
        case "adaptive": .adaptive
        default: .seamless
        }
        settings.engine = TranslationEngineChoice(rawValue: option("--engine") ?? "auto") ?? .auto
        settings.useInpaintingModel = !args.contains("--no-inpaint")
        // `--glossary "co-op=협력;raid=레이드"` sets the glossary (one `term=translation` per `;`).
        if let g = option("--glossary") { settings.glossary = g.replacingOccurrences(of: ";", with: "\n") }
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
        // The two sources of an issue reach the hint as they do in the app (`AppModel.received`, `recognitionNotice`).
        await translator.setIssueHandler { issue in report(issue); instruments.issues.fromTranslation(issue) }
        TextRecognizer.setNoticeHandler { issue in report(issue); instruments.issues.fromRecognizer(issue) }
        _ = await translator.observe { event in instruments.trouble.apply(event) }
        // A render is a fresh process, the cold case: the text model loads in the background, as at the app's launch, and `--warm`
        // waits for it.
        let source = settings.sourceLanguage
        let loading = instruments.beginWarmUp(source: source)
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
            let ended = await instruments.waitForWarmUp(loading)
            print("warm-up: \(ended ? "" : "timeout ")\(ms(w)) ms")
        }
        let still = StillTranslation(decoded, settings: settings, translator: translator, inpainter: inpainter, lensApp: lensApp)
        let pipeline = still.pipeline
        let capture = CGRect(x: 0, y: 0, width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        // The silence timeline runs from here (the start of the lens pass) to the exit.
        await pipeline.setReadHandler { tally in instruments.streak.read(tally); instruments.trouble.read(tally) }
        instruments.startSampling(source: settings.sourceLanguage, target: settings.targetLanguage, engine: settings.activeEngineConfig?.id,
                                  drawn: { still.latest?.blocks.isEmpty == false })
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
                instruments.setTarget(step)
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
                if step == "reader-ready" { await instruments.waitForReader(); continue }
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
                if step == "reader-ready" { await instruments.waitForReader(); continue }
                let t = Date()
                await applyThen(step)
                try await settle(from: t)
                print("then \(step): \(ms(t)) ms")
                await printCounts(step, pipeline)
                phase += 1
                keeping.observe(still.latest, lens: lensRect, time: phase)
            }
        }
        printPace(translator)
        for (source, translation) in await pipeline.debugState().blocks {
            print("  \(source)\n    → \(translation ?? "(no translation)")")
        }
        await printEngineSummary(translator, issues: issues, wasAdded: !settings.engines.isEmpty)

        printLayout(still.latest)
        // Composite: original + overlay blocks, the same function the lens image uses.
        guard let out = still.composite(still.latest) else { throw Failure(description: "context") }
        do { try LensImage.writePNG(out, to: output) } catch { throw Failure(description: "cannot write \(output.path)") }
        print("wrote \(output.path)")
        try keeping.finish(still.latest, lens: lensRect, time: phase + 1)
    }

    /// `layout: blocks=N overlaps=K spill=S cut=C clipped=Q` (LayoutCheck) and one line per finding with the sources involved: the
    /// gate and the debug view of a page whose translated blocks run into each other. After it, `image: W×H` and one `block:`
    /// line per drawn block (core and text rects in image pixels, drawn font size, source lines, characters, clipped, ellipsis) for
    /// `tools/paper-bench/score.py`.
    private static func printLayout(_ snapshot: OverlaySnapshot?) {
        let drawn = snapshot?.drawn ?? []
        let report = LayoutCheck.check(drawn)
        func name(_ i: Int) -> String { "\"" + String(drawn[i].source.prefix(40)) + "\"" }
        print(report.summary)
        if let frame = snapshot?.frame { print("image: \(frame.width)×\(frame.height)") }
        func rect(_ r: CGRect) -> String { "\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))" }
        for b in drawn {
            print("block: core=\(rect(b.core)) text=\(rect(b.text)) size=\(String(format: "%.1f", b.fontSize)) lines=\(b.lines) chars=\(b.source.count) "
                  + "clipped=\(b.clipped ? 1 : 0) ellipsis=\(b.ellipsis ? 1 : 0) \"\(b.source.prefix(60).replacingOccurrences(of: "\n", with: " "))\"")
        }
        for (a, b) in report.overlaps { print("  overlap: \(name(a)) x \(name(b))") }
        for (a, b) in report.cut { print("  cut: \(name(a)) painted over by \(name(b))") }
        for a in report.spill { print("  spill: \(name(a)) past its column") }
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
        Instruments.seen.add(counts)
        for key in ["translate.cancelled", "translate.wasted", "translate.landed_outside", "translate.lens_unserved"] where counts[key] == nil { counts[key] = 0 }
        var parts = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        // How long text waited for its translation while in the lens (first seen there → translated).
        let samples = Trace.takeSamples()
        let engine = (samples["translate.engine_ms"] ?? []).sorted()
        engineMs += engine
        if !engine.isEmpty { parts.append(String(format: "engine_ms[p50=%.0f max=%.0f n=%d]", engine[engine.count / 2], engine[engine.count - 1], engine.count)) }
        func summary(_ name: String, _ key: String) -> String {
            let all = samples[key] ?? [], v = all.sorted()
            return v.isEmpty ? "\(name)=n/a" : String(format: "\(name)_ms[p50=%.0f max=%.0f last=%.0f n=%d]", v[v.count / 2], v[v.count - 1], all[all.count - 1], v.count)
        }
        parts.append(summary("lens_wait", "translate.lens_wait_ms"))
        // From the stop of the motion to every block in the lens being translated.
        parts.append(summary("settle", "translate.settle_ms"))
        if let pipeline { parts.append("parked=\(await pipeline.debugState().parked)") }
        print("work[\(phase)]: " + parts.joined(separator: " "))
    }

    /// The engine's measured speed per namespace (numbers only), from `TranslationService.paceStats()`.
    private static func printPace(_ translator: TranslationService) {
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "n/a" }
        for p in translator.paceStats() {
            print("pace: \(p.key) samples=\(p.samples) first=\(f(p.first))s perLine=\(f(p.perLine))s batch[p50=\(f(p.batchP50))s p90=\(f(p.batchP90))s n=\(p.batches)] cancelled=\(p.cancelled) lines[cached=\(p.cachedLines) translated=\(p.translatedLines)]")
        }
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
        let watch = option("--watch")
        let lf = numbers("--late-fixed")
        var hidden: CGRect? = lf.count == 4 ? CGRect(x: lf[0], y: lf[1], width: lf[2], height: lf[3]) : nil
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
            if let hidden, case let h = hidden.intersection(r), !h.isNull {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: (h.minX - r.minX) * scale, y: CGFloat(ctx.height) - (h.maxY - r.minY) * scale, width: h.width * scale, height: h.height * scale))
            }
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
            let state = await pipeline.debugState()
            let flight = state.flight, motion = state.motion
            let watched = watch.map { w in
                let hits = state.blocks.filter { $0.0.contains(w) }
                return " watch=" + (hits.isEmpty ? "absent" : hits.allSatisfy { $0.1 != nil } ? "translated" : "waiting")
            } ?? ""
            guard let out = ctx.makeImage() else { return }
            let url = outdir.appendingPathComponent(String(format: "frame_%03d.png", frameIndex))
            if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, out, nil)
                CGImageDestinationFinalize(dest)
            }
            frameIndex += 1
            print(String(format: "frame %03d lens (%4.0f,%4.0f) capture (%4.0f,%4.0f %4.0f×%4.0f) blocks shown %d drift %.1f %@%@ flight [%@]",
                         frameIndex - 1, lens.minX, lens.minY, capture.minX, capture.minY, capture.width, capture.height, shown, drift,
                         String(format: "%@ v=%.0f L=%@", motion.moving ? "moving" : "still", motion.velocity.dy, motion.expected.map { String(format: "%.1f", $0) } ?? "n/a"),
                         watched, flight.joined(separator: " ")))
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
                hidden = nil
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
        printPace(translator)
        let lensState = await pipeline.debugState().lens
        print("lens at end: \(lensState.total) blocks, \(lensState.untranslated) untranslated")
        await printCounts(CommandLine.arguments.contains("--back") ? "back" : "moved")
        try keeping.finish(collector.latest, lens: lens, time: ProcessInfo.processInfo.systemUptime - began)
        print(String(format: "drift: mean %.1f pt, max %.1f pt, %d of %d frames over 2 pt", drifts.reduce(0, +) / CGFloat(max(1, drifts.count)),
                     drifts.max() ?? 0, drifts.filter { $0 > 2 }.count, drifts.count))
        await printEngineSummary(translator, issues: issues, wasAdded: !settings.engines.isEmpty)
    }
}

// MARK: - What the host registers, and the numbers a run ends with

extension SelfTest {
    /// What the recognition host registers (R3) so that a headless run can wait for it and read it. Each is optional: with none
    /// registered a run drains on what `TextRecognizer` exposes today (`inFlight`), prints `reader-ready: n/a` and no `reader:` lines.
    struct Hooks: Sendable {
        /// Recognition requests in flight now in the host's workers, queued ones included. The drain before exit waits for 0.
        var inFlight: (@Sendable () async -> Int)?
        /// Both workers are warm for the run's language key (`--then reader-ready` waits for it).
        var readerReady: (@Sendable () async -> Bool)?
        /// The host's stats, one line each; printed at the end as `reader: <line>` (a line that starts with `reader:` is printed as is).
        var statsLines: (@Sendable () async -> [String])?
    }

    private static let registered = OSAllocatedUnfairLock(initialState: Hooks())
    static var hooks: Hooks { registered.withLock { $0 } }

    /// Registers the hooks the host has; one that is not passed keeps what it had. Call once, when the host starts.
    static func register(inFlight: (@Sendable () async -> Int)? = nil, readerReady: (@Sendable () async -> Bool)? = nil,
                         statsLines: (@Sendable () async -> [String])? = nil) {
        registered.withLock { h in
            if let inFlight { h.inFlight = inFlight }
            if let readerReady { h.readerReady = readerReady }
            if let statsLines { h.statsLines = statsLines }
        }
    }

    /// The case of a hint without its payload (`downloadPack(…)` → `downloadPack`), `none` for no hint: whatever cases `LensHint` gets.
    static func hintName(_ hint: LensHint?) -> String {
        guard let hint else { return "none" }
        return String(String(describing: hint).prefix { $0 != "(" })
    }

    /// The time with neither a translated block nor a hint, from samples taken at known times.
    struct SilenceMeter: Equatable {
        private(set) var longest = 0.0
        private(set) var total = 0.0
        private var since: Double?

        /// One sample at `t` seconds. A silent run lasts from its first silent sample to the first sample that is not silent.
        mutating func sample(at t: Double, silent: Bool) {
            if silent { if since == nil { since = t } } else { close(at: t) }
        }

        /// The exit at `t`: a silent run still open ends here.
        mutating func end(at t: Double) { close(at: t) }

        private mutating func close(at t: Double) {
            guard let s = since else { return }
            since = nil
            let run = max(0, t - s)
            longest = max(longest, run)
            total += run
        }
    }

    /// `--render --check-instruments`: the meter, the hint names and the hooks on made-up input (no render, no Vision). True when all hold.
    fileprivate static func checkInstruments() async -> Bool {
        var failed = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failed += 1 }
        }
        // Samples every 0.1 s to a 12 s exit: silent to 2.3 s, shown, silent 5.0 to 5.4 s, shown, silent from 9.0 s to the exit.
        var m = SilenceMeter()
        for i in 0 ... 120 {
            let t = Double(i) / 10
            m.sample(at: t, silent: t < 2.3 || (t >= 5.0 && t < 5.4) || t >= 9.0)
        }
        m.end(at: 12)
        check("longest is the run open at the exit (3.0 s)", abs(m.longest - 3.0) < 1e-9)
        check("total adds the runs (2.3 + 0.4 + 3.0 s)", abs(m.total - 5.7) < 1e-9)
        var never = SilenceMeter()
        for i in 0 ... 20 { never.sample(at: Double(i) / 10, silent: false) }
        never.end(at: 2)
        check("a lens never silent measures 0", never.longest == 0 && never.total == 0)
        var always = SilenceMeter()
        for i in 0 ... 20 { always.sample(at: Double(i) / 10, silent: true) }
        always.end(at: 2.05)
        check("a lens silent to the exit measures the whole run", abs(always.longest - 2.05) < 1e-9 && always.longest == always.total)
        check("no hint is none", hintName(nil) == "none")
        check("a hint without a payload", hintName(.preparingRecognition) == "preparingRecognition")
        check("a hint with a payload loses it", hintName(.alreadyInTarget(target: "ko")) == "alreadyInTarget"
              && hintName(.downloadPack(PackPair(source: "ja", target: "ko"))) == "downloadPack")
        check("the translation hints keep their case names", hintName(.translationSlow(engine: "Apple")) == "translationSlow"
              && hintName(.translationNotAnswering(engine: "Apple", addedEngine: false)) == "translationNotAnswering")
        let trouble = Instruments(args: ["in.png", "out.png"]).trouble
        let ko = TranslationRoute(source: "en", target: "ko", engineID: nil, engineName: "Apple")
        trouble.set(LensPair(source: "auto", target: "ko", engine: nil))
        trouble.read(ReadTally(inTarget: 0, needing: 3))
        trouble.apply(TranslationEvent(.timedOut, ko))
        check("one timeout is no trouble", trouble.current() == nil)
        trouble.apply(TranslationEvent(.timedOut, TranslationRoute(source: "en", target: "ja", engineID: nil, engineName: "Apple")))
        check("a batch into another language is not this lens's", trouble.current() == nil)
        trouble.apply(TranslationEvent(.timedOut, ko))
        check("two in a row are slow", trouble.current()?.kind == .slow)
        check("and a lapsed run is not", trouble.current(at: ProcessInfo.processInfo.systemUptime + TranslationWait.window + 1) == nil)
        trouble.apply(TranslationEvent(.answered, ko))
        check("a translated group ends it", trouble.current() == nil)
        // The hooks, as the host will register them. Nothing registered first: a run still has its answers.
        let bare = Instruments(args: ["in.png", "out.png", "--max-wait", "0.5"])
        check("no readerReady registered: n/a", await bare.readerLine() == "reader-ready: n/a")
        check("no statsLines registered: no lines", await bare.readerStats().isEmpty)
        let polls = OSAllocatedUnfairLock(initialState: 0), left = OSAllocatedUnfairLock(initialState: 3)
        register(inFlight: { left.withLock { n in defer { n = max(0, n - 1) }; return n } })
        register(readerReady: { polls.withLock { n in n += 1; return n >= 3 } }, statsLines: { ["lines=1", "reader: workers=2"] })
        check("a later register keeps the earlier hooks", hooks.inFlight != nil && hooks.readerReady != nil && hooks.statsLines != nil)
        let wait = await bare.readerLine()
        check("readerReady true on the third poll: its time (\(wait))", wait.hasPrefix("reader-ready: ") && Int(wait.dropFirst(14)) != nil && polls.withLock { $0 } == 3)
        check("stats lines get the prefix once", await bare.readerStats() == ["reader: lines=1", "reader: workers=2"])
        let drained = await bare.drain()
        check("the drain waits for the registered inFlight to reach 0 (\(drained.ms) ms)", drained.inFlight == 0 && drained.ms >= 200)
        register(readerReady: { false })
        check("a reader that never comes is reported after --max-wait", await bare.readerLine().hasPrefix("reader-ready: timeout "))
        print("check-instruments: \(failed == 0 ? "all PASS" : "\(failed) FAIL")")
        return failed == 0
    }

    /// What a run measures besides its result, and prints at its end (`finish`): the lens's silence and hints, the drain, the host's lines.
    fileprivate final class Instruments: @unchecked Sendable {
        /// The Trace counters of every phase so far: `printCounts` drains them.
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var counts: [String: Int] = [:]
            func add(_ c: [String: Int]) { lock.withLock { for (k, v) in c { counts[k, default: 0] += v } } }
            subscript(key: String) -> Int { lock.withLock { counts[key] ?? 0 } }
        }
        static let seen = Seen()

        /// The one issue the app keeps (`AppModel.issue`), from its two sources.
        final class Issues: @unchecked Sendable {
            private let lock = NSLock()
            private var current: TranslationIssue?
            var value: TranslationIssue? { lock.withLock { current } }
            /// A translation's issue, or its end: as `AppModel.received` (a translation that went well does not end the recognizer's).
            func fromTranslation(_ new: TranslationIssue?) {
                lock.withLock { if !(new == nil && current?.isTextRecognition == true) { current = new } }
            }
            /// The recognizer's notice, or its end: as `AppModel.recognitionNotice`.
            func fromRecognizer(_ new: TranslationIssue?) {
                lock.withLock { if let new { current = new } else if current?.isTextRecognition == true { current = nil } }
            }
        }

        /// What the reads found, for "already in <target>" (`RegionSession.read`).
        final class Streak: @unchecked Sendable {
            private let lock = NSLock()
            private var streak = TargetLanguageStreak()
            func read(_ tally: ReadTally) { _ = lock.withLock { streak.read(tally) } }
            var shown: Bool { lock.withLock { streak.shown } }
        }

        /// What the translator did with each batch and what the reads found, for "translation isn't answering" (`RegionSession.translationEvent`, `read`).
        final class Trouble: @unchecked Sendable {
            private let lock = NSLock()
            private var wait = TranslationWait()
            private var lens = LensPair(source: "auto", target: "", engine: nil)
            func set(_ pair: LensPair) { lock.withLock { lens = pair } }
            /// A new target: what failed before says nothing about it.
            func setTarget(_ language: String) { lock.withLock { lens.target = language; wait.reset() } }
            func apply(_ event: TranslationEvent) { lock.withLock { wait.apply(event, at: ProcessInfo.processInfo.systemUptime, lens: lens) } }
            func read(_ tally: ReadTally) { lock.withLock { wait.read(tally) } }
            func current(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TranslationTrouble? { lock.withLock { wait.trouble(at: now) } }
        }

        enum WarmUp { case none, running, ended }

        let issues = Issues()
        let streak = Streak()
        let trouble = Trouble()
        /// `--max-wait` when given.
        private let maxWait: Double?
        private let noDrain: Bool
        private let lock = NSLock()
        private var warmUp = WarmUp.none
        private var source = "auto", target = ""
        private var began: Date?
        private var sampler: Task<Void, Never>?
        private var meter = SilenceMeter()
        private var hints: [(name: String, ms: Int)] = []
        private var lastHint = "none"

        init(args: [String]) {
            maxWait = args.firstIndex(of: "--max-wait").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil }
            noDrain = args.contains("--no-drain")
        }

        func setTarget(_ language: String) {
            lock.withLock { target = language }
            trouble.setTarget(language)
        }

        // MARK: Warm-up

        /// Starts the text models' load as the app does at launch; the drain waits for it.
        func beginWarmUp(source: String) -> Task<Void, Never> {
            lock.withLock { warmUp = .running }
            return Task.detached(priority: .utility) { [self] in
                await AppModel.loadVision(source: source)
                lock.withLock { warmUp = .ended }
            }
        }

        /// `--warm`: until the load is done, or `--max-wait` seconds when given. False when the bound came first.
        func waitForWarmUp(_ loading: Task<Void, Never>) async -> Bool {
            guard let bound = maxWait else {
                await loading.value
                return true
            }
            let began = Date()
            while lock.withLock({ warmUp }) == .running {
                if Date().timeIntervalSince(began) >= bound { return false }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return true
        }

        // MARK: Silence timeline

        /// Samples what the lens would show every 100 ms, from now to `finish`. `drawn` is whether a translated block is on the lens.
        func startSampling(source: String, target: String, engine: UUID?, drawn: @escaping @Sendable () -> Bool) {
            let t0 = Date()
            lock.withLock { began = t0; self.source = source; self.target = target }
            trouble.set(LensPair(source: source, target: target, engine: engine))
            let task = Task.detached(priority: .userInitiated) { [self] in
                var k = 0
                while !Task.isCancelled {
                    await sample(at: Date().timeIntervalSince(t0), drawn: drawn())
                    k += 1
                    try? await Task.sleep(for: .seconds(max(0.01, Double(k) * 0.1 - Date().timeIntervalSince(t0))))
                }
            }
            lock.withLock { sampler = task }
        }

        private func sample(at t: Double, drawn: Bool) async {
            let hint = await signals(drawn: drawn).hint()
            let name = SelfTest.hintName(hint)
            lock.withLock {
                if name != lastHint {
                    hints.append((name, Int(t * 1000)))
                    lastHint = name
                }
                meter.sample(at: t, silent: !drawn && hint == nil)
            }
        }

        /// What `RegionSession.hintSignals` gathers for a lens, from the same sources: the screen is fine (a still has no capture), the
        /// recognizer's setup is `AppModel.recognitionPreparing`, and the pack is the issue's when it is this lens's pair.
        private func signals(drawn: Bool) async -> LensSignals {
            let (gate, now) = await MainActor.run { VisionSetupDisplay.current }
            let issue = issues.value
            let (source, target) = lock.withLock { (self.source, self.target) }
            var preparing: Bool
            if case .textRecognitionStarting? = issue {
                preparing = true
            } else {
                preparing = gate.shouldShowProgress(now: now) && !VisionSetupDisplay.failed(gate) && !VisionSetupDisplay.allDone(gate)
            }
            var signals = LensSignals(screen: .fine, recognitionPreparing: preparing, showsTranslations: drawn,
                                      alreadyInTarget: streak.shown ? target : nil,
                                      translation: trouble.current())
            func same(_ a: String, _ b: String) -> Bool { Locale.Language(identifier: a).languageCode == Locale.Language(identifier: b).languageCode }
            if case let .languagePackMissing(missingSource, missingTarget)? = issue, same(missingTarget, target),
               source == "auto" || same(missingSource, source) {
                signals.missingPack = PackPair(source: missingSource, target: missingTarget)
            }
            return signals
        }

        // MARK: Drain

        /// What `TextRecognizer` exposes today: a setup step is compiling (this run's load, or one a read started), or revision 3 has a
        /// request past its deadline that has not answered, which Vision keeps running (`ocr.stalled.vn3` counted, `ocr.recovered.vn3`
        /// not yet). A request that a later answer retired is not seen, so this is a lower bound.
        private func todaysInFlight() async -> Int {
            let warming = lock.withLock { warmUp } == .running || TextRecognizer.setupState.running != nil
            let counts = Self.peek()
            func n(_ key: String) -> Int { Self.seen[key] + (counts[key] ?? 0) }
            let stalled = n("ocr.stalled.vn3") - n("ocr.recovered.vn3") > 0
            return (warming ? 1 : 0) + (stalled ? 1 : 0)
        }

        /// The Trace counters without draining them (the next `printCounts` still sees them).
        private static func peek() -> [String: Int] {
            let counts = Trace.takeCounts()
            for (key, n) in counts { Trace.count(key, n) }
            return counts
        }

        /// Waits until nothing is in flight (the host's `inFlight` plus today's), 180 s at most. `--max-wait` does not shorten it: a run
        /// that gave up waiting (a settle that hit its bound behind a compile) is the one that would exit mid-compile.
        func drain() async -> (ms: Int, inFlight: Int) {
            // The host's requests (the Docs service) and what this process still runs itself (the text model's load, a revision 3
            // request past its deadline): both, because Lines is not hosted yet (r3-docs-xpc).
            let inFlight: @Sendable () async -> Int = { [self] in await (SelfTest.hooks.inFlight?() ?? 0) + todaysInFlight() }
            let began = Date(), bound = 180.0
            var n = await inFlight()
            while n > 0, Date().timeIntervalSince(began) < bound {
                try? await Task.sleep(for: .milliseconds(100))
                n = await inFlight()
            }
            return (SelfTest.ms(began), n)
        }

        // MARK: Reader

        /// `--then reader-ready`: prints `readerLine`.
        func waitForReader() async { print(await readerLine()) }

        /// Waits until the host says its readers are warm, `--max-wait` seconds at most (600 by default); the line to print: its time in
        /// ms, `timeout <ms>`, or `n/a` while no host has registered.
        func readerLine() async -> String {
            guard let ready = SelfTest.hooks.readerReady else { return "reader-ready: n/a" }
            let began = Date(), bound = maxWait ?? 600
            while !(await ready()) {
                if Date().timeIntervalSince(began) >= bound { return "reader-ready: timeout \(SelfTest.ms(began))" }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return "reader-ready: \(SelfTest.ms(began))"
        }

        /// The host's stats as `reader: <line>` lines (a line that starts with `reader:` is kept as it is).
        func readerStats() async -> [String] {
            guard let stats = SelfTest.hooks.statsLines else { return [] }
            return await stats().map { $0.hasPrefix("reader:") ? $0 : "reader: \($0)" }
        }

        // MARK: The end of the run

        /// Drains, stops the timeline, and prints: `hint:` lines, `silence:`, `drain:`, then the host's `reader:` lines.
        func finish() async {
            let drained = noDrain ? nil : await drain()
            let (task, t0) = lock.withLock { (sampler, began) }
            task?.cancel()
            await task?.value
            if let t0 {
                let (m, changes) = lock.withLock { () -> (SilenceMeter, [(name: String, ms: Int)]) in
                    meter.end(at: Date().timeIntervalSince(t0))
                    return (meter, hints)
                }
                for h in changes { print("hint: \(h.name) at \(h.ms)") }
                print("silence: longest=\(Int((m.longest * 1000).rounded())) total=\(Int((m.total * 1000).rounded()))")
            } else {
                print("silence: n/a")
            }
            print(drained.map { "drain: \($0.ms) in-flight=\($0.inFlight)" } ?? "drain: skipped")
            for line in await readerStats() { print(line) }
        }
    }
}
#endif
