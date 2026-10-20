#if !MAS
import AppKit
import CoreText
import MwoyeoCore

/// The checks of the code-region wiring, run by `--capture-ui … check-logic` (PASS/FAIL lines): a picture drawn with prose and a tinted
/// code box, the blocks the reader would hand over (one per line, as the document read cuts a listing), the real line appearance and
/// frame colour measured on it. The rule itself is `CodeRegionTests`; this is what the pipeline does with it: the code is kept as
/// written (verdict `.literal`, the road that is neither erased nor sent), the prose is translated, a callout of prose is translated,
/// and `MWOYEO_KEEP=off` brings the translation of the code back. No Vision, no engine, no clock.
@MainActor
enum CodeKeepChecks {
    static func run() -> Int {
        var failed = 0
        func check(_ what: String, _ ok: Bool, _ note: @autoclosure () -> String = "") {
            print("check-logic: \(ok ? "PASS" : "FAIL") code keep: \(what)" + (ok || note().isEmpty ? "" : " [\(note())]"))
            if !ok { failed += 1 }
        }
        let target = "ko"
        let prose = ["Install the latest release and check the version.", "Run it with the month flag to see one month only."]
        let code = ["const nested = [1, 12, [3, [4]]];", "// flatten every level at once", "console.log(flat); // [1, 2, 3, 4]"]
        let page = Picture(page: RGBA(255, 255, 255), size: CGSize(width: 900, height: 560))
        let box = RGBA(246, 248, 250)                                           // a code box on a white page: 9 levels

        // A run cut out of a line (the lines of a syntax-coloured listing are cut at the colour changes) keeps the ranges of its words in its own
        // text: CodeKeep reads them (the first build of the pitch crashed on 20 of the 52 use-case pictures, "String index range is out of bounds").
        let source = "let total = price * 2"
        let coloured = OCRLine(rect: CGRect(x: 0, y: 0, width: 400, height: 30), text: source,
                               words: ["let", "total", "=", "price", "*", "2"].map { w in OCRWord(rect: .zero, range: source.range(of: w)!) })
        let middle = coloured.run(1..<4, in: coloured.rect)
        check("a run cut out of a line has its own text, and its words' ranges index it",
              middle.text == "total = price" && middle.words.map { String(middle.text[$0.range]) } == ["total", "=", "price"])

        // The page colour of a frame.
        var flat = RGBAImage(width: 20, height: 10, color: RGBA(255, 255, 255))
        for x in 0..<5 { for y in 0..<10 { flat.set(x: x, y: y, RGBA(246, 248, 250)) } }
        check("the frame's colour is the one most of it has, not the box's", FrameBackground.dominant(of: flat) == RGBA(255, 255, 255))
        var banded = RGBAImage(width: 4, height: 1, color: RGBA(30, 30, 30))
        for (x, v) in [28, 30, 31, 32].enumerated() { banded.set(x: x, y: 0, RGBA(UInt8(v), UInt8(v), UInt8(v))) }
        check("a soft gradient gives the middle of its largest band", FrameBackground.dominant(of: banded) == RGBA(30, 30, 30))

        // The reader's blocks of the picture: prose, a tinted code box of three lines, prose.
        let boxed = page.drawing { p in
            p.text(prose[0], at: 60, y: 40, code: false)
            p.fill(CGRect(x: 50, y: 120, width: 800, height: 150), box)
            for (i, line) in code.enumerated() { p.text(line, at: 80, y: 140 + CGFloat(i) * 35, code: true) }
            p.text(prose[1], at: 60, y: 420, code: false)
        }
        check("the frame colour of the drawn picture is the page's", boxed.image.flatMap(FrameBackground.dominant(of:)) == RGBA(255, 255, 255))
        guard let image = boxed.image else { check("the picture is drawn", false); return failed }
        let today = boxed.blocks.map { TextRecognizer.verdict($0.text, target: target) }
        check("today's rules translate the prose and the code lines alike", today == Array(repeating: .needs, count: 5), "\(today)")

        var looked = 0
        let look: (CGRect) -> TextAppearance = { looked += 1; return RegionPipeline.appearance(of: $0, in: image) }
        let kept = CodeKeep.apply(today, to: boxed.blocks, frame: image, enabled: true, look: look)
        check("the code box is kept as written, with the reason", kept.verdicts == [.needs, .literal, .literal, .literal, .needs]
              && kept.kept.map(\.text) == code && kept.kept.allSatisfy { $0.reason == .code }, "\(kept.verdicts) \(kept.kept.map(\.reason))")
        let sent = zip(boxed.blocks, kept.verdicts).filter { $1 == .needs }.map { $0.0.text }
        check("what is erased and sent to the engine is the prose, in order", sent == prose, "\(sent)")
        check("every line of the read was measured once", looked == boxed.blocks.reduce(0) { $0 + $1.lines.count }, "\(looked)")

        // The same box as one block (a reader that keeps the listing whole).
        let whole = OCRBlock(rect: boxed.blocks[1].rect.union(boxed.blocks[3].rect), lines: boxed.blocks[1...3].flatMap(\.lines), text: code.joined(separator: " "))
        let oneBlock = [boxed.blocks[0], whole, boxed.blocks[4]]
        let wholeKept = CodeKeep.apply(oneBlock.map { TextRecognizer.verdict($0.text, target: target) }, to: oneBlock, frame: image, enabled: true, look: look)
        check("a box read as one block is kept as one", wholeKept.verdicts == [.needs, .literal, .needs] && wholeKept.kept.count == 1)

        // MWOYEO_KEEP=off.
        let off = CodeKeep.apply(today, to: boxed.blocks, frame: image, enabled: false, look: look)
        check("with the switch off the code box is translated as before", off.verdicts == today && off.kept.isEmpty)
        check("the switch is read from MWOYEO_KEEP=off and nothing else",
              DebugSwitch.isOff("MWOYEO_KEEP", in: ["MWOYEO_KEEP": "off"]) && !DebugSwitch.isOff("MWOYEO_KEEP", in: [:])
              && !DebugSwitch.isOff("MWOYEO_KEEP", in: ["MWOYEO_KEEP": "on"]) && !DebugSwitch.isOff("MWOYEO_KEEP", in: ["MWOYEO_PREDICT": "off"]))
        let env = ProcessInfo.processInfo.environment
        let byDefault = CodeKeep.apply(today, to: boxed.blocks, frame: image, look: look)
        check("the process default follows the environment (\(env["MWOYEO_KEEP"] == "off" ? "off" : "on"))",
              CodeKeep.enabled == (env["MWOYEO_KEEP"] != "off") && byDefault.kept.count == (CodeKeep.enabled ? 3 : 0))

        // The scroll predictor switch: on unless MWOYEO_PREDICT=off.
        check("the scroll predictor is on unless MWOYEO_PREDICT=off",
              DebugSwitch.isOff("MWOYEO_PREDICT", in: ["MWOYEO_PREDICT": "off"]) && !DebugSwitch.isOff("MWOYEO_PREDICT", in: [:])
              && RegionSession.predicts == (env["MWOYEO_PREDICT"] != "off"))

        // A callout box of prose is a container, not code.
        let callout = page.drawing { p in
            p.fill(CGRect(x: 50, y: 100, width: 800, height: 150), box)
            for (i, line) in ["Tip: if you want to see the balance of one account,", "pass its name in the command line and press Enter.",
                              "The report is printed to the terminal."].enumerated() { p.text(line, at: 80, y: 120 + CGFloat(i) * 35, code: false) }
        }
        if let image = callout.image {
            let v = callout.blocks.map { TextRecognizer.verdict($0.text, target: target) }
            let r = CodeKeep.apply(v, to: callout.blocks, frame: image, enabled: true) { RegionPipeline.appearance(of: $0, in: image) }
            check("a tinted callout of prose is translated", r.verdicts == v && r.kept.isEmpty && v.allSatisfy { $0 == .needs }, "\(r.verdicts) \(r.kept.map(\.reason))")
        } else { check("the callout picture is drawn", false) }

        // Nothing to translate: nothing is measured (a screen of numbers, links and times costs the read nothing).
        let literal = page.drawing { p in p.text("12:30", at: 60, y: 40, code: false) }
        if let image = literal.image {
            var measured = 0
            let v = literal.blocks.map { TextRecognizer.verdict($0.text, target: target) }
            let r = CodeKeep.apply(v, to: literal.blocks, frame: image, enabled: true) { measured += 1; return RegionPipeline.appearance(of: $0, in: image) }
            check("a read with nothing to translate measures nothing", v == [.literal] && r.verdicts == v && measured == 0)
        } else { check("the literal picture is drawn", false) }
        return failed
    }

