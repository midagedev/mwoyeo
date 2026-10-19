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
    /// Set on each of the blocks a paragraph that goes on in the next column was cut into (`ColumnBreak`): `text` is then the whole
    /// paragraph's, translated once, and the block draws its share of the translation (`FlowSplit`).
    var part: FlowPart?
}

/// What the pipelines call to read a picture. A facade over `RecognitionHost`: the Vision requests run in the reader services
/// (Lines and Docs, `App/Reader`), which the host routes, queues, watches and warms. A read that no reader can take now throws
/// `RecognitionUnavailable`; the pass does not read again until the host says a reader is ready.
enum TextRecognizer {
    /// Per-line recognition, optionally restricted to `roi` (image pixels).
    /// `fast` only reads Latin scripts; callers pick it only for those.
    static func lines(in image: CGImage, roi: CGRect? = nil, languages: [Locale.Language], fast: Bool,
                      customWords: [String] = [], client: Int? = nil) async throws -> [OCRLine] {
        Trace.count("ocr.lines")
        guard regionOfInterest(roi, in: CGSize(width: image.width, height: image.height)) != nil else { return [] }
        let ask = makeAsk(.lines, in: image, roi: roi, languages: languages, ladder: fast ? fastLadder(languages) : ladder(languages),
                          customWords: customWords, client: client)
        return try await result(of: ask).allLines
    }

