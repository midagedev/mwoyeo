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
    /// `fast` only reads Latin scripts; callers pick it only for those. `warmUp` reads only to load the models: it never
    /// tells the user anything.
    static func lines(in image: CGImage, roi: CGRect? = nil, languages: [Locale.Language], fast: Bool,
                      customWords: [String] = [], warmUp: Bool = false) async throws -> [OCRLine] {
        Trace.count("ocr.lines")
        if fast { return try await fastLines(in: image, roi: roi, languages: languages) }
        var req = RecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.customWords = customWords
        if languages.isEmpty {
            req.automaticallyDetectsLanguage = true
        } else {
            req.recognitionLanguages = languages
        }
        let size = CGSize(width: image.width, height: image.height)
        let region = roi.map { normalized($0, in: size) } ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        req.regionOfInterest = region
        let request = req
        return try await accurate(languages, warmUp: warmUp, newest: {
            try await request.perform(on: image).compactMap { obs in
                guard let candidate = obs.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
                return line(candidate, box: obs.boundingBox.cgRect, region: region, size: size)
            }
        }, older: { rung in
            try readOlder(rung, in: image, roi: roi, customWords: customWords)
        })
    }

    /// The Swift `RecognizeTextRequest` at `.fast` returns no observations at all on macOS 27 (any image, any
    /// language); the Objective-C request still reads. ponytail: back to `RecognizeTextRequest` once `.fast` reads.
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
        let region = roi.map { normalized($0, in: size) } ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        if let revision { req.revision = revision }
        req.usesLanguageCorrection = level == .accurate
        req.customWords = customWords
        let codes = languages(req)
        if codes.isEmpty { req.automaticallyDetectsLanguage = true } else { req.recognitionLanguages = codes }
        req.regionOfInterest = region.cgRect
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

    /// Paragraph-level recognition via the document recognizer, which groups lines into reading units. While the
    /// newest model is stalled the lines of another recognizer stand in, one block per line.
    static func blocks(in image: CGImage, roi: CGRect? = nil, languages: [Locale.Language], customWords: [String] = [],
                       warmUp: Bool = false) async throws -> [OCRBlock] {
        Trace.count("ocr.blocks")
        var req = RecognizeDocumentsRequest()
        req.textRecognitionOptions.customWords = customWords
        if languages.isEmpty {
            req.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
            req.textRecognitionOptions.recognitionLanguages = languages
        }
        let size = CGSize(width: image.width, height: image.height)
        let region = roi.map { normalized($0, in: size) } ?? NormalizedRect(x: 0, y: 0, width: 1, height: 1)
        req.regionOfInterest = region
        let request = req
        return try await accurate(languages, warmUp: warmUp, newest: {
            var out: [OCRBlock] = []
            for doc in try await request.perform(on: image) {
                for paragraph in doc.document.paragraphs {
                    let lines = paragraph.lines.compactMap { obs -> OCRLine? in
                        guard let c = obs.topCandidates(1).first, !c.string.isEmpty else { return nil }
                        return line(c, box: obs.boundingBox.cgRect, region: region, size: size)
                    }
                    guard !lines.isEmpty else { continue }
                    out.append(makeBlock(lines))
                }
            }
            return out
        }, older: { rung in
            try readOlder(rung, in: image, roi: roi, customWords: customWords).map { makeBlock([$0]) }
        })
    }

    /// Boxes come back normalized to the region of interest, not the whole image.
    private static func line(_ c: RecognizedText, box: CGRect, region: NormalizedRect, size: CGSize) -> OCRLine {
        let s = c.string
        let words = wordRanges(s).compactMap { r in
            c.boundingBox(for: r).map { OCRWord(rect: pixelRect(unclip($0.boundingBox.cgRect, from: region), in: size), range: r) }
        }
        return OCRLine(rect: pixelRect(unclip(box, from: region), in: size), text: s, words: words)
    }

    struct Timeout: Error {}

    /// An accurate read that cannot be had: the newest model and every other recognizer for these languages are not
    /// answering. Not retried by the passes (a retry would only wait again); the user has been told (see `setNoticeHandler`).
    struct Stalled: Error {}

    private static let warm = OSAllocatedUnfairLock(initialState: false)
    private static let log = Logger(subsystem: "dev.midagedev.mwoyeo", category: "ocr")

    /// Vision requests occasionally never return (seen with the document recognizer after many runs). A stuck
    /// request must not stall the region forever: give up after `seconds` and let the caller fall back or retry.
    /// The abandoned request keeps running in the background, and is never cancelled: a model that is only compiling
    /// (the newest one takes minutes the first time, once per app binary) starts over when its client goes away.
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

    /// The two models that can stall, each with its own health: the Swift requests (`RecognizeTextRequest`,
    /// `RecognizeDocumentsRequest`), and the Objective-C request at revision 3 that stands in for them.
    private enum Model { case swift, vision3 }

    private static let swiftHealth = OSAllocatedUnfairLock(initialState: OCRHealth())
    private static let vision3Health = OSAllocatedUnfairLock(initialState: OCRHealth())

    private static func health(_ m: Model) -> OSAllocatedUnfairLock<OCRHealth> { m == .swift ? swiftHealth : vision3Health }
    private static func tag(_ m: Model) -> String { m == .swift ? "" : ".vn3" }

    /// On some Macs the Swift models never answer (a compile that hangs or crawls, `OCRHealth`) while the Objective-C
    /// request still does. A read the Swift model does not answer in time goes down the ladder (`OCRFallback`): revision 3
    /// of the Objective-C request (reads everything), then revision 2, then `.fast`, as far as each reads the languages.
    /// `older` reads with one rung. Where none is left it throws `Stalled`. A slow model is never cancelled.
    private static func accurate<T: Sendable>(_ languages: [Locale.Language], warmUp: Bool,
                                              newest work: @escaping @Sendable () async throws -> T,
                                              older read: @escaping @Sendable (OCRFallback) throws -> T) async throws -> T {
        let rungs = OCRFallback.ladder(requested: languages.compactMap(code), vision3: vision3Languages,
                                       revision2: revision2Languages, fast: fastLanguages)
        switch swiftHealth.withLock({ $0.plan(canFallBack: !rungs.isEmpty, now: Trace.now) }) {
        case .refuse:
            throw stalled(languages, warmUp: warmUp)
        case .fallback:
            break
        case let .run(seconds):
            do {
                return try await tracked(.swift, seconds, tellingAbout: rungs.isEmpty && !warmUp ? languages : nil, work)
            } catch is Timeout {
                if rungs.isEmpty { throw stalled(languages, warmUp: warmUp) }
            }
        }
        for (i, rung) in rungs.enumerated() {
            let more = i < rungs.count - 1
            switch rung {
            case .vision3:
                switch vision3Health.withLock({ $0.plan(canFallBack: more, now: Trace.now) }) {
                case .refuse:
                    throw stalled(languages, warmUp: warmUp)
                case .fallback:
                    continue
                case let .run(seconds):
                    Trace.count("ocr.fallback.vn3")
                    do {
                        return try await tracked(.vision3, seconds, tellingAbout: !more && !warmUp ? languages : nil) { try read(rung) }
                    } catch is Timeout {
                        if !more { throw stalled(languages, warmUp: warmUp) }
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
        throw stalled(languages, warmUp: warmUp)
    }

    /// One request on a model that can stall, within `seconds`. `tellingAbout` is the languages to tell the user about
    /// when nothing else can read them and the wait runs long.
    private static func tracked<T: Sendable>(_ model: Model, _ seconds: Double, tellingAbout languages: [Locale.Language]? = nil,
                                             _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let id = health(model).withLock { $0.begin(now: Trace.now) }
        let starting: Task<Void, Never>? = languages == nil || seconds <= OCRHealth.lateAfter ? nil : Task {
            try? await Task.sleep(for: .seconds(OCRHealth.lateAfter))
            if !Task.isCancelled { raise(preparing(languages ?? [])) }
        }
        defer { starting?.cancel() }
        do {
            return try await deadline(seconds: seconds) { try await observed(model, id, work) }
        } catch is Timeout {
            if health(model).withLock({ $0.missed(id, now: Trace.now) }) {
                Trace.count("ocr.stalled" + tag(model))
                log.error("\(String(describing: model), privacy: .public) text model did not answer in \(Int(seconds)) s")
                startProbing(model)
            }
            throw Timeout()
        }
    }

    /// Runs `work` as request `id` of `model`, and notes how it ended, whenever that is (an abandoned request can come
    /// back minutes later).
    private static func observed<T: Sendable>(_ model: Model, _ id: Int, _ work: @Sendable () async throws -> T) async throws -> T {
        do {
            try await simulated(model)
            let r = try await work()
            if health(model).withLock({ $0.answered(id) }) { Trace.count("ocr.recovered" + tag(model)) }
            raise(nil)
            return r
        } catch {
            health(model).withLock { $0.failed(id) }
            throw error
        }
    }

    /// While stalled, one small picture goes to the model every two minutes (and none while a request of the last two
    /// minutes is still loading), so that the notice and the fallback end when it answers again.
    private static func startProbing(_ model: Model) {
        guard let picture = probePicture, health(model).withLock({ $0.startProbing() }) else { return }
        Task.detached(priority: .utility) {
            while true {
                try? await Task.sleep(for: .seconds(OCRHealth.probeEvery))
                if health(model).withLock({ $0.stopProbing() }) { return }
                guard let id = health(model).withLock({ $0.probeDue(now: Trace.now) ? $0.begin(now: Trace.now) : nil }) else { continue }
                Trace.count("ocr.probe" + tag(model))
                // Returns when the model does, if ever: the next probe waits for it.
                switch model {
                case .swift:
                    var probe = RecognizeTextRequest()
                    probe.automaticallyDetectsLanguage = true
                    let request = probe
                    _ = try? await observed(model, id) { try await request.perform(on: picture) }
                case .vision3:
                    _ = try? await observed(model, id) {
                        try visionRead(in: picture, roi: nil, level: .accurate, revision: 3, customWords: []) { _ in [] }
                    }
                }
            }
        }
    }

    /// Latin and CJK text, drawn here so that the probe needs no file.
    private static let probePicture: CGImage? = {
        let w = 420, h = 80
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(.black)
        let font = CTFontCreateUIFontForLanguage(.system, 32, nil)
        let text = NSAttributedString(string: "Hello 世界 こんにちは",
                                      attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font as Any,
                                                   NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true])
        ctx.textPosition = CGPoint(x: 16, y: 26)
        CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        return ctx.makeImage()
    }()

    /// `MWOYEO_FAKE_OCR=stall` (the Swift models never answer, as on the stalled Mac), `stall-vn` (the Objective-C
    /// revision 3 request too) or `slow:<ms>` (the Swift models answer late), to exercise the fallback and the recovery
    /// on a healthy Mac. Read like `MWOYEO_FAKE_ENGINE`: in any build.
    private static let fake = ProcessInfo.processInfo.environment["MWOYEO_FAKE_OCR"]

    private static func simulated(_ model: Model) async throws {
        guard let fake else { return }
        if fake == "stall-vn" || fake == "stall" && model == .swift {
            try await Task.sleep(for: .seconds(31_536_000))
        } else if model == .swift, fake.hasPrefix("slow:"), let ms = Int(fake.dropFirst(5)) {
            try await Task.sleep(for: .milliseconds(ms))
        }
    }

    // MARK: Other recognizers

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
    private static func code(_ l: Locale.Language) -> String? {
        guard let c = l.languageCode?.identifier else { return nil }
        return l.script.map { "\(c)-\($0.identifier)" } ?? c
    }

    private static func readOlder(_ rung: OCRFallback, in image: CGImage, roi: CGRect?, customWords: [String]) throws -> [OCRLine] {
        switch rung {
        case let .vision3(ids): try visionRead(in: image, roi: roi, level: .accurate, revision: 3, customWords: customWords) { _ in ids }
        case let .revision2(ids): try visionRead(in: image, roi: roi, level: .accurate, revision: 2, customWords: customWords) { _ in ids }
        case let .fast(ids): try visionRead(in: image, roi: roi, level: .fast, revision: nil, customWords: []) { _ in ids }
        }
    }

    /// Loads the other recognizers on a blank picture. Their models compile once per app binary (revision 2 took half a
    /// minute), and the compiler service takes one compile at a time: a fallback that is not compiled yet waits behind a
    /// newest model that is still compiling, or stuck. So these go first.
    static func warmOlder(_ image: CGImage) async {
        let rungs: [(VNRequestTextRecognitionLevel, Int?, [String])] = [(.accurate, 3, vision3Languages), (.accurate, 2, revision2Languages),
                                                                        (.fast, nil, fastLanguages)]
        for (level, revision, languages) in rungs where !languages.isEmpty {
            _ = try? await deadline { try visionRead(in: image, roi: nil, level: level, revision: revision, customWords: []) { _ in [] } }
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

    /// A read nothing answers: "still preparing" until a model has been silent for three minutes, then "not responding".
    private static func stalled(_ languages: [Locale.Language], warmUp: Bool) -> Stalled {
        if !warmUp {
            let now = Trace.now
            let age = [swiftHealth, vision3Health].compactMap { $0.withLock { $0.stalledFor(now: now) } }.max() ?? 0
            raise(age >= OCRHealth.giveUpAfter ? .textRecognitionStalled : preparing(languages))
        }
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
    private static func unclip(_ b: CGRect, from region: NormalizedRect) -> CGRect {
        let r = region.cgRect
        return CGRect(x: r.minX + b.minX * r.width, y: r.minY + b.minY * r.height, width: b.width * r.width, height: b.height * r.height)
    }

    private static func pixelRect(_ n: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: n.minX * size.width, y: (1 - n.maxY) * size.height, width: n.width * size.width, height: n.height * size.height)
    }

    private static func normalized(_ r: CGRect, in size: CGSize) -> NormalizedRect {
        let c = r.intersection(CGRect(origin: .zero, size: size))
        return NormalizedRect(x: c.minX / size.width, y: 1 - c.maxY / size.height,
                              width: c.width / size.width, height: c.height / size.height)
    }
}
