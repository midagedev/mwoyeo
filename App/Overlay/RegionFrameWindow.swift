import AppKit
import MwoyeoCore
import QuartzCore

/// The draggable "lens" around a region: a glowing gradient ring (in the colours of Apple Intelligence) that breathes
/// while the lens reads and translates, a name pill on top, and a resize corner.
/// The ring and pill are grabbable; the interior is fully transparent, so clicks there go to the app underneath.
/// The pill's icon says whether the lens follows a window or is pinned to the screen; clicking it switches.
final class RegionFrameWindow: NSPanel {
    /// Room around the region for the glow and the grab band.
    static let margin: CGFloat = 18
    static let tabHeight: CGFloat = 26
    /// What the name tag takes beside the region: the gap to the region, its height, and room for its shadow (blur 8) so the
    /// window edge does not cut it.
    static let tabExtra: CGFloat = 6 + tabHeight + 8

    /// Live drag: the region's new AppKit frame.
    var onMove: ((NSRect) -> Void)?
    var onResize: ((NSRect) -> Void)?
    /// Drag/resize finished.
    var onCommit: (() -> Void)?
    var onClose: (() -> Void)?
    var onToggleFollowing: (() -> Void)?
    /// Right-click on the name pill: the menu to show, built when asked.
    var onContextMenu: (() -> NSMenu?)?
    /// The pill's hint (`setHint`) was clicked.
    var onHintAction: (() -> Void)?
    /// VoiceOver's actions for the lens (`LensAccessElement`): show the original or the translation, pause every lens.
    var onToggleOriginal: (() -> Void)?
    var onPause: (() -> Void)?
    /// What the lens translated, in reading order: VoiceOver reads the start of it. Asked when a screen reader asks, never otherwise.
    var translationLines: (() -> [String])?
    /// Fit to Column, or its undo: a double-click on the ring, and VoiceOver's action (named by `fitTitle`, as the menu names its row).
    var onFit: (() -> Void)?
    var fitTitle: (() -> String)?
    /// A resize drag's frame as the hand made it, and the frame it takes after the snap (`RegionSession.snapResized`; the same frame when nothing pulls).
    var onSnapResize: ((NSRect) -> NSRect)?
    /// A move ended at this frame: the frame it settles on after the snap, nil to stay (`RegionSession.settleFrame`).
    var onSettle: ((NSRect) -> NSRect?)?
    /// A resize ended at this frame: the frame it settles on, the rest of the way onto a column's edge (`RegionSession.settleResized`).
    var onSettleResize: ((NSRect) -> NSRect?)?
    /// The ring's outline changed with no change of frame (the skin settling after a fit, a drag or a commit): the panel cuts its clip by it again.
    var onOutline: (() -> Void)?

    private let chrome: FrameChromeView
    private var tabPosition = LensTabPosition.topLeading