    /// Paragraph-level recognition. The reader depends on `plan` (`ParagraphReader`): `lineGrouping` reads lines (the best rung
    /// that answers) and groups them with `ParagraphGrouper`; `documentLayout` asks for the document layout, which the host serves
    /// from the Docs service when it is idle and warm for the key, else as lines + `ParagraphGrouper` (the lens reads again once,
    /// when Docs is ready: `ReadTarget.StandIn.layout`); `automatic` reads the lines first and lets `ReaderDecider` pick from their
    /// layout, and once the plan holds the document model, that model reads alone and its lines feed the decision. `client` is
    /// the pipeline asking (`ReaderClients`).
    static func blocks(in image: CGImage, roi: CGRect? = nil, languages: [Locale.Language], customWords: [String] = [],
                       plan: ReaderPlan? = nil, client: Int? = nil) async throws -> [OCRBlock] {
        Trace.count("ocr.blocks")
        let key = key(languages)
        let wanted: ParagraphReader = switch RecognitionHost.ocrPath {
        case .vn: .lineGrouping
        case .swift: .documentLayout
        case nil: plan?.setting ?? .automatic
        }
        func ask(_ want: RouteRequest.Want) -> ReadAsk {
            var a = makeAsk(want, in: image, roi: roi, languages: languages, ladder: ladder(languages), customWords: customWords, client: client)
            a.layoutWanted = wanted != .lineGrouping
            return a
        }
        var read: [OCRLine]?
        if wanted != .lineGrouping {
            var docs = true
            if wanted == .automatic { docs = await RecognitionHost.shared.documentsUsable(key: key, ladder: ask(.layout).ladder) }
            if !docs {
                // Docs cannot take the read now: the grouper reads, and this lens reads again when Docs is ready.
            } else if wanted == .automatic, let plan, plan.held == .documentLayout {
                // Automatic with the document model already held: its own lines are the layout evidence, so the frame is read
                // once, not twice (VN first cost ~0.2 s more per subtitle frame, usecase-bench 2026-10-18).
                let t = Trace.now
                let found = try await layoutBlocks(ask(.layout))
                let lines = found.flatMap(\.lines)
                let (_, why) = plan.decide(lines: lines.map(\.rect), texts: lines.map(\.text),
                                           size: CGSize(width: image.width, height: image.height), partial: roi != nil)
                Trace.count("ocr.reader.auto.held")
                Trace.mark(why + " (document lines)", since: t)
                return found
            } else {
                var reader = wanted
                if wanted == .automatic {
                    let t = Trace.now
                    // Lines not read must not stop the read: the document model does not need them.
                    var seen: [OCRLine] = []
                    do { seen = try await result(of: ask(.lines)).allLines } catch {
                        Trace.count("ocr.reader.auto.vnfailed")
                        Trace.mark("reader auto → documentLayout: lines not read (\(error))", since: t)
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
                if reader == .documentLayout { return try await layoutBlocks(ask(.layout)) }
            }
        }
        Trace.count("ocr.blocks.vn")
        let lines: [OCRLine]
        if let read { lines = read } else { lines = try await result(of: ask(.lines)).allLines }
        Trace.count("ocr.blocks.lines", lines.count)
        return ParagraphGrouper.groups(lines, rect: \.rect, text: \.text).map(makeBlock)
    }

    /// The blocks of a layout read: the document model's paragraphs, or the lines of the grouper's stand-in.
    private static func layoutBlocks(_ ask: ReadAsk) async throws -> [OCRBlock] {
        let t = Trace.now
        switch try await result(of: ask) {
        case let .paragraphs(paragraphs):
            Trace.mark("document read (Docs service)", since: t)
            Trace.count("ocr.blocks.swift")
            Trace.count("ocr.blocks.lines", paragraphs.reduce(0) { $0 + $1.count })
            return paragraphs.map(makeBlock)
        case let .lines(lines):
            Trace.count("ocr.blocks.vn")
            Trace.count("ocr.blocks.lines", lines.count)
            return ParagraphGrouper.groups(lines, rect: \.rect, text: \.text).map(makeBlock)
        default:
            return []
        }
    }

    /// One read through the host, with what is not an answer thrown.
    private static func result(of ask: ReadAsk) async throws -> ReadResult {
        let result = await RecognitionHost.shared.read(ask)
        switch result {
        case let .unavailable(why): throw RecognitionUnavailable(why: why)
        case let .failed(failure): throw failure
        case .superseded: throw ReadSuperseded()
        case .lines, .paragraphs: return result
        }
    }

    private static func makeAsk(_ want: RouteRequest.Want, in image: CGImage, roi: CGRect?, languages: [Locale.Language],
                            ladder: [OCRFallback], customWords: [String], client: Int?) -> ReadAsk {
        var ask = ReadAsk(client: client, want: want, key: key(languages), ladder: [], image: image, roi: roi)
        ask.customWords = customWords
        ask.documentLanguages = languages
        for rung in ladder {
            switch rung {
            case let .vision3(ids): ask.ladder.append(.rev3); ask.languages[.rev3] = ids
            case let .revision2(ids): ask.ladder.append(.rev2); ask.languages[.rev2] = ids
            case let .fast(ids): ask.ladder.append(.fast); ask.languages[.fast] = ids
            }
        }
        return ask
    }

    // MARK: - Which recognizer reads

    /// The initialization steps as `VisionSetup` shows them, mirrored from the host's `ReaderWarmup` (`SwiftVisionGate` goes in R3c).
    private static let gate = OSAllocatedUnfairLock(initialState: SwiftVisionGate())

    /// The gate as it is now.
    static var setupState: SwiftVisionGate { gate.withLock { $0 } }

    /// The host's warm-up changes the mirror and tells `VisionSetup`.
    static func setup(_ change: (inout SwiftVisionGate) -> Void) {
        gate.withLock { change(&$0) }
        Task { @MainActor in
            VisionSetup.shared.gate = TextRecognizer.setupState
            VisionSetup.shared.onChange?()
        }
    }

    /// The key for reads in these languages (empty: detect).
    static func key(_ languages: [Locale.Language]) -> String {
        let codes = languages.compactMap(code)
        return codes.isEmpty ? ReaderWarmup.anyLanguage : codes.joined(separator: ",")
    }

    static func languages(of key: String) -> [Locale.Language] {
        key == ReaderWarmup.anyLanguage ? [] : key.split(separator: ",").map { Locale.Language(identifier: String($0)) }
    }

    /// The initialization, at every launch: for the key of `languages`, Lines (rev3 on the drawn probe picture) and then Docs (the
    /// document networks), each in its own service (`RecognitionHost.warmUp`). Nothing in this process compiles a model. Tells the
    /// user nothing (`VisionSetup` is what a screen reads).
    static func warmUp(languages: [Locale.Language] = []) async {
        await RecognitionHost.shared.warmUp(languages: languages)
    }

    /// Every failed step is run again (the screen's retry button); steps never retry themselves.
    static func retrySetup() {
        Task { await RecognitionHost.shared.retryWarmup() }
    }

    /// The drawn warm-up picture (`VisionExec.probePicture`).
    static var probePicture: CGImage? { VisionExec.probePicture }

    // MARK: The recognizers

    private static let vision3Languages = supportedLanguages(level: .accurate, revision: 3)
    private static let revision2Languages = supportedLanguages(level: .accurate, revision: 2)
    private static let fastLanguages = supportedLanguages(level: .fast, revision: nil)

    /// The rungs that read every requested language, best first (`OCRFallback.ladder`).
    private static func ladder(_ languages: [Locale.Language]) -> [OCRFallback] {
        OCRFallback.ladder(requested: languages.compactMap(code), vision3: vision3Languages, revision2: revision2Languages, fast: fastLanguages)
    }

    /// `.fast` through the Objective-C request: the Swift `RecognizeTextRequest` at `.fast` returns no observations at all on
    /// macOS 27. Its identifiers look like "en-US"; match by language code.
    private static func fastLadder(_ languages: [Locale.Language]) -> [OCRFallback] {
        let wanted = languages.compactMap(\.languageCode)
        return [.fast(wanted.compactMap { w in fastLanguages.first { Locale.Language(identifier: $0).languageCode == w } })]
    }

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

    // MARK: The notice

    private struct Notice {
        var handler: (@Sendable (TranslationIssue?) -> Void)?
    }
    private static let notice = OSAllocatedUnfairLock(initialState: Notice())

    /// Told when reading is impossible for now. The host does not use it: a lens with no reader says so itself (`ReadWait`,
    /// `LensSignals.recognition`). R3c removes the handler with the issue cases.
    static func setNoticeHandler(_ h: @escaping @Sendable (TranslationIssue?) -> Void) {
        notice.withLock { $0.handler = h }
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

    // MARK: Tracing the reads

    /// `MWOYEO_TRACE_READS=1` prints the lines of every read (kind, size, region, then one record per line: text, rect, word
    /// rects) on stderr: what `tools/ocr-probe/same-lines.py` compares between two runs.
    static let traceReads = ProcessInfo.processInfo.environment["MWOYEO_TRACE_READS"] != nil

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

private extension ReadResult {
    /// The lines of a lines read, or of every paragraph of a document read (a lines read that Docs served).
    var allLines: [OCRLine] {
        switch self {
        case let .lines(lines): lines
        case let .paragraphs(paragraphs): paragraphs.flatMap { $0 }
        default: []
        }
    }
}
