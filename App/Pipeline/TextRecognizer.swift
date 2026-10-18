import CoreGraphics
import CoreText
import Foundation
import MwoyeoCore
import NaturalLanguage
import Vision
import os

/// One recognized line, in image pixels (top-left origin).
struct OCRLine: Sendable {
    var rect: CGRect
    var text: String
    /// Its words (CJK: characters) with their boxes, where Vision could place them.
    var words: [OCRWord] = []
}

struct OCRWord: Sendable {
    var rect: CGRect
    /// Range in the line's `text`.
    var range: Range<String.Index>
}

/// A paragraph: lines that read as one unit and should be translated together.
struct OCRBlock: Sendable {
    var rect: CGRect
    var lines: [OCRLine]
    var text: String
}

enum TextRecognizer {
    /// Per-line recognition, optionally restricted to `roi` (image pixels).
    /// `fast` only reads Latin scripts; callers pick it only for those.
    static func lines(in image: CGImage, roi: CGRect? = nil, languages: [Locale.Language], fast: Bool,
                      customWords: [String] = []) async throws -> [OCRLine] {
        Trace.count("ocr.lines")
        if fast { return try await fastLines(in: image, roi: roi, languages: languages) }
        return try await accurate(in: image, roi: roi, languages: languages, customWords: customWords)
    }

    /// `.fast` through the Objective-C request: the Swift `RecognizeTextRequest` at `.fast` returns no observations at all on
    /// macOS 27 (the Swift document and text requests are used for paragraphs only, see `blocks`).
    private static func fastLines(in image: CGImage, roi: CGRect?, languages: [Locale.Language]) async throws -> [OCRLine] {
        let wanted = languages.compactMap(\.languageCode)
        return try await deadline {
            try visionRead(in: image, roi: roi, level: .fast, revision: nil, customWords: []) { req in
                // Its identifiers look like "en-US"; match by language code.
                let supported = (try? req.supportedRecognitionLanguages()) ?? []
                return wanted.compactMap { w in supported.first { Locale.Language(identifier: $0).languageCode == w } }
            }
        }
    }

    /// The Objective-C recognizer, run to completion (the callers bound it). `languages` picks the identifiers to read
    /// (empty: detect), given the request to ask.
    private static func visionRead(in image: CGImage, roi: CGRect?, level: VNRequestTextRecognitionLevel, revision: Int?,
                                   customWords: [String], languages: (VNRecognizeTextRequest) -> [String]) throws -> [OCRLine] {
        let size = CGSize(width: image.width, height: image.height)
        let region = roi.map { normalized($0, in: size) } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        if let revision { req.revision = revision }
        req.usesLanguageCorrection = level == .accurate
        req.customWords = customWords
        let codes = languages(req)
        if codes.isEmpty { req.automaticallyDetectsLanguage = true } else { req.recognitionLanguages = codes }
        req.regionOfInterest = region
        try VNImageRequestHandler(cgImage: image).perform([req])
        return (req.results ?? []).compactMap { obs -> OCRLine? in
            guard let c = obs.topCandidates(1).first, c.confidence >= 0.3 else { return nil }
            let words = wordRanges(c.string).compactMap { r in
                (try? c.boundingBox(for: r)).flatMap { $0 }.map { OCRWord(rect: pixelRect(unclip($0.boundingBox, from: region), in: size), range: r) }
            }
            return OCRLine(rect: pixelRect(unclip(obs.boundingBox, from: region), in: size), text: c.string, words: words)
        }
    }

    /// Words split at spaces; CJK has none, so its words are single characters.
    private static func wordRanges(_ s: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var i = s.startIndex
        while i < s.endIndex {
            guard !s[i].isWhitespace else { i = s.index(after: i); continue }
            let j = s[i...].firstIndex(where: \.isWhitespace) ?? s.endIndex
            if s[i..<j].contains(where: isCJK) {
                ranges += s[i..<j].indices.map { $0..<s.index(after: $0) }
            } else {
                ranges.append(i..<j)
            }
            i = j
        }
        return ranges
    }