    init(region: NSRect, name: String) {
        chrome = FrameChromeView(name: name)
        super.init(contentRect: Self.windowFrame(for: region, position: .topLeading), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
        contentView = chrome
        chrome.window_ = self
    }

    override var canBecomeKey: Bool { false }

    /// What a screen reader's window list calls the lens ("Translation lens, Safari"); the window itself has no title.
    override func accessibilityTitle() -> String? { "\(String(localized: "Translation lens")), \(chrome.name)" }

    /// The window around `region`: the margin on every side, and room for the name tag above it or below it.
    static func windowFrame(for region: NSRect, position: LensTabPosition) -> NSRect {
        let below = position.isBottom ? tabExtra : margin
        return NSRect(x: region.minX - margin, y: region.minY - below,
                      width: region.width + 2 * margin, height: region.height + margin + tabExtra)
    }

    var regionFrame: NSRect {
        let below = tabPosition.isBottom ? Self.tabExtra : Self.margin
        return NSRect(x: frame.minX + Self.margin, y: frame.minY + below,
                      width: frame.width - 2 * Self.margin, height: frame.height - Self.margin - Self.tabExtra)
    }

    /// The lens is at `r` and nobody animated it there (it followed its window, changed display, came up): the outline rests on it.
    func setRegion(_ r: NSRect) {
        driveRegion(r)
        chrome.seat()
    }

    /// The lens goes to `r` as a hand or an animation steps it: the outline (`LensSkin`) lags that frame, so it is not put at rest.
    func driveRegion(_ r: NSRect) {
        setFrame(Self.windowFrame(for: r, position: tabPosition), display: true)
    }

    func setName(_ name: String) { chrome.name = name }
    /// Second line of the pill, e.g. "English → Korean".
    /// `badge` is an SF Symbol name shown before it when an added engine translates (nil for Apple).
    func setDetail(_ detail: String, badge: String? = nil) { chrome.badge = badge; chrome.detail = detail }

    /// Handles and full brightness while the pointer is near or a drag is in progress.
    func setEmphasized(_ on: Bool) { chrome.setEmphasized(on) }

    func setBusy(_ busy: Bool) { chrome.busy = busy }

    /// Window lens (true) or screen lens.
    func setFollowing(_ on: Bool) { chrome.following = on }

    func setAppearance(_ s: AppSettings) {
        setAppearance(style: s.lensStyle, tint: s.lensTint, tabVisibility: s.lensTabVisibility, tabPosition: s.lensTabPosition)
    }

    /// How the lens looks. A new tag position moves the window around the region, never the region.
    func setAppearance(style: LensStyle, tint: LensTint, tabVisibility: LensTabVisibility, tabPosition: LensTabPosition) {
        let region = regionFrame
        let moved = tabPosition != self.tabPosition
        self.tabPosition = tabPosition
        chrome.tabPosition = tabPosition
        chrome.tabVisibility = tabVisibility
        chrome.tint = tint
        chrome.style = style
        if moved { setRegion(region) }
    }

    /// Showing the original: the ring turns grey, the pill says so, and a sweep marks the switch.
    func setOriginal(_ on: Bool) { chrome.original = on }

    /// Says `text` on the pill for a moment ("Copied", "Saved").
    func flash(_ text: String, seconds: TimeInterval = 1.5) { chrome.flash(text, seconds: seconds) }

    /// The one line a lens that shows nothing has for the user (`LensHint`), in place of the languages while it lasts and never
    /// beside them; a flash wins over it for its few seconds. `actionable`: clicking it calls `onHintAction`. `forcesTab`: the pill
    /// shows even where the look keeps it away. nil takes it down.
    func setHint(_ text: String?, actionable: Bool = false, forcesTab: Bool = false) {
        chrome.setHint(text, actionable: actionable, forcesTab: forcesTab)
    }

    /// A light sweep across the lens, for when it first comes alive.
    func sweep() { chrome.sweep() }

    /// Takes the region to `target` in `duration` (`FitMotion`: a spring, no overshoot; at once under Reduce Motion), telling `onResize` (the size
    /// changes) or `onMove` of every frame as a drag does, so the capture and the translations follow as they follow a hand. `completion(true)` after
    /// the last frame, `completion(false)` when a hand took the lens or `stopAnimating` cut it short, wherever it had got to. `moment` is the row of
    /// `LensSkin.choreography` the ring's outline plays over the frame.
    func animate(to target: NSRect, duration: TimeInterval = LensMotion.fit, moment: LensSkin.Moment, completion: @escaping (_ finished: Bool) -> Void) {
        chrome.animate(to: target, duration: duration, moment: moment, completion: completion)
    }

    func stopAnimating() { chrome.stopAnimating() }

    /// An animation (`animate`) is under way.
    var isAnimating: Bool { chrome.isAnimating }

    /// The lens was placed by the picker's click (AppKit coordinates): from its first frame the outline takes hold, the side nearest the click
    /// first, and the pill comes in (motion contract 3.5, 9.4). A lens that is only restored does not.
    func takeHold(at click: CGPoint) { chrome.takeHold(at: click) }

    /// The ring's outline now, relative to the region's bottom-left (y up). The panel's clip is cut by the same one.
    func outline() -> LensOutline { chrome.outline() }

    /// One line for the lens's own log and the checks: the bows (left, top, right, bottom, pt) and what the outline has done in its moment.
    func stats() -> String { chrome.stats() }

    /// What the outline has done in the moment under way (peak bow, when it rested), and how far the pill has come in (0 to 1) after a hold.
    var meter: LensSkin.Meter { chrome.meter }
    var introAlpha: CGFloat { chrome.introAlpha }

    /// A moment of the outline begins, and one frame of it as the display link makes it; the checks make theirs by hand, on a fake clock: the skin steps
    /// `dt` towards `target` under `hand`, the window goes to `frame` when given, and the ring and the panel follow.
    func beginOutline(_ moment: LensSkin.Moment) { chrome.beginMoment(moment) }
    func stepOutline(_ dt: TimeInterval, toward target: NSRect, to frame: NSRect? = nil, hand: LensSkin.Hand = .none) {
        chrome.stepOutline(dt, toward: target, to: frame, hand: hand)
    }

    /// The ring's mask path as drawn (view coordinates, y up), for the checks.
    var ringPath: CGPath? { chrome.ringPath }
}

private final class FrameChromeView: NSView {
    weak var window_: RegionFrameWindow? { didSet { seat() } }
    var name: String { didSet { needsDisplay = true } }
    var detail = "" { didSet { needsDisplay = true } }
    var badge: String? { didSet { needsDisplay = true } }
    var busy = false { didSet { if busy != oldValue { updateGlow(); needsDisplay = true } } }
    var original = false { didSet { if original != oldValue { applyStyle(); sweep(); accessibilityChanged() } } }
    var following = false { didSet { if following != oldValue { needsDisplay = true; updateToolTip() } } }
    var style = LensStyle.glow { didSet { if style != oldValue { applyStyle() } } }
    var tint = LensTint.spectrum { didSet { if tint != oldValue { applyStyle() } } }
    var tabVisibility = LensTabVisibility.automatic { didSet { if tabVisibility != oldValue { needsDisplay = true; updateToolTip() } } }
    var tabPosition = LensTabPosition.topLeading {
        didSet { if tabPosition != oldValue { needsLayout = true; needsDisplay = true; updateToolTip() } }
    }
    private var accentObserver: NSObjectProtocol?
    /// Reduce Motion switched while the lens is reading: the breathing starts or stops at once.
    private var motionObserver: NSObjectProtocol?
    /// A short message that takes the place of the pill's second line.
    private var notice: String? { didSet { needsDisplay = true; if let notice, notice != oldValue { announce(notice) } } }
    private var noticeTimer: Timer?
    /// What the lens says about itself (`RegionFrameWindow.setHint`) in the second line's place, after any notice.
    private var hint: String? { didSet { needsDisplay = true; if hint != oldValue { accessibilityChanged() } } }
    private var hintActionable = false
    private var hintForcesTab = false
    /// Where the hint was last drawn (view coordinates), for clicks and the cursor; nil when it is not on the pill.
    private var hintHit: NSRect?
    /// The hint as the pill writes it: a hint to click ends in an arrow.
    private var hintLine: String? { hint.map { hintActionable ? $0 + " ›" : $0 } }

