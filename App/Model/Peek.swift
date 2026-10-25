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
/// A read of a whole display takes about two seconds. Meanwhile a thin frame in the lens's colours turns round the display (`Glow`). Once the
/// paragraphs are found, each is outlined the way a reading lens is, drawn on in reading order (`Glow.outline`), and each turns into its
/// translation as that lands (`Bloom`), its outline fading. Under Reduce Motion nothing turns or draws on: the outlines and the translations
/// fade in.
@MainActor
final class Peek {
    /// Lines per engine call: every block of a screen of text in one or two calls.
    static let batch = 64
    /// Seconds an outline takes to draw itself on, and the most the last one starts after the first (reading order).
    static let draw: CFTimeInterval = 0.35
    static let stagger: CFTimeInterval = 0.4
    /// Seconds a paragraph takes to turn into its translation, and its outline to fade.
    static let turn: CFTimeInterval = 0.3
    /// An outline whose paragraph has no translation this long after the first one turned (text already in the target language, code) fades.
    static let linger: TimeInterval = 1.2
    /// Nothing drawn this long after the key went down: the line under the top of the screen says why, when the app knows (`Note`).
    static let noteAfter: TimeInterval = 2.5

    private var pipeline: RegionPipeline?
    private var panel: OverlayPanel?
    private var glow: Glow?
    private var bloom: Bloom?
    private var task: Task<Void, Never>?
    private var noteTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?
    private var note: Note?
    private var outlined = false
    private var revealed = false
    private(set) var holding = false