    /// Paragraph-level recognition. Priority: Swift document model (`RecognizeDocumentsRequest`, once the gate says its model is
    /// loaded for these languages) > VN revision 3 + `ParagraphGrouper` > revision 2 > `.fast` > issue (`accurate`). A document read
    /// that has not answered in `documentDeadline` falls back to VN for that read, and the key waits for a retry (`SwiftVisionGate.missed`).
    /// `plan` says which paragraph reader the lens wants (`ParagraphReader`): `lineGrouping` never asks the document model, and
    /// `automatic` reads the lines with VN first and lets `ReaderDecider` pick from their layout; once the plan holds the document
    /// model, that model reads alone and its lines feed the decision.
    static func blocks(in image: CGImage, roi: CGRect? = nil, languages: [Locale.Language], customWords: [String] = [],
                       plan: ReaderPlan? = nil) async throws -> [OCRBlock] {
        Trace.count("ocr.blocks")
        let key = key(languages)
        let wanted: ParagraphReader = switch ocrPath {
        case .vn: .lineGrouping
        case .swift: .documentLayout
        case nil: plan?.setting ?? .automatic
        }
        var read: [OCRLine]?
        if wanted != .lineGrouping {
            if gate.withLock({ $0.want(key) }) { publishAndRun() }
            if gate.withLock({ $0.isReady(key) }) {
                var reader = wanted
                // Automatic with the document model already held: its own lines are the layout evidence, so the frame is read
                // once, not twice (VN first cost ~0.2 s more per subtitle frame, usecase-bench 2026-10-18).
                if wanted == .automatic, let plan, plan.held == .documentLayout {
                    let t = Trace.now
                    do {
                        let found = try await deadline(seconds: documentDeadline) { try await swiftBlocks(in: image, roi: roi, languages: languages, customWords: customWords) }
                        let lines = found.flatMap(\.lines)
                        let (_, why) = plan.decide(lines: lines.map(\.rect), texts: lines.map(\.text),
                                                   size: CGSize(width: image.width, height: image.height), partial: roi != nil)
                        Trace.count("ocr.reader.auto.held")
                        Trace.mark(why + " (document lines)", since: t)
                        Trace.count("ocr.blocks.swift")
                        Trace.count("ocr.blocks.lines", lines.count)
                        return found
                    } catch is Timeout {
                        Trace.count("ocr.swift.missed")
                        log.error("document recognition did not answer in \(Int(documentDeadline)) s, reading with VN")
                        gate.withLock { $0.missed(key) }
                        publishAndRun()
                    } catch {
                        if OCRHealth.programsNotReady(error) { Trace.count("ocr.swift.notready") }
                        log.error("document recognition failed: \(String(describing: error), privacy: .public), reading with VN")
                    }
                    reader = .lineGrouping
                } else if wanted == .automatic {
                    let t = Trace.now
                    // VN not answering must not stop the read: the document model does not need its lines.
                    let seen: [OCRLine]
                    do { seen = try await accurate(in: image, roi: roi, languages: languages, customWords: customWords) } catch {
                        Trace.count("ocr.reader.auto.vnfailed")
                        Trace.mark("reader auto → documentLayout: lines not read (\(error))", since: t)
                        seen = []
                    }
                    read = seen.isEmpty ? nil : seen
                    let size = CGSize(width: image.width, height: image.height)
                    let rects = seen.map(\.rect)
                    let (chosen, why) = seen.isEmpty ? (.documentLayout, "reader auto → documentLayout: no lines") : plan?.decide(lines: rects, texts: seen.map(\.text), size: size, partial: roi != nil)
                        ?? (.documentLayout, "reader auto → documentLayout: no plan")
                    reader = chosen
                    Trace.count("ocr.reader.auto." + chosen.rawValue)
                    Trace.mark(why, since: t)
                    if Trace.lineDump {
                        Trace.mark("reader lines \(size.width)x\(size.height) " + rects.map { "[\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width)),\(Int($0.height))]" }.joined(), since: t)
                    }
                }
                if reader == .documentLayout {
                    do {
                        let found = try await deadline(seconds: documentDeadline) { try await swiftBlocks(in: image, roi: roi, languages: languages, customWords: customWords) }
                        Trace.count("ocr.blocks.swift")
                        Trace.count("ocr.blocks.lines", found.reduce(0) { $0 + $1.lines.count })
                        return found
                    } catch is Timeout {
                        Trace.count("ocr.swift.missed")
                        log.error("document recognition did not answer in \(Int(documentDeadline)) s, reading with VN")
                        gate.withLock { $0.missed(key) }
                        publishAndRun()
                    } catch {
                        if OCRHealth.programsNotReady(error) { Trace.count("ocr.swift.notready") }
                        log.error("document recognition failed: \(String(describing: error), privacy: .public), reading with VN")
                    }
                }
            }
        }
        Trace.count("ocr.blocks.vn")
        let lines: [OCRLine]
        if let read { lines = read } else { lines = try await accurate(in: image, roi: roi, languages: languages, customWords: customWords) }
        Trace.count("ocr.blocks.lines", lines.count)
        return ParagraphGrouper.groups(lines, rect: \.rect, text: \.text).map(makeBlock)
    }

