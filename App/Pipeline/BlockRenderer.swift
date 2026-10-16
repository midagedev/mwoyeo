import AppKit
import CoreText
import MwoyeoCore

/// Draws a translated block into an image the size of the block (device pixels).
enum BlockRenderer {
    enum Background {
        /// Original pixels with the source text erased.
        case erased(RGBAImage)
        /// A rounded box in the background colour (fast mode).
        case box(RGBA, opacity: Double)
    }

    struct Input {
        var size: CGSize            // pixels
        var text: String
        var background: Background
        var appearance: TextAppearance
        /// Height of one original text line box in pixels.
        var lineHeight: CGFloat
        /// Font size (pixels, em) estimated from the original glyphs; the starting point for fitting.
        var fontSize: CGFloat?
        var originalLineCount: Int
        /// Extra pixels on the right the text may spill into (flat background, nothing else there).
        var spareWidth: CGFloat = 0
        var fontStyle: FontStyleChoice
        var targetLanguage: String
        var scale: CGFloat
        /// Centred lines (subtitles, captions) stay centred on where the original was.
        var centered = false
    }

    /// Background around the text (pixels) that an erased block takes in, for the glyph mask's ring.
    static func eraseMargin(lineHeight: CGFloat) -> Int { max(3, Int(lineHeight * 0.18)) }

    static func render(_ input: Input) -> CGImage? {
        let w = Int(input.size.width.rounded(.up)), h = Int(input.size.height.rounded(.up))
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)

        switch input.background {
        case let .erased(img):
            if let cg = img.cgImage { ctx.draw(cg, in: bounds) }
        case let .box(color, opacity):
            let radius = min(CGFloat(h) * 0.22, 6 * input.scale)
            ctx.setFillColor(color.cgColor.copy(alpha: opacity) ?? color.cgColor)
            ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }

        // An erased patch reaches `eraseMargin` past the original text on each side: start the text where it started.
        var padX = max(1, input.lineHeight * 0.06)
        if case .erased = input.background { padX = CGFloat(eraseMargin(lineHeight: input.lineHeight)) }
        let padY = max(0, input.lineHeight * 0.02)
        // The text box is the original block; `spareWidth` on the right is only used if the text needs it.
        let full = bounds.insetBy(dx: padX, dy: padY)
        let original = CGRect(x: full.minX, y: full.minY, width: max(1, full.width - input.spareWidth), height: full.height)
        let outline = input.appearance.outlineColor?.cgColor
        // Outlined text keeps its own fill: the outline, not the background, is what it is read against.
        let textColor = outline != nil ? input.appearance.textColor.cgColor : legibleTextColor(input.appearance)
        let weight = fontWeight(coverage: input.appearance.coverage)
        func make(_ s: CGFloat) -> NSAttributedString {
            attributed(input.text, size: s, weight: weight, style: input.fontStyle, color: textColor, language: input.targetLanguage,
                       centered: input.centered)
        }

        let maxSize = max(6 * input.scale, min(input.fontSize ?? input.lineHeight * 0.78, input.lineHeight * 1.05))
        let minSize = min(maxSize, max(7 * input.scale, maxSize * 0.55))
        var box = original
        var size: CGFloat
        var wraps = input.originalLineCount != 1
        if !wraps {
            // A single line stays a single line: first at full size within the original width, then spilling
            // right into free space, and only then shrinking. Wrap as a last resort.
            let unwrapped = { (s: CGFloat) in TextFitter.measure(make(s), width: .greatestFiniteMagnitude) }
            let needed = unwrapped(maxSize).width
            // Centred text has no free side to spill into: it shrinks, then wraps, around its centre.
            if needed > original.width, !input.centered { box.size.width = min(full.width, max(original.width, needed + 2)) }
            size = TextFitter.fitFontSize(in: CGSize(width: box.width, height: .greatestFiniteMagnitude), minSize: minSize, maxSize: maxSize, measure: unwrapped)
            if unwrapped(size).width > box.width + 0.5 {
                wraps = true
                size = TextFitter.fitFontSize(in: box.size, minSize: minSize * 0.8, maxSize: maxSize) { TextFitter.measure(make($0), width: box.width) }
            }
        } else {
            size = TextFitter.fitFontSize(in: box.size, minSize: minSize, maxSize: maxSize) { TextFitter.measure(make($0), width: box.width) }
            if TextFitter.measure(make(size), width: box.width).height > box.height + 0.5, input.spareWidth > 0, !input.centered {
                box.size.width = full.width
                size = TextFitter.fitFontSize(in: box.size, minSize: minSize, maxSize: maxSize) { TextFitter.measure(make($0), width: box.width) }
            }
        }
        let string = make(size)
        let measured = TextFitter.measure(string, width: wraps ? box.width : .greatestFiniteMagnitude)