    /// A picture drawn with CoreText in top-left coordinates, and the block the reader would report for each text run.
    private struct Picture {
        var page: RGBA
        var size: CGSize
        var image: CGImage?
        var blocks: [OCRBlock] = []

        init(page: RGBA, size: CGSize) { self.page = page; self.size = size }

        func drawing(_ body: (inout Canvas) -> Void) -> Picture {
            var canvas = Canvas(page: page, size: size)
            body(&canvas)
            var out = self
            out.image = canvas.context.makeImage()
            out.blocks = canvas.blocks
            return out
        }
    }

    private struct Canvas {
        let context: CGContext
        var blocks: [OCRBlock] = []

        init(page: RGBA, size: CGSize) {
            let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context = ctx
            fill(CGRect(origin: .zero, size: size), page)
        }

        func fill(_ rect: CGRect, _ c: RGBA) {
            context.setFillColor(CGColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1))
            context.fill(rect)
        }

        /// One line of text with its top-left at (x, y); its block is what a reader would report: the measured line box.
        mutating func text(_ string: String, at x: CGFloat, y: CGFloat, code: Bool) {
            let font = code ? CTFontCreateWithName("Menlo" as CFString, 16, nil) : CTFontCreateUIFontForLanguage(.system, 17, nil)!
            let ink = CGColor(srgbRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                             NSAttributedString.Key(kCTForegroundColorAttributeName as String): ink]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            context.textPosition = CGPoint(x: x, y: y + ascent)
            CTLineDraw(line, context)
            let rect = CGRect(x: x, y: y, width: width, height: ascent + descent)
            blocks.append(OCRBlock(rect: rect, lines: [OCRLine(rect: rect, text: string)], text: string))
        }
    }
}
#endif
