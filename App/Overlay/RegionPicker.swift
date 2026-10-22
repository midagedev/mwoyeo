import AppKit
import MwoyeoCore
import NaturalLanguage

/// Full-screen chooser: point at a paragraph and click, or drag an area. A lens that lands in a window follows it; holding ⌥ pins it to the
/// screen instead. A lens never defaults to a whole window: the bigger the area, the slower every read. Esc cancels.
///
/// One click (docs/design/first-lens.md, round oneclick117): when the picker opens, one read of the display under the pointer (`PickerMap`)
/// finds its text columns, and the spotlight under the pointer becomes the lens a click places: the column's width by whole paragraphs, from
/// the paragraph under the pointer (`LensTarget`). Where there is no column (chat, games, subtitles, code, a margin), and until the map is
/// there, the spotlight is the default lens centred on the pointer, as it always was. A click never waits for the map.
///
/// Without a pointer: an arrow key (or Return) puts a lens of the default size in the middle of the screen, and from then on the
/// arrow keys move it, ⇧ + arrow resizes it, ⌥ makes a step 1 point instead of 10, Return places it (⌥↩ pins it to the screen)
/// and Esc leaves. With the pointer over a column's target, Return places that target, as a click would. The keys are the picker's only
/// while it is up: they are read by a monitor of this app's own events, installed when the picker opens and removed when it closes, so no
/// key is taken from anything else, and a handled key goes no further. With VoiceOver or Switch Control on, the lens is there from the start.
///
/// Focus: the picker activates the app and makes the window on the pointer's screen key, with its view first responder. A finish by
/// key (Return, Esc) gives the app that was in front back its focus; a finish by pointer leaves things as they were.
@MainActor
final class RegionPicker {
    struct Result {
        /// Global Quartz points.
        var rect: CGRect
        /// The window to follow: the one the lens landed in, unless ⌥ pinned it to the screen.
        var window: WindowInfo?
    }

    /// What the picker did since launch, for the checks and the trace (`picker.*` counts carry the same).
    struct Stats: Equatable {
        var opens = 0, reads = 0, cancelled = 0, maps = 0, empty = 0, clickTarget = 0, clickGhost = 0
    }
    static var stats = Stats()

    /// Reads one display's map (`PickerMap.live`, set by the app); nil: no map, the spotlight is always the default lens.
    var readMap: PickerMap.Reader?

    private var windows: [PickerWindow] = []
    private var continuation: CheckedContinuation<Result?, Never>?
    private var keyMonitor: Any?
    /// The app that was in front when the picker opened, to hand its focus back after a finish by key.
    private var previousApp: NSRunningApplication?
    private var finishedByKey = false

    func pick() async -> Result? {
        let snapshot = WindowInfo.onScreen()
        previousApp = NSWorkspace.shared.frontmostApplication
        finishedByKey = false
        NSApp.activate(ignoringOtherApps: true)
        Self.stats.opens += 1
        return await withCheckedContinuation { cont in
            continuation = cont
            for screen in NSScreen.screens {
                let w = PickerWindow(screen: screen, windows: snapshot, readMap: readMap) { [weak self] result in self?.finish(result) }
                w.orderFrontRegardless()
                w.fade(in: true)
                windows.append(w)
            }
            let mouse = NSEvent.mouseLocation
            let key = windows.first { $0.frame.contains(mouse) } ?? windows.first
            key?.makeKey()
            if let view = key?.contentView as? PickerView {
                key?.makeFirstResponder(view)
                // The display under the pointer is read at once; another display's when the pointer first comes to it.
                view.startMap()
                let assisted = NSWorkspace.shared.isVoiceOverEnabled || NSWorkspace.shared.isSwitchControlEnabled
                if assisted { view.handle(.engage) }
            }
            NSCursor.crosshair.push()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] e in
                if e.type == .flagsChanged { self?.windows.forEach { ($0.contentView as? PickerView)?.refresh() } } // ⌥ flips the label
                guard e.type == .keyDown, let self, let input = PlacementInput(e) else { return e }
                // A key that finishes hands the focus back (`finish`); one that only moves the lens, or shows it, does not.
                if input == .cancel || input == .confirm { self.finishedByKey = true }
                if input == .cancel { self.finish(nil); return nil }
                let view = (NSApp.keyWindow as? PickerWindow ?? self.windows.first)?.contentView as? PickerView
                let handled = view?.handle(input) == true
                if self.continuation != nil { self.finishedByKey = false }
                return handled ? nil : e
            }
        }
    }

    private func finish(_ result: Result?) {
        guard let cont = continuation else { return }
        continuation = nil
        NSCursor.pop()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        // The maps go with the picker (a read under way is cancelled); the dim fades out while the lens comes in (motion contract 3.5).
        windows.forEach { ($0.contentView as? PickerView)?.close(); $0.fade(in: false) }
        windows = []
        // The keyboard moved the focus here, so the keyboard gives it back: the app underneath takes the next keys.
        if finishedByKey, let app = previousApp, app != NSRunningApplication.current {
            NSApp.yieldActivation(to: app)
            app.activate()
        }
        previousApp = nil
        cont.resume(returning: result)
    }
}