        // Vertically centre; CoreText draws in a y-up space, which matches CGContext's default.
        let textRect = CGRect(x: box.minX, y: box.midY - measured.height / 2, width: box.width, height: measured.height)
        if outline == nil, !input.appearance.isFlatBackground, case .erased = input.background {
            // Busy background: a soft halo in the background colour keeps text readable.
            ctx.setShadow(offset: .zero, blur: size * 0.25, color: input.appearance.backgroundColor.cgColor)
        }
        if ProcessInfo.processInfo.environment["MWOYEO_ERASE_ONLY"] != nil { return ctx.makeImage() } // debug: background only
        let setter = CTFramesetterCreateWithAttributedString(string)
        let pathWidth = input.centered ? textRect.width : max(textRect.width, measured.width + 1)
        let path = CGPath(rect: CGRect(x: textRect.minX, y: textRect.minY - 2, width: pathWidth, height: textRect.height + 4), transform: nil)
        if let outline {
            // The edge first, as a wide stroke in the outline colour, then the letters on top: the stroke shows only
            // outside the glyphs, as subtitles are drawn. Same font and size, so both lay out identically.
            let edge = NSMutableAttributedString(attributedString: string)
            let all = NSRange(location: 0, length: edge.length)
            edge.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String), value: outline, range: all)
            edge.addAttribute(NSAttributedString.Key(kCTStrokeColorAttributeName as String), value: outline, range: all)
            edge.addAttribute(NSAttributedString.Key(kCTStrokeWidthAttributeName as String), value: 18.0, range: all)
            ctx.saveGState()
            ctx.setLineJoin(.round)
            CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(edge), CFRange(location: 0, length: 0), path, nil), ctx)
            ctx.restoreGState()
        }
        let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
        CTFrameDraw(frame, ctx)
        return ctx.makeImage()
    }

    private static func attributed(_ text: String, size: CGFloat, weight: NSFont.Weight, style: FontStyleChoice,
                                   color: CGColor, language: String, centered: Bool = false) -> NSAttributedString {
        var font = NSFont.systemFont(ofSize: size, weight: weight)
        switch style {
        case .system: break
        case .rounded:
            if let d = font.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: size) { font = f }
        case .serif:
            if let d = font.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { font = f }
            // Korean has no serif system design; prefer a Myeongjo face when installed.
            if language.hasPrefix("ko"), let f = NSFont(name: "AppleMyungjo", size: size) { font = f }
        }
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byWordWrapping
        para.lineBreakStrategy = .standard
        para.lineHeightMultiple = 0.95
        if centered { para.alignment = .center }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            .paragraphStyle: para,
            NSAttributedString.Key(kCTLanguageAttributeName as String): language,
        ]
        return NSAttributedString(string: text, attributes: attributes)
    }

    /// Stroke density stands in for font weight: bold text covers more of its line box.
    private static func fontWeight(coverage: Double) -> NSFont.Weight {
        switch coverage {
        case ..<0.18: .regular
        case ..<0.28: .medium
        case ..<0.95: .semibold
        default: .regular // whole-box fallback mask, weight unknown
        }
    }

    /// The detected text colour, nudged away from the background if they ended up too close.
    private static func legibleTextColor(_ a: TextAppearance) -> CGColor {
        let fg = a.textColor, bg = a.backgroundColor
        if abs(fg.luma - bg.luma) >= 70 { return fg.cgColor }
        return bg.luma > 140 ? CGColor(gray: 0.08, alpha: 1) : CGColor(gray: 0.97, alpha: 1)
    }
}
