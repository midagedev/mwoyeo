import AppKit

/// The menu bar symbol with a badge: a filled dot at the top right, a ring cut out around it so it stands off the glyph. A template
/// image (one colour, any alpha), so the menu bar tints it like every other icon, light or dark. Static: no animation.
enum MenuBarIconImage {
    /// The size the system draws `Image(systemName:)` at in the menu bar (the body text style, medium scale).
    static let pointSize: CGFloat = 13
    /// The dot's diameter and the ring around it, points.
    static let dot: CGFloat = 5.5
    static let ring: CGFloat = 1.9

    static func badged(_ symbol: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular, scale: .medium)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
            return NSImage(size: NSSize(width: 18, height: 18))
        }
        let size = base.size
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            // The dot sits on the glyph's top right corner, inside the image.
            let c = NSPoint(x: rect.maxX - dot / 2 - 0.5, y: rect.maxY - dot / 2 - 0.5)
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: c.x - dot / 2 - ring, y: c.y - dot / 2 - ring, width: dot + 2 * ring, height: dot + 2 * ring)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: c.x - dot / 2, y: c.y - dot / 2, width: dot, height: dot)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
