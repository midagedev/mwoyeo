import CoreGraphics
import Foundation
import MwoyeoCore

/// Code, terminal output, logs, config and diffs stay on the screen as written, and so do the rows of a displayed equation that hold a word
/// (`CodeRegion.Reason.equation`). `CodeRegion` (Core) decides from the text and the geometry of one read; this is the app's side of it:
/// the blocks as the rule wants them, the frame's page colour, and the verdicts that follow. A kept block takes today's `.literal` road:
/// not erased, not sent to the engine, its pixels stay visible.
enum CodeKeep {
    /// A block of the latest read that stays as written, and why (`RegionPipeline.debugState`, the trace).
    struct Kept: Sendable, Equatable {
        var text: String
        var rect: CGRect
        var reason: CodeRegion.Reason
    }

    /// `MWOYEO_KEEP=off` translates the code regions as before (the film's "without" take). The App Store build has no such switch.
    #if MAS
    static let enabled = true
    #else
    static let enabled = !DebugSwitch.isOff("MWOYEO_KEEP", in: ProcessInfo.processInfo.environment)
    #endif

    /// `verdicts` (today's rules, one per block of `read`) with the blocks that sit in a region of code turned to `.literal`; the kept
    /// ones next to them. Final keep = not worth translating, or in a region. A block already `.literal` or `.inTarget` stays what it
    /// was, but still counts as a member of its region. `look` measures one line's appearance in `frame` (its background is the block's
    /// median); nothing is measured when no block needs translating.
    static func apply(_ verdicts: [TextRecognizer.Verdict], to read: [OCRBlock], frame: CGImage, enabled: Bool = CodeKeep.enabled,
                      look: (CGRect) -> TextAppearance) -> (verdicts: [TextRecognizer.Verdict], kept: [Kept]) {
        guard enabled, verdicts.contains(.needs) else { return (verdicts, []) }
        let start = Trace.now
        guard let page = FrameBackground.dominant(of: frame) else { return (verdicts, []) }
        let t = Trace.now
        let blocks = read.map { b in
            CodeRegion.Block(text: b.text, rect: b.rect,
                             lines: b.lines.map { line in .init(text: line.text, rect: line.rect, words: line.words.map { .init(text: String(line.text[$0.range]), rect: $0.rect) }) },
                             background: CodeRegion.background(ofLines: b.lines.map { look($0.rect).backgroundColor }))
        }
        let measured = Trace.now
        let reasons = CodeRegion.keep(blocks: blocks, frameBackground: page)
        let ruled = Trace.now
        if TextRecognizer.traceReads { printFeed(blocks, verdicts: verdicts, reasons: reasons, frame: page) }
        var out = verdicts, kept: [Kept] = []
        for (i, reason) in reasons.enumerated() where verdicts[i] == .needs {
            guard let reason else { continue }
            out[i] = .literal
            kept.append(Kept(text: read[i].text, rect: read[i].rect, reason: reason))
            Trace.count("ocr.kept.code")
            Trace.count("ocr.kept.code." + reason.rawValue)
            Trace.mark("kept code (\(reason.rawValue)): \(read[i].text.prefix(100))", since: Trace.now)
        }
        Trace.mark("keep: \(read.count) blocks, \(read.reduce(0) { $0 + $1.lines.count }) lines, \(kept.count) kept as code; "
                   + "frame \(Int((t - start) * 1000)) + look \(Int((measured - t) * 1000)) + rule \(Int((ruled - measured) * 1000)) ms, total", since: start)
        return (out, kept)
    }

    /// `MWOYEO_TRACE_READS=1` prints the blocks as `CodeRegion` read them, one `[keepfeed]` JSON record per block on stderr: its text, rect,
    /// background, lines with their words, today's verdict and the region's reason. The fields are those of `tools/keep-labels` regionfeed
    /// (`id`, `pic` = the pass, `read` = "app", `idx`, `r`, `t`, `bg`, `frame`, `lines`), so `keeprules` takes a trace as its KEEP_FEED:
    /// why a block was kept or translated reproduces without its picture.
    private static func printFeed(_ blocks: [CodeRegion.Block], verdicts: [TextRecognizer.Verdict], reasons: [CodeRegion.Reason?], frame: RGBA) {
        func rect(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
        let pass = UUID().uuidString.prefix(8)
        for (i, b) in blocks.enumerated() {
            let lines: [[String: Any]] = b.lines.map { l in
                ["t": l.text, "r": rect(l.rect), "w": l.words.map { w in rect(w.rect) + [w.text] as [Any] }]
            }
            let record: [String: Any] = ["id": "\(pass)-\(i)", "pic": String(pass), "read": "app", "pass": String(pass), "idx": i, "t": b.text, "r": rect(b.rect), "bg": [Int(b.background.r), Int(b.background.g), Int(b.background.b)],
                                         "frame": [Int(frame.r), Int(frame.g), Int(frame.b)], "lines": lines, "verdict": "\(verdicts[i])", "region": reasons[i]?.rawValue ?? "-"]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) {
                FileHandle.standardError.write(Data(("[keepfeed]\t" + line + "\n").utf8))
            }
        }
    }
}
