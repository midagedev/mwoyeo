import CoreGraphics
import Foundation
import MwoyeoCore
import NaturalLanguage
import Vision
import os

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
        // Its identifiers look like "en-US"; match by language code.
        let ids = wanted.compactMap { w in fastLanguages.first { Locale.Language(identifier: $0).languageCode == w } }
        return try await deadline { try await exec(.fast, in: image, roi: roi, languages: ids).lines }
    }

    /// Paragraph-level recognition. Priority: the document model of the Docs service (`RecognizeDocumentsRequest`, in its own process,
    /// when Docs is idle and warm for the key) > VN revision 3 + `ParagraphGrouper` > revision 2 > `.fast` > issue (`accurate`).
    /// The lens never waits for Docs: a pass that cannot send its read (Docs warming, busy, compiling, restarting) reads with VN at
    /// once, and one that did send waits `ReadVia.doc.patience` (S = 2 s) and then reads with VN while the request runs on, never
    /// cancelled. A document answer that is here when the VN read ends is the one used (it is the better layout); a later one
    /// marks Docs ready, and the lens reads again once (`ReaderClients`, `RegionPipeline.layoutReady`).
    /// `plan` says which paragraph reader the lens wants (`ParagraphReader`): `lineGrouping` never asks the document model, and
    /// `automatic` reads the lines with VN first and lets `ReaderDecider` pick from their layout; once the plan holds the document
    /// model, that model reads alone and its lines feed the decision. `client` is the pipeline asking (`ReaderClients`).
    static func blocks(in image: CGImage, roi: CGRect? = nil, languages: [Locale.Language], customWords: [String] = [],
                       plan: ReaderPlan? = nil, client: Int? = nil) async throws -> [OCRBlock] {
        Trace.count("ocr.blocks")
        let key = key(languages)
        let wanted: ParagraphReader = switch ocrPath {
        case .vn: .lineGrouping
        case .swift: .documentLayout
        case nil: plan?.setting ?? .automatic
        }
        var read: [OCRLine]?
        var sent: DocsRead?
        if wanted != .lineGrouping {
            if gate.withLock({ $0.want(key) }) { publishAndRun() }
            if case .doc = await DocsHost.shared.route(key: key, client: client) {
                var reader = wanted
                // Automatic with the document model already held: its own lines are the layout evidence, so the frame is read
                // once, not twice (VN first cost ~0.2 s more per subtitle frame, usecase-bench 2026-10-18).
                if wanted == .automatic, let plan, plan.held == .documentLayout {
                    let t = Trace.now
                    switch await documentBlocks(in: image, roi: roi, languages: languages, customWords: customWords, key: key, client: client) {
                    case let .found(found):
                        let lines = found.flatMap(\.lines)
                        let (_, why) = plan.decide(lines: lines.map(\.rect), texts: lines.map(\.text),
                                                   size: CGSize(width: image.width, height: image.height), partial: roi != nil)
                        Trace.count("ocr.reader.auto.held")
                        Trace.mark(why + " (document lines)", since: t)
                        Trace.count("ocr.blocks.swift")
                        Trace.count("ocr.blocks.lines", lines.count)
                        return found
                    case let .fellBack(late):
                        sent = late
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
                    switch await documentBlocks(in: image, roi: roi, languages: languages, customWords: customWords, key: key, client: client) {
                    case let .found(found):
                        Trace.count("ocr.blocks.swift")
                        Trace.count("ocr.blocks.lines", found.reduce(0) { $0 + $1.lines.count })
                        return found
                    case let .fellBack(late):
                        sent = late
                    }
                }
            }
            // else: Docs cannot take the read now (`DocsRoute`, counted by the host): the grouper reads, and this lens reads again
            // when Docs is ready.
        }
        Trace.count("ocr.blocks.vn")
        let lines: [OCRLine]
        if let read { lines = read } else { lines = try await accurate(in: image, roi: roi, languages: languages, customWords: customWords) }
        // A document answer that came while the VN read ran is the better layout, and is here: use it, not the grouper's.
        if let sent, case let .success(paragraphs)? = sent.answer {
            ReaderClients.shared.served(client)
            Trace.count("ocr.blocks.swift")
            Trace.count("ocr.blocks.lines", paragraphs.reduce(0) { $0 + $1.count })
            return paragraphs.map(makeBlock)
        }
        Trace.count("ocr.blocks.lines", lines.count)
        return ParagraphGrouper.groups(lines, rect: \.rect, text: \.text).map(makeBlock)
    }

    /// What a document read came to for one pass.
    private enum Document {
        case found([OCRBlock])
        /// The grouper reads. `late` is the request that did not answer in S and runs on (nil: none was sent, or it failed).
        case fellBack(DocsRead?)
    }

    /// The paragraphs of the Docs service for this picture, if it answers within S. Never cancels the request.
    private static func documentBlocks(in image: CGImage, roi: CGRect?, languages: [Locale.Language], customWords: [String], key: String,
                                       client: Int?) async -> Document {
        let t = Trace.now
        switch await DocsHost.shared.send(client: client, key: key, image: image, roi: roi, languages: languages, customWords: customWords) {
        case .fallback:
            return .fellBack(nil)
        case let .sent(read):
            switch await read.wait(seconds: DocsHost.patience) {
            case let .success(paragraphs)?:
                ReaderClients.shared.served(client)
                Trace.mark("document read (Docs service)", since: t)
                return .found(paragraphs.map(makeBlock))
            case .failure?:
                Trace.count("ocr.swift.failed")
                ReaderClients.shared.fellBack(client)
                return .fellBack(nil)
            case nil:
                // S passed: probably compiling. It runs on; its answer marks Docs ready for the lenses that stood in for it.
                Trace.count("ocr.swift.missed")
                ReaderClients.shared.fellBack(client)
                return .fellBack(read)
            }
        }
    }

    typealias Timeout = ReadTimeout

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

    /// The Objective-C `VNRecognizeTextRequest` reads lines in this process; paragraphs come from the document model of the Docs
    /// service (`DocsHost`, a process of its own) once it is warm for the key, else from those lines grouped by `ParagraphGrouper`.
    /// The models are loaded by the app itself at launch (`warmUp`): a cold compile takes 80-90 s and every Vision request of the
    /// process that compiles it waits for it, so the document model compiles in the service and revision 3 (in this process) is
    /// never behind it. A warm document read answers in 0.33-0.48 s. Revision 3 is the one that can stall here (a compile that
    /// hangs or crawls, `OCRHealth`); the health below is that revision's.
    ///
    /// `MWOYEO_OCR_PATH=vn|swift` for gates: `vn` never asks Docs, `swift` assumes the document model warm for every key.
    private enum OCRPath { case vn, swift }
    private static let ocrPath: OCRPath? = switch ProcessInfo.processInfo.environment["MWOYEO_OCR_PATH"] {
    case "vn": .vn
    case "swift": .swift
    default: nil
    }

    /// The initialization steps (`SwiftVisionGate`); `VisionSetup` shows it. Whether a read may go to Docs is `DocsHost`'s to say.
    private static let gate = OSAllocatedUnfairLock(initialState: SwiftVisionGate())

    /// The gate as it is now.
    static var setupState: SwiftVisionGate { gate.withLock { $0 } }

    /// The key for reads in these languages (empty: detect).
    static func key(_ languages: [Locale.Language]) -> String {
        let codes = languages.compactMap(code)
        return codes.isEmpty ? SwiftVisionGate.anyLanguage : codes.joined(separator: ",")
    }

    static func languages(of key: String) -> [Locale.Language] {
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
        let read: @Sendable (OCRFallback) async throws -> [OCRLine] = { try await readRung($0, in: image, roi: roi, customWords: customWords) }
        for (i, rung) in rungs.enumerated() {
            let more = i < rungs.count - 1
            switch rung {
            case .vision3:
                switch health.withLock({ $0.plan(canFallBack: more, now: Trace.now) }) {
                case .refuse:
                    throw stalled(languages)
                case .fallback:
                    continue
                case let .run(seconds):
                    // Named for the ladder (`ocr.fallback.<rung>`, as the scripts count it): every read counts its rung, the first too.
                    Trace.count("ocr.fallback.vn3")
                    do {
                        return try await tracked(seconds, tellingAbout: more ? nil : languages) { try await read(rung) }
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
                return try await deadline { try await read(rung) }
            case .fast:
                Trace.count("ocr.fallback.fast")
                return try await deadline { try await read(rung) }
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
        guard probePicture != nil, health.withLock({ $0.startProbing() }) else { return }
        Task.detached(priority: .utility) {
            while true {
                try? await Task.sleep(for: .seconds(OCRHealth.probeEvery))
                if health.withLock({ $0.stopProbing() }) { return }
                guard let id = health.withLock({ $0.probeDue(now: Trace.now) ? $0.begin(now: Trace.now) : nil }) else { continue }
                Trace.count("ocr.probe" + counterTag)
                // Returns when the model does, if ever: the next probe waits for it.
                _ = try? await observed(id) { try await exec(.warmLines, in: nil, roi: nil) }
            }
        }
    }

    /// The initialization, at every launch: for the key of `languages`, `SwiftVisionGate.Step`s in order, in the background and to
    /// completion (a load is never cancelled): revision 3 on a drawn wide line in this process (given the cold allowance; reads that
    /// come meanwhile do not queue behind it unless nothing else can read their language), then the document model, which the Docs
    /// service compiles (`DocsHost.warm`), so that nothing in this process waits for it. A failed step is not retried here: the next
    /// launch or `retry()` does. Tells the user nothing (`VisionSetup` is what a screen reads).
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
        guard probePicture != nil else { throw Stalled() }
        switch due.step {
        case .textModel:
            try await askingAgainWhileNotReady {
                _ = try await tracked(OCRHealth.coldWait) { try await exec(.warmLines, in: nil, roi: nil) }
            }
        case .documentModel:
            // The Docs service compiles it, in its own process: no read of this one waits for the compile.
            try await DocsHost.shared.warm(key: due.key, languages: languages(of: due.key))
        }
    }

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
        Task { @MainActor in
            VisionSetup.shared.gate = TextRecognizer.setupState
            VisionSetup.shared.onChange?()
        }
    }

    /// The drawn warm-up picture (`VisionExec.probePicture`).
    static var probePicture: CGImage? { VisionExec.probePicture }

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

    private static func readRung(_ rung: OCRFallback, in image: CGImage, roi: CGRect?, customWords: [String]) async throws -> [OCRLine] {
        switch rung {
        case let .vision3(ids): try await exec(.rev3, in: image, roi: roi, languages: ids, customWords: customWords).lines
        case let .revision2(ids): try await exec(.rev2, in: image, roi: roi, languages: ids, customWords: customWords).lines
        case let .fast(ids): try await exec(.fast, in: image, roi: roi, languages: ids).lines
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

    /// What a block of text is to the lens.
    enum Verdict: Sendable {
        /// Stays as written: no letters, a time stamp, a link, a formula.
        case literal
        /// Already in the target language.
        case inTarget
        /// Worth translating.
        case needs
    }

    /// Text worth translating: has letters, and is not already in the target language.
    static func needsTranslation(_ text: String, target: String) -> Bool { verdict(text, target: target) == .needs }

    static func verdict(_ text: String, target: String) -> Verdict {
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return .literal }
        if TranslationFilter.isLiteral(text) {
            if TranslationFilter.isFormula(text) || TranslationFilter.isIdentifier(text) {
                Trace.count("ocr.kept.formula")
            } else if TranslationFilter.isMathHeavy(text) {
                Trace.count("ocr.kept.math")
                Trace.mark("kept math \(TranslationFilter.mathShare(of: text)): \(text.prefix(100))", since: Trace.now)
            }
            return .literal
        }
        let targetCode = Locale.Language(identifier: target).languageCode?.identifier
        // Hangul is unambiguous; for other targets ask NaturalLanguage, but only trust confident answers.
        if targetCode == "ko" {
            let hangul = text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) || (0x3131...0x318E).contains($0.value) }.count
            let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            return Double(hangul) / Double(max(letters, 1)) < 0.5 ? .needs : .inTarget
        }
        let r = NLLanguageRecognizer()
        r.processString(text)
        if let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p > 0.8,
           Locale.Language(identifier: lang.rawValue).languageCode?.identifier == targetCode {
            return .inTarget
        }
        return .needs
    }

    /// What one read found, for the lens's "already in <language>" line: literals count for nothing. `partial`: it read only a part
    /// of the capture.
    static func tally(_ verdicts: [Verdict], partial: Bool = false) -> ReadTally {
        ReadTally(inTarget: verdicts.filter { $0 == .inTarget }.count, needing: verdicts.filter { $0 == .needs }.count, partial: partial)
    }

    static func isCJK(_ c: Character) -> Bool { VisionExec.isCJK(c) }

    /// The region of interest for `roi` in image pixels (nil: the whole picture), or nil when no pixel of it lies in the picture
    /// (`VisionRegion`): the caller reads nothing, and the count says how often that happened.
    private static func regionOfInterest(_ roi: CGRect?, in size: CGSize) -> CGRect? {
        guard let region = VisionExec.regionOfInterest(roi, in: size) else { Trace.count("ocr.roi.empty"); return nil }
        return region
    }

    // MARK: Where a read runs

    /// `MWOYEO_READER=xpc` sends the line reads to the Lines service (`ReaderConnection`, a process of the app bundle); otherwise
    /// Vision runs in this process, as it always did. The document reads always go to the Docs service (`DocsHost`), whatever this
    /// says. Routing and health of the lines stay as they are: moving Lines is 1.1.3.
    private static let readsViaXPC = ProcessInfo.processInfo.environment["MWOYEO_READER"] == "xpc"

    /// `MWOYEO_TRACE_READS=1` prints the lines of every read (kind, size, region, then one record per line: text, rect, word
    /// rects) on stderr: what `tools/ocr-probe/same-lines.py` compares between two runs.
    static let traceReads = ProcessInfo.processInfo.environment["MWOYEO_TRACE_READS"] != nil

    /// One read of `kind`, here or in a service. The warm-up kinds take no picture. A region with no pixel in the picture reads
    /// nothing, and does not cross to a service.
    private static func exec(_ kind: ReadKind, in image: CGImage?, roi: CGRect?, languages: [String] = [], documentLanguages: [Locale.Language] = [],
                             customWords: [String] = []) async throws -> VisionExec.Output {
        let empty: VisionExec.Output = kind == .doc ? .paragraphs([]) : .lines([])
        if let image, regionOfInterest(roi, in: CGSize(width: image.width, height: image.height)) == nil { return empty }
        let out: VisionExec.Output
        if readsViaXPC {
            out = try await ReaderConnection.shared(ReaderRole.home(of: kind)).read(kind, image: image, roi: roi, languages: languages,
                                                                                     documentLanguages: documentLanguages, customWords: customWords)
        } else {
            out = try await VisionExec.run(kind, image: image, roi: roi, languages: languages, documentLanguages: documentLanguages,
                                           customWords: customWords)
        }
        if traceReads { printRead(kind, size: image.map { "\($0.width)x\($0.height)" } ?? "probe", roi: roi, out) }
        return out
    }

    static func printRead(_ kind: ReadKind, size: String, roi: CGRect?, _ out: VisionExec.Output) {
        func field(_ s: String) -> String { s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n") }
        func rect(_ r: CGRect) -> String { "\(r.minX)\t\(r.minY)\t\(r.width)\t\(r.height)" }
        var text = "[read]\t\(kind.rawValue)\tbegin\t\(size)\t\(roi.map { "\($0)" } ?? "-")\t\(out.lines.count)\n"
        for (p, lines) in out.paragraphs.enumerated() {
            for line in lines {
                let words = line.words.map { "\($0.rect.minX),\($0.rect.minY),\($0.rect.width),\($0.rect.height)@\(line.text.utf8.distance(from: line.text.utf8.startIndex, to: $0.range.lowerBound))-\(line.text.utf8.distance(from: line.text.utf8.startIndex, to: $0.range.upperBound))" }
                text += "[read]\t\(kind.rawValue)\tline\t\(p)\t\(rect(line.rect))\t\(field(line.text))\t\(words.joined(separator: ";"))\n"
            }
        }
        FileHandle.standardError.write(text.data(using: .utf8)!)
    }
}