    private enum Drag { case move, resize }
    private var drag: Drag?
    private var startMouse: NSPoint = .zero
    private var startRegion: NSRect = .zero
    /// Follows a move the window server is doing, once per display frame.
    private var moveLink: CADisplayLink?
    private var followed: NSRect?
    /// ⌘ was down at the last frame of a move: a snap guide is taken down when it goes down, though the lens stands still.
    private var commandWasDown = false
    /// The press went down on the ring (not the pill, not the corner), and where releases without a move are counted for a double-click.
    private var ringDown = false
    private var taps = DoubleTap()
    /// A resize's right edge as the person last saw it (screen x), and the system's filter that decides when the alignment tick plays.
    private var shownRight: CGFloat = 0
    private let haptic = AlignmentHaptic()
    /// A fit, a growth or a settle under way (`animate`): its frames come from the display link, `elapsed` seconds of them so far.
    private struct Animation {
        let from: NSRect, to: NSRect
        var elapsed: TimeInterval
        let duration: TimeInterval
        let resizing: Bool
        let completion: (Bool) -> Void
    }
    private var animation: Animation?
    /// The membrane over the rigid frame (`LensSkin`, motion contract section 9), in the space of `regionFrame`. The frame is the window's and keeps its
    /// own springs; this is how the ring and the panel's clip bow around it. Stepped on the tick of whatever moves the lens, and put at rest by
    /// `seat` when nobody did.
    private var skin = LensSkin(frame: .zero)
    /// The display link of a hand's resize, an animation, a commit, and the skin settling after them; nil while the lens rests. A move has its own
    /// (`moveLink`), which steps the skin too.
    private var link: CADisplayLink?
    private var linkStamp: CFTimeInterval = 0
    /// The rest line of the moment under way has been written (`noteRest`).
    private var restNoted = true
    /// What the masks hold, so a tick that changes nothing (a move, with the bows off) does not draw them again.
    private var drawn: (outline: LensOutline, region: NSRect, corners: Bool)?
    /// Where the picker's click was, until the first frame the lens shows takes hold of it (`takeHold`).
    private var pendingHold: CGPoint?
    /// The pill comes in over `LensSkin.commitPillIn`: seconds of it left.
    private var introLeft: TimeInterval = 0
    private var emphasized = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    /// What a screen reader sees inside the lens group (`LensAccessElement`): kept, so its focus survives a query.
    private lazy var accessElements = Dictionary(uniqueKeysWithValues: LensAccessElement.Kind.allCases.map { ($0, LensAccessElement($0, in: self)) })

    private let band: CGFloat = 10         // grabbable width of the ring
    private let corner: CGFloat = 20       // resize handle size
    private let radius: CGFloat = 12

    // Ring: a conic gradient inside a stroke-shaped mask; the glow is a wider, blurred copy. Both hold still and are
    // rasterized, so the window server draws them once: a spinning gradient was redrawn every display frame and took
    // the window server from about 25 % to 90 % CPU, enough to make a dragged lens stutter. Reading shows as the glow
    // breathing, an opacity change the compositor does on the cached image.
    // The mask sits on the gradient, never on the rasterized container: a container that is both rasterized and masked
    // is drawn at full opacity whatever its `opacity` (macOS 27), and a mask beside the blur cuts the blur back to the
    // stroke's hard edge. Together they made the glow an opaque band that hid the ring (tools/lens-look/profile.py).
    private let ring = CALayer(), ringMask = CAShapeLayer(), ringGradient = CAGradientLayer()
    private let glow = CALayer(), glowMask = CAShapeLayer(), glowGradient = CAGradientLayer()
    private let sweepClip = CALayer(), sweepMask = CAShapeLayer(), sweepLayer = CAGradientLayer()

    /// Around the ring: the tint, or the greys for the faint style and while showing the original.
    private var ringColors: [CGColor] { (style == .minimal || original ? LensTint.mono : tint).colors.map(\.cgColor) }

