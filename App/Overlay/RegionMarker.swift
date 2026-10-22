import AppKit
import MwoyeoCore

/// Chooser for a part of a lens that is not to be read (a HUD, a name tag, a timer): the screen dims except the lens, a drag inside the lens
/// marks the part, and the part is the answer (global Quartz points). Esc, or a right click, leaves without one.
///
/// Without a pointer: an arrow key (or Return) shows a small region in the middle of the lens, the arrow keys move it, ⇧ + arrow resizes
/// it, ⌥ makes a step 1 point instead of 10, Return places it and Esc leaves (`PlacementInput`, as the lens picker). The keys are the
/// marker's only while it is up: a monitor of this app's own events, installed when it opens and removed when it closes.
///
/// Focus: the app is activated and the window on the lens's screen is key; however the marker ends (a drag, a key, Esc, a right click) the app
/// that was in front gets its focus back: the person goes on in it (a game, with a lens over it), and a first click that only activated it
/// would be lost.
@MainActor
final class RegionMarker {
    private var window: MarkerWindow?
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    /// The system, as the marker asks it: the app in front, and an app given its focus. A check puts others in their place.
    var frontmost: () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }
    var refocus: (NSRunningApplication) -> Void = { app in
        NSApp.yieldActivation(to: app)
        app.activate()
    }

    /// A part of `lens` (global Quartz points) chosen by the person, or nil. `existing`: the parts already ignored, drawn so a new one can be
    /// placed against them.
    func mark(in lens: CGRect, existing: [CGRect]) async -> CGRect? {
        guard continuation == nil, let screen = ScreenGeometry.screen(for: lens) else { return nil }
        previousApp = frontmost()
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { cont in
            continuation = cont
            let w = MarkerWindow(screen: screen, lens: lens, existing: existing) { [weak self] result in self?.finish(result) }
            window = w
            w.orderFrontRegardless()
            w.makeKey()
            if let view = w.contentView as? MarkerView {
                w.makeFirstResponder(view)
                if NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled { view.handle(.engage) }
            }
            NSCursor.crosshair.push()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let input = PlacementInput(e) else { return e }
                if input == .cancel { self.finish(nil); return nil }
                let handled = (self.window?.contentView as? MarkerView)?.handle(input) == true
                return handled ? nil : e
            }
        }
    }

    /// The marker is up (the checks look; nothing else asks).
    var isUp: Bool { continuation != nil }

    /// The view the marker shows, for the checks.
    var view: NSView? { window?.contentView }

    private func finish(_ result: CGRect?) {
        guard let cont = continuation else { return }
        continuation = nil
        NSCursor.pop()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        window?.orderOut(nil)
        window = nil
        if let app = previousApp, app != NSRunningApplication.current { refocus(app) }
        previousApp = nil
        cont.resume(returning: result)
    }
}

private final class MarkerWindow: NSWindow {
    init(screen: NSScreen, lens: CGRect, existing: [CGRect], done: @escaping (CGRect?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = MarkerView(screen: screen, lens: lens, existing: existing, done: done)
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }
    override func accessibilityTitle() -> String? { String(localized: "Ignore a region") }
}

final class MarkerView: NSView {
    private let screenFrame: NSRect
    private let lens: NSRect
    private let existing: [NSRect]
    private let done: (CGRect?) -> Void
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    /// The region being placed with the keyboard (view coordinates); nil until a key shows it, and again once the pointer takes over.
    private(set) var placement: KeyboardLens?

    /// A region placed with the keyboard starts this size, in the middle of the lens, and may shrink to the smallest the lens takes.
    private static let startSize = CGSize(width: 120, height: 48)
    private static let smallest = CGSize(width: IgnoredRegions.minimumSide, height: IgnoredRegions.minimumSide)