/// The picker's map of one display: its columns, read once, the first time the pointer is on the display while the picker is up, and dropped
/// with the picker (docs/design/first-lens.md 4.4). Nothing of the picture is kept: the read returns only the map.
enum PickerMap {
    /// The columns of the display whose frame (global Quartz points) it is given; nil when there are none to be had (no reader, no
    /// permission, no answer within its patience).
    typealias Reader = @Sendable (_ display: CGRect) async -> LensTarget.Map?

    case idle
    case reading(Task<Void, Never>)
    case ready(LensTarget.Map)
    /// The read gave nothing: the spotlight stays the default lens.
    case none
    /// The picker has closed: a read that ends now is dropped.
    case closed

    /// The app's reader: one picture of the display without this app's windows (`RegionCapturer.snapshot`), its blocks on the lines path
    /// (the host schedules it as `.picker`: after a running lens, before an image window and warm-up), their columns. The language most of the
    /// text is in goes to `warm` when the source is detected (`detects`; the translator warms that pair before the first lens asks), unless it
    /// is `target` already.
    static func live(languages: [Locale.Language], target: String, detects: Bool, patience: Duration = .seconds(4),
                     warm: @escaping @Sendable (String) async -> Void) -> Reader {
        { display in
            let t = Trace.now
            let outcome = await withDeadline(patience) { () async throws -> (LensTarget.Map, String?) in
                let (image, scale) = try await RegionCapturer.snapshot(of: display)
                return try await read(image, scale: scale, display: display, languages: languages)
            }
            guard case let .value((map, language)) = outcome else {
                Trace.mark("picker: no map (\(outcome))", since: t)
                return nil
            }
            if Trace.enabled {
                let columns = map.columns.filter { $0.width >= LensTarget.minWidth }.map { c in
                    "[\(TraceNumber.px(c.left))..\(TraceNumber.px(c.right)) \(TraceNumber.px(c.members.first?.core.minY ?? 0))..\(TraceNumber.px(c.members.map(\.core.maxY).max() ?? 0))]"
                }
                Trace.mark("picker: map n=\(map.blocks) columns=\(map.readingColumns) \(columns.joined(separator: " ")) language=\(language ?? "und") read=\(Int((Trace.now - t) * 1000)) ms", since: t)
            }
            if detects, let language, language != target { Task.detached(priority: .utility) { await warm(language) } }
            return map
        }
    }

    /// The map of `image`, a picture of `display` (global Quartz points) at `scale`: its blocks on the lines path, read as the host's `.picker`,
    /// in global points; and the language most of their text is in.
    static func read(_ image: CGImage, scale: CGFloat, display: CGRect, languages: [Locale.Language]) async throws -> (LensTarget.Map, String?) {
        let plan = ReaderPlan()
        plan.configure(setting: .lineGrouping, context: ReaderContext())
        let found = try await TextRecognizer.blocks(in: image, languages: languages, plan: plan, purpose: .picker)
        let blocks = found.map { b in
            ColumnFit.Block(core: CGRect(x: display.minX + b.rect.minX / scale, y: display.minY + b.rect.minY / scale,
                                         width: b.rect.width / scale, height: b.rect.height / scale), lines: b.lines.count)
        }
        return (LensTarget.Map(blocks: blocks), language(of: found.map(\.text)))
    }

    /// The language most of `texts` is in, when the recognizer is sure of it (the same codes as `TranslationService.sourceLanguage`).
    nonisolated static func language(of texts: [String]) -> String? {
        let r = NLLanguageRecognizer()
        r.languageConstraints = Languages.sources.filter { $0 != "auto" }.map { NLLanguage($0) }
        r.processString(String(texts.joined(separator: "\n").prefix(4000)))
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first, p >= 0.75 else { return nil }
        return switch lang {
        case .simplifiedChinese: "zh-Hans"
        case .traditionalChinese: "zh-Hant"
        default: lang.rawValue
        }
    }
}