    /// The key went down: read and translate the display under the pointer.
    /// `preparing`: the text recognizer is still in its first-time setup (`AppModel.recognitionPreparing`).
    func begin(settings: AppSettings, translator: TranslationService, inpainter: Inpainter?, preparing: @escaping () -> Bool) {
        guard !holding else { return }
        holding = true
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let display = ScreenGeometry.quartzRect(fromAppKit: screen.frame)
        Trace.count("peek.begin")
        Trace.mark("peek: begin display=\(TraceNumber.px(display.width))x\(TraceNumber.px(display.height))", since: Trace.now)
        let panel = OverlayPanel(frame: screen.frame)
        self.panel = panel
        outlined = false
        revealed = false
        bloom = Bloom(panel)
        var options = PipelineOptions(settings)
        options.renderMode = .seamless
        options.translationBatch = Self.batch
        let pipeline = RegionPipeline(options: options, capture: display, translator: translator, inpainter: inpainter, onSnapshot: { [weak self] snapshot in
            Task { @MainActor in self?.shown(snapshot) }
        })
        self.pipeline = pipeline
        let origin = display.origin
        Task { await pipeline.setFoundHandler { [weak self] rects in Task { @MainActor in self?.found(rects, origin: origin) } } }
        panel.orderFrontRegardless()
        glow = Glow(frame: screen.frame, colors: settings.lensTint.colors)
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.noteAfter))
            guard !Task.isCancelled, let self, !revealed, preparing() else { return }
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
        noteTask?.cancel()
        noteTask = nil
        lingerTask?.cancel()
        lingerTask = nil
        note?.close()
        note = nil
        if let pipeline { Task { await pipeline.halt() } }
        pipeline = nil
        glow?.close()
        glow = nil
        bloom = nil
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
        guard let panel, let bloom else { return }
        panel.apply(snapshot)
        guard !snapshot.blocks.isEmpty else { return }
        if let note {
            note.close()
            self.note = nil
        }
        glow?.turned(bloom.add(snapshot))
        guard !revealed else { return }
        revealed = true
        Trace.mark("peek: reveal", since: Trace.now)
        Trace.count("peek.reveal")
        glow?.settle()
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.linger))
            guard !Task.isCancelled else { return }
            self?.glow?.turned(nil)
        }
    }

    /// The read found the paragraphs to translate (capture-local points from `origin`): each is outlined while they are erased and drawn.
    private func found(_ rects: [CGRect], origin: CGPoint) {
        guard let panel, !outlined, !rects.isEmpty else { return }
        outlined = true
        Trace.mark("peek: outlines \(rects.count)", since: Trace.now)
        glow?.outline(rects.map { Self.local($0, from: origin, in: panel) })
    }

    /// A frame of `snapshot` (top-left points from its origin, global Quartz) in `panel`'s view (AppKit points, y up).
    static func local(_ frame: CGRect, of snapshot: OverlaySnapshot, in panel: NSPanel) -> CGRect {
        local(frame, from: snapshot.origin, in: panel)
    }

    static func local(_ frame: CGRect, from origin: CGPoint, in panel: NSPanel) -> CGRect {
        let here = ScreenGeometry.quartzRect(fromAppKit: panel.frame).origin
        let dx = origin.x - here.x, dy = origin.y - here.y
        return CGRect(x: dx + frame.minX, y: panel.frame.height - (dy + frame.maxY), width: frame.width, height: frame.height)
    }

    private nonisolated static func frame(_ image: CGImage, scale: CGFloat, display: CGRect) -> CapturedFrame? {
        guard let rgba = RGBAImage(cgImage: image), let image = rgba.cgImage else { return nil }
        let gray = rgba.withBGRA { GrayImage(bgra: $0, width: rgba.width, height: rgba.height, bytesPerRow: rgba.width * 4, step: 4) }
        return CapturedFrame(image: image, gray: gray, grayStep: 4, scale: scale, rect: display, time: ProcessInfo.processInfo.systemUptime)
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

    /// The lens's colours (`LensTint.colors`) turning round the display: a conic gradient seen through a mask. The mask holds a thin soft frame along
    /// the display's edges, which says the key is down, and the outline of every paragraph found, drawn as a reading lens's (`LensRing`): a line
    /// and a faint wider one. An outline fades when its paragraph turns.
    @MainActor final class Glow {
        /// Points from the display's edge the frame's band reaches; the depths below are shares of it.
        static let depth: CGFloat = 60
        static let reading = 0.5, breath = 0.3, thin = 0.12
        static let period: CFTimeInterval = 3
        /// Points between a paragraph and its outline, and the outline's corner radius.
        static let pad: CGFloat = 5
        static let corner: CGFloat = 8
        private let window: NSPanel
        private let spin = CAGradientLayer()
        private let mask = CALayer()
        private var edges: [CAGradientLayer] = []
        private var outlines: [(rect: CGRect, layers: [CAShapeLayer])] = []

        init(frame: NSRect, colors: [NSColor]) {
            let w = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.isReleasedWhenClosed = false
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let size = frame.size
            let view = NSView(frame: NSRect(origin: .zero, size: size))
            view.wantsLayer = true
            w.contentView = view
            window = w
            // A square as wide as the display's diagonal, so it covers the display at every angle while it turns.
            let side = hypot(size.width, size.height)
            spin.type = .conic
            spin.colors = colors.map(\.cgColor)
            spin.startPoint = CGPoint(x: 0.5, y: 0.5)
            spin.endPoint = CGPoint(x: 0.5, y: 0)
            spin.frame = CGRect(x: (size.width - side) / 2, y: (size.height - side) / 2, width: side, height: side)
            let host = CALayer()
            host.frame = CGRect(origin: .zero, size: size)
            host.addSublayer(spin)
            mask.frame = host.bounds
            host.mask = mask
            view.layer?.addSublayer(host)
            let d = Self.depth
            // The view is not flipped: y 0 is the bottom of the display. Each band is opaque at the edge and clear inward.
            for (rect, from, to) in [(CGRect(x: 0, y: size.height - d, width: size.width, height: d), CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0)),
                                     (CGRect(x: 0, y: 0, width: size.width, height: d), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)),
                                     (CGRect(x: 0, y: 0, width: d, height: size.height), CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5)),
                                     (CGRect(x: size.width - d, y: 0, width: d, height: size.height), CGPoint(x: 1, y: 0.5), CGPoint(x: 0, y: 0.5))] {
                let band = CAGradientLayer()
                band.frame = rect
                band.startPoint = from
                band.endPoint = to
                band.colors = [NSColor.black.cgColor, NSColor.black.withAlphaComponent(0.35).cgColor, NSColor.clear.cgColor]
                band.locations = Self.stops(Motion.shared.reduced ? Self.reading : 0)
                mask.addSublayer(band)
                edges.append(band)
            }
            w.orderFrontRegardless()
            if Motion.shared.reduced {
                w.alphaValue = 0
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    w.animator().alphaValue = 1
                }
                return
            }
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = 0
            turn.toValue = -2 * Double.pi
            turn.duration = Self.period
            turn.repeatCount = .infinity
            spin.add(turn, forKey: "turn")
            let swell = CABasicAnimation(keyPath: "locations")
            swell.fromValue = Self.stops(0)
            swell.toValue = Self.stops(Self.reading)
            swell.duration = 0.3
            swell.timingFunction = CAMediaTimingFunction(name: .easeOut)
            let breathe = CABasicAnimation(keyPath: "locations")
            breathe.fromValue = Self.stops(Self.reading)
            breathe.toValue = Self.stops(Self.breath)
            breathe.beginTime = 0.3
            breathe.duration = 0.8
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let group = CAAnimationGroup()
            group.animations = [swell, breathe]
            group.duration = .infinity
            set(Self.stops(Self.reading))
            for band in edges { band.add(group, forKey: "breathe") }
        }

        /// Outlines the paragraphs found (panel-local points), each drawn on in reading order: top to bottom, then left to right.
        func outline(_ rects: [CGRect]) {
            let order = rects.sorted { ($0.maxY, -$0.minX) > ($1.maxY, -$1.minX) }
            let step = order.count > 1 ? min(0.03, Peek.stagger / Double(order.count - 1)) : 0
            let reduced = Motion.shared.reduced
            let now = CACurrentMediaTime()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for (i, rect) in order.enumerated() {
                let path = CGPath(roundedRect: rect.insetBy(dx: -Self.pad, dy: -Self.pad), cornerWidth: Self.corner, cornerHeight: Self.corner, transform: nil)
                var layers: [CAShapeLayer] = []
                for (width, alpha) in [(CGFloat(6), 0.3), (2, 1.0)] {
                    let line = CAShapeLayer()
                    line.path = path
                    line.fillColor = nil
                    line.strokeColor = NSColor.black.withAlphaComponent(alpha).cgColor
                    line.lineWidth = width
                    let on = CABasicAnimation(keyPath: reduced ? "opacity" : "strokeEnd")
                    on.fromValue = 0
                    on.toValue = 1
                    on.duration = reduced ? 0.2 : Peek.draw
                    on.beginTime = now + Double(i) * step
                    on.fillMode = .backwards
                    on.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    mask.addSublayer(line)
                    line.add(on, forKey: "on")
                    layers.append(line)
                }
                outlines.append((rect, layers))
            }
            CATransaction.commit()
        }

        /// Paragraphs that turned (panel-local points): their outlines fade. Nil: every outline left fades.
        func turned(_ rects: [CGRect]?) {
            var gone: [CAShapeLayer] = []
            outlines.removeAll { o in
                guard rects?.contains(where: { o.rect.contains(CGPoint(x: $0.midX, y: $0.midY)) || $0.contains(CGPoint(x: o.rect.midX, y: o.rect.midY)) }) ?? true else {
                    return false
                }
                gone += o.layers
                return true
            }
            guard !gone.isEmpty else { return }
            CATransaction.begin()
            CATransaction.setAnimationDuration(Peek.turn)
            CATransaction.setCompletionBlock { gone.forEach { $0.removeFromSuperlayer() } }
            for line in gone {
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = line.presentation()?.opacity ?? 1
                fade.toValue = 0
                line.opacity = 0
                line.add(fade, forKey: "off")
            }
            CATransaction.commit()
        }

        /// The first paragraph turned: the frame thins for as long as the key is held.
        func settle() {
            let end = Self.stops(Self.thin)
            guard !Motion.shared.reduced else { return set(end) }
            let thin = CABasicAnimation(keyPath: "locations")
            thin.fromValue = edges.first?.presentation()?.locations ?? Self.stops(Self.reading)
            thin.toValue = end
            thin.duration = 0.5
            thin.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            set(end)
            for band in edges {
                band.removeAnimation(forKey: "breathe")
                band.add(thin, forKey: "settle")
            }
        }

        func close() {
            let w = window
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                w.animator().alphaValue = 0
            }, completionHandler: { w.orderOut(nil) })
        }

        private func set(_ locations: [NSNumber]) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for band in edges { band.locations = locations }
            CATransaction.commit()
        }

        /// A band `share` of `depth` deep: opaque at the edge, 35 % a fifth of the way in, clear at the end.
        static func stops(_ share: Double) -> [NSNumber] {
            [0, share * 0.2, max(share, 0.001)].map { NSNumber(value: $0) }
        }
    }

    /// The panel seen through a mask of one soft rounded rect per drawn paragraph: nothing shows until a paragraph's translation is drawn, then
    /// that paragraph turns (fading in, and growing from 97 % unless Reduce Motion is on).
    @MainActor final class Bloom {
        private weak var panel: NSPanel?
        private let mask = CALayer()
        private var shown: Set<UUID> = []

        init(_ panel: NSPanel) {
            self.panel = panel
            guard let root = panel.contentView else { return }
            root.wantsLayer = true
            mask.frame = root.bounds
            root.layer?.mask = mask
        }

        /// Turns the paragraphs of `snapshot` drawn for the first time; returns them (panel-local points).
        func add(_ snapshot: OverlaySnapshot) -> [CGRect] {
            guard let panel else { return [] }
            let new = snapshot.blocks.filter { !shown.contains($0.id) }
            guard !new.isEmpty else { return [] }
            let reduced = Motion.shared.reduced
            let pad = Glow.pad
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let rects = new.map { b in
                shown.insert(b.id)
                let rect = Peek.local(b.frame, of: snapshot, in: panel)
                let l = CALayer()
                l.frame = rect.insetBy(dx: -pad, dy: -pad)
                l.cornerRadius = Glow.corner
                l.backgroundColor = NSColor.black.cgColor
                let fade = CABasicAnimation(keyPath: "opacity")
                fade.fromValue = 0
                fade.toValue = 1
                let grow = CABasicAnimation(keyPath: "transform.scale")
                grow.fromValue = reduced ? 1 : 0.97
                grow.toValue = 1
                let group = CAAnimationGroup()
                group.animations = [fade, grow]
                group.duration = Peek.turn
                group.timingFunction = CAMediaTimingFunction(name: .easeOut)
                mask.addSublayer(l)
                l.add(group, forKey: "turn")
                return rect
            }
            CATransaction.commit()
            return rects
        }
    }
}
