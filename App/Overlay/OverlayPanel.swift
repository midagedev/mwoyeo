import AppKit
import MwoyeoCore
import QuartzCore

/// Transparent, click-through panel floating over a region's display. Shows one layer per translated block.
///
/// The panel covers the whole display and never moves while the lens does: a window move and a layer move reach the
/// screen in different frames, so a panel sliding along with a dragged lens dragged its blocks along for a frame at a
/// time. Only the clip changes: translations show inside the lens and nowhere else.
///
/// While the page scrolls, blocks in the scrolling area are moved ahead of the captured frames by `prediction`, and
/// the frames' correction is eased in with a critically damped spring instead of a jump.
///
/// The clip is the lens window's own outline (`LensSkin`, motion contract 9.5): the ring bows and settles over the frame, and the translations are cut
/// by the same shape, so no text shows where the ring is not and none is cut where it is.
///
/// Parts of the lens its person marked not to read (`IgnoredRegions`) are cut out of the clip, so no translation is drawn over them, and
/// outlined while the pointer is over the lens (`setIgnored`, `showsIgnored`). The outlines are in a view of their own: the clip would cut
/// them away with the translations.
final class OverlayPanel: NSPanel {
    private let host = OverlayHostView()
    /// Holds the host and the snap guide: the host's layer is clipped to the lens, the guide stands outside it.
    private let root = NSView()
    private let guide = NSView()
    private let outlines = IgnoredOutlinesView()
    /// The regions as the session has them (fractions of the lens); `lens` below is where they lie.
    private var ignored: [UnitRect] = []
    private var lastVersion = 0
    /// The lens, AppKit coordinates.
    private var lens: NSRect
    private var displayLink: CADisplayLink?