    /// Warm document reads take 0.33-0.48 s (vision-revive, 2026-10-18).
    private static let documentDeadline: Double = 8

    private static func swiftBlocks(in image: CGImage, roi: CGRect?, languages: [Locale.Language], customWords: [String]) async throws -> [OCRBlock] {
        var req = RecognizeDocumentsRequest()
        req.textRecognitionOptions.customWords = customWords
        if languages.isEmpty {
            req.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
            req.textRecognitionOptions.recognitionLanguages = languages
        }
        let size = CGSize(width: image.width, height: image.height)
        let region = roi.map { normalized($0, in: size) } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        req.regionOfInterest = NormalizedRect(normalizedRect: region)
        var out: [OCRBlock] = []
        for doc in try await req.perform(on: image) {
            for paragraph in doc.document.paragraphs {
                let lines = paragraph.lines.compactMap { obs -> OCRLine? in
                    guard let c = obs.topCandidates(1).first, !c.string.isEmpty else { return nil }
                    let words = wordRanges(c.string).compactMap { r in
                        c.boundingBox(for: r).map { OCRWord(rect: pixelRect(unclip($0.boundingBox.cgRect, from: region), in: size), range: r) }
                    }
                    return OCRLine(rect: pixelRect(unclip(obs.boundingBox.cgRect, from: region), in: size), text: c.string, words: words)
                }
                guard !lines.isEmpty else { continue }
                out.append(makeBlock(lines))
            }
        }
        return out
    }

    struct Timeout: Error {}

    /// An accurate read that cannot be had: every recognizer for these languages is not answering (or none reads them). Not
    /// retried by the passes (a retry would only wait again); the user has been told (see `setNoticeHandler`).
    struct Stalled: Error {}

