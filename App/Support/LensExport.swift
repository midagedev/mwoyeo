import AppKit
import AVFoundation
import ImageIO
import MwoyeoCore
import UniformTypeIdentifiers

/// Keeping what a lens read: its image, its text, its transcripts, its voice. The app and the headless self-test
/// both go through these, so what the self-test measures is what the lens menu does.
enum LensExport {
    static func stamp(_ date: Date, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = seconds ? "yyyy-MM-dd HH-mm-ss" : "yyyy-MM-dd HH-mm"
        return f.string(from: date)
    }

    /// A lens name as a file name: no path separators, never empty.
    static func fileName(_ lens: String) -> String {
        let clean = lens.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Lens" : clean
    }

    /// `dir/base`, or `base 2`, `base 3`… when a file of that name with `ext` exists.
    static func freeBase(in dir: URL, _ base: String, ext: String) -> URL {
        var n = 1
        while true {
            let name = n == 1 ? base : "\(base) \(n)"
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.appendingPathExtension(ext).path) { return url }
            n += 1
        }
    }

    static func capturesFolder(_ root: URL) -> URL { root.appendingPathComponent("Captures") }
    static func transcriptsFolder(_ root: URL) -> URL { root.appendingPathComponent("Transcripts") }
}

// MARK: - Image

enum LensImage {
    struct Layer {
        /// Points, top-left origin, relative to the frame's top-left.
        var frame: CGRect
        var image: CGImage
    }

    /// `frame` (image pixels; `scale` pixels per point) with `layers` drawn on it as the overlay shows them, cropped to
    /// `crop` (points, same space as the layers) or whole when nil. One function for the lens image and the self-test's
    /// composite, so the one the gates check is the one the menu saves.
    static func composite(frame: CGImage, scale: CGFloat, layers: [Layer], crop: CGRect? = nil) -> CGImage? {
        let W = frame.width, H = frame.height
        var x0 = 0, y0 = 0, w = W, h = H
        if let crop {
            x0 = max(0, min(W - 1, Int((crop.minX * scale).rounded())))
            y0 = max(0, min(H - 1, Int((crop.minY * scale).rounded())))
            w = max(1, min(W - x0, Int((crop.width * scale).rounded())))
            h = max(1, min(H - y0, Int((crop.height * scale).rounded())))
        }
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // The crop's bottom-left, in the frame's bottom-left based pixels.
        ctx.translateBy(x: -CGFloat(x0), y: -CGFloat(H - y0 - h))
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: W, height: H))
        for l in layers {
            ctx.draw(l.image, in: CGRect(x: l.frame.minX * scale, y: CGFloat(H) - l.frame.maxY * scale,
                                         width: l.frame.width * scale, height: l.frame.height * scale))
        }
        return ctx.makeImage()
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

// MARK: - Text

enum LensText {
    /// The blocks of `snapshot` the lens (global Quartz points) shows, in reading order.
    static func inLens(_ snapshot: OverlaySnapshot, lens: CGRect) -> [BlockText] {
        ReadingOrder.sorted(snapshot.texts.filter { shown($0, in: snapshot, lens: lens) }, frame: \.frame)
    }

    private static func shown(_ t: BlockText, in snapshot: OverlaySnapshot, lens: CGRect) -> Bool {
        let r = t.frame.offsetBy(dx: snapshot.origin.x, dy: snapshot.origin.y).intersection(lens)
        return !r.isNull && r.width > 0 && r.height > 0
    }

    /// A translation worth keeping: there is one, and it is not the source left as it was.
    static func usable(_ t: BlockText) -> String? {
        guard let s = t.translation, !s.isEmpty, s != t.source else { return nil }
        return s
    }

    static func originals(_ blocks: [BlockText]) -> [String] { blocks.map(\.source) }
    static func translations(_ blocks: [BlockText]) -> [String] { blocks.compactMap(usable) }

    /// What the transcript recorder is fed: every block of the capture, flagged by whether the lens shows it.
    static func observed(_ snapshot: OverlaySnapshot, lens: CGRect) -> [TranscriptRecorder.Observed] {
        ReadingOrder.sorted(snapshot.texts, frame: \.frame).map {
            TranscriptRecorder.Observed(source: $0.source, translation: $0.translation, inLens: shown($0, in: snapshot, lens: lens))
        }
    }