/// What a key means to the picker. `engage` puts the default lens on the screen (a first arrow or Return, or VoiceOver being on).
enum PlacementInput: Equatable {
    case engage
    case move(KeyboardLens.Key, resize: Bool, fine: Bool)
    case confirm
    case cancel

    /// Return, Esc and the arrows with at most ⇧ and ⌥ held; anything else (a ⌘ or ⌃ combination, a letter) is not the picker's.
    /// What an arrow means before the lens is there is decided by the view (`PickerView.handle`).
    init?(_ event: NSEvent) {
        // Esc leaves whatever is held with it.
        if event.keyCode == 53 { self = .cancel; return }
        let held = event.modifierFlags.intersection([.shift, .option, .command, .control])
        guard held.isSubset(of: [.shift, .option]) else { return nil }
        let key: KeyboardLens.Key? = switch Int(event.keyCode) {
        case 123: .left
        case 124: .right
        case 125: .down
        case 126: .up
        default: nil
        }
        if let key {
            self = .move(key, resize: held.contains(.shift), fine: held.contains(.option))
        } else if event.keyCode == 36 || event.keyCode == 76 {
            // A held key repeats: Return placing or engaging is for a press of its own.
            guard !event.isARepeat else { return nil }
            self = .confirm
        } else {
            return nil
        }
    }
}

private final class PickerWindow: NSWindow {
    init(screen: NSScreen, windows: [WindowInfo], readMap: PickerMap.Reader?, done: @escaping (RegionPicker.Result?) -> Void) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PickerView(screen: screen, windows: windows, readMap: readMap, done: done)
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { true }

    /// What a screen reader's window list calls it.
    override func accessibilityTitle() -> String? { String(localized: "Place a lens") }

    /// In: the dim, the spotlight and the label come up together, 0.15 s linear. Out (a lens placed, or none): the dim goes, 0.20 s
    /// ease-out, while the lens window comes in under it; the pointer already belongs to what is underneath. Opacity only: the same under
    /// Reduce Motion (motion contract 3.5).
    func fade(in comingIn: Bool) {
        if comingIn { alphaValue = 0 } else { ignoresMouseEvents = true }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = comingIn ? 0.15 : 0.20
            ctx.timingFunction = comingIn ? CAMediaTimingFunction(name: .linear) : CAMediaTimingFunction(controlPoints: 0, 0, 0.58, 1)
            animator().alphaValue = comingIn ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { if !comingIn { self?.orderOut(nil) } }
        }
    }
}

/// The outline of the picker's spotlight, for its hole in the dim and for its stroke: today a rounded rect. The one place the lens's
/// organic outline (`LensSkin`, round skin117) replaces.
func pickerOutlinePath(rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
}

final class PickerView: NSView {
    private let screenFrame: NSRect
    private let windows: [WindowInfo]
    private let done: (RegionPicker.Result?) -> Void
    private var dragStart: NSPoint?
    private var dragCurrent: NSPoint?
    private var hovered: WindowInfo?
    private var pointer: NSPoint?
    private var tracking: NSTrackingArea?
    /// The lens being placed with the keyboard (view coordinates); nil until a key shows it, and again once the pointer takes over.
    private(set) var placement: KeyboardLens?

    private let readMap: PickerMap.Reader?
    /// This display's map (`PickerMap`).
    private(set) var map: PickerMap = .idle
    /// What the pointer aims at (global Quartz points); nil over no column, and until the map is there: the spotlight is the default lens.
    private(set) var target: LensTarget.Target?
    /// The spotlight's rect over time, in view coordinates (`LensTarget.Glide`), stepped by the display link while it moves.
    private var glide = LensTarget.Glide()
    private var link: CADisplayLink?
    /// The clock of the glide: the display link's (`CACurrentMediaTime`); the checks step their own.
    var clock: () -> TimeInterval = { CACurrentMediaTime() }

    /// Draws of the picker's views, for the checks: the spotlight moves its layers and its label's frame, and draws nothing while it glides.
    static var draws = 0

    private let shapes = PickerShapes()
    private let label = PickerPill(.label)
    private let hintPill = PickerPill(.hint), keysPill = PickerPill(.hint)