    init(screen: NSScreen, lens: CGRect, existing: [CGRect], done: @escaping (CGRect?) -> Void) {
        screenFrame = screen.frame
        self.done = done
        func local(_ q: CGRect) -> NSRect { ScreenGeometry.appKitRect(fromQuartz: q).offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
        self.lens = local(lens)
        self.existing = existing.map(local)
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func quartz(_ local: NSRect) -> CGRect {
        ScreenGeometry.quartzRect(fromAppKit: local.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY))
    }

    private var selection: NSRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(lens)
    }

    // MARK: - Events

    override func mouseDown(with event: NSEvent) {
        placement = nil   // the pointer takes over
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragCurrent = nil; needsDisplay = true }
        guard let sel = selection, sel.width >= IgnoredRegions.minimumSide, sel.height >= IgnoredRegions.minimumSide else { return }
        done(quartz(sel))
    }

    override func rightMouseDown(with event: NSEvent) { done(nil) }

    // MARK: - Keyboard

    /// A key of the placement (`PlacementInput`). The first arrow or Return shows a region in the middle of the lens; after that the arrows move
    /// it and Return places it. Returns whether the marker took the key.
    @discardableResult
    func handle(_ input: PlacementInput) -> Bool {
        switch input {
        case .engage:
            guard placement == nil else { return true }
            placement = KeyboardLens(bounds: lens, size: Self.startSize, minimum: Self.smallest)
            announce(String(localized: "Region in the middle of the lens. Arrow keys move it, Shift resizes, Return places it, Escape cancels."))
        case let .move(key, resize, fine):
            guard placement != nil else { return handle(.engage) }
            if placement?.press(key, resize: resize, fine: fine) == true {
                NSAccessibility.post(element: self, notification: .valueChanged)
            } else {
                NSSound.beep()
            }
        case .confirm:
            guard let region = placement?.rect else { return handle(.engage) }
            announce(String(localized: "Region ignored"))
            done(quartz(region))
        case .cancel:
            done(nil)
        }
        needsDisplay = true
        return true
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { String(localized: "Ignore a region") }
    override func accessibilityHelp() -> String? { String(localized: "Drag over a part of the lens  ·  esc to cancel") }
    override func accessibilityValue() -> Any? {
        guard let r = placement?.rect else { return String(localized: "Or press an arrow key to place it with the keyboard") }
        return String(localized: "\(Int(r.width)) by \(Int(r.height)) points, \(Int(r.minX - lens.minX)) from the left of the lens, \(Int(lens.maxY - r.maxY)) from the top")
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.32).setFill()
        bounds.fill()
        NSGraphicsContext.current?.compositingOperation = .copy
        NSColor.clear.setFill()
        NSBezierPath(roundedRect: lens, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver
        let accent = NSColor.controlAccentColor
        for r in existing { outline(r, color: accent.withAlphaComponent(0.6), fill: accent.withAlphaComponent(0.12)) }
        if let r = selection ?? placement?.rect { outline(r, color: .white, fill: accent.withAlphaComponent(0.25), width: 2) }
        hintPill(String(localized: "Drag over what the lens should not read  ·  esc to cancel"), y: bounds.maxY - 120)
        if placement != nil {
            hintPill(String(localized: "Arrow keys move  ·  ⇧ resizes  ·  ⌥ steps 1 pt  ·  ↩ places  ·  esc cancels"), y: bounds.maxY - 164)
        }
    }

    private func outline(_ r: NSRect, color: NSColor, fill: NSColor, width: CGFloat = 1) {
        let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
        fill.setFill()
        p.fill()
        color.setStroke()
        p.lineWidth = width
        p.stroke()
    }

    private func hintPill(_ text: String, y: CGFloat) {
        guard screenFrame.contains(NSEvent.mouseLocation) || NSScreen.screens.count == 1 else { return }
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ])
        let size = s.size()
        let pill = NSRect(x: bounds.midX - (size.width + 32) / 2, y: y, width: size.width + 32, height: size.height + 16)
        NSColor(white: 0.12, alpha: 0.88).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        s.draw(at: NSPoint(x: pill.minX + 16, y: pill.minY + 8))
    }
}
