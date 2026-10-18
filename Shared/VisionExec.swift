import CoreGraphics
import CoreText
import Foundation
import MwoyeoCore
import Vision

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

/// The Vision calls themselves, with the parameters the app has always read with (moved out of `TextRecognizer`). Pure: no
/// counters, no health, no deadline (`TextRecognizer` owns those), no state. They run in the reader services; the app still
/// compiles them in until it stops reading in its own process (design §4.3).
enum VisionExec {
    /// What a read of one kind returns: lines for the lines kinds, the lines of each paragraph for the document kinds.
    enum Output: Sendable {
        case lines([OCRLine])
        case paragraphs([[OCRLine]])

        var lines: [OCRLine] {
            switch self {
            case let .lines(lines): lines
            case let .paragraphs(paragraphs): paragraphs.flatMap { $0 }
            }
        }

        var paragraphs: [[OCRLine]] {
            switch self {
            case let .lines(lines): lines.map { [$0] }
            case let .paragraphs(paragraphs): paragraphs
            }
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    /// Runs `kind` on `image` (the warm-up kinds draw their own picture). Lines kinds block the calling thread until Vision
    /// answers; a compile is never aborted from here.
    static func run(_ kind: ReadKind, image: CGImage?, roi: CGRect?, languages: [String], documentLanguages: [Locale.Language],
                    customWords: [String]) async throws -> Output {
        switch kind {
        case .rev3, .rev2, .fast:
            guard let image else { throw Failure(description: "\(kind.rawValue) read without a picture") }
            return .lines(try readLines(kind, in: image, roi: roi, languages: languages, customWords: customWords))
        case .doc:
            guard let image else { throw Failure(description: "doc read without a picture") }
            return .paragraphs(try await documentLines(in: image, roi: roi, languages: documentLanguages, customWords: customWords))
        case .warmLines:
            guard let picture = probePicture else { throw Failure(description: "the probe picture could not be drawn") }
            return .lines(try recognize(in: picture, roi: nil, level: .accurate, revision: 3, customWords: [], identifiers: []))
        case .warmDoc:
            guard let picture = probePicture else { throw Failure(description: "the probe picture could not be drawn") }
            return .paragraphs(try await documentLines(in: picture, roi: nil, languages: documentLanguages, customWords: []))
        }
    }

    /// The Objective-C recognizer of `kind`, restricted to Vision's own `languages` identifiers (empty: detect). `.fast` has no
    /// custom words.
    static func readLines(_ kind: ReadKind, in image: CGImage, roi: CGRect?, languages: [String], customWords: [String]) throws -> [OCRLine] {
        switch kind {
        case .rev3: try recognize(in: image, roi: roi, level: .accurate, revision: 3, customWords: customWords, identifiers: languages)
        case .rev2: try recognize(in: image, roi: roi, level: .accurate, revision: 2, customWords: customWords, identifiers: languages)
        case .fast: try recognize(in: image, roi: roi, level: .fast, revision: nil, customWords: [], identifiers: languages)
        default: throw Failure(description: "\(kind.rawValue) is not a lines read")
        }
    }

    /// The Objective-C recognizer, run to completion (the callers bound it). `identifiers` picks the languages to read (empty:
    /// detect).
    private static func recognize(in image: CGImage, roi: CGRect?, level: VNRequestTextRecognitionLevel, revision: Int?,
                                  customWords: [String], identifiers: [String]) throws -> [OCRLine] {
        let size = CGSize(width: image.width, height: image.height)
        // A region with no pixel in the picture has no origin, and Vision traps on it (v1.0.0 crash report): no request.
        guard let region = regionOfInterest(roi, in: size) else { return [] }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = level
        if let revision { req.revision = revision }
        req.usesLanguageCorrection = level == .accurate
        req.customWords = customWords
        if identifiers.isEmpty { req.automaticallyDetectsLanguage = true } else { req.recognitionLanguages = identifiers }
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

    /// `RecognizeDocumentsRequest`: the lines of each paragraph it finds.
    static func documentLines(in image: CGImage, roi: CGRect?, languages: [Locale.Language], customWords: [String]) async throws -> [[OCRLine]] {
        var req = RecognizeDocumentsRequest()
        req.textRecognitionOptions.customWords = customWords
        if languages.isEmpty {
            req.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
            req.textRecognitionOptions.recognitionLanguages = languages
        }
        let size = CGSize(width: image.width, height: image.height)
        guard let region = regionOfInterest(roi, in: size) else { return [] }
        req.regionOfInterest = NormalizedRect(normalizedRect: region)
        var out: [[OCRLine]] = []
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
                out.append(lines)
            }
        }
        return out
    }

    // MARK: Geometry and text

    /// Words split at spaces; CJK has none, so its words are single characters.
    static func wordRanges(_ s: String) -> [Range<String.Index>] {
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

    static func isCJK(_ c: Character) -> Bool {
        c.unicodeScalars.contains { s in
            (0x3040...0x30FF).contains(s.value) || (0x3400...0x9FFF).contains(s.value) ||
                (0xF900...0xFAFF).contains(s.value) || (0xFF00...0xFFEF).contains(s.value) ||
                (0x3000...0x303F).contains(s.value)
        }
    }

    /// Region-of-interest-relative normalized box → image-relative normalized box.
    static func unclip(_ b: CGRect, from region: CGRect) -> CGRect {
        CGRect(x: region.minX + b.minX * region.width, y: region.minY + b.minY * region.height,
               width: b.width * region.width, height: b.height * region.height)
    }

    static func pixelRect(_ n: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: n.minX * size.width, y: (1 - n.maxY) * size.height, width: n.width * size.width, height: n.height * size.height)
    }

    /// The region of interest for `roi` in image pixels (nil: the whole picture), or nil when no pixel of it lies in the picture
    /// (`VisionRegion`): nothing is read. The caller that counts those does so before it asks (`TextRecognizer.regionOfInterest`).
    static func regionOfInterest(_ roi: CGRect?, in size: CGSize) -> CGRect? {
        guard let roi else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        return VisionRegion.normalized(roi, in: size)
    }

    // MARK: Wire conversion

    /// The lines of a reply, with word ranges as UTF-8 offsets into each line's text (`ReadWord`).
    static func wire(_ line: OCRLine) -> ReadLine {
        let utf8 = line.text.utf8
        return ReadLine(rect: line.rect, text: line.text, words: line.words.map {
            ReadWord(rect: $0.rect, start: utf8.distance(from: utf8.startIndex, to: $0.range.lowerBound),
                     end: utf8.distance(from: utf8.startIndex, to: $0.range.upperBound))
        })
    }

    static func unwire(_ line: ReadLine) -> OCRLine {
        let utf8 = line.text.utf8
        return OCRLine(rect: line.rect, text: line.text, words: line.words.compactMap { w in
            guard w.start >= 0, w.start <= w.end, w.end <= utf8.count else { return nil }
            return OCRWord(rect: w.rect, range: utf8.index(utf8.startIndex, offsetBy: w.start)..<utf8.index(utf8.startIndex, offsetBy: w.end))
        })
    }

    // MARK: The drawn picture

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
}