    /// The lens's outline now, relative to its bottom-left (the lens window's ring draws the same one); nil: the rounded rect.
    var outline: (() -> LensOutline?)?

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
        root.frame = NSRect(origin: .zero, size: Self.display(of: frame).size)
        root.wantsLayer = true
        for view in [host, outlines] {
            view.frame = root.bounds
            view.autoresizingMask = [.width, .height]
            root.addSubview(view)
        }
        guide.wantsLayer = true
        guide.alphaValue = 0
        root.addSubview(guide)
        contentView = root
        host.prepare(outline: .rigid(CGRect(origin: .zero, size: frame.size)), lens: hostRect(frame))
    }

    /// The clip's outline as the layers place it, in screen coordinates (y up), for the checks.
    func clipOutlineOnScreen() -> CGPath? {
        guard let hostPath = host.clipOutlineInHost else { return nil }
        var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: frame.minX, ty: frame.maxY)
        return hostPath.copy(using: &t)
    }

    /// The outline changed with the lens where it was (it settles after a fit, a drag or a commit): the clip is cut again.
    func restyle() {
        host.prepare(outline: outline?() ?? .rigid(CGRect(origin: .zero, size: lens.size)), lens: host.lens)
    }

    /// The snap guide (design lens-fit): one point wide, in the accent colour, along `rect` (AppKit coordinates, the column's edge and its extent). It is
    /// not clipped to the lens, since the edge it marks is a few points from the lens's own.
    func showGuide(_ rect: NSRect) {
        let r = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        effectiveAppearance.performAsCurrentDrawingAppearance { guide.layer?.backgroundColor = NSColor.controlAccentColor.cgColor }
        guide.frame = NSRect(x: r.minX - 0.5, y: r.minY, width: 1, height: r.height)
        fadeGuide(to: LensMotion.guideAlpha)
    }

    func hideGuide() { fadeGuide(to: 0) }

    private func fadeGuide(to alpha: CGFloat) {
        guard guide.alphaValue != alpha else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = LensMotion.seconds(LensMotion.guideFade, reduced: Motion.shared.reduced)
            guide.animator().alphaValue = alpha
        }
    }

    /// The regions of the lens that are not read or drawn over, as fractions of it.
    func setIgnored(_ regions: [UnitRect]) {
        ignored = regions
        placeIgnored()
    }

    /// Whether the outlines of the regions show (the pointer is over the lens, or one is being marked).
    func showsIgnored(_ on: Bool) { outlines.setShown(on && !ignored.isEmpty) }

    /// The regions in the host's coordinates, for the clip and the outlines.
    private func placeIgnored() {
        let rects = ignored.map { $0.rect(in: host.lens) }
        host.ignored = rects
        outlines.regions = rects
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
        host.prepare(outline: outline?() ?? .rigid(CGRect(origin: .zero, size: newLens.size)), lens: hostRect(newLens))
        placeIgnored()
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
    /// The lens, host coordinates (top-left origin, y down). Translations are clipped to its outline, not to this rect.
    private(set) var lens = CGRect.zero
    /// The outline, relative to the lens's bottom-left (y up): the ring's own.
    private(set) var outline = LensOutline.rigid(.zero)

    /// The lens and its outline, as the lens window has them. The clip layer is the outline's own size, placed in the host (a move only changes its frame);
    /// its path is that outline at the origin, turned over because the host's geometry is flipped.
    func prepare(outline: LensOutline, lens: CGRect) {
        guard outline != self.outline || lens != self.lens else { return }
        self.outline = outline
        self.lens = lens
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let local = outline.moved(by: CGVector(dx: -outline.frame.minX, dy: -outline.frame.minY))
        clip.frame = CGRect(x: lens.minX + outline.frame.minX, y: lens.maxY - outline.frame.maxY, width: local.frame.width, height: local.frame.height)
        if clipped != local {
            clipped = local
            var turn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: local.frame.height)
            clip.path = local.path(outset: 0).copy(using: &turn)
        }
        cutIgnored()
        CATransaction.commit()
    }

    /// The outline in host coordinates (y down), for the clip with parts cut out of it.
    var hostPath: CGPath {
        var turn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: lens.minX, ty: lens.maxY)
        return outline.path(outset: 0).copy(using: &turn) ?? CGPath(rect: lens, transform: nil)
    }

    /// The clip's outline as the layers place it: each point of its path taken to the host layer's space by CoreAnimation, which does the flip. For the checks.
    var clipOutlineInHost: CGPath? {
        guard let path = clip.path, let host = layer else { return nil }
        let out = CGMutablePath()
        path.applyWithBlock { e in
            let p = e.pointee.points
            func at(_ i: Int) -> CGPoint { clip.convert(p[i], to: host) }
            switch e.pointee.type {
            case .moveToPoint: out.move(to: at(0))
            case .addLineToPoint: out.addLine(to: at(0))
            case .addQuadCurveToPoint: out.addQuadCurve(to: at(1), control: at(0))
            case .addCurveToPoint: out.addCurve(to: at(2), control1: at(0), control2: at(1))
            case .closeSubpath: out.closeSubpath()
            @unknown default: break
            }
        }
        return out
    }

    /// Parts of the lens (host coordinates) where nothing is drawn.
    var ignored: [CGRect] = [] {
        didSet {
            guard ignored != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cutIgnored()
            CATransaction.commit()
        }
    }
    private let clip = CAShapeLayer()
    /// What `clip.path` holds: the outline at the origin.
    private var clipped: LensOutline?
    /// The clip with the ignored parts cut out of it (even-odd), used only while there are any: a lens with none keeps the plain clip.
    private let holes = CAShapeLayer()
    /// Capture time of the frame the blocks were placed from.
    private(set) var time: TimeInterval = 0
    private var prediction: (area: CGRect, dy: CGFloat)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.isGeometryFlipped = true // block frames are top-left based
        layerContentsRedrawPolicy = .never
        // The ring's corner construction (`LensOutline`: arcs and cubics), not a continuous corner radius: one outline for the ring and the clip.
        clip.fillColor = NSColor.black.cgColor
        clip.strokeColor = nil
        holes.fillColor = .black
        holes.fillRule = .evenOdd
        layer?.mask = clip
    }

    /// The mask is the lens, less the ignored regions inside it.
    private func cutIgnored() {
        let inside = ignored.map { $0.intersection(lens) }.filter { !$0.isNull && !$0.isEmpty }
        guard !inside.isEmpty else {
            if layer?.mask !== clip { layer?.mask = clip }
            return
        }
        let path = CGMutablePath()
        path.addPath(hostPath)
        inside.forEach { path.addRect($0) }
        holes.frame = CGRect(origin: .zero, size: CGSize(width: max(bounds.width, lens.maxX), height: max(bounds.height, lens.maxY)))
        holes.path = path
        if layer?.mask !== holes { layer?.mask = holes }
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

/// The outlines of the regions a lens does not read: a hatched fill and a thin edge in the accent colour, over whatever the screen shows, only
/// while the pointer is over the lens. Click-through like the panel.
private final class IgnoredOutlinesView: NSView {
    var regions: [CGRect] = [] {
        didSet {
            guard regions != oldValue else { return }
            needsDisplay = true
        }
    }
    private var shown = false

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        alphaValue = 0
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setShown(_ on: Bool) {
        guard on != shown else { return }
        shown = on
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            animator().alphaValue = on ? 1 : 0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let accent = NSColor.controlAccentColor
        for r in regions where r.intersects(dirtyRect) {
            ctx.saveGState()
            ctx.clip(to: r)
            accent.withAlphaComponent(0.10).setFill()
            ctx.fill(r)
            accent.withAlphaComponent(0.45).setStroke()
            ctx.setLineWidth(1)
            var x = r.minX - r.height
            while x < r.maxX {
                ctx.move(to: CGPoint(x: x, y: r.maxY))
                ctx.addLine(to: CGPoint(x: x + r.height, y: r.minY))
                x += 7
            }
            ctx.strokePath()
            ctx.restoreGState()
            accent.withAlphaComponent(0.9).setStroke()
            let edge = NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
            edge.lineWidth = 1
            edge.stroke()
        }
    }
}
