import AppKit
import MwoyeoCore
import QuartzCore

/// The whole screen in the target language while a shortcut is held (`HotKeyAction.peek`): one picture of the display under the pointer, read,
/// erased and translated as a lens does it (`RegionPipeline`, seamless), drawn over the display; let go, it is gone. Nothing follows the screen
/// while it is held: the picture is the moment the key went down.
///
/// The lens's queue translates a few lines at a time so that a moving lens is served first; here nothing moves and every line is wanted at once,
/// so the queue takes them in one batch (`PipelineOptions.translationBatch`).
///
/// A read of a whole display takes about two seconds. Meanwhile a band of light sweeps down the screen (`Beam`); once most of the screen is
/// translated, one last sweep writes it in: the translations show above the band and the original below (`Reveal`). Under Reduce Motion there is
/// no band and the translations fade in.
///
/// X-ray (`HotKeyAction.xray`) reads the same way and shows the translations only inside a circle that follows the pointer (`Lens`), the rest
/// of the screen as it is: the ring is there at once, and the translations come into it as they land.
@MainActor
final class Peek {
    enum Style { case screen, xray }

    /// Lines per engine call: every block of a screen of text in one or two calls.
    static let batch = 64
    /// Seconds of one sweep down the display.
    static let sweep: CFTimeInterval = 1.0
    static let revealSweep: CFTimeInterval = 0.7
    /// The reveal starts once this share of the blocks is drawn, or this long after the first one was.
    static let revealShare = 0.6
    static let revealWait: TimeInterval = 0.8
    /// Nothing drawn this long after the key went down: the line under the top of the screen says why, when the app knows (`Note`).
    static let noteAfter: TimeInterval = 2.5

    private var pipeline: RegionPipeline?
    private var panel: OverlayPanel?
    private var beam: Beam?
    private var xray: XRay?
    private var task: Task<Void, Never>?
    private var revealTask: Task<Void, Never>?
    private var noteTask: Task<Void, Never>?
    private var note: Note?
    private var revealed = false
    private(set) var holding = false