    static func copy(_ lines: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

// MARK: - Transcripts

/// Writes a lens's transcript: Markdown entries as lines are first translated, SRT cues as the recorder closes them.
/// All file work runs on one serial queue, never on the capture or translation path. Times are seconds since the
/// transcript began.
final class TranscriptWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.midagedev.mwoyeo.transcript", qos: .utility)
    private let directory: URL
    private let lens: String
    private let sourceCode: String
    private let targetCode: String
    private let formats: Set<TranscriptFileFormat>
    private let engine: String
    /// The languages as set ("auto" stays "auto"), for the JSON lines.
    private let sourceSetting: String
    private var app: String?
    private let started: Date
    private let onError: @Sendable () -> Void
    private var recorder = TranscriptRecorder()
    private var base: URL?
    /// Holds entries for a fuller reading of their line and keeps every closed cue sorted by start. Lines close in the
    /// order they leave the lens, not the order they appeared, so the SRT files are rewritten sorted each time a cue
    /// closes (they stay small) and a player never sees cues out of order.
    private var merger = TranscriptMerger()
    private var failed = false
    /// The security-scoped access to `directory`'s folder, held for the writer's whole life and ended with its last write.
    private let access: ExportFolder.Access?

    /// `directory` is where the files go; `sourceCode` names the source SRT ("auto" becomes "source").
    /// `formats` are the files written; `engine` is "apple" or the added engine's name (for the JSON lines).
    init(directory: URL, access: ExportFolder.Access? = nil, lens: String, sourceCode: String, targetCode: String, formats: [TranscriptFileFormat] = [.markdown, .srt],
         engine: String = "apple", started: Date = Date(), onError: @escaping @Sendable () -> Void) {
        self.directory = directory
        self.access = access
        self.formats = Set(formats)
        self.engine = engine
        self.sourceSetting = sourceCode
        self.lens = lens
        self.sourceCode = sourceCode == "auto" ? "source" : sourceCode
        self.targetCode = targetCode
        self.started = started
        self.onError = onError
    }

    /// The bundle ID of the app in the lens, for the JSON lines that follow.
    func setApp(_ bundleID: String?) {
        queue.async { self.app = bundleID }
    }

    func observe(time: TimeInterval, lines: [TranscriptRecorder.Observed]) {
        queue.async { self.write(self.recorder.observe(time: time, lines: lines), now: time) }
    }

    /// Closes every open cue (the lens closed, paused, or the app quits).
    func finish(time: TimeInterval) {
        queue.async { self.close(time) }
    }

    func finishAndWait(time: TimeInterval) {
        queue.sync { self.close(time) }
    }

    private func close(_ time: TimeInterval) {
        let events = recorder.finish(time: time)
        write(entries: merger.add(events, now: time) + merger.finish(), cuesChanged: events.contains { if case .cue = $0 { true } else { false } })
        access?.end()
    }

    private func write(_ events: [TranscriptRecorder.TranscriptEvent], now: TimeInterval) {
        write(entries: merger.add(events, now: now), cuesChanged: events.contains { if case .cue = $0 { true } else { false } })
    }

    private func write(entries: [TranscriptRecorder.Entry], cuesChanged: Bool) {
        guard !entries.isEmpty || cuesChanged else { return }
        do {
            for e in entries {
                if formats.contains(.markdown) {
                    try append(TranscriptFormat.markdownEntry(e, start: started, timeZone: .current), to: file("md"),
                               header: TranscriptFormat.markdownHeader(lens: lens, date: started, timeZone: .current))
                }
                if formats.contains(.jsonl) {
                    // Appended and closed per line, so `tail -f` follows it.
                    try append(TranscriptFormat.jsonlLine(time: started.addingTimeInterval(e.time), timeZone: .current, lens: lens, app: app,
                                                          source: sourceSetting, target: targetCode, engine: engine,
                                                          original: e.source, translation: e.translation), to: file("jsonl"))
                }
            }
            if cuesChanged, formats.contains(.srt) {
                try writeSRT(.source, to: file("\(sourceCode).srt"))
                try writeSRT(.translation, to: file("\(targetCode).srt"))
            }
        } catch {
            guard !failed else { return }
            failed = true
            onError()
        }
    }

    /// `<lens name> <date time>.<ext>`, chosen on the first write so a lens reopened in the same minute gets its own files.
    private func file(_ ext: String) -> URL {
        if base == nil {
            let probe = formats.contains(.markdown) ? "md" : formats.contains(.jsonl) ? "jsonl" : "\(targetCode).srt"
            base = LensExport.freeBase(in: directory, "\(LensExport.fileName(lens)) \(LensExport.stamp(started))", ext: probe)
        }
        return base!.appendingPathExtension(ext)
    }

    private func writeSRT(_ track: TranscriptFormat.Track, to url: URL) throws {
        let text = merger.cues.enumerated().map { TranscriptFormat.srtCue(index: $0.offset + 1, cue: $0.element, origin: 0, track: track) }.joined()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    private func append(_ text: String, to url: URL, header: String = "") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { try Data(header.utf8).write(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}

// MARK: - Reading aloud

/// The app's one speaker: starting on another lens stops the first.
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()

    private let synth = AVSpeechSynthesizer()
    private var live = Set<ObjectIdentifier>()
    private(set) var owner: UUID?
    var onChange: (() -> Void)?

    private override init() {
        super.init()
        synth.delegate = self
    }

    /// The system's voice for a target language, nil when none is installed.
    static func voice(for target: String) -> AVSpeechSynthesisVoice? {
        let tag = ["zh-Hans": "zh-CN", "zh-Hant": "zh-TW", "en": "en-US"][target] ?? target
        let code = tag.split(separator: "-").first.map(String.init) ?? tag
        if let v = AVSpeechSynthesisVoice(language: tag), v.language.hasPrefix(code) { return v }
        return AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(code) }.max { $0.quality.rawValue < $1.quality.rawValue }
    }

    func isReading(_ lens: UUID) -> Bool { owner == lens }

    func read(_ lines: [String], voice: AVSpeechSynthesisVoice, for lens: UUID) {
        synth.stopSpeaking(at: .immediate)
        let utterances = lines.map { line -> AVSpeechUtterance in
            let u = AVSpeechUtterance(string: line)
            u.voice = voice
            u.postUtteranceDelay = 0.25
            return u
        }
        live = Set(utterances.map(ObjectIdentifier.init))
        owner = utterances.isEmpty ? nil : lens
        utterances.forEach(synth.speak)
        onChange?()
    }

    func stop(_ lens: UUID) {
        guard owner == lens else { return }
        synth.stopSpeaking(at: .immediate)
        live = []
        owner = nil
        onChange?()
    }

    private func ended(_ u: AVSpeechUtterance) {
        live.remove(ObjectIdentifier(u))
        if live.isEmpty, owner != nil {
            owner = nil
            onChange?()
        }
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { Task { @MainActor in self.ended(u) } }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { Task { @MainActor in self.ended(u) } }
}

// MARK: - Menu

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