    init(screen: NSScreen, windows: [WindowInfo], readMap: PickerMap.Reader? = nil, done: @escaping (RegionPicker.Result?) -> Void) {
        self.screenFrame = screen.frame
        self.windows = windows
        self.readMap = readMap
        self.done = done
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
        wantsLayer = true
        shapes.frame = bounds
        shapes.autoresizingMask = [.width, .height]
        for v in [shapes, label, hintPill, keysPill] { addSubview(v) }
        hintPill.text = String(localized: "Drag an area or click  ·  ⌥ pins to the screen  ·  esc to cancel")
        keysPill.text = String(localized: "Arrow keys move  ·  ⇧ resizes  ·  ⌥ steps 1 pt  ·  ↩ places  ·  esc cancels")
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    // MARK: - Coordinates

    private func quartz(_ local: NSRect) -> CGRect {
        ScreenGeometry.quartzRect(fromAppKit: local.offsetBy(dx: screenFrame.minX, dy: screenFrame.minY))
    }

    private func local(_ quartzRect: CGRect) -> NSRect {
        ScreenGeometry.appKitRect(fromQuartz: quartzRect).offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
    }

    private var selection: NSRect? {
        guard let a = dragStart, let b = dragCurrent else { return nil }
        return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// The selection once the press has become a drag (4 pt): until then the spotlight stays what the click would place.
    private var dragged: NSRect? {
        guard let s = selection, max(s.width, s.height) >= 4 else { return nil }
        return s
    }

    /// ⌥ pins the lens to the screen.
    private var pinned: Bool { NSEvent.modifierFlags.contains(.option) }

    private func window(at p: NSPoint) -> WindowInfo? {
        let q = quartz(NSRect(origin: p, size: .zero)).origin
        return windows.first { $0.bounds.contains(q) }
    }

    /// The lens a click at `p` would drop where there is no target: a typical chat or comment column, kept inside the window's content and
    /// the screen (`LensTarget.ghost`).
    private func clickLens(at p: NSPoint) -> NSRect {
        LensTarget.ghost(at: p, window: hovered.map { local($0.bounds) }, in: bounds)
    }

    /// The target under `p` from this display's map, the anchor shown held; nil without a map.
    private func aim(_ p: NSPoint) -> LensTarget.Target? {
        guard case let .ready(m) = map else { return nil }
        let q = quartz(NSRect(origin: p, size: .zero)).origin
        return LensTarget.choose(m, pointer: q, held: target, bounds: LensTarget.content(of: hovered?.bounds, on: quartz(bounds)),
                                 scale: window?.backingScaleFactor ?? 2)
    }

    // MARK: - The map

    /// Starts this display's read, once per picker; the picker goes on as it is meanwhile (a click places the default lens).
    func startMap() {
        guard case .idle = map, let readMap else { return }
        let display = quartz(bounds)
        RegionPicker.stats.reads += 1
        Trace.count("picker.map.read")
        map = .reading(Task { [weak self] in
            let found = await readMap(display)
            self?.mapArrived(found)
        })
    }

    private func mapArrived(_ found: LensTarget.Map?) {
        guard case .reading = map else { return }
        if let found, found.readingColumns > 0 {
            map = .ready(found)
            RegionPicker.stats.maps += 1
        } else {
            map = .none
            RegionPicker.stats.empty += 1
        }
        if let p = pointer { aimAt(p) }
    }

    /// The picker is gone: a read under way is cancelled and the map dropped.
    func close() {
        if case let .reading(task) = map {
            task.cancel()
            RegionPicker.stats.cancelled += 1
            Trace.count("picker.map.cancelled")
        }
        map = .closed
        target = nil
        link?.invalidate()
        link = nil
        if Trace.enabled { Trace.mark("picker: closed \(RegionPicker.stats)", since: Trace.now) }
    }

    // MARK: - Events

    /// The spotlight goes to the target under `p`, or to the default lens there: between targets (and between a target and the default lens)
    /// it glides, and under the default lens it follows the pointer; under Reduce Motion it jumps.
    private func aimAt(_ p: NSPoint) {
        let aimed = aim(p)
        let now = clock()
        let how: LensTarget.Glide.Move = Motion.shared.reduced ? .jump : (aimed == nil && target == nil ? .follow : .glide)
        glide.move(to: aimed.map { local($0.rect) } ?? clickLens(at: p), at: now, how)
        if Trace.enabled, aimed?.anchor != target?.anchor || aimed?.column != target?.column {
            let r = aimed?.rect ?? .zero
            Trace.mark("picker: target " + (aimed.map { "column=\($0.column) anchor=\($0.anchor) rect=\(TraceNumber.px(r.minX)),\(TraceNumber.px(r.minY)) \(TraceNumber.px(r.width))x\(TraceNumber.px(r.height))" } ?? "none"), since: now)
        }
        if aimed != nil, aimed != target { Trace.count("picker.target.hit") }
        target = aimed
        render(at: now)
        if glide.moving(at: now), link == nil {
            link = displayLink(target: self, selector: #selector(frame(_:)))
            link?.add(to: .main, forMode: .common)
        }
    }

    @objc private func frame(_ link: CADisplayLink) {
        render(at: link.targetTimestamp)
        if !glide.moving(at: link.targetTimestamp) {
            link.invalidate()
            self.link = nil
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        startMap()
        hovered = window(at: p)
        pointer = p
        aimAt(p)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        pointer = nil
        target = nil
        glide.clear()
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        placement = nil   // the pointer takes over
        dragStart = convert(event.locationInWindow, from: nil)
        dragCurrent = dragStart
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        dragCurrent = convert(event.locationInWindow, from: nil)
        if dragged != nil { glide.clear() }   // the drag is the user's own rectangle: the spotlight goes
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragCurrent = nil }
        if let sel = selection, sel.width >= 24, sel.height >= 12 {
            let rect = quartz(sel)
            // A lens overhanging a window's edge still belongs to it: go by its centre.
            let container = windows.first { $0.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) }
            done(.init(rect: rect, window: pinned ? nil : container))
        } else {
            let p = convert(event.locationInWindow, from: nil)
            hovered = window(at: p)
            // The target the spotlight shows (its anchor held), else the default lens: the click never waits for the map.
            let aimed = aim(p)
            RegionPicker.stats.clickTarget += aimed == nil ? 0 : 1
            RegionPicker.stats.clickGhost += aimed == nil ? 1 : 0
            Trace.count(aimed == nil ? "picker.click.ghost" : "picker.click.target")
            done(.init(rect: aimed?.rect ?? quartz(clickLens(at: p)), window: pinned ? nil : hovered))
        }
    }

    override func rightMouseDown(with event: NSEvent) { done(nil) }

    // MARK: - Keyboard

    /// A key of the placement (`PlacementInput`). The first arrow or Return shows the default lens in the middle of the screen; after
    /// that the arrows move it, Return places it. With the pointer over a target and no keyboard lens, Return places the target, the way a
    /// click would. Returns whether the picker took the key.
    @discardableResult
    func handle(_ input: PlacementInput) -> Bool {
        switch input {
        case .engage:
            guard placement == nil else { return true }
            placement = KeyboardLens(bounds: bounds)
            announce(String(localized: "Lens at the center of the screen. Arrow keys move it, Shift resizes, Return places it, Escape cancels."))
        case let .move(key, resize, fine):
            guard placement != nil else { return handle(.engage) }
            // At an edge or a limit nothing moves: a beep says so.
            if placement?.press(key, resize: resize, fine: fine) == true {
                NSAccessibility.post(element: self, notification: .valueChanged)
            } else {
                NSSound.beep()
            }
        case .confirm:
            guard let lens = placement?.rect else {
                guard let aimed = target else { return handle(.engage) }
                announce(String(localized: "Lens added"))
                done(.init(rect: aimed.rect, window: pinned ? nil : hovered))
                return true
            }
            // The way a drag finishes: the lens follows the window under its centre, unless ⌥ pins it to the screen.
            let rect = quartz(lens)
            let container = windows.first { $0.bounds.contains(CGPoint(x: rect.midX, y: rect.midY)) }
            announce(String(localized: "Lens added"))
            done(.init(rect: rect, window: pinned ? nil : container))
        case .cancel:
            done(nil)
        }
        refresh()
        return true
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: - Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { String(localized: "Place a lens") }
    override func accessibilityHelp() -> String? { String(localized: "Drag an area or click  ·  ⌥ pins to the screen  ·  esc to cancel") }
    /// Where the lens is while it is placed with the keyboard, and what it will do; otherwise how to start.
    override func accessibilityValue() -> Any? {
        guard let r = placement?.rect else { return String(localized: "Or press an arrow key to place it with the keyboard") }
        let w = pinned ? nil : window(at: NSPoint(x: r.midX, y: r.midY))
        let spot = String(localized: "\(Int(r.width)) by \(Int(r.height)) points, \(Int(r.minX)) from the left, \(Int(bounds.height - r.maxY)) from the top")
        return "\(spot). \(mode(w))"
    }

    // MARK: - Drawing

    /// Puts the picture as it is now on screen.
    func refresh() { render(at: clock()) }

    /// The picture at time `t`: the dim with the spotlight's hole, its stroke, the outline of the window it follows and the label are layers and
    /// a small view that move; nothing redraws while the spotlight glides (a full-display redraw costs 15.7 ms: design first-lens 4.4).
    func render(at t: TimeInterval) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if let sel = dragged {
            let w = pinned ? nil : window(at: NSPoint(x: sel.midX, y: sel.midY))
            shapes.show(hole: CGPath(roundedRect: sel, cornerWidth: 4, cornerHeight: 4, transform: nil),
                        stroke: CGPath(roundedRect: sel.insetBy(dx: -0.75, dy: -0.75), cornerWidth: 4, cornerHeight: 4, transform: nil),
                        color: .white, width: 1.5, window: w.map { local($0.bounds) })
            label.show("\(Int(sel.width)) × \(Int(sel.height))  ·  \(mode(w))", near: sel, inside: false)
        } else if let r = placement?.rect {
            let w = pinned ? nil : window(at: NSPoint(x: r.midX, y: r.midY))
            shapes.show(hole: pickerOutlinePath(rect: r), stroke: pickerOutlinePath(rect: r.insetBy(dx: -1.5, dy: -1.5)),
                        color: .controlAccentColor, width: 3, window: w.map { local($0.bounds) })
            label.show("\(Int(r.width)) × \(Int(r.height))  ·  \(mode(w))", near: r, inside: false)
        } else if pointer != nil, let r = glide.rect(at: t) {
            let w = pinned ? nil : hovered
            shapes.show(hole: pickerOutlinePath(rect: r), stroke: pickerOutlinePath(rect: r.insetBy(dx: -1.5, dy: -1.5)),
                        color: .controlAccentColor, width: 3, window: w.map { local($0.bounds) })
            label.show(mode(w), near: r, inside: true)
        } else {
            shapes.show(hole: nil, stroke: nil, color: .controlAccentColor, width: 3, window: nil)
            label.isHidden = true
        }
        shapes.dim(bounds)
        // The hint, on the screen with the pointer; the keyboard's keys under it only once the keyboard is in use: the pointer's picker
        // looks as it always did. How to start by keyboard is in the accessibility value and is announced, not drawn.
        hintPill.isHidden = !(screenFrame.contains(NSEvent.mouseLocation) || NSScreen.screens.count == 1)
        keysPill.isHidden = hintPill.isHidden || placement == nil
        hintPill.setFrameOrigin(NSPoint(x: (bounds.midX - hintPill.frame.width / 2).rounded(), y: bounds.maxY - 120 - PickerPill.shadowRoom))
        keysPill.setFrameOrigin(NSPoint(x: (bounds.midX - keysPill.frame.width / 2).rounded(), y: bounds.maxY - 164 - PickerPill.shadowRoom))
    }

    /// The spotlight as it is now (view coordinates), for the checks: nil while there is none.
    var spotlight: CGRect? { shapes.hole?.boundingBoxOfPath }

    /// Animations running on the picker's layers, for the checks (none: every change is set with actions off, and the glide is stepped).
    var runningAnimations: Int { shapes.runningAnimations }

    /// Whether the spotlight is gliding at the picker's clock (the display link steps it only then, and stops at its next frame after).
    var gliding: Bool { glide.moving(at: clock()) }

    /// What the lens will do once placed.
    private func mode(_ w: WindowInfo?) -> String {
        guard let w else { return String(localized: "Pinned to the screen") }
        let app = w.appName.isEmpty ? String(localized: "Window") : w.appName
        return String(localized: "Follows \(app)  ·  ⌥ pins to the screen")
    }
}

/// The picker's shapes: the 0.32 black dim with the spotlight's hole (even-odd), the outline of the window the lens will follow (under the
/// dim's hole, as the punched drawing had it), and the spotlight's stroke. A layer-hosting view: its layers are this app's own, set with
/// actions off, and a change of path costs microseconds where a redraw of the display cost a frame.
private final class PickerShapes: NSView {
    private let dimLayer = CAShapeLayer(), outline = CAShapeLayer(), outlineMask = CAShapeLayer(), ring = CAShapeLayer()
    private(set) var hole: CGPath?

    init() {
        super.init(frame: .zero)
        layer = CALayer()
        wantsLayer = true
        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.32).cgColor
        outlineMask.fillRule = .evenOdd
        outline.mask = outlineMask
        for l in [outline, ring] { l.fillColor = nil }
        outline.lineWidth = 1.5
        for l in [dimLayer, outline, ring] { layer?.addSublayer(l) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        for l in [dimLayer, outline, outlineMask, ring] { l.frame = bounds }
    }

    func show(hole: CGPath?, stroke: CGPath?, color: NSColor, width: CGFloat, window: CGRect?) {
        self.hole = hole
        ring.path = stroke
        ring.strokeColor = color.cgColor
        ring.lineWidth = width
        outline.path = window.map { CGPath(roundedRect: $0.insetBy(dx: -0.75, dy: -0.75), cornerWidth: 10, cornerHeight: 10, transform: nil) }
        outline.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.5).cgColor
    }

    /// The dim over `bounds` with the hole punched; the window's outline is masked by the same shape.
    func dim(_ bounds: CGRect) {
        let p = CGMutablePath()
        p.addRect(bounds)
        if let hole { p.addPath(hole) }
        dimLayer.path = p
        outlineMask.path = p
    }

    var runningAnimations: Int { [dimLayer, outline, outlineMask, ring].reduce(0) { $0 + ($1.animationKeys()?.count ?? 0) } }
}

/// A pill of white text: the spotlight's label (what the lens will do) or one of the hints. A small view that draws only when its text
/// changes; moving it is a change of frame. It hosts its own layer and draws through it: a layer-backed view is drawn again on every
/// move of its frame (measured: one draw per `setFrameOrigin`), a hosted layer only on `setNeedsDisplay` or a new size.
private final class PickerPill: NSView, CALayerDelegate {
    enum Style { case label, hint }
    /// The hint's shadow is drawn inside the view: this much room on every side.
    static let shadowRoom: CGFloat = 14
    private let style: Style