    /// The key went down: read and translate the display under the pointer.
    /// `preparing`: the text recognizer is still in its first-time setup (`AppModel.recognitionPreparing`).
    func begin(_ style: Style, settings: AppSettings, translator: TranslationService, inpainter: Inpainter?, preparing: @escaping () -> Bool) {
        guard !holding else { return }
        holding = true
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let display = ScreenGeometry.quartzRect(fromAppKit: screen.frame)
        Trace.count("peek.begin")
        Trace.mark("peek: begin \(style) display=\(TraceNumber.px(display.width))x\(TraceNumber.px(display.height))", since: Trace.now)
        let panel = OverlayPanel(frame: screen.frame)
        self.panel = panel
        revealed = false
        let reduced = Motion.shared.reduced
        switch style {
        case .xray: xray = XRay(panel: panel)
        case .screen: if reduced { panel.alphaValue = 0 } else { Reveal.cover(panel) }
        }
        var options = PipelineOptions(settings)
        options.renderMode = .seamless
        options.translationBatch = Self.batch
        let pipeline = RegionPipeline(options: options, capture: display, translator: translator, inpainter: inpainter, onSnapshot: { [weak self] snapshot in
            Task { @MainActor in self?.shown(snapshot) }
        })
        self.pipeline = pipeline
        panel.orderFrontRegardless()
        if style == .screen, !reduced {
            let beam = Beam(frame: screen.frame)
            self.beam = beam
            beam.scan(period: Self.sweep)
        }
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noteAfter))
            guard !Task.isCancelled, let self, !revealed, xray?.hasTranslation != true, preparing() else { return }
            say(.preparingRecognition, on: screen.frame)
        }
        task = Task { [weak self] in
            let t = Trace.now
            guard let (image, scale) = try? await RegionCapturer.snapshot(of: display), !Task.isCancelled,
                  let frame = Self.frame(image, scale: scale, display: display) else {
                Trace.mark("peek: no picture", since: t)
                // No picture of the display: screen recording is not allowed (or the display went away while the key was down).
                if !Task.isCancelled { self?.say(.allowScreenRecording, on: screen.frame) }
                return
            }
            Trace.mark("peek: picture", since: t)
            await pipeline.ingest(frame)
        }
    }

    /// The key went up: the translations fade and the reading stops.
    func end() {
        guard holding else { return }
        holding = false
        task?.cancel()
        task = nil
        revealTask?.cancel()
        revealTask = nil
        noteTask?.cancel()
        noteTask = nil
        note?.close()
        note = nil
        if let pipeline { Task { await pipeline.halt() } }
        pipeline = nil
        beam?.close()
        beam = nil
        xray?.close()
        xray = nil
        guard let panel else { return }
        self.panel = nil
        Trace.mark("peek: end", since: Trace.now)
        panel.setTranslationsVisible(false, animated: true)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            panel.orderOut(nil)
        }
    }

    private func say(_ hint: LensHint, on screen: NSRect) {
        guard holding, note == nil else { return }
        Trace.mark("peek: note \(hint)", since: Trace.now)
        note = Note(LensHintText.line(hint), on: screen)
    }

    private func shown(_ snapshot: OverlaySnapshot) {
        guard let panel else { return }
        panel.apply(snapshot)
        if !snapshot.blocks.isEmpty, let note {
            note.close()
            self.note = nil
        }
        if let xray, !snapshot.blocks.isEmpty { xray.translated() }
        guard xray == nil, !revealed, !snapshot.blocks.isEmpty else { return }
        if Double(snapshot.blocks.count) >= Self.revealShare * Double(max(1, snapshot.texts.count)) {
            reveal()
        } else if revealTask == nil {
            revealTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.revealWait))
                guard !Task.isCancelled else { return }
                self?.reveal()
            }
        }
    }

    private func reveal() {
        guard !revealed, let panel else { return }
        revealed = true
        revealTask?.cancel()
        revealTask = nil
        Trace.mark("peek: reveal", since: Trace.now)
        Trace.count("peek.reveal")
        guard let beam else {
            panel.setTranslationsVisible(true, animated: true)
            return
        }
        Reveal.uncover(panel, duration: Self.revealSweep)
        beam.last(duration: Self.revealSweep)
    }

    private nonisolated static func frame(_ image: CGImage, scale: CGFloat, display: CGRect) -> CapturedFrame? {
        guard let rgba = RGBAImage(cgImage: image), let image = rgba.cgImage else { return nil }
        let gray = rgba.withBGRA { GrayImage(bgra: $0, width: rgba.width, height: rgba.height, bytesPerRow: rgba.width * 4, step: 4) }
        return CapturedFrame(image: image, gray: gray, grayStep: 4, scale: scale, rect: display, time: ProcessInfo.processInfo.systemUptime)
    }

    /// The translations are written in from the top: a mask on the panel, opaque above an edge that moves down the display and clear below it,
    /// with a soft feather where the band of light is.
    enum Reveal {
        static let feather = 0.08

        static func cover(_ panel: NSPanel) {
            guard let root = panel.contentView else { return }
            root.wantsLayer = true
            let mask = CAGradientLayer()
            mask.frame = root.bounds
            // The view is not flipped: y 1 is the top of the display.
            mask.startPoint = CGPoint(x: 0.5, y: 1)
            mask.endPoint = CGPoint(x: 0.5, y: 0)
            mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor, NSColor.clear.cgColor]
            mask.locations = locations(edge: 0)
            root.layer?.mask = mask
        }

        static func uncover(_ panel: NSPanel, duration: CFTimeInterval) {
            guard let mask = panel.contentView?.layer?.mask as? CAGradientLayer else { return }
            let end = locations(edge: 1 + feather)
            let a = CABasicAnimation(keyPath: "locations")
            a.fromValue = mask.locations
            a.toValue = end
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak panel] in panel?.contentView?.layer?.mask = nil }
            mask.locations = end
            mask.add(a, forKey: "reveal")
            CATransaction.commit()
        }

        /// The gradient's stops for an edge at `edge` (0 top, 1 bottom): opaque down to the feather, clear from the edge.
        static func locations(edge: Double) -> [NSNumber] {
            [0, edge - feather, edge, max(1, edge + 0.001)].map { NSNumber(value: $0) }
        }
    }

    /// The x-ray: the panel masked to a circle at the pointer, soft at its edge, with a ring in the accent colour around it (a click-through
    /// window over the panel). The circle follows the pointer every display frame; the ring breathes until the first translation lands.
    @MainActor final class XRay {
        static let radius: CGFloat = 190
        static let feather: CGFloat = 0.12
        private weak var panel: NSPanel?
        private let mask = CAGradientLayer()
        private let ringWindow: NSPanel
        private let ring = CAShapeLayer()
        private var timer: Timer?

        init(panel: NSPanel) {
            self.panel = panel
            let r = Self.radius
            mask.type = .radial
            mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            mask.locations = [0, NSNumber(value: Double(1 - Self.feather)), 1]
            mask.startPoint = CGPoint(x: 0.5, y: 0.5)
            mask.endPoint = CGPoint(x: 1, y: 1)
            mask.frame = CGRect(x: 0, y: 0, width: 2 * r, height: 2 * r)
            if let root = panel.contentView {
                root.wantsLayer = true
                root.layer?.mask = mask
            }
            let w = NSPanel(contentRect: panel.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
            view.wantsLayer = true
            w.contentView = view
            ringWindow = w
            ring.path = CGPath(ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
            ring.fillColor = nil
            ring.lineWidth = 3
            w.effectiveAppearance.performAsCurrentDrawingAppearance {
                ring.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
                ring.shadowColor = NSColor.controlAccentColor.cgColor
            }
            ring.shadowRadius = 8
            ring.shadowOpacity = 0.6
            ring.shadowOffset = .zero
            view.layer?.addSublayer(ring)
            follow()
            w.orderFrontRegardless()
            if !Motion.shared.reduced {
                let a = CABasicAnimation(keyPath: "opacity")
                a.fromValue = 1
                a.toValue = 0.35
                a.duration = 0.5
                a.autoreverses = true
                a.repeatCount = .infinity
                ring.add(a, forKey: "breathe")
            }
            let t = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.follow() } }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }

        private(set) var hasTranslation = false

        /// A translation is in: the ring stops breathing.
        func translated() {
            hasTranslation = true
            guard ring.animation(forKey: "breathe") != nil else { return }
            ring.removeAnimation(forKey: "breathe")
            Trace.mark("peek: xray translated", since: Trace.now)
        }

        func close() {
            timer?.invalidate()
            timer = nil
            ringWindow.orderOut(nil)
        }

        /// The circle and the ring where the pointer is, in the panel's (unflipped) view coordinates.
        private func follow() {
            guard let panel else { return }
            let p = NSEvent.mouseLocation
            let local = CGPoint(x: p.x - panel.frame.minX, y: p.y - panel.frame.minY)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.position = local
            ring.position = local
            CATransaction.commit()
        }
    }

    /// Why nothing shows yet, in a pill near the top of the display: the lens hint's words (`LensHintText`), as a lens's pill says them.
    @MainActor final class Note {
        private let window: NSPanel

        init(_ text: String, on screen: NSRect) {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textColor = .labelColor
            label.sizeToFit()
            let size = NSSize(width: label.frame.width + 28, height: 30)
            let frame = NSRect(x: screen.midX - size.width / 2, y: screen.maxY - 80 - size.height, width: size.width, height: size.height)
            let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = true
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let pill = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
            pill.material = .hudWindow
            pill.state = .active
            pill.wantsLayer = true
            pill.layer?.cornerRadius = size.height / 2
            pill.layer?.masksToBounds = true
            label.frame.origin = NSPoint(x: 14, y: (size.height - label.frame.height) / 2)
            pill.addSubview(label)
            w.contentView = pill
            window = w
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = LensMotion.seconds(LensMotion.guideFade, reduced: Motion.shared.reduced)
                w.animator().alphaValue = 1
            }
        }

        func close() { window.orderOut(nil) }
    }

    /// A band of light in the accent colour that sweeps down the display while it is read, over the panel and click-through.
    @MainActor final class Beam {
        static let height: CGFloat = 120
        private let window: NSPanel
        private let band = CAGradientLayer()
        private let line = CALayer()

        init(frame: NSRect) {
            let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            w.contentView = view
            window = w
            let accent = NSColor.controlAccentColor
            var colors: [CGColor] = []
            w.effectiveAppearance.performAsCurrentDrawingAppearance {
                colors = [accent.withAlphaComponent(0).cgColor, accent.withAlphaComponent(0.16).cgColor, accent.withAlphaComponent(0.30).cgColor]
                line.backgroundColor = accent.withAlphaComponent(0.85).cgColor
            }
            // The band trails above its leading line, which is at the bottom of the band (the sweep goes down).
            band.colors = colors
            band.locations = [0, 0.75, 1]
            band.startPoint = CGPoint(x: 0.5, y: 1)
            band.endPoint = CGPoint(x: 0.5, y: 0)
            band.frame = CGRect(x: 0, y: 0, width: frame.width, height: Self.height)
            band.anchorPoint = CGPoint(x: 0.5, y: 0)
            line.frame = CGRect(x: 0, y: 0, width: frame.width, height: 2)
            band.addSublayer(line)
            view.layer?.addSublayer(band)
            band.position = CGPoint(x: frame.width / 2, y: frame.height)
            w.orderFrontRegardless()
        }

        private var top: CGFloat { window.frame.height }

        /// Sweeps down again and again until `last` or `close`.
        func scan(period: CFTimeInterval) {
            let a = sweep(duration: period, timing: .linear)
            a.repeatCount = .infinity
            band.add(a, forKey: "scan")
        }

        /// One last sweep, with the reveal's edge, then the band fades.
        func last(duration: CFTimeInterval) {
            band.removeAnimation(forKey: "scan")
            let a = sweep(duration: duration, timing: .easeInEaseOut)
            a.fillMode = .forwards
            a.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    self?.window.animator().alphaValue = 0
                }
            }
            band.add(a, forKey: "last")
            CATransaction.commit()
        }

        func close() { window.orderOut(nil) }

        /// The band's leading line from the top of the display to past its bottom, the band behind it.
        private func sweep(duration: CFTimeInterval, timing: CAMediaTimingFunctionName) -> CABasicAnimation {
            let a = CABasicAnimation(keyPath: "position.y")
            a.fromValue = top
            a.toValue = -Self.height * 0.1
            a.duration = duration
            a.timingFunction = CAMediaTimingFunction(name: timing)
            return a
        }
    }
}
