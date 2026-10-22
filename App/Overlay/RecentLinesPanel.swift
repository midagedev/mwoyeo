import AppKit
import MwoyeoCore

/// The last few translated lines that left a lens, in a small stack just outside it, for a chat or a visual novel (design games-and-video §2).
///
/// Just outside, not inside the bottom edge: a game's text box and a chat's newest message are at the bottom of the lens, and a stack inside
/// would lie on the very line being read. The stack goes below the lens, newest nearest it, and above it when the screen has no room below.
/// Older lines are fainter (`RecentLines.opacity`). Click-through; it follows the lens.
@MainActor
final class RecentLinesPanel: NSPanel {
    private let effect = NSVisualEffectView()
    private let stack = NSStackView()
    /// The lens, AppKit coordinates.
    private var lens: NSRect
    private(set) var lines: [String] = []
    /// Whether the stack sits below the lens (false: above it).
    private(set) var isBelow = true

    private static let gap: CGFloat = 6
    private static let inset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    private static let spacing: CGFloat = 4

    /// `lens` is the lens, AppKit coordinates.
    init(lens: NSRect) {
        self.lens = lens
        super.init(contentRect: NSRect(origin: lens.origin, size: NSSize(width: max(lens.width, 200), height: 1)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = Self.spacing
        stack.edgeInsets = Self.inset
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
        ])
        contentView = effect
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The panel shows what the lens keeps; a screen reader reads the lens, whose own text is the translations on screen.
    override func isAccessibilityElement() -> Bool { false }

    /// The lens moved or was resized (AppKit coordinates): the stack follows.
    func setLens(_ new: NSRect) {
        lens = new
        place()
    }

    /// Shows `kept` (newest first): the translations, faded by age. No lines takes the panel off the screen.
    func show(_ kept: [RecentLines.Line]) {
        lines = kept.map(\.translation)
        guard !kept.isEmpty else { orderOut(nil); return }
        let width = Self.width(for: lens)
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        isBelow = Self.fitsBelow(lens, height: 0)
        // Newest nearest the lens: first below it, last above it.
        let ordered = isBelow ? Array(kept.enumerated()) : Array(kept.enumerated().reversed())
        for (rank, line) in ordered {
            let label = NSTextField(wrappingLabelWithString: line.translation)
            label.font = .systemFont(ofSize: 13)
            label.textColor = .labelColor
            label.maximumNumberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.preferredMaxLayoutWidth = width - Self.inset.left - Self.inset.right
            label.alphaValue = RecentLines.opacity(rank: rank, of: kept.count)
            label.isSelectable = false
            stack.addArrangedSubview(label)
        }
        place()
        orderFrontRegardless()
    }

    /// The stack's frame: the lens's width (at least 200 points, at most the screen's), just below the lens or, with no room, just above it.
    private func place() {
        guard !lines.isEmpty else { return }
        let width = Self.width(for: lens)
        effect.setFrameSize(NSSize(width: width, height: effect.frame.height))
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        isBelow = Self.fitsBelow(lens, height: height)
        let y = isBelow ? lens.minY - Self.gap - height : lens.maxY + Self.gap
        setFrame(NSRect(x: lens.minX, y: y, width: width, height: height), display: true)
    }

    /// The usable part of the screen that shows most of `lens`.
    private static func visible(of lens: NSRect) -> NSRect {
        let shown = NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(lens), ib = b.frame.intersection(lens)
            return (ia.isNull ? 0 : ia.width * ia.height) < (ib.isNull ? 0 : ib.width * ib.height)
        }
        return shown?.visibleFrame ?? .zero
    }

    private static func width(for lens: NSRect) -> CGFloat {
        min(max(lens.width, 200), max(visible(of: lens).width, 200))
    }

    static func fitsBelow(_ lens: NSRect, height: CGFloat) -> Bool {
        lens.minY - gap - height >= visible(of: lens).minY
    }
}