    init(name: String) {
        self.name = name
        super.init(frame: .zero)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        for (container, mask, gradient) in [(glow, glowMask, glowGradient), (ring, ringMask, ringGradient)] {
            gradient.type = .conic
            gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
            gradient.endPoint = CGPoint(x: 0.5, y: 0)
            mask.fillColor = nil
            mask.strokeColor = NSColor.black.cgColor
            gradient.mask = mask
            container.shouldRasterize = true
            container.addSublayer(gradient)
            layer?.addSublayer(container)
        }
        glowMask.lineWidth = 4
        glow.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 6])!]
        sweepLayer.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.22).cgColor,
                             NSColor.white.withAlphaComponent(0).cgColor]
        sweepLayer.startPoint = CGPoint(x: 0, y: 0.5)
        sweepLayer.endPoint = CGPoint(x: 1, y: 0.5)
        sweepLayer.opacity = 0
        sweepClip.mask = sweepMask
        sweepClip.addSublayer(sweepLayer)
        layer?.addSublayer(sweepClip)
        // The accent tint follows the system accent colour.
        accentObserver = NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.tint == .accent { self?.applyStyle() } }
        }
        motionObserver = NotificationCenter.default.addObserver(forName: Motion.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.skin.reduceMotion = Motion.shared.reduced
                self?.updateGlow()
            }
        }
        applyStyle()
    }

    deinit {
        accentObserver.map(NotificationCenter.default.removeObserver)
        motionObserver.map(NotificationCenter.default.removeObserver)
        link?.invalidate()
    }

    private func applyStyle() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        for gradient in [ringGradient, glowGradient] { gradient.colors = ringColors }
        CATransaction.commit()
        ringMask.lineWidth = switch style {
        case .glow, .corners: 1.5
        case .subtle, .minimal: 1.0
        }
        for mask in [ringMask, glowMask] { mask.lineCap = style == .corners ? .round : .butt }
        drawn = nil
        needsLayout = true
        updateGlow()
        needsDisplay = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func setEmphasized(_ on: Bool) {
        guard on != emphasized else { return }
        emphasized = on
        updateGlow()
        needsDisplay = true
    }

    // MARK: - Geometry (view coordinates, y up)

    private var regionRect: NSRect {
        NSRect(x: RegionFrameWindow.margin, y: tabPosition.isBottom ? RegionFrameWindow.tabExtra : RegionFrameWindow.margin,
               width: bounds.width - 2 * RegionFrameWindow.margin,
               height: bounds.height - RegionFrameWindow.margin - RegionFrameWindow.tabExtra)
    }

    private var strong: Bool { emphasized || hovering || drag != nil }
    /// A notice always shows the tag; otherwise the setting decides (automatic: minimal lenses show it only under the pointer).
    private var showsTab: Bool {
        if strong || notice != nil || (hint != nil && hintForcesTab) { return true }
        switch tabVisibility {
        case .automatic: return style != .minimal
        case .always: return true
        case .onHover: return false
        }
    }

    private var tabRect: NSRect {
        let title = (name as NSString).size(withAttributes: [.font: Self.titleFont]).width
        let longest = [detail, notice ?? "", hintLine ?? ""].max { $0.count < $1.count } ?? ""
        let sub = longest.isEmpty ? 0 : (longest as NSString).size(withAttributes: [.font: Self.detailFont]).width + 10 + (badge == nil ? 0 : 14)
        let w = min(regionRect.width, title + sub + 40 + 20 + (strong ? 22 : 0))
        let width = max(72, w)
        return NSRect(x: tabPosition.isTrailing ? regionRect.maxX - width : regionRect.minX,
                      y: tabPosition.isBottom ? regionRect.minY - 6 - RegionFrameWindow.tabHeight : regionRect.maxY + 6,
                      width: width, height: RegionFrameWindow.tabHeight)
    }

    private var closeRect: NSRect {
        NSRect(x: tabRect.maxX - 23, y: tabRect.midY - 8, width: 16, height: 16)
    }

    /// The window / pin icon, left of the close button.
    private var modeRect: NSRect {
        NSRect(x: tabRect.maxX - (strong ? 44 : 25), y: tabRect.midY - 8, width: 18, height: 16)
    }

    /// What a click, the pointer, the tooltip and a screen reader treat as each button: 22 × 22 and 22 × 20 pt around the 16 × 16 and 18 × 16 pt
    /// glyphs, which `closeRect` and `modeRect` still draw (HIG, Accessibility: 20 × 20 pt at least; ui-audit-1-1-5 2.1). Both sit inside the
    /// 26 pt tab, and the title's room (`limit` in `draw`) already clears them.
    private var closeHit: NSRect {
        NSRect(x: tabRect.maxX - 26, y: tabRect.midY - 11, width: 22, height: 22)
    }

    private var modeHit: NSRect {
        NSRect(x: tabRect.maxX - (strong ? 48 : 26), y: tabRect.midY - 10, width: 22, height: 20)
    }

    private var resizeRect: NSRect {
        NSRect(x: regionRect.maxX - corner + band / 2, y: regionRect.minY - band / 2, width: corner, height: corner)
    }

    /// The hint's place on the pill while it is something to click.
    private var clickableHint: NSRect? { hintActionable && hint != nil && notice == nil && !original ? hintHit : nil }

    private func zone(at p: NSPoint) -> Drag? {
        if resizeRect.contains(p) { return .resize }
        if showsTab, tabRect.contains(p) { return .move }
        let outer = regionRect.insetBy(dx: -band / 2, dy: -band / 2), inner = regionRect.insetBy(dx: band / 2, dy: band / 2)
        return outer.contains(p) && !inner.contains(p) ? .move : nil
    }

    // MARK: - Layers

    override func layout() {
        super.layout()
        if let click = pendingHold {
            pendingHold = nil
            beginHold(at: click)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let diagonal = hypot(bounds.width, bounds.height)
        for (container, mask, gradient) in [(glow, glowMask, glowGradient), (ring, ringMask, ringGradient)] {
            container.frame = bounds
            // A square big enough to cover the ring, centred on the lens.
            gradient.bounds = CGRect(x: 0, y: 0, width: diagonal, height: diagonal)
            gradient.position = CGPoint(x: regionRect.midX, y: regionRect.midY)
            // The mask lives in the gradient's coordinates; this frame puts the path back in the view's.
            mask.frame = CGRect(origin: CGPoint(x: -gradient.frame.minX, y: -gradient.frame.minY), size: bounds.size)
            container.rasterizationScale = window?.backingScaleFactor ?? 2
        }
        drawOutline()
        sweepClip.frame = bounds
        sweepMask.frame = bounds
        sweepLayer.bounds = CGRect(x: 0, y: 0, width: regionRect.width * 0.6, height: regionRect.height)
        sweepLayer.position = CGPoint(x: regionRect.minX - regionRect.width, y: regionRect.midY)
        sweepMask.path = CGPath(roundedRect: regionRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }

    /// Four corner brackets: each a quarter arc of `radius` with a straight arm along both sides, min(18, a quarter of the
    /// side) long, kept clear of the neighbouring bracket on a small lens.
    private static func brackets(in r: NSRect, radius: CGFloat) -> CGPath {
        let arm = { (side: CGFloat) in max(0, min(18, side * 0.25, side / 2 - radius - 2)) }
        let ax = arm(r.width), ay = arm(r.height)
        let p = CGMutablePath()
        // Each corner, walked from the end of one arm to the end of the other (y up).
        p.move(to: CGPoint(x: r.minX, y: r.minY + radius + ay))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + radius, y: r.minY), radius: radius)
        p.addLine(to: CGPoint(x: r.minX + radius + ax, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - radius - ax, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + radius), radius: radius)
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + radius + ay))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - radius - ay))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.maxX - radius, y: r.maxY), radius: radius)
        p.addLine(to: CGPoint(x: r.maxX - radius - ax, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + radius + ax, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY - radius), radius: radius)
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - radius - ay))
        return p
    }

    // MARK: - Outline (LensSkin)

    /// The ring's outline now, relative to the region's bottom-left (y up). The corner brackets stay the rigid frame, and the panel's clip with them.
    func outline() -> LensOutline {
        let region = window_?.regionFrame ?? .zero
        return (style == .corners ? LensOutline.rigid(region) : skin.outline(around: region)).moved(by: CGVector(dx: -region.minX, dy: -region.minY))
    }

    var ringPath: CGPath? { ringMask.path }

    /// The ring and the glow take the outline when it is not what they hold already: a move changes nothing of it, so the window server draws
    /// the cached raster again; a resize, a fit and a commit change it every frame, as they changed the rounded rect's size.
    private func drawOutline() {
        let o = outline(), region = regionRect, corners = style == .corners
        guard drawn.map({ $0.outline != o || $0.region != region || $0.corners != corners }) ?? true else { return }
        drawn = (o, region, corners)
        let path = corners ? Self.brackets(in: region.insetBy(dx: -1, dy: -1), radius: radius)
            : o.moved(by: CGVector(dx: region.minX, dy: region.minY)).path(outset: 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ringMask.path = path
        glowMask.path = path
        CATransaction.commit()
    }

    /// The outline at rest on the window's region: nobody animated the lens there (it followed its window, changed display, came up).
    func seat() {
        guard let region = window_?.regionFrame else { return }
        skin = LensSkin(frame: region)
        skin.reduceMotion = Motion.shared.reduced
        restNoted = true
        drawOutline()
        window_?.onOutline?()
    }

    func beginMoment(_ moment: LensSkin.Moment) {
        // A moment the next one cuts short (a resize let go within a column's reach glides on as a drop) still says what it did.
        if !restNoted { Trace.mark(skin.meter.summary + " (cut by \(moment.rawValue))", since: Trace.now) }
        skin.begin(moment)
        restNoted = false
    }

    /// The skin steps `dt` towards `target` (where the frame is heading: the hand's frame, or an animation's end).
    private func stepSkin(_ dt: TimeInterval, toward target: NSRect, hand: LensSkin.Hand) {
        skin.step(dt, target: target, hand: hand)
        skin.land()   // at rest the outline is the rounded rect itself, and nothing ticks
        guard introLeft > 0 else { return }
        introLeft = max(0, introLeft - dt)
        setNeedsDisplay(tabRect.insetBy(dx: -16, dy: -16))
    }

    /// After the frame is where this frame puts it: the meter sees the outline, the ring and the panel take it.
    private func finishFrame() {
        skin.record(skin.outline(around: window_?.regionFrame ?? .zero))
        drawOutline()
        window_?.onOutline?()
        noteRest()
    }

    func stepOutline(_ dt: TimeInterval, toward target: NSRect, to frame: NSRect?, hand: LensSkin.Hand) {
        stepSkin(dt, toward: target, hand: hand)
        if let frame { window_?.driveRegion(frame) }
        finishFrame()
    }

    var meter: LensSkin.Meter { skin.meter }

    /// The pill's alpha while it comes in after a hold; 1 otherwise.
    var introAlpha: CGFloat { introLeft > 0 ? 1 - CGFloat(introLeft / LensSkin.commitPillIn) : 1 }

    /// Once per moment, when the outline has landed: `skin: fit peak=4.00 rest=344ms` (Trace prints only while `MWOYEO_TRACE` is set).
    private func noteRest() {
        guard !restNoted, skin.isAtRest, animation == nil, drag == nil, introLeft == 0 else { return }
        restNoted = true
        Trace.mark(skin.meter.summary, since: Trace.now)
    }

    func stats() -> String {
        "bows=" + outline().bows.map { String(format: "%.2f", Double($0)) }.joined(separator: ",") + " " + skin.meter.summary
    }

    // MARK: Driving it

    private func ensureLink() {
        guard link == nil, moveLink == nil else { return }
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        linkStamp = 0
    }

    /// The seconds since this link's last frame (the first frame: one display frame).
    private func frameDT(_ l: CADisplayLink) -> TimeInterval {
        let dt = linkStamp > 0 ? l.targetTimestamp - linkStamp : 0
        linkStamp = l.targetTimestamp
        return dt > 0 ? dt : l.duration
    }

    /// One display frame of whatever moves the lens and of the outline settling after it. The frame and the skin step on this one tick, so the ring,
    /// the clip and the window always come from one frame.
    @objc private func tick(_ l: CADisplayLink) {
        let dt = frameDT(l)
        if animation != nil {
            animationFrame(dt)
        } else {
            stepSkin(dt, toward: window_?.regionFrame ?? .zero, hand: drag == .resize ? .corner : .none)
        }
        finishFrame()
        guard animation == nil, drag == nil, introLeft == 0, skin.isAtRest else { return }
        l.invalidate()
        link = nil
    }

    /// The picker's click placed this lens (`RegionFrameWindow.takeHold`): the outline takes hold from the first frame the window shows.
    func takeHold(at click: CGPoint) {
        pendingHold = click
        needsLayout = true
    }

    private func beginHold(at click: CGPoint) {
        guard let region = window_?.regionFrame else { return }
        skin.commit(target: region, click: click)
        restNoted = false
        introLeft = LensSkin.commitPillIn
        let appear = CABasicAnimation(keyPath: "opacity")
        appear.fromValue = 0
        appear.duration = LensSkin.commitGlowIn
        glow.add(appear, forKey: "commitIn")
        ensureLink()
    }

    /// Calm at rest; brighter under the pointer, and breathing while reading or translating.
    /// Subtle glows only while reading; minimal never does.
    private func updateGlow() {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.35)
        switch style {
        case .glow:
            ring.opacity = busy || strong ? 1 : 0.8
            glow.opacity = busy ? 0.95 : strong ? 0.7 : 0.35
        case .subtle, .corners:
            ring.opacity = busy || strong ? 1 : 0.7
            glow.opacity = busy ? 0.7 : strong ? 0.3 : 0
        case .minimal:
            ring.opacity = strong ? 0.9 : busy ? 0.6 : 0.45
            glow.opacity = strong ? 0.25 : 0
        }
        CATransaction.commit()
        // Minimal has no glow: its ring breathes instead.
        let breathing = style == .minimal ? ring : glow
        for l in [ring, glow] where l !== breathing || !busy || original || Motion.shared.reduced { l.removeAnimation(forKey: "breathe") }
        // Reduce Motion: the busy glow stays at its brighter, steady level instead of breathing.
        if busy, !original, !Motion.shared.reduced {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = breathing.opacity * 0.45
            breathe.toValue = breathing.opacity
            breathe.duration = 0.9
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            breathe.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
            breathing.add(breathe, forKey: "breathe")
        }
        updateToolTip() // the icon shifts when the close button shows
    }

    func setHint(_ text: String?, actionable: Bool, forcesTab: Bool) {
        hintActionable = actionable
        hintForcesTab = forcesTab
        hint = text
    }

    func flash(_ text: String, seconds: TimeInterval) {
        notice = text
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.notice = nil }
    }

    func sweep() {
        guard !Motion.shared.reduced else { return }
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = regionRect.minX - regionRect.width / 2
        move.toValue = regionRect.maxX + regionRect.width / 2
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.8, 1]
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = 0.9
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweepLayer.add(group, forKey: "sweep")
    }

    // MARK: - Events

    private func updateToolTip() {
        removeAllToolTips()
        addToolTip(modeHit, owner: self, userData: nil)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .cursorUpdate], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }
    override func mouseMoved(with event: NSEvent) { updateCursor(convert(event.locationInWindow, from: nil)) }

    private func updateCursor(_ p: NSPoint) {
        if let hit = clickableHint, hit.contains(p) { return NSCursor.pointingHand.set() }
        switch zone(at: p) {
        case .resize?: NSCursor.frameResize(position: .bottomRight, directions: .all).set()
        case .move?: ((strong && closeHit.contains(p)) || (showsTab && modeHit.contains(p)) ? NSCursor.arrow : NSCursor.openHand).set()
        case nil: NSCursor.arrow.set()
        }
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; updateGlow(); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; updateGlow(); needsDisplay = true }

    override func rightMouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard showsTab, tabRect.contains(p), let menu = window_?.onContextMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if strong, closeHit.contains(p) { window_?.onClose?(); return }
        if showsTab, modeHit.contains(p) { window_?.onToggleFollowing?(); return }
        if let hit = clickableHint, hit.contains(p) { window_?.onHintAction?(); return }
        // A hand on the lens takes it from a fit or a settle that is moving it: it stays where it has got to.
        stopAnimating()
        drag = zone(at: p)
        ringDown = drag == .move && !(showsTab && tabRect.contains(p))
        Trace.mark("lens press: \(drag.map { "\($0)" } ?? "none") ring=\(ringDown) clicks=\(event.clickCount)", since: Trace.now)
        startMouse = NSEvent.mouseLocation
        startRegion = window_?.regionFrame ?? .zero
        shownRight = startRegion.maxX
        updateGlow()
        needsDisplay = true
        if drag == .resize {
            beginMoment(.cornerDrag)
            ensureLink()
        }
        guard drag == .move, let w = window_ else { return }
        // The window server moves the window, in step with the pointer however busy this app or the window server
        // is. Moving it here took a round trip to the window server per event: the lens fell behind and jumped.
        // `performDrag` returns at once and the mouse-up goes to the window server, so a display link follows the
        // move (the translations and the capture go where the lens is) and notices the button going up. That link
        // steps the skin too, with every edge held to the frame (the hand carries the lens: nothing bows).
        NSCursor.closedHand.set()
        w.performDrag(with: event)
        self.link?.invalidate()
        self.link = nil
        linkStamp = 0
        let link = displayLink(target: self, selector: #selector(followMove(_:)))
        link.add(to: .main, forMode: .common)
        moveLink = link
    }

    @objc private func followMove(_ l: CADisplayLink) {
        guard let w = window_ else { return }
        stepSkin(frameDT(l), toward: w.regionFrame, hand: .move)
        finishFrame()
        let m = NSEvent.mouseLocation
        let r = onScreen(startRegion.offsetBy(dx: m.x - startMouse.x, dy: m.y - startMouse.y))
        let command = NSEvent.modifierFlags.contains(.command)
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            moveLink?.invalidate()
            moveLink = nil
            // The window server lets a window go past the screen's sides: bring it back.
            if w.regionFrame != r { w.setRegion(r) }
            if (followed ?? startRegion) != r { w.onMove?(r) }
            followed = nil
            let pointer = convert(w.mouseLocationOutsideOfEventStream, from: nil)
            // A release on the ring where the press went down is a click; two in the double-click interval are Fit to Column.
            let travelled = hypot(m.x - startMouse.x, m.y - startMouse.y)
            Trace.mark("lens release: moved \(travelled) pt, ring=\(ringDown)", since: Trace.now)
            if travelled < DoubleTap.slop, ringDown {
                if taps.tap(at: m, time: ProcessInfo.processInfo.systemUptime, interval: NSEvent.doubleClickInterval) {
                    Trace.mark("lens double-click on the ring: fit", since: Trace.now)
                    finishDrag(at: pointer)
                    w.onFit?()
                    return
                }
            } else {
                taps.reset()
            }
            // A lens let go on a column's edge settles on it.
            if let settled = w.onSettle?(r), settled != r {
                animate(to: settled, duration: LensMotion.settle, moment: .drop) { [weak self] _ in self?.finishDrag(at: pointer) }
                return
            }
            finishDrag(at: pointer)
            return
        }
        // A press on the ring that goes nowhere is a click, not a move: the session hears of a frame only when the lens has moved (or ⌘ went up or down).
        if (followed ?? startRegion) != r || command != commandWasDown { followed = r; commandWasDown = command; w.onMove?(r) }
    }

    /// Keeps the lens on the screen it started on: the capture cannot span displays.
    private func onScreen(_ region: NSRect) -> NSRect {
        var r = region
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: startRegion.midX, y: startRegion.midY)) }) {
            let f = screen.frame
            r.origin.x = min(max(r.minX, f.minX), f.maxX - r.width)
            r.origin.y = min(max(r.minY, f.minY), f.maxY - r.height)
        }
        return r
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag == .resize, let w = window_ else { return }
        haptic.update(with: event)
        let m = NSEvent.mouseLocation
        let dx = m.x - startMouse.x, dy = m.y - startMouse.y
        // Bottom-right corner: the top-left stays put (in AppKit, top = maxY).
        let width = max(80, startRegion.width + dx), height = max(40, startRegion.height - dy)
        let wanted = NSRect(x: startRegion.minX, y: startRegion.maxY - height, width: width, height: height)
        // The right edge pulls to a column's edge (the session decides; ⌘ held, it does not).
        let r = w.onSnapResize?(wanted) ?? wanted
        haptic.resized(in: self, previousX: shownRight - w.frame.minX, alignedX: r.maxX - w.frame.minX, defaultX: wanted.maxX - w.frame.minX)
        shownRight = r.maxX
        w.driveRegion(r)
        w.onResize?(r)
    }

    override func mouseUp(with event: NSEvent) {
        guard drag == .resize else { return }
        let pointer = convert(event.locationInWindow, from: nil)
        // A resize let go within a column's reach settles the rest of the way onto its edge, as a move does.
        if let w = window_, let settled = w.onSettleResize?(w.regionFrame), settled != w.regionFrame {
            animate(to: settled, duration: LensMotion.settle, moment: .drop) { [weak self] _ in self?.finishDrag(at: pointer) }
            return
        }
        finishDrag(at: pointer)
    }

    private func finishDrag(at p: NSPoint) {
        drag = nil
        updateCursor(p)
        updateGlow()
        needsDisplay = true
        window_?.onCommit?()
        // The outline goes on settling after the hand lets go.
        if !skin.isAtRest { ensureLink() }
    }

    // MARK: - Animation (a fit, a growth, a settle)

    var isAnimating: Bool { animation != nil }

    func animate(to target: NSRect, duration: TimeInterval, moment: LensSkin.Moment, completion: @escaping (Bool) -> Void) {
        stopAnimating()
        guard let w = window_ else { return completion(false) }
        let from = w.regionFrame
        // Reduce Motion, or nowhere to go: the lens is there in one frame, and its outline at rest on it.
        guard !Motion.shared.reduced, from != target else {
            place(target, resizing: target.size != from.size)
            seat()
            return completion(true)
        }
        beginMoment(moment)
        animation = Animation(from: from, to: target, elapsed: 0, duration: duration, resizing: target.size != from.size, completion: completion)
        ensureLink()
    }

    func stopAnimating() { finishAnimation(finished: false) }

    /// One frame: the skin steps towards the end, then the window goes where the spring has it (the outline reads that frame).
    private func animationFrame(_ dt: TimeInterval) {
        guard var a = animation else { return }
        a.elapsed += dt
        animation = a
        stepSkin(dt, toward: a.to, hand: .none)
        guard a.elapsed < a.duration else { return finishAnimation(finished: true) }
        place(FitMotion.frame(from: a.from, to: a.to, progress: FitMotion.progress(a.elapsed, duration: a.duration)), resizing: a.resizing)
    }

    /// The last frame is the target itself; a cut-short animation leaves the lens where it is. The outline goes on settling either way.
    private func finishAnimation(finished: Bool) {
        guard let a = animation else { return }
        animation = nil
        if finished { place(a.to, resizing: a.resizing) }
        a.completion(finished)
    }

    /// One frame of an animation: the window, then the session as a drag tells it.
    private func place(_ r: NSRect, resizing: Bool) {
        guard let w = window_ else { return }
        w.driveRegion(r)
        if resizing { w.onResize?(r) } else { w.onMove?(r) }
    }

    // MARK: - Drawing (pill, handles)

    private static let titleFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let detailFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        let r = regionRect
        // An almost invisible band makes the ring grabbable; the interior stays alpha 0 (click-through).
        let bandPath = NSBezierPath(roundedRect: r.insetBy(dx: -band / 2, dy: -band / 2), xRadius: radius + 4, yRadius: radius + 4)
        bandPath.append(NSBezierPath(roundedRect: r.insetBy(dx: band / 2, dy: band / 2), xRadius: radius - 4, yRadius: radius - 4).reversed)
        NSColor.black.withAlphaComponent(0.004).setFill()
        bandPath.fill()

        guard showsTab else { return }
        // A lens just placed brings the pill in over `LensSkin.commitPillIn`, the whole of it at one alpha.
        let alpha = introAlpha
        let ctx = NSGraphicsContext.current?.cgContext
        if alpha < 1 {
            ctx?.setAlpha(alpha)
            ctx?.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer { if alpha < 1 { ctx?.endTransparencyLayer() } }
        // Name pill: dark glass with a gradient dot that pulses while busy.
        let tab = tabRect
        let pill = NSBezierPath(roundedRect: tab, xRadius: tab.height / 2, yRadius: tab.height / 2)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor(white: 0.08, alpha: strong ? 0.88 : 0.72).setFill()
        pill.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.14).setStroke()
        pill.lineWidth = 0.5
        pill.stroke()

        let dot = NSRect(x: tab.minX + 11, y: tab.midY - 4.5, width: 9, height: 9)
        NSGradient(colors: Array((original ? LensTint.mono : tint).colors.prefix(4)))?
            .draw(in: NSBezierPath(ovalIn: dot), angle: busy ? 90 : -45)

        hintHit = nil
        var x = dot.maxX + 8
        let title = NSAttributedString(string: name, attributes: [.font: Self.titleFont, .foregroundColor: NSColor.white])
        let limit = tab.maxX - x - (strong ? 48 : 30)
        title.draw(with: NSRect(x: x, y: tab.midY - title.size().height / 2 + 1, width: limit, height: title.size().height),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        x += title.size().width + 10
        // A notice and the original's label are the pill's own words; the hint stands where the languages would.
        let hinted = notice == nil && !original ? hint : nil
        if original || !detail.isEmpty || notice != nil || hinted != nil, x < tab.maxX - 50 {
            let line = notice ?? (original ? String(localized: "Original") : hinted != nil ? hintLine ?? detail : detail)
            let sub = NSAttributedString(string: line, attributes: [.font: Self.detailFont,
                                                                    .foregroundColor: NSColor.white.withAlphaComponent(hinted == nil ? 0.6 : hintActionable ? 0.95 : 0.8)])
            // An added engine's mark: a cloud for a remote one, a Mac for one on this Mac.
            if let badge, notice == nil, !original, hinted == nil,
               let icon = NSImage(systemSymbolName: badge, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) {
                let s = icon.size
                icon.tinted(.white.withAlphaComponent(0.6))
                    .draw(in: NSRect(x: x, y: tab.midY - s.height / 2 + 1, width: s.width, height: s.height))
                x += s.width + 4
            }
            let room = tab.maxX - x - (strong ? 48 : 30)
            sub.draw(with: NSRect(x: x, y: tab.midY - sub.size().height / 2 + 1, width: room, height: sub.size().height),
                     options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            if hinted != nil { hintHit = NSRect(x: x - 4, y: tab.minY, width: min(sub.size().width, room) + 8, height: tab.height) }
        }

        if let icon = NSImage(systemSymbolName: following ? "macwindow" : "pin.fill", accessibilityDescription: modeHelp)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) {
            let m = modeRect, s = icon.size
            icon.tinted(.white.withAlphaComponent(strong ? 0.9 : 0.6))
                .draw(in: NSRect(x: m.midX - s.width / 2, y: m.midY - s.height / 2, width: s.width, height: s.height))
        }

        guard strong else { return }
        if let xmark = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Close"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) {
            xmark.tinted(.white.withAlphaComponent(0.8)).draw(in: closeRect)
        }

        // Resize grip: two short diagonal strokes in the corner.
        let g = NSBezierPath()
        let c = NSPoint(x: r.maxX - 4, y: r.minY + 4)
        for d in [CGFloat(7), 12] {
            g.move(to: NSPoint(x: c.x - d, y: c.y))
            g.line(to: NSPoint(x: c.x, y: c.y + d))
        }
        g.lineWidth = 2
        g.lineCapStyle = .round
        NSColor.white.withAlphaComponent(0.9).setStroke()
        g.stroke()
    }
}