    init(_ style: Style) {
        self.style = style
        super.init(frame: .zero)
        let pill = CALayer()
        pill.delegate = self
        pill.needsDisplayOnBoundsChange = true
        layer = pill
        wantsLayer = true
        isHidden = style == .label
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        layer?.setNeedsDisplay()
    }

    var text = "" {
        didSet {
            guard text != oldValue else { return }
            let size = attributed.size()
            let room = style == .hint ? Self.shadowRoom : 0
            let pad = style == .hint ? NSSize(width: 32, height: 16) : NSSize(width: 16, height: 8)
            setFrameSize(NSSize(width: (size.width + pad.width + 2 * room).rounded(.up), height: (size.height + pad.height + 2 * room).rounded(.up)))
            layer?.setNeedsDisplay()
        }
    }

    private var attributed: NSAttributedString {
        NSAttributedString(string: text, attributes: style == .hint
            ? [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor.white]
            : [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white])
    }

    /// Shows `text` by `r`: inside it at the top centre, or outside under its right end (above its bottom when that is off the screen).
    func show(_ text: String, near r: NSRect, inside: Bool) {
        self.text = text
        isHidden = false
        let pill = frame.size
        var origin = inside ? NSPoint(x: r.midX - pill.width / 2, y: r.maxY - pill.height - 12) : NSPoint(x: r.maxX - pill.width, y: r.minY - pill.height - 8)
        if origin.y < 4 { origin.y = r.minY + 8 }
        setFrameOrigin(origin)
    }

    /// The hosted layer's actions are none: the pill moves with the spotlight's steps, never on an animation of its own.
    func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }

    func draw(_ layer: CALayer, in ctx: CGContext) {
        PickerView.draws += 1
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let s = attributed
        switch style {
        case .label:
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
            s.draw(at: NSPoint(x: bounds.minX + 8, y: bounds.minY + 4))
        case .hint:
            let pill = bounds.insetBy(dx: Self.shadowRoom, dy: Self.shadowRoom)
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 12
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            NSColor(white: 0.12, alpha: 0.88).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
            s.draw(at: NSPoint(x: pill.minX + 16, y: pill.minY + 8))
        }
    }
}
