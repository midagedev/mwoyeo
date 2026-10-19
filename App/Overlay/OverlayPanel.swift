import AppKit
import QuartzCore

/// Transparent, click-through panel floating over a region's display. Shows one layer per translated block.
///
/// The panel covers the whole display and never moves while the lens does: a window move and a layer move reach the
/// screen in different frames, so a panel sliding along with a dragged lens dragged its blocks along for a frame at a
/// time. Only the clip changes: translations show inside the lens and nowhere else.
///
/// While the page scrolls, blocks in the scrolling area are moved ahead of the captured frames by `prediction`, and
/// the frames' correction is eased in with a critically damped spring instead of a jump.
final class OverlayPanel: NSPanel {
    private let host = OverlayHostView()
    private var lastVersion = 0
    /// The lens, AppKit coordinates.
    private var lens: NSRect
    private var displayLink: CADisplayLink?

    /// Predicted scrolling between a frame's capture time and a display time: the area that scrolls (global Quartz
    /// points) and by how much (points, positive = down). nil when nothing is being scrolled.
    var prediction: ((_ since: TimeInterval, _ now: TimeInterval) -> (area: CGRect, dy: CGFloat)?)?

    /// `frame` is the lens, AppKit coordinates.
    init(frame: NSRect) {
        lens = frame
        super.init(contentRect: Self.display(of: frame), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        isMovable = false
        // Above app windows, below menus and popovers of the app underneath.
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        contentView = host
        host.lens = hostRect(frame)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The panel only draws what the lens shows; the lens window (`RegionFrameWindow`) is what a screen reader reads, with the text. An
    /// empty full-screen window in its window list would be noise.
    override func isAccessibilityElement() -> Bool { false }

    private static func display(of lens: NSRect) -> NSRect {
        NSScreen.screens.max { a, b in
            let ia = a.frame.intersection(lens), ib = b.frame.intersection(lens)
            return ia.width * ia.height < ib.width * ib.height
        }?.frame ?? lens
    }

    /// An AppKit rect in the host view's (top-left based) coordinates.
    private func hostRect(_ r: NSRect) -> CGRect {
        CGRect(x: r.minX - frame.minX, y: frame.maxY - r.maxY, width: r.width, height: r.height)
    }

    func apply(_ snapshot: OverlaySnapshot) {
        guard snapshot.version > lastVersion else { return }
        lastVersion = snapshot.version
        let here = ScreenGeometry.quartzRect(fromAppKit: frame).origin
        let offset = CGVector(dx: snapshot.origin.x - here.x, dy: snapshot.origin.y - here.y)
        host.apply(snapshot, offset: offset)
        predict(at: CACurrentMediaTime(), correcting: true)
    }

    /// The lens moved with its content (the window under it moved): the blocks move along.
    func move(to newLens: NSRect) {
        place(newLens, contentDelta: CGVector(dx: newLens.minX - lens.minX, dy: lens.maxY - newLens.maxY))
    }

    /// The lens moved over still content (dragged or resized): the blocks stay where they are on screen.
    func slide(to newLens: NSRect) {
        place(newLens, contentDelta: .zero)
    }

    /// `contentDelta` in points, y down.
    private func place(_ newLens: NSRect, contentDelta: CGVector) {
        lens = newLens
        let display = Self.display(of: newLens)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var d = contentDelta
        if display != frame {
            // Another display: the panel follows (once, not per drag step); the blocks keep their place on screen.
            d.dx += frame.minX - display.minX
            d.dy += display.maxY - frame.maxY
            setFrame(display, display: false)
        }
        if d.dx != 0 || d.dy != 0 { host.offsetBlocks(by: d) }
        host.lens = hostRect(newLens)
        CATransaction.commit()
        host.updateVisibility(animated: contentDelta == .zero)
    }

    /// Fades the translations out (show original) or back in.
    func setTranslationsVisible(_ visible: Bool, animated: Bool = true) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = animated ? 0.18 : 0
            animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: - Scroll prediction

    /// Places the predicted scroll for display time `now`, and keeps doing so every display frame while a scroll is
    /// under way. `correcting`: the frames just moved the blocks, so any difference to where they were is an error
    /// of the prediction, eased out.
    func predict(at now: TimeInterval = CACurrentMediaTime(), correcting: Bool = false) {
        let here = ScreenGeometry.quartzRect(fromAppKit: frame).origin
        let p = prediction?(host.time, now)
        // Ending a prediction is a correction too: whatever the frames have not confirmed eases away.
        host.setPrediction(p.map { (area: $0.area.offsetBy(dx: -here.x, dy: -here.y), dy: $0.dy) }, correcting: correcting || p == nil)
        if p != nil, displayLink == nil {
            let link = host.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if p == nil {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    @objc private func tick(_ link: CADisplayLink) { predict(at: link.targetTimestamp) }
}

private final class OverlayHostView: NSView {
    private var layersByID: [UUID: CALayer] = [:]
    /// Each block's frame as the last snapshot placed it (host coordinates), before any predicted scroll.
    private var placed: [UUID: CGRect] = [:]
    /// The lens, host coordinates. Translations are clipped to it.
    var lens = CGRect.zero {
        didSet {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            clip.frame = lens
            CATransaction.commit()
        }
    }
    private let clip = CALayer()
    /// Capture time of the frame the blocks were placed from.
    private(set) var time: TimeInterval = 0
    private var prediction: (area: CGRect, dy: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = true // block frames are top-left based
        layerContentsRedrawPolicy = .never
        clip.backgroundColor = .black
        clip.cornerRadius = 12 // the lens frame's
        clip.cornerCurve = .continuous
        layer?.mask = clip
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let s = window?.backingScaleFactor ?? 2
        layer?.contentsScale = s
        layersByID.values.forEach { $0.contentsScale = s }
    }

    func apply(_ snapshot: OverlaySnapshot, offset: CGVector) {
        let scale = window?.backingScaleFactor ?? 2
        time = snapshot.time
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var seen = Set<UUID>()
        for var block in snapshot.blocks {
            block.frame = block.frame.offsetBy(dx: offset.dx, dy: offset.dy)
            seen.insert(block.id)
            placed[block.id] = block.frame
            if let l = layersByID[block.id] {
                if snapshot.animated, (l.contents as AnyObject?) !== block.image {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = 0.22
                    l.add(fade, forKey: "contents")
                }
                l.bounds.size = block.frame.size
                l.contents = block.image
            } else {
                let l = CALayer()
                l.contentsScale = scale
                l.contentsGravity = .resize
                l.magnificationFilter = .linear
                l.frame = block.frame
                l.contents = block.image
                layer?.addSublayer(l)
                layersByID[block.id] = l
                if snapshot.animated {
                    let fade = CABasicAnimation(keyPath: "opacity")
                    fade.fromValue = 0
                    fade.toValue = 1
                    fade.duration = 0.22
                    l.add(fade, forKey: "appear")
                }
            }
        }
        for (id, l) in layersByID where !seen.contains(id) {
            layersByID[id] = nil
            placed[id] = nil
            if snapshot.animated {
                CATransaction.begin()
                CATransaction.setCompletionBlock { l.removeFromSuperlayer() }
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 1
                fade.toValue = 0
                fade.duration = 0.18
                l.opacity = 0
                l.add(fade, forKey: "disappear")
                CATransaction.commit()
            } else {
                l.removeFromSuperlayer()
            }
        }
        CATransaction.commit()
        // Positions (with any prediction) are set by `setPrediction`, which the panel calls right after.
        updateVisibility(animated: snapshot.animated)
    }

    /// Moves the blocks in the scrolling area (host coordinates) by the predicted scroll. With `correcting`, a block
    /// that is not where it was shown (the frames corrected the prediction) eases there instead of jumping.
    func setPrediction(_ p: (area: CGRect, dy: CGFloat)?, correcting: Bool) {
        let was = prediction
        prediction = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, l) in layersByID {
            guard let f = placed[id] else { continue }
            let dy = p.map { $0.area.contains(CGPoint(x: f.midX, y: f.midY)) ? $0.dy : 0 } ?? 0
            let target = CGPoint(x: f.midX, y: f.midY + dy)
            // Measured from where the block is seen: a correction still easing in carries on from there.
            let shown = l.animation(forKey: "correction") != nil ? (l.presentation() ?? l).position : l.position
            let error = CGVector(dx: shown.x - target.x, dy: shown.y - target.y)
            l.position = target
            // Only a correction of a prediction eases; a block placed or moved by the frames alone goes straight there.
            if correcting, was != nil || p != nil, error.dx != 0 || error.dy != 0, hypot(error.dx, error.dy) < 80,
               l.animation(forKey: "appear") == nil {
                let spring = CASpringAnimation(keyPath: "position")
                spring.mass = 1
                spring.stiffness = 900
                spring.damping = 2 * (spring.stiffness * spring.mass).squareRoot()   // critically damped: no overshoot
                spring.isAdditive = true
                spring.fromValue = NSValue(point: NSPoint(x: error.dx, y: error.dy))
                spring.toValue = NSValue(point: .zero)
                spring.duration = spring.settlingDuration
                l.add(spring, forKey: "correction")
            }
        }
        CATransaction.commit()
        updateVisibility(animated: false)
    }

    /// Shows the blocks the lens touches (the clip cuts them at its edge); hides the rest.
    func updateVisibility(animated: Bool) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.15 : 0)
        CATransaction.setDisableActions(!animated)
        for l in layersByID.values {
            let opacity: Float = l.frame.intersects(lens) ? 1 : 0
            if l.opacity != opacity { l.opacity = opacity }
        }
        CATransaction.commit()
    }

    /// Content moved by `d` (points, y down): the blocks go along.
    func offsetBlocks(by d: CGVector) {
        for (id, l) in layersByID {
            l.position = CGPoint(x: l.position.x + d.dx, y: l.position.y + d.dy)
            placed[id] = placed[id]?.offsetBy(dx: d.dx, dy: d.dy)
        }
    }
}