// MARK: - Accessibility

/// A screen reader sees the lens as one group: "Translation lens", what it is doing in words (and the start of what it translated),
/// with the name pill's buttons and the translation inside it, and the lens's actions beside them (show the original, pause, close,
/// the menu). Everything is answered when asked: nothing runs while no screen reader is attached. The look is not touched.
extension FrameChromeView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { String(localized: "Translation lens") }
    override func accessibilityValue() -> Any? { accessibilityStateText() }
    /// Which lens, and the pair: "Safari, English → Korean".
    override func accessibilityHelp() -> String? { [name, detail].filter { !$0.isEmpty }.joined(separator: ", ") }

    override func accessibilityChildren() -> [Any]? {
        LensAccessElement.Kind.allCases.filter(accessHas).compactMap { accessElements[$0] }
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        let w = window_
        var actions = [
            NSAccessibilityCustomAction(name: original ? String(localized: "Show Translation") : String(localized: "Show Original")) {
                w?.onToggleOriginal?(); return w?.onToggleOriginal != nil
            },
            NSAccessibilityCustomAction(name: String(localized: "Pause all")) { w?.onPause?(); return w?.onPause != nil },
            NSAccessibilityCustomAction(name: String(localized: "Remove Lens")) { w?.onClose?(); return w?.onClose != nil },
            NSAccessibilityCustomAction(name: String(localized: "Open Lens Menu")) { [weak self] in self?.accessibilityOpenMenu() ?? false },
        ]
        // Fit to Column (or its undo), where the lens has a session to ask: the double-click's equivalent for a screen reader.
        if w?.onFit != nil {
            actions.insert(NSAccessibilityCustomAction(name: w?.fitTitle?() ?? String(localized: "Fit to Column")) { w?.onFit?(); return true }, at: 1)
        }
        return actions
    }

    /// The lens's translations in reading order, as the session has them now.
    fileprivate var accessibilityLines: [String] { window_?.translationLines?() ?? [] }

    /// The group's value: the state in words (the pill's order, `LensAccessState`), and after "Translated" the first 200 characters of it.
    func accessibilityStateText() -> String {
        let lines = accessibilityLines
        switch LensAccessState(notice: notice, original: original, hint: hintLine, busy: busy, translated: !lines.isEmpty) {
        case let .notice(text), let .hint(text): return text
        case .showingOriginal: return String(localized: "Showing original")
        case .reading: return String(localized: "Reading")
        case .waiting: return String(localized: "Waiting for text")
        case .translated:
            let excerpt = LensAccessSummary.excerpt(lines)
            return excerpt.isEmpty ? String(localized: "Translated") : "\(String(localized: "Translated")): \(excerpt)"
        }
    }

    /// The menu of the pill's right-click, from the actions: opened after this call returns, since its tracking would hold the answer.
    fileprivate func accessibilityOpenMenu() -> Bool {
        guard let menu = window_?.onContextMenu?() else { return false }
        let at = NSPoint(x: tabRect.minX, y: tabRect.minY)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            menu.popUp(positioning: nil, at: at, in: self)
        }
        return true
    }

    /// The state changed in a way worth a word from a screen reader focused on the lens.
    fileprivate func accessibilityChanged() { NSAccessibility.post(element: self, notification: .valueChanged) }

    /// A notice is said once, whatever has the focus.
    fileprivate func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    // The children: the translation, and the pill's buttons while the pill is there.

    fileprivate func accessHas(_ kind: LensAccessElement.Kind) -> Bool {
        switch kind {
        case .translation: !accessibilityLines.isEmpty
        case .mode, .close: showsTab
        case .hint: hintActionable && hint != nil && notice == nil && !original && showsTab
        }
    }

    fileprivate func accessLabel(_ kind: LensAccessElement.Kind) -> String {
        switch kind {
        case .translation: String(localized: "Translation")
        case .mode: modeHelp
        case .close: String(localized: "Close")
        case .hint: hintLine ?? ""
        }
    }

    fileprivate func accessValue(_ kind: LensAccessElement.Kind) -> String? {
        kind == .translation ? accessibilityLines.joined(separator: "\n") : nil
    }

    fileprivate func accessFrame(_ kind: LensAccessElement.Kind) -> NSRect {
        let r: NSRect = switch kind {
        case .translation: regionRect
        case .mode: modeHit
        case .close: closeHit
        case .hint: hintHit ?? tabRect
        }
        guard let w = window else { return .zero }
        return w.convertToScreen(convert(r, to: nil))
    }

    fileprivate func accessPress(_ kind: LensAccessElement.Kind) -> Bool {
        switch kind {
        case .translation: return false
        case .mode: window_?.onToggleFollowing?()
        case .close: window_?.onClose?()
        case .hint: window_?.onHintAction?()
        }
        return true
    }
}

/// One thing inside the lens group: the translated text, or a button of the name pill. It holds no state of its own: the lens answers.
private final class LensAccessElement: NSAccessibilityElement {
    enum Kind: CaseIterable { case translation, mode, close, hint }
    let kind: Kind
    private weak var lens: FrameChromeView?

    init(_ kind: Kind, in lens: FrameChromeView) {
        self.kind = kind
        self.lens = lens
        super.init()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityParent() -> Any? { lens }
    override func accessibilityRole() -> NSAccessibility.Role? { kind == .translation ? .staticText : .button }
    override func accessibilityLabel() -> String? { lens?.accessLabel(kind) }
    override func accessibilityValue() -> Any? { lens?.accessValue(kind) }
    override func accessibilityFrame() -> NSRect { lens?.accessFrame(kind) ?? .zero }
    override func accessibilityPerformPress() -> Bool { lens?.accessPress(kind) ?? false }
}

extension FrameChromeView: NSViewToolTipOwner {
    fileprivate var modeHelp: String {
        following ? String(localized: "Follows this window. Click to pin the lens to the screen.")
            : String(localized: "Pinned to the screen. Click to follow the window underneath.")
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        modeHelp
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