    private static let warm = OSAllocatedUnfairLock(initialState: false)
    private static let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "ocr")

    /// Vision requests occasionally never return (seen with the Swift document recognizer after many runs). A stuck
    /// request must not stall the region forever: give up after `seconds` and let the caller fall back or retry.
    /// The abandoned request keeps running in the background, and is never cancelled: a model that is only compiling
    /// (revision 3 compiles for up to a minute the first time it meets a wider line of text, see `probePicture`) starts over
    /// when its client goes away.
    static func deadline<T: Sendable>(seconds: Double? = nil, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        // Until one request has finished, the models are still loading (tens of seconds on a fresh install).
        let seconds: Double = seconds ?? (warm.withLock { $0 } ? 8 : 90)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let done = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Result<T, Error>) -> Void = { r in
                if done.withLock({ was in defer { was = true }; return !was }) { cont.resume(with: r) }
            }
            Task {
                do {
                    let r = try await work()
                    warm.withLock { $0 = true }
                    finish(.success(r))
                } catch { finish(.failure(error)) }
            }
            Task { try? await Task.sleep(for: .seconds(seconds)); finish(.failure(Timeout())) }
        }
    }

    // MARK: - Which recognizer reads

    /// The Objective-C `VNRecognizeTextRequest` reads lines; paragraphs come from the Swift document model once it is loaded
    /// (`gate`), else from those lines grouped by `ParagraphGrouper`. The Swift models are loaded by the app itself at launch
    /// (`warmUp`): a cold compile takes 80-90 s and a VN revision 3 read in the same process waits for it, a warm one answers in
    /// 0.3-0.5 s and does not disturb VN (tools/ocr-probe/mix.swift). Revision 3 is the one that can stall (a compile that hangs or
    /// crawls, `OCRHealth`); the health below is that revision's.
    ///
    /// `MWOYEO_OCR_PATH=vn|swift` for gates: `vn` never asks a Swift model, `swift` assumes the document model ready.
    private enum OCRPath { case vn, swift }
    private static let ocrPath: OCRPath? = switch ProcessInfo.processInfo.environment["MWOYEO_OCR_PATH"] {
    case "vn": .vn
    case "swift": .swift
    default: nil
    }

    /// The initialization steps and which keys may ask the Swift models (`SwiftVisionGate`); `VisionSetup` shows it.
    private static let gate = OSAllocatedUnfairLock<SwiftVisionGate>(initialState: {
        var g = SwiftVisionGate()
        if ocrPath == .swift { g.assumeReady() }
        return g
    }())

    /// The gate as it is now.
    static var setupState: SwiftVisionGate { gate.withLock { $0 } }

    /// The key for reads in these languages (empty: detect).
    static func key(_ languages: [Locale.Language]) -> String {
        let codes = languages.compactMap(code)
        return codes.isEmpty ? SwiftVisionGate.anyLanguage : codes.joined(separator: ",")
    }

    private static func languages(of key: String) -> [Locale.Language] {
        key == SwiftVisionGate.anyLanguage ? [] : key.split(separator: ",").map { Locale.Language(identifier: String($0)) }
    }

    private static let health = OSAllocatedUnfairLock(initialState: OCRHealth())
    /// Suffix of the counters about revision 3: `ocr.stalled.vn3`, `ocr.recovered.vn3`, `ocr.probe.vn3`.
    private static let counterTag = ".vn3"

    /// The recognizers for these languages go down the ladder (`OCRFallback`): revision 3 (reads everything), then revision 2,
    /// then `.fast`, as far as each reads the languages. A read revision 3 does not answer in time goes down the same
    /// ladder, which is also where reads go while it is stalled. Where no rung is left it throws `Stalled`. A slow model is
    /// never cancelled.
    private static func accurate(in image: CGImage, roi: CGRect?, languages: [Locale.Language],
                                 customWords: [String]) async throws -> [OCRLine] {
        let rungs = OCRFallback.ladder(requested: languages.compactMap(code), vision3: vision3Languages,
                                       revision2: revision2Languages, fast: fastLanguages)
        let read: @Sendable (OCRFallback) throws -> [OCRLine] = { try readRung($0, in: image, roi: roi, customWords: customWords) }
        for (i, rung) in rungs.enumerated() {
            let more = i < rungs.count - 1
            switch rung {
            case .vision3:
                // While a Swift model is compiling, a revision 3 read of this process waits for the compile: 37 s with revision 3
                // warm and a cold Swift text model (vision-revive, 2026-10-18, /tmp/vision2/step0f.log), against 0.23 s when warm. So a read
                // that has an older recognizer for its language goes there; one that has none waits (the notice tells).
                if more, gate.withLock({ $0.isSwiftCompiling }) {
                    Trace.count("ocr.fallback.swiftcompiling")
                    continue
                }
                switch health.withLock({ $0.plan(canFallBack: more, now: Trace.now) }) {
                case .refuse:
                    throw stalled(languages)
                case .fallback:
                    continue
                case let .run(seconds):
                    // Named for the ladder (`ocr.fallback.<rung>`, as the scripts count it): every read counts its rung, the first too.
                    Trace.count("ocr.fallback.vn3")
                    do {
                        return try await tracked(seconds, tellingAbout: more ? nil : languages) { try read(rung) }
                    } catch is Timeout {
                        if !more { throw stalled(languages) }
                    } catch where more && OCRHealth.programsNotReady(error) {
                        // Its programs are not ready (a transient after a long cold compile): the same call reads on revision 2 or
                        // `.fast`, and `health` keeps reads there for `OCRHealth.notReadyRetryEvery`.
                        Trace.count("ocr.fallback.notready")
                    }
                }
            case .revision2:
                Trace.count("ocr.fallback.rev2")
                return try await deadline { try read(rung) }
            case .fast:
                Trace.count("ocr.fallback.fast")
                return try await deadline { try read(rung) }
            }
        }
        throw stalled(languages)
    }

    /// One request on revision 3, within `seconds`. `tellingAbout` is the languages to tell the user about when nothing else
    /// can read them and the wait runs long.
    private static func tracked<T: Sendable>(_ seconds: Double, tellingAbout languages: [Locale.Language]? = nil,
                                             _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let id = health.withLock { $0.begin(now: Trace.now) }
        let starting: Task<Void, Never>? = languages == nil || seconds <= OCRHealth.lateAfter ? nil : Task {
            try? await Task.sleep(for: .seconds(OCRHealth.lateAfter))
            if !Task.isCancelled { raise(preparing(languages ?? [])) }
        }
        defer { starting?.cancel() }
        do {
            return try await deadline(seconds: seconds) { try await observed(id, work) }
        } catch is Timeout {
            if health.withLock({ $0.missed(id, now: Trace.now) }) {
                Trace.count("ocr.stalled" + counterTag)
                log.error("text recognition (revision 3) did not answer in \(Int(seconds)) s")
                startProbing()
            }
            throw Timeout()
        }
    }

    /// Runs `work` as request `id`, and notes how it ended, whenever that is (an abandoned request can come back minutes
    /// later).
    private static func observed<T: Sendable>(_ id: Int, _ work: @Sendable () async throws -> T) async throws -> T {
        do {
            try await simulated()
            let r = try await work()
            if health.withLock({ $0.answered(id) }) { Trace.count("ocr.recovered" + counterTag) }
            raise(nil)
            return r
        } catch {
            if OCRHealth.programsNotReady(error) {
                health.withLock { $0.notReady(id, now: Trace.now) }
                Trace.count("ocr.notready" + counterTag)
            } else {
                health.withLock { $0.failed(id) }
            }
            throw error
        }
    }

    /// While stalled, one small picture goes to revision 3 every two minutes (and none while a request of the last two
    /// minutes is still loading), so that the notice and the fallback end when it answers again.
    private static func startProbing() {
        guard let picture = probePicture, health.withLock({ $0.startProbing() }) else { return }
        Task.detached(priority: .utility) {
            while true {
                try? await Task.sleep(for: .seconds(OCRHealth.probeEvery))
                if health.withLock({ $0.stopProbing() }) { return }
                guard let id = health.withLock({ $0.probeDue(now: Trace.now) ? $0.begin(now: Trace.now) : nil }) else { continue }
                Trace.count("ocr.probe" + counterTag)
                // Returns when the model does, if ever: the next probe waits for it.
                _ = try? await observed(id) { try visionRead(in: picture, roi: nil, level: .accurate, revision: 3, customWords: []) { _ in [] } }
            }
        }
    }

    /// The initialization, at every launch: for the key of `languages`, `SwiftVisionGate.Step`s in order, in the background and to
    /// completion (a load is never cancelled): revision 3 on a drawn wide line (given the cold allowance; reads that come meanwhile
    /// do not queue behind it unless nothing else can read their language), then the Swift document model, then the Swift text
    /// model. A failed step is not retried here: the next launch or `retry()` does (a first missed document deadline is not a
    /// failure: `SwiftVisionGate.missed`). Tells the user nothing (`VisionSetup` is what a screen reads).
    static func warmUp(languages: [Locale.Language] = []) async {
        gate.withLock { $0.want(key(languages)) }
        await runSteps()
        // A read may have started the steps first: wait for the one that runs.
        while gate.withLock({ $0.running != nil }) { try? await Task.sleep(for: .milliseconds(100)) }
    }

    /// Runs the due steps one after another; a second caller while one runs returns at once (the first goes on to the next).
    private static func runSteps() async {
        while true {
            let due = gate.withLock { g -> SwiftVisionGate.Due? in
                guard let d = g.nextDue(), ocrPath != .vn || d.step == .textModel else { return nil }
                g.started(d, now: Trace.now)
                return d
            }
            guard let due else { return }
            publish()
            var failure: String?
            let began = Trace.now
            do { try await perform(due) } catch { failure = String(describing: error) }
            gate.withLock { $0.finished(failure: failure, now: Trace.now) }
            publish()
            Trace.mark("vision setup \(due.step.rawValue) [\(due.key)] \(failure.map { "failed: \($0)," } ?? "done,")", since: began)
            if let failure { log.error("vision setup \(due.step.rawValue, privacy: .public) for \(due.key, privacy: .public) failed: \(failure, privacy: .public)") }
        }
    }

    private static func perform(_ due: SwiftVisionGate.Due) async throws {
        guard let picture = probePicture else { throw Stalled() }
        switch due.step {
        case .textModel:
            try await askingAgainWhileNotReady {
                _ = try await tracked(OCRHealth.coldWait) {
                    try visionRead(in: picture, roi: nil, level: .accurate, revision: 3, customWords: []) { _ in [] }
                }
            }
        case .documentModel, .swiftTextModel:
            // The compile (80-90 s cold) runs in a child process, where no read of this process waits for it; the load here
            // afterwards finds the model in the system's cache (under 2 s). If no child can be started, it is loaded here.
            gate.withLock { $0.childPhase(true) }
            let outcome = await SwiftVisionChild.run(step: due.step, key: due.key)
            gate.withLock { $0.childPhase(false) }
            if case let .failed(message) = outcome { throw ChildFailure(message: message) }
            let began = Trace.now
            try await loadSwiftModel(step: due.step, key: due.key)
            Trace.mark("vision setup \(due.step.rawValue) [\(due.key)] in this process, child \(outcome == .loaded ? "loaded" : "unavailable"),", since: began)
        }
    }

    private struct ChildFailure: Error, CustomStringConvertible { let message: String; var description: String { message } }

    /// "Programs not ready" is a transient (OCRHealth): a model load asks again every few seconds, within the cold allowance.
    private static func askingAgainWhileNotReady(_ load: () async throws -> Void) async throws {
        let began = Trace.now
        while true {
            do {
                try await load()
                return
            } catch where OCRHealth.programsNotReady(error) && Trace.now - began < OCRHealth.coldWait {
                Trace.count("ocr.setup.notready")
                try await Task.sleep(for: .seconds(OCRHealth.notReadyRetryEvery))
            }
        }
    }

    /// Loads the Swift model of `step` for `key` on the drawn picture (the app's own load, and the child's).
    static func loadSwiftModel(step: SwiftVisionGate.Step, key: String) async throws {
        guard let picture = probePicture else { throw Stalled() }
        let languages = languages(of: key)
        switch step {
        case .textModel:
            break
        case .documentModel:
            try await askingAgainWhileNotReady {
                _ = try await swiftBlocks(in: picture, roi: nil, languages: languages, customWords: [])
            }
        case .swiftTextModel:
            var req = RecognizeTextRequest()
            req.recognitionLevel = .accurate
            if languages.isEmpty { req.automaticallyDetectsLanguage = true } else { req.recognitionLanguages = languages }
            try await askingAgainWhileNotReady { _ = try await req.perform(on: picture) }
        }
    }

    /// Every failed step is run again (the screen's retry button); steps never retry themselves.
    static func retrySetup() {
        gate.withLock { $0.retry() }
        publishAndRun()
    }

    private static func publishAndRun() {
        publish()
        Task.detached(priority: .utility) { await runSteps() }
    }

    private static func publish() {
        Task { @MainActor in VisionSetup.shared.gate = TextRecognizer.setupState }
    }

    /// Latin and CJK text, drawn here so that the probe and the warm-up need no file: a Latin line of 240 characters, a CJK line of
    /// 80 and a short one, 24 pt. Revision 3 compiles a program per width of text line (line width over line height) on first
    /// use, 30 to 65 s each on a Mac, and a program serves every narrower line. Measured 2026-10-17: a short line (aspect 9) left
    /// the first read of the chat picture (aspect 45) 32 s cold, a line of aspect 82 (2486 × 52 px) made all of them (chat, article,
    /// forum, ja, en, aspect 9 to 60) fast. So the warm-up picture carries the widest line a screen shows.
    static let probePicture: CGImage? = {
        let sentence = "the quick brown fox jumps over a lazy dog while reading text"
        let latin = String(Array(repeating: sentence, count: 4).joined(separator: " ").prefix(240))
        let cjk = String(Array(repeating: "今日はとても楽しかったねまた明日も一緒に遊ぼう海外のゲームや漫画まだ翻訳されていない最新の技術記事", count: 2).joined().prefix(80))
        let font = CTFontCreateUIFontForLanguage(.system, 24, nil)
        let lines = [latin, cjk, "Hello 世界 こんにちは"].map {
            CTLineCreateWithAttributedString(NSAttributedString(
                string: $0, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
                                         NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]))
        }
        let w = Int(lines.map { CTLineGetBoundsWithOptions($0, []).width }.max() ?? 0) + 48, h = lines.count * 64 + 16
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(.black)
        for (i, line) in lines.enumerated() {
            ctx.textPosition = CGPoint(x: 24, y: CGFloat(h - 64 * (i + 1)) + 10)
            CTLineDraw(line, ctx)
        }
        return ctx.makeImage()
    }()

    /// `MWOYEO_FAKE_OCR=stall` or `stall-vn` (revision 3 never answers, as on the stalled Mac: the reads go down the ladder to
    /// revision 2 and `.fast`) or `slow:<ms>` (revision 3 answers late), to exercise the fallback and the recovery on a healthy
    /// Mac. Read like `MWOYEO_FAKE_ENGINE`: in any build. Only revision 3 is simulated, never the Swift models, so `stall` is the
    /// same as `stall-vn`.
    private static let fake = ProcessInfo.processInfo.environment["MWOYEO_FAKE_OCR"]

    /// `MWOYEO_FAKE_OCR=e5rt[:n]`: revision 3 throws the error a Mac logs while its programs are not ready, n times (20), then works.
    private enum FakeVisionError: Error { case e5rtError(String, Int) }
    private static let e5rtLeft = OSAllocatedUnfairLock<Int?>(initialState: nil)

    private static func simulated() async throws {
        guard let fake else { return }
        if fake == "e5rt" || fake.hasPrefix("e5rt:") {
            let throwing = e5rtLeft.withLock { left -> Bool in
                let n = left ?? Int(fake.dropFirst(5)) ?? 20
                left = max(0, n - 1)
                return n > 0
            }
            if throwing {
                throw FakeVisionError.e5rtError("e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed", 13)
            }
        } else if fake == "stall" || fake == "stall-vn" {
            try await Task.sleep(for: .seconds(31_536_000))
        } else if fake.hasPrefix("slow:"), let ms = Int(fake.dropFirst(5)) {
            try await Task.sleep(for: .milliseconds(ms))
        }
    }

    // MARK: The recognizers

    private static let vision3Languages = supportedLanguages(level: .accurate, revision: 3)
    private static let revision2Languages = supportedLanguages(level: .accurate, revision: 2)
    private static let fastLanguages = supportedLanguages(level: .fast, revision: nil)

    /// What a recognizer reads, as its own identifiers ("en-US"); empty if this system no longer has it.
    private static func supportedLanguages(level: VNRequestTextRecognitionLevel, revision: Int?) -> [String] {
        if let revision, !VNRecognizeTextRequest.supportedRevisions.contains(revision) { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        if let revision { req.revision = revision }
        return (try? req.supportedRecognitionLanguages()) ?? []
    }

    /// "ja", "zh-Hans": the language, and the script when it names one.
    static func code(_ l: Locale.Language) -> String? {
        guard let c = l.languageCode?.identifier else { return nil }
        return l.script.map { "\(c)-\($0.identifier)" } ?? c
    }

    private static func readRung(_ rung: OCRFallback, in image: CGImage, roi: CGRect?, customWords: [String]) throws -> [OCRLine] {
        switch rung {
        case let .vision3(ids): try visionRead(in: image, roi: roi, level: .accurate, revision: 3, customWords: customWords) { _ in ids }
        case let .revision2(ids): try visionRead(in: image, roi: roi, level: .accurate, revision: 2, customWords: customWords) { _ in ids }
        case let .fast(ids): try visionRead(in: image, roi: roi, level: .fast, revision: nil, customWords: []) { _ in ids }
        }
    }

    // MARK: The notice

    private struct Notice {
        var handler: (@Sendable (TranslationIssue?) -> Void)?
        var shown: TranslationIssue?
    }
    private static let notice = OSAllocatedUnfairLock(initialState: Notice())

    /// Told when reading is impossible for now (no recognizer answers for the source language yet), first that macOS is
    /// still preparing, after three minutes that it is not responding; nil once one has answered. Only changes are passed on.
    static func setNoticeHandler(_ h: @escaping @Sendable (TranslationIssue?) -> Void) {
        notice.withLock { $0.handler = h }
    }

    private static func raise(_ issue: TranslationIssue?) {
        let call = notice.withLock { n -> (@Sendable (TranslationIssue?) -> Void)? in
            guard n.shown != issue else { return nil }
            n.shown = issue
            return n.handler
        }
        call?(issue)
    }

    private static func preparing(_ languages: [Locale.Language]) -> TranslationIssue {
        // The name the language bar uses: "ja", not "ja-Jpan" ("Japanese (Japanese)"); only Chinese needs its script.
        .textRecognitionStarting(language: languages.first.flatMap { $0.languageCode?.identifier == "zh" ? code($0) : $0.languageCode?.identifier } ?? "")
    }

    /// A read nothing answers: "still preparing" until revision 3 has been silent for three minutes, then "not responding".
    private static func stalled(_ languages: [Locale.Language]) -> Stalled {
        let age = health.withLock { $0.stalledFor(now: Trace.now) } ?? 0
        raise(age >= OCRHealth.giveUpAfter ? .textRecognitionStalled : preparing(languages))
        return Stalled()
    }

    /// Lines → block, joining text the way the script expects (no spaces between CJK lines).
    static func makeBlock(_ lines: [OCRLine]) -> OCRBlock {
        let rect = lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) }
        var text = ""
        for line in lines {
            if let last = text.last, let first = line.text.first, !(isCJK(last) || isCJK(first)) {
                text += last == "-" ? "" : " "
            }
            text += line.text
        }
        return OCRBlock(rect: rect, lines: lines, text: text)
    }

    /// Text worth translating: has letters, and is not already in the target language.
    static func needsTranslation(_ text: String, target: String) -> Bool {
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return false }
        if TranslationFilter.isLiteral(text) {
            if TranslationFilter.isFormula(text) || TranslationFilter.isIdentifier(text) { Trace.count("ocr.kept.formula") }
            return false
        }
        let targetCode = Locale.Language(identifier: target).languageCode?.identifier
        // Hangul is unambiguous; for other targets ask NaturalLanguage, but only trust confident answers.
        if targetCode == "ko" {
            let hangul = text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }.count
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            return Double(hangul) / Double(max(letters, 1)) < 0.5
        }
        let r = NLLanguageRecognizer()
        r.processString(text)
        if let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p > 0.8,
           Locale.Language(identifier: lang.rawValue).languageCode?.identifier == targetCode {
            return false
        }
        return true
    }

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            (0x3040...0x30FF).contains(s.value) || (0x3400...0x9FFF).contains(s.value) ||
                (0xF900...0xFAFF).contains(s.value) || (0xFF00...0xFFEF).contains(s.value) ||
                (0x3000...0x303F).contains(s.value)
        }
    }

    /// Region-of-interest-relative normalized box → image-relative normalized box.
    private static func unclip(_ b: CGRect, from region: CGRect) -> CGRect {
        CGRect(x: region.minX + b.minX * region.width, y: region.minY + b.minY * region.height,
               width: b.width * region.width, height: b.height * region.height)
    }

    private static func pixelRect(_ n: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: n.minX * size.width, y: (1 - n.maxY) * size.height, width: n.width * size.width, height: n.height * size.height)
    }

    /// Image pixels (top-left origin) → Vision's normalized region of interest (bottom-left origin).
    private static func normalized(_ r: CGRect, in size: CGSize) -> CGRect {
        let c = r.intersection(CGRect(origin: .zero, size: size))
        return CGRect(x: c.minX / size.width, y: 1 - c.maxY / size.height, width: c.width / size.width, height: c.height / size.height)
    }
}
